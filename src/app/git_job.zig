const std = @import("std");
const git = @import("../git.zig");
const windows = @import("git_windows.zig");
pub const Snapshot = @import("../buffer/text_snapshot.zig");

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
    snapshot: ?Snapshot = null,
    dirty: bool = false,
    diff: git.FileDiff = .{},
    diff_valid: bool = false,
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
        .status => {
            if (runStatus(job)) |_| job.diff_valid = true else |_| {}
            if (job.snapshot) |s| s.deinit();
            job.snapshot = null;
        },
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

const Temp = struct {
    path: []u8,
    file: std.Io.File,

    fn init(job: *GitJob, tag: []const u8) !Temp {
        const path = makeTempPath(job.alloc, tag) orelse return error.OutOfMemory;
        errdefer job.alloc.free(path);
        const f = try std.Io.Dir.cwd().createFile(job.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        return .{ .file = f, .path = path };
    }

    fn deinit(self: Temp, job: *GitJob) void {
        self.file.close(job.io);
        std.Io.Dir.cwd().deleteFile(job.io, self.path) catch {};
        job.alloc.free(self.path);
    }
};

const Base = struct {
    bytes: []const u8,
    owned: bool,
};

// Pin the object ID before reading it: HEAD may move while the job runs.
// Stream identical blobs directly against the immutable origin. Only a
// genuinely different HEAD needs its own allocation.
fn readBase(job: *GitJob, s: Snapshot, oid: []const u8) !Base {
    const owner = s.origin;
    if (std.mem.eql(u8, oid, owner.verified_blob[0..owner.verified_blob_len]))
        return .{ .bytes = owner.bytes, .owned = false };
    const sz = runGit(job, &.{ "git", "cat-file", "-s", oid }, null);
    defer freeCmdResult(job, sz);
    if (!sz.ok) return error.GitBlobUnavailable;
    const len = try std.fmt.parseInt(usize, std.mem.trim(u8, sz.out orelse return error.GitBlobUnavailable, " \r\n"), 10);
    if (len >= std.math.maxInt(u32)) return error.FileTooBig;
    var proc = try std.process.spawn(job.io, .{ .argv = &.{ "git", "cat-file", "blob", oid }, .cwd = .{ .path = job.cwd }, .stdout = .pipe, .stdin = .ignore, .stderr = .ignore });
    defer proc.kill(job.io);
    var copy: ?[]u8 = if (len == owner.bytes.len) null else try job.alloc.alloc(u8, len);
    errdefer if (copy) |b| job.alloc.free(b);
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    while (pos < len) {
        const target = if (copy) |b| b[pos..] else buf[0..@min(buf.len, len - pos)];
        const n = try proc.stdout.?.readStreaming(job.io, &.{target});
        if (n == 0) return error.EndOfStream;
        if (copy == null and !std.mem.eql(u8, buf[0..n], owner.bytes[pos..][0..n])) {
            copy = try job.alloc.alloc(u8, len);
            @memcpy(copy.?[0..pos], owner.bytes[0..pos]);
            @memcpy(copy.?[pos..][0..n], buf[0..n]);
        }
        pos += n;
    }
    const result = try proc.wait(job.io);
    if (result != .exited or result.exited != 0) return error.GitBlobUnavailable;
    if (copy) |b| return .{ .bytes = b, .owned = true };
    @memcpy(owner.verified_blob[0..oid.len], oid);
    owner.verified_blob_len = @intCast(oid.len);
    return .{ .bytes = owner.bytes, .owned = false };
}

fn binaryPrefix(s: Snapshot) bool {
    var left: usize = 8000;
    for (s.pieces) |p| {
        const bytes = s.bytes(p);
        const n = @min(left, bytes.len);
        if (std.mem.indexOfScalar(u8, bytes[0..n], 0) != null) return true;
        left -= n;
        if (left == 0) break;
    }
    return false;
}

// Rebase both sides of the unified patch, so previews and parsed gutter
// marks describe the full document even when earlier edits added lines.
fn rebasePatch(a: std.mem.Allocator, patch: []const u8, w: windows.Window) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ -")) {
            var rest = line[4..];
            try out.writer.writeAll("@@ -");
            for ([2]u32{ w.old_lines, w.new_lines }, 0..) |off, side| {
                var n: usize = 0;
                while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
                try out.writer.print("{d}", .{try std.fmt.parseInt(u32, rest[0..n], 10) + off});
                rest = rest[n..];
                if (side == 0) {
                    const plus = std.mem.indexOf(u8, rest, " +") orelse return error.BadHunkHeader;
                    try out.writer.writeAll(rest[0 .. plus + 2]);
                    rest = rest[plus + 2 ..];
                }
            }
            try out.writer.writeAll(rest);
        } else try out.writer.writeAll(line);
        if (lines.index != null) try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn diffWindow(job: *GitJob, w: windows.Window) !void {
    const old = try Temp.init(job, "head");
    defer old.deinit(job);
    try old.file.writeStreamingAll(job.io, w.old);
    const new = try Temp.init(job, "buf");
    defer new.deinit(job);
    var pos: usize = 0;
    var newlines: u32 = 0;
    for (job.snapshot.?.pieces) |p| {
        if (pos >= w.end) break;
        if (pos + p.len > w.start) {
            const part = job.snapshot.?.bytes(p)[w.start -| pos..@min(w.end - pos, p.len)];
            try new.file.writeStreamingAll(job.io, part);
            newlines += @import("../buffer/line_pages.zig").countNewlines(part);
        }
        pos += p.len;
    }
    const r = runGitEx(job, &.{ "git", "diff", "--no-index", "--no-color", "--no-ext-diff", "--text", "--", old.path, new.path }, null, &.{ 0, 1 });
    defer freeCmdResult(job, r);
    if (!r.ok) return error.GitDiffFailed;
    const raw = r.out orelse return;
    const rebased = if (w.old_lines != 0 or w.new_lines != 0) try rebasePatch(job.alloc, raw, w) else null;
    defer if (rebased) |p| job.alloc.free(p);
    var diff = try git.parseDiff(job.alloc, rebased orelse raw);
    defer diff.deinit(job.alloc);
    // Identical repeated lines can slide an insertion or deletion up to a
    // synthetic file edge. Let Git choose the alignment in the full document
    // when a hunk ran out of context on a side we clipped.
    for (diff.hunks.items) |h| {
        if ((w.start > 0 and h.start_line <= w.new_lines + 1) or
            (w.end < job.snapshot.?.len and h.end_line >= w.new_lines + newlines -| 1)) return error.AmbiguousWindow;
    }
    try job.diff.hunks.appendSlice(job.alloc, diff.hunks.items);
    diff.hunks.clearRetainingCapacity();
}

