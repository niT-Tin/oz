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
    path: []u8, // owned (absolute path of the file, as the App stores it)
    /// Directory the git commands run in — the file's parent directory
    /// (owned). git discovers the repository by walking up from HERE, not
    /// from the process cwd: an oz launched anywhere (absolute file argv
    /// from $HOME, :e / picker into another directory) must still find the
    /// opened file's repo, branch and diff. Without this, rev-parse fails
    /// whenever oz's cwd is not inside the repo and NO marks ever appear.
    cwd: []u8,
    /// status only: temp file holding a snapshot of the BUFFER text
    /// (owned; deleted by finishGitJob). The status diff compares this
    /// content against the file's HEAD blob, so the gutter marks describe
    /// the text on screen — they stay live while the buffer has unsaved
    /// edits instead of hiding (gitsigns semantics). null = snapshot
    /// unavailable → the worker falls back to diffing the file on disk.
    work_path: ?[]u8 = null,
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
/// spawn failure). Exit code 0 counts as success.
pub fn runGit(self: *GitJob, argv: []const []const u8, stdin_data: ?[]const u8) CmdResult {
    return runGitEx(self, argv, stdin_data, &.{0});
}

/// runGit accepting extra exit codes as success: `git diff --no-index`
/// exits 1 when the two files differ — which IS the result we want.
pub fn runGitEx(self: *GitJob, argv: []const []const u8, stdin_data: ?[]const u8, ok_exit: []const u8) CmdResult {
    var proc = std.process.spawn(self.io, .{
        .argv = argv,
        // resolve the repo from the FILE's directory, never the process
        // cwd (an oz launched anywhere must still find the file's repo)
        .cwd = .{ .path = self.cwd },
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
    const ok = switch (term_status) {
        .exited => |code| std.mem.indexOfScalar(u8, ok_exit, code) != null,
        else => false,
    };
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

var tmp_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// A fresh unique temp-file path under /tmp (owned). Callers create and
/// delete the file; single job slot + atomic counter keep names unique
/// across the main thread and the worker.
pub fn makeTempPath(alloc: std.mem.Allocator, tag: []const u8) ?[]u8 {
    const n = tmp_seq.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(alloc, "/tmp/oz_git_{s}_{d}_{d}.tmp", .{ tag, std.c.getpid(), n }) catch null;
}

/// status: branch + untracked flag + the diff of the BUFFER text (not the
/// disk file) vs the file's HEAD blob. The buffer snapshot (job.work_path)
/// is written by the App before the job spawns — the piece table is
/// main-thread state, the worker only touches files. Diffing the visible
/// text keeps the gutter marks truthful while the buffer is dirty: they
/// live-update as the user edits instead of hiding until :w (gitsigns
/// semantics). When no snapshot is available the disk file is diffed (the
/// old fallback: marks describe the file on disk).
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
    if (self.untracked) {
        return; // whole file reads as added — no diff needed
    }
    const work_path = self.work_path orelse {
        // Clean-buffer fast path (or snapshot unavailable): the file on
        // disk IS the buffer text, so one `git diff HEAD` spawn gives the
        // same buffer-vs-HEAD marks the snapshot path computes (diffing vs
        // HEAD — not the index — keeps staged changes visible, matching
        // e90066d's buffer-vs-HEAD semantics).
        var disk_r = runGit(self, &.{ "git", "diff", "HEAD", "--no-color", "--no-ext-diff", "--", self.path }, null);
        defer freeCmdResult(self, disk_r);
        if (disk_r.ok) {
            self.out = disk_r.out;
            disk_r.out = null;
        }
        return;
    };
    // base = the HEAD blob of the file. "HEAD:./<name>" resolves the blob
    // relative to the job's cwd (the file's directory) — git accepts the
    // repo-relative name only, not the absolute path.
    const name = std.fs.path.basename(self.path);
    const spec = std.fmt.allocPrint(self.alloc, "HEAD:./{s}", .{name}) catch return;
    defer self.alloc.free(spec);
    const base_r = runGit(self, &.{ "git", "show", spec }, null);
    defer freeCmdResult(self, base_r);
    if (!base_r.ok) return; // no HEAD blob (gitignored etc.) — treat as clean
    const base_path = makeTempPath(self.alloc, "head") orelse return;
    defer {
        std.Io.Dir.cwd().deleteFile(self.io, base_path) catch {};
        self.alloc.free(base_path);
    }
    {
        var f = std.Io.Dir.cwd().createFile(self.io, base_path, .{ .truncate = true }) catch return;
        defer f.close(self.io);
        if (base_r.out) |o| {
            f.writeStreamingAll(self.io, o) catch return;
        }
    }
    // diff the HEAD blob against the buffer snapshot; exit 1 = differ (ok)
    var diff_r = runGitEx(self, &.{ "git", "diff", "--no-index", "--no-color", "--", base_path, work_path }, null, &.{ 0, 1 });
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
