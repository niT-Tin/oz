const std = @import("std");
const git = @import("../git.zig");

// ---- M3a git: async job plumbing (types live at file scope so the worker
// thread functions — which are NOT App methods — can reference them) ----

pub const GitJobKind = enum { status, blame, apply };
pub const GitApplyOp = enum { stage, reset };

/// A git job requested while the single job slot was busy — re-spawned
/// verbatim when the slot frees (path owned).
pub const QueuedGitJob = struct {
    kind: GitJobKind,
    path: []u8, // owned
    hunk_start: u32,
    op: GitApplyOp,
};

/// One async git job: the worker thread spawns git, captures stdout/stderr,
/// fills the result fields and flips `done` (release); the main loop
/// consumes it (acquire) and joins the thread. Result fields are written by
/// the thread BEFORE `done.store(true)` — no locking needed. Output buffers
/// are owned by the job and freed by finishGitJob (after the App moved out
/// what it keeps).
pub const GitJob = struct {
    kind: GitJobKind,
    path: []u8, // owned (relative path, as git wants it)
    /// apply: 0-based final-file line where the target hunk STARTS (from the
    /// user's diff view). The worker re-diffs and locates the hunk by this
    /// line — a stale INDEX would otherwise pick the wrong hunk when the
    /// working tree changed between the view and the apply.
    hunk_start: u32 = 0,
    op: GitApplyOp = .stage,
    alloc: std.mem.Allocator,
    io: std.Io,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    out: ?[]u8 = null, // status: diff output; blame: blame output
    branch: ?[]u8 = null, // status: current branch (null = not a repo)
    untracked: bool = false, // status: file untracked ("??")
    msg: ?[]u8 = null, // apply: result message
    thread: ?std.Thread = null,
    /// Wake callback invoked from the worker thread when the job lands —
    /// posts an event so the main loop (blocked in pollEvent) wakes and
    /// drains the job without waiting for a keypress.
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (ctx: *anyopaque) void = null,
};

// ---- M3a git worker thread (file scope — not App methods) ----

/// Worker thread entry: run the job, publish the result, then wake the main
/// loop (which may be blocked in pollEvent).
pub fn gitJobMain(job: *GitJob) void {
    switch (job.kind) {
        .status => runStatus(job),
        .blame => runBlame(job),
        .apply => runApply(job),
    }
    job.done.store(true, .release);
    if (job.wake_fn) |f| {
        if (job.wake_ctx) |ctx| f(ctx);
    }
}

pub const CmdResult = struct { out: ?[]u8, err: ?[]u8, ok: bool };

/// Run one git command to completion (blocking — worker thread only),
/// capturing stdout/stderr. Returns owned buffers (null when empty or on
/// spawn failure).
pub fn runGit(self: *GitJob, argv: []const []const u8, stdin_data: ?[]const u8) CmdResult {
    var proc = std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return .{ .out = null, .err = null, .ok = false };
    if (stdin_data) |data| {
        if (proc.stdin) |in| {
            std.Io.File.writeStreamingAll(in, self.io, data) catch {};
            // close our write end so the child sees EOF on its stdin (git
            // apply - reads until EOF), then null the handle so wait()'s
            // cleanup doesn't double-close it (EBADF → panic)
            std.Io.File.close(in, self.io);
            proc.stdin = null;
        }
    }
    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(self.alloc);
    var err_buf = std.ArrayList(u8).empty;
    defer err_buf.deinit(self.alloc);
    if (proc.stdout) |out| gitReadAll(self, out, &out_buf);
    if (proc.stderr) |err| gitReadAll(self, err, &err_buf);
    const term_status = proc.wait(self.io) catch return .{ .out = null, .err = null, .ok = false };
    const ok = term_status == .exited and term_status.exited == 0;
    return .{
        .out = if (out_buf.items.len > 0) out_buf.toOwnedSlice(self.alloc) catch null else null,
        .err = if (err_buf.items.len > 0) err_buf.toOwnedSlice(self.alloc) catch null else null,
        .ok = ok,
    };
}

/// Drain a pipe into `buf` until EOF, then close it (worker thread).
pub fn gitReadAll(self: *GitJob, file: std.Io.File, buf: *std.ArrayList(u8)) void {
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = file.readStreaming(self.io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        buf.appendSlice(self.alloc, tmp[0..n]) catch break;
    }
    // NOT closed here: child.wait() closes the child's pipes; closing them
    // early makes its cleanup hit EBADF (recoverableOsBugDetected panics).
}