pub fn runStatus(job: *GitJob) !void {
    var branch = runGit(job, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, null);
    defer freeCmdResult(job, branch);
    if (!branch.ok) {
        freeCmdResult(job, branch);
        branch = runGit(job, &.{ "git", "symbolic-ref", "--short", "HEAD" }, null);
        if (!branch.ok) return;
    }
    job.branch = branch.out;
    branch.out = null;
    const status = runGit(job, &.{ "git", "status", "--porcelain", "--", job.path }, null);
    defer freeCmdResult(job, status);
    if (!status.ok) return error.GitStatusFailed;
    const porcelain = status.out orelse "";
    if (std.mem.startsWith(u8, porcelain, "??")) {
        job.diff.untracked = true;
        return;
    }

    const s = job.snapshot orelse {
        const r = runGit(job, &.{ "git", "diff", "HEAD", "--no-color", "--no-ext-diff", "--", job.path }, null);
        defer freeCmdResult(job, r);
        if (!r.ok) return error.GitDiffFailed;
        if (r.out) |raw| job.diff = try git.parseDiff(job.alloc, raw);
        return;
    };
    if (!job.dirty and porcelain.len == 0) return;
    const spec = try std.fmt.allocPrint(job.alloc, "HEAD:./{s}", .{std.fs.path.basename(job.path)});
    defer job.alloc.free(spec);
    const rev = runGit(job, &.{ "git", "rev-parse", "--verify", "--quiet", spec }, null);
    defer freeCmdResult(job, rev);
    if (!rev.ok) {
        if (std.mem.startsWith(u8, porcelain, "A"))
            try diffWindow(job, .{ .old = "", .start = 0, .end = s.len, .old_lines = 0, .new_lines = 0 });
        return; // an ignored file has no HEAD blob or marks
    }
    const oid = std.mem.trim(u8, rev.out orelse return error.GitBlobUnavailable, "\r\n ");
    if (oid.len != 40 and oid.len != 64) return error.GitBlobUnavailable;
    const base = try readBase(job, s, oid);
    defer if (base.owned) job.alloc.free(base.bytes);
    try diffView(job, s, base.bytes);
}

fn diffView(job: *GitJob, s: Snapshot, base: []const u8) !void {
    if (std.mem.indexOfScalar(u8, base[0..@min(base.len, 8000)], 0) != null or binaryPrefix(s)) return;
    windows.visit(s, base, job, diffWindow) catch |err| {
        if (err != error.AmbiguousWindow) return err;
        job.diff.deinit(job.alloc);
        job.diff = .{};
        try diffWindow(job, .{ .old = base, .start = 0, .end = s.len, .old_lines = 0, .new_lines = 0 });
    };
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

// Use a full native Git patch as an independent oracle for the marked lines.
fn expectGitMarksMatch(pt: *@import("../buffer/piece_table.zig").PieceTable, base: []const u8) !void {
    const a = std.testing.allocator;
    const view = try Snapshot.capture(pt);
    defer view.deinit();
    var actual = GitJob{ .alloc = a, .io = std.testing.io, .cwd = @constCast("."), .path = @constCast("fixture"), .kind = .status, .snapshot = view };
    var full = actual;
    defer actual.diff.deinit(a);
    defer full.diff.deinit(a);
    try diffView(&actual, view, base);
    try diffWindow(&full, .{ .old = base, .start = 0, .end = view.len, .old_lines = 0, .new_lines = 0 });
    try std.testing.expectEqual(full.diff.hunks.items.len, actual.diff.hunks.items.len);
    for (full.diff.hunks.items, actual.diff.hunks.items) |want, got| {
        try std.testing.expectEqualSlices(git.MarkRun, want.runs, got.runs);
    }
}

test "large git marks match full Git across multiple windows, staged lines and duplicate-line alignment" {
    const a = std.testing.allocator;
    const PT = @import("../buffer/piece_table.zig").PieceTable;
    const row = "repeated 0123456789 repeated 0123456789 repeated 0123456789\r\n";
    const n = windows.threshold / row.len + 8;
    var buf = try std.ArrayList(u8).initCapacity(a, n * row.len + 16);
    defer buf.deinit(a);
    for (0..n) |_| buf.appendSliceAssumeCapacity(row);
    buf.appendSliceAssumeCapacity("end without LF");
    var pt = try PT.init(a, buf.items);
    defer pt.deinit();
    // Ordinary sparse replacements plus an insertion shifting later hunks.
    _ = try pt.replace(3, 2, "new\nline");
    _ = try pt.replace(@intCast(pt.len() - 4), 3, "changed");
    try expectGitMarksMatch(&pt, pt.origin);
    // Disk at open can already differ from HEAD independently of this edit.
    buf.items[n / 2 * row.len] = 'H';
    try expectGitMarksMatch(&pt, buf.items);
    var duplicate = try PT.init(a, buf.items);
    defer duplicate.deinit();
    const at: u32 = @intCast(row.len * (n / 4));
    _ = try duplicate.replace(at, row.len, "");
    try expectGitMarksMatch(&duplicate, duplicate.origin);
    _ = try duplicate.replace(at, 0, row);
    try expectGitMarksMatch(&duplicate, duplicate.origin);
}

test "large git marks preserve absolute line coordinates across separate sparse edits and independent HEAD changes" {
    const a = std.testing.allocator;
    const PT = @import("../buffer/piece_table.zig").PieceTable;
    var doc: std.Io.Writer.Allocating = .init(a);
    defer doc.deinit();
    var n: usize = 0;
    while (doc.written().len < windows.threshold + 512) : (n += 1)
        try doc.writer.print("line {d} has data here\n", .{n});
    var pt = try PT.init(a, doc.written());
    defer pt.deinit();
    _ = try pt.replace(0, 0, "new\nsecond\n");
    const at = pt.lineStart(41002);
    _ = try pt.replace(at, pt.lineStart(41004) - at, "");
    _ = try pt.replace(pt.len() - 8, 3, "terminal");
    const s = try Snapshot.capture(&pt);
    defer s.deinit();
    const Stats = struct {
        num: usize = 0,
        fn record(self: *@This(), w: windows.Window) !void {
            try std.testing.expect(w.old.len < 2048 and w.end - w.start < 2048);
            self.num += 1;
        }
    };
    var stats = Stats{};
    try windows.visit(s, s.origin.bytes, &stats, Stats.record);
    try std.testing.expectEqual(@as(usize, 3), stats.num);
    try expectGitMarksMatch(&pt, pt.origin);
    const head = try a.dupe(u8, doc.written());
    defer a.free(head);
    head[head.len / 3] = '#';
    try expectGitMarksMatch(&pt, head);
}

test "git marks compare unsaved text with HEAD across staging and a moved HEAD" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "fixture.txt";
    const original = "one\ntwo\nthree\nfour\n";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = original });
    const path = try tmp.dir.realPathFileAlloc(io, name, a);
    defer a.free(path);
    var pt = try @import("../buffer/piece_table.zig").PieceTable.init(a, original);
    defer pt.deinit();
    _ = try pt.replace(14, 4, "user");
    const view = try Snapshot.capture(&pt);
    defer view.deinit();
    var j = GitJob{ .kind = .status, .alloc = a, .io = io, .cwd = @constCast(std.fs.path.dirname(path).?), .path = path, .snapshot = view, .dirty = true };
    const TestGit = struct {
        fn command(job: *GitJob, args: []const []const u8) !void {
            const r = runGit(job, args, null);
            defer freeCmdResult(job, r);
            try std.testing.expect(r.ok);
        }
        fn commit(job: *GitJob) !void {
            try command(job, &.{ "git", "-c", "user.name=test", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture" });
        }
        fn marks(job: *GitJob, moved: bool) !void {
            defer {
                job.diff.deinit(job.alloc);
                job.diff = .{};
                if (job.branch) |b| job.alloc.free(b);
                job.branch = null;
            }
            try runStatus(job);
            try std.testing.expectEqual(@as(?git.LineKind, .modified), job.diff.markAt(3));
            try std.testing.expectEqual(if (moved) @as(?git.LineKind, .modified) else null, job.diff.markAt(0));
        }
    };
    try TestGit.command(&j, &.{ "git", "init", "-q" });
    try TestGit.command(&j, &.{ "git", "add", name });
    try TestGit.commit(&j);
    try TestGit.marks(&j, false);
    try std.testing.expect(view.origin.verified_blob_len != 0);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "new\ntwo\nthree\nfour\n" });
    try TestGit.command(&j, &.{ "git", "add", name });
    try TestGit.marks(&j, false);
    try TestGit.commit(&j);
    try TestGit.marks(&j, true);
}