pub fn freeCmdResult(self: *GitJob, r: CmdResult) void {
    if (r.out) |o| self.alloc.free(o);
    if (r.err) |e| self.alloc.free(e);
}

pub fn dupOrNull(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    return alloc.dupe(u8, s) catch null;
}

/// status: branch + untracked flag + working-tree diff for `path`.
pub fn runStatus(self: *GitJob) void {
    var branch_r = runGit(self, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, null);
    defer freeCmdResult(self, branch_r);
    if (!branch_r.ok) return; // not a git repo — everything stays empty
    if (branch_r.out) |o| {
        // take ownership of the original buffer (branch output is "main\n";
        // the renderer trims). NEVER hand out a shorter slice of the
        // allocation — DebugAllocator's free validates the size.
        self.branch = o;
        branch_r.out = null;
    }
    const status_r = runGit(self, &.{ "git", "status", "--porcelain", "--", self.path }, null);
    defer freeCmdResult(self, status_r);
    if (status_r.ok) {
        if (status_r.out) |o| {
            self.untracked = std.mem.startsWith(u8, o, "??");
        }
    }
    var diff_r = runGit(self, &.{ "git", "diff", "--no-color", "--no-ext-diff", "--", self.path }, null);
    defer freeCmdResult(self, diff_r);
    if (diff_r.ok) {
        self.out = diff_r.out;
        diff_r.out = null;
    }
}

/// blame: `git blame --line-porcelain` output for `path`.
pub fn runBlame(self: *GitJob) void {
    var r = runGit(self, &.{ "git", "blame", "--line-porcelain", "--", self.path }, null);
    defer freeCmdResult(self, r);
    if (r.ok) {
        self.out = r.out;
        r.out = null;
    }
}

/// apply: re-diff in-thread (the user's hunk index must map onto a diff
/// computed at apply time, or a stale index could touch the wrong hunk),
/// then stage (git apply --cached) or reset (git apply -R) that hunk.
/// Untracked files stage whole-file via `git add`.
pub fn runApply(self: *GitJob) void {
    const d = runGit(self, &.{ "git", "diff", "--no-color", "--no-ext-diff", "--", self.path }, null);
    defer freeCmdResult(self, d);
    if (!d.ok) {
        self.msg = dupOrNull(self.alloc, "git diff failed");
        return;
    }
    var diff = git.parseDiff(self.alloc, d.out orelse "") catch {
        self.msg = dupOrNull(self.alloc, "git diff parse failed");
        return;
    };
    defer diff.deinit(self.alloc);
    if (diff.untracked) {
        if (self.op == .stage) {
            const add_r = runGit(self, &.{ "git", "add", "--", self.path }, null);
            defer freeCmdResult(self, add_r);
            self.msg = if (add_r.ok)
                dupOrNull(self.alloc, "file staged")
            else
                dupOrNull(self.alloc, std.mem.trim(u8, add_r.err orelse "", " \t\r\n"));
        } else {
            self.msg = dupOrNull(self.alloc, "untracked: nothing to reset");
        }
        return;
    }
    const target = self.hunk_start;
    const found = for (diff.hunks.items, 0..) |*h, i| {
        if (h.start_line == target) break i;
    } else null;
    const hi = found orelse {
        self.msg = dupOrNull(self.alloc, "hunk gone (file changed?)");
        return;
    };
    const patch = diff.hunks.items[hi].patch;
    const apply_r = if (self.op == .stage)
        runGit(self, &.{ "git", "apply", "--cached", "-" }, patch)
    else
        runGit(self, &.{ "git", "apply", "-R", "-" }, patch);
    defer freeCmdResult(self, apply_r);
    self.msg = if (apply_r.ok)
        dupOrNull(self.alloc, if (self.op == .stage) "hunk staged" else "hunk reset")
    else
        dupOrNull(self.alloc, std.mem.trim(u8, apply_r.err orelse "", " \t\r\n"));
}

/// "HH:MM" (24h) from an epoch-seconds timestamp — the nvim formatter's
/// author_time:%R equivalent (gitsigns current_line_blame_formatter).
pub fn formatHm(buf: *[5]u8, epoch_secs: i64) []const u8 {
    const secs: u64 = if (epoch_secs > 0) @intCast(epoch_secs) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    const h = ds.getHoursIntoDay();
    const m = ds.getMinutesIntoHour();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ h, m }) catch "??:??";
}

/// Number of lines in a hunk patch (for the preview's scroll window).
pub fn gitPreviewLineCount(text: []const u8) usize {
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}
