//! git — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("../git.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const git_job = @import("git_job.zig");

const max_blame_lines = app_mod.max_blame_lines;
const GitJobKind = git_job.GitJobKind;
const GitApplyOp = git_job.GitApplyOp;
const GitJob = git_job.GitJob;
const gitJobMain = git_job.gitJobMain;
const dupOrNull = git_job.dupOrNull;
const gitPreviewLineCount = git_job.gitPreviewLineCount;
const Buffer = App.Buffer;
const lspWake = App.lspWake;

/// Hunk preview float (<leader>hp): the raw patch text of the hunk under
/// the cursor, shown in a floating window until Esc/Enter/q.
pub const GitPreview = struct {
    text: []u8, // owned (patch)
    top: usize, // scroll offset
};

/// Cached current-line blame ghost label (owned via self.alloc). The ghost
/// repaints every idle frame, so the formatted label is rebuilt only when the
/// blame LINE or the blame DATA changed — the entry pointer identifies both
/// (entries live in git_blame's own array, which is replaced on refresh).
pub const BlameGhostLabel = struct {
    line: u32,
    entry: *const git.BlameEntry,
    label: []u8, // owned
};

// ---- M3a git (async jobs + hunk/blame/lazygit actions) ----

/// Write the CURRENT buffer's text into a fresh temp file (owned path).
/// The git worker diffs this snapshot against the file's HEAD blob — the
/// piece table is main-thread state, so the snapshot is taken HERE before
/// the worker spawns. Returns null on failure (caller falls back to the
/// disk-based diff).
pub fn snapshotGitWork(self: *App) ?[]u8 {
    const path = git_job.makeTempPath(self.alloc, "buf") orelse return null;
    var f = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true }) catch {
        self.alloc.free(path);
        return null;
    };
    var ok = false;
    defer {
        f.close(self.io);
        if (!ok) {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.alloc.free(path);
        }
    }
    var chunk: [16384]u8 = undefined;
    var off: u32 = 0;
    const len = self.cur().pt.len();
    while (off < len) {
        const n: u32 = @intCast(@min(chunk.len, len - off));
        self.cur().pt.copyRange(off, chunk[0..n]);
        f.writeStreamingAll(self.io, chunk[0..n]) catch return null;
        off += n;
    }
    ok = true;
    return path;
}

/// Spawn one async git job for `path`. One job at a time: when a job is
/// already running, a status request is remembered (git_refresh_pending)
/// and re-spawned after the current one lands; other kinds are queued
/// with their full params (git_queued) and retried too.
pub fn spawnGitJob(self: *App, kind: GitJobKind, path: []const u8, hunk_start: u32, op: GitApplyOp) !void {
    if (self.git_job != null) {
        if (kind == .status) {
            self.git_refresh_pending = true;
        } else {
            // A queued hunk stage/reset is the user's EXPLICIT action and
            // must never be displaced by an auto current-line blame
            // (status refreshes re-trigger blame once the apply lands, so
            // the dropped blame request is not lost — only deferred).
            // Auto-blames supersede each other; applies keep the user's
            // last hunk action.
            const apply_queued = (self.git_queued != null and self.git_queued.?.kind == .apply);
            if (!(kind == .blame and apply_queued)) {
                if (self.git_queued) |q| self.alloc.free(q.path);
                self.git_queued = .{
                    .kind = kind,
                    .path = try self.alloc.dupe(u8, path),
                    .hunk_start = hunk_start,
                    .op = op,
                };
            }
        }
        return;
    }
    const job = try self.alloc.create(GitJob);
    errdefer self.alloc.destroy(job);
    // git must resolve the repo from the FILE's directory, not the
    // process cwd (an oz launched elsewhere would fail rev-parse and show
    // no branch / no marks at all). status jobs additionally diff the
    // CURRENT buffer text vs HEAD, so the marks live-update while editing.
    const dir = std.fs.path.dirname(path) orelse "/";
    const cwd = try self.alloc.dupe(u8, dir);
    errdefer self.alloc.free(cwd);
    const path_copy = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(path_copy);
    var work: ?[]u8 = null;
    if (kind == .status) work = self.snapshotGitWork();
    errdefer {
        if (work) |w| {
            std.Io.Dir.cwd().deleteFile(self.io, w) catch {};
            self.alloc.free(w);
        }
    }
    job.* = .{
        .kind = kind,
        .path = path_copy,
        .cwd = cwd,
        .work_path = work,
        .hunk_start = hunk_start,
        .op = op,
        .alloc = self.alloc,
        .io = self.io,
    };
    job.wake_ctx = self;
    job.wake_fn = lspWake; // same trick as the LSP reader thread
    // the status diff's snapshot was taken NOW — record the edit counter
    // so the landing diff can tell whether edits raced it (stale marks)
    if (kind == .status) self.git_status_spawn_seq = self.edit_seq;
    job.thread = try std.Thread.spawn(.{}, gitJobMain, .{job});
    self.git_job = job;
}

/// Main loop: consume a finished job (join the thread first), repaint.
pub fn consumeGitJob(self: *App, job: *GitJob) void {
    job.thread.?.join();
    defer self.finishGitJob(job);
    switch (job.kind) {
        .status => {
            // replace the diff/branch state wholesale
            if (self.git_branch) |b| self.alloc.free(b);
            if (self.git_diff_path) |p| self.alloc.free(p);
            self.git_diff.deinit(self.alloc);
            self.git_diff = .{};
            self.git_diff_path = dupOrNull(self.alloc, job.path);
            self.git_branch = job.branch; // thread-owned → App-owned
            job.branch = null;
            if (job.out) |o| {
                // parseDiff copies what it keeps — job.out stays owned by
                // the job and finishGitJob frees it below
                self.git_diff = git.parseDiff(self.alloc, o) catch git.FileDiff{};
            }
            // untracked must land even when the diff output is EMPTY
            // (git diff prints nothing for an untracked file — without
            // this the all-added marks never appeared)
            self.git_diff.untracked = job.untracked;
            // Live marks staleness: a landed diff reflects the CURRENT
            // buffer only when the job's snapshot was taken after the last
            // edit (edit_seq == git_status_spawn_seq) AND the job targeted
            // the current buffer. Otherwise the text on screen has moved
            // on — stay stale so the refresh loop diffs it again.
            if (self.cur().path) |cp| {
                if (std.mem.eql(u8, cp, job.path)) {
                    self.git_marks_stale = (self.edit_seq != self.git_status_spawn_seq);
                    if (!self.git_marks_stale) self.git_change_ms = 0;
                }
            }
            // auto current-line blame (nvim current_line_blame=true):
            // the repo is confirmed now — load blame for this file
            self.maybeLoadBlame();
            if (self.git_preview_pending) {
                self.git_preview_pending = false;
                self.showHunkPreview();
            }
        },
        .blame => {
            self.clearBlameGhostLabel();
            if (self.git_blame) |*b| b.deinit(self.alloc);
            self.git_blame = null;
            // blame must describe the CURRENT file; a stale response
            // (buffer switched mid-job) is dropped
            if (job.out) |o| {
                if (self.cur().path) |cp| {
                    if (std.mem.eql(u8, cp, job.path)) {
                        self.git_blame = git.parseBlame(self.alloc, o) catch null;
                        if (self.git_blame_path) |bp| self.alloc.free(bp);
                        self.git_blame_path = dupOrNull(self.alloc, job.path);
                    }
                }
                // job.out freed by finishGitJob (blame output is owned)
            }
        },
        .apply => {
            if (job.msg) |m| {
                self.setMsg(m) catch {};
                job.msg = null;
            } else if (dupOrNull(self.alloc, "git apply failed")) |m| {
                self.setMsg(m) catch {};
            }
            // the working tree changed (staged/reset): refresh the marks
            if (self.cur().path) |p| self.spawnGitJob(.status, p, 0, .stage) catch {};
            // and the blame describes the old file — invalidate it so
            // the status refresh reloads blame for the new content
            if (self.blame_active) {
                self.clearBlameGhostLabel();
                if (self.git_blame) |*b| b.deinit(self.alloc);
                self.git_blame = null;
                if (self.git_blame_path) |bp| self.alloc.free(bp);
                self.git_blame_path = null;
            }
        },
    }
}

pub fn finishGitJob(self: *App, job: *GitJob) void {
    self.alloc.free(job.path);
    self.alloc.free(job.cwd);
    if (job.work_path) |w| {
        std.Io.Dir.cwd().deleteFile(self.io, w) catch {};
        self.alloc.free(w);
    }
    if (job.out) |o| self.alloc.free(o);
    if (job.branch) |b| self.alloc.free(b);
    if (job.msg) |m| self.alloc.free(m);
    self.alloc.destroy(job);
    self.git_job = null;
    // resume work requested while the slot was busy: a stale status
    // refresh first, then any queued non-status job (blame/apply)
    if (self.git_refresh_pending) {
        self.git_refresh_pending = false;
        if (self.cur().path) |p| self.spawnGitJob(.status, p, 0, .stage) catch {};
    } else if (self.git_queued) |q| {
        self.git_queued = null;
        defer self.alloc.free(q.path);
        if (q.kind == .blame) {
            // blame goes through the auto-loader: it re-checks
            // blame_active and the current buffer's path/staleness
            self.maybeLoadBlame();
        } else {
            self.spawnGitJob(q.kind, q.path, q.hunk_start, q.op) catch {};
        }
    }
}

/// Refresh branch + diff marks for the current buffer (async). Called on
/// file open/switch and after save. The diff compares the BUFFER text vs
/// HEAD (snapshotted at spawn), so the marks describe the visible buffer
/// even while it is dirty — they refresh again after edits quiesce (see
/// gitMarksStaleNow / the run loop).
pub fn scheduleGitStatus(self: *App) void {
    const path = self.cur().path orelse return;
    self.spawnGitJob(.status, path, 0, .stage) catch {};
}

/// An edit changed the current buffer: the buffer-vs-HEAD diff is stale
/// until the run loop refreshes it once typing quiesces (git_marks_hold_ms
/// after the last edit). No-op outside a repo (git_branch == null) — the
/// initial open/save refresh already probed repo-ness.
pub fn gitMarksStaleNow(self: *App) void {
    if (self.git_branch == null) return;
    self.git_marks_stale = true;
    self.git_change_ms = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// ]c / [c — jump to the next/previous hunk of the current file.
pub fn gotoHunk(self: *App, forward: bool) void {
    const path = self.cur().path orelse return;
    if (self.cur().dirty) {
        // hunk ops stage/reset the FILE ON DISK, so navigation stays in
        // sync only on a saved buffer (the live gutter marks, by contrast,
        // describe the visible text and update while editing)
        if (dupOrNull(self.alloc, "save first (hunk ops apply to the file on disk)")) |m| self.setMsg(m) catch {};
        return;
    }
    if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
        if (dupOrNull(self.alloc, "git state loading…")) |m| self.setMsg(m) catch {};
        return;
    }
    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const idx = if (forward)
        self.git_diff.hunkAtOrAfter(cursor_line + 1)
    else
        self.git_diff.hunkBefore(cursor_line);
    const i = idx orelse {
        if (dupOrNull(self.alloc, if (forward) "no more hunks" else "no previous hunks")) |m| self.setMsg(m) catch {};
        return;
    };
    const start = self.git_diff.hunks.items[i].start_line;
    const pt = &self.cur().pt;
    const line = @min(start, pt.lineCount() -| 1);
    self.curCursor().* = pt.lineStart(line);
    // scroll the target into view (same as the grep-picker jump)
    self.curViewTop().* = line;
}

/// <leader>hs / <leader>hr — stage / reset the hunk under the cursor.
pub fn applyHunk(self: *App, op: GitApplyOp) void {
    const path = self.cur().path orelse return;
    if (self.cur().dirty) {
        if (dupOrNull(self.alloc, "save first (hunk ops apply to the file on disk)")) |m| self.setMsg(m) catch {};
        return;
    }
    if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
        if (dupOrNull(self.alloc, "git state loading…")) |m| self.setMsg(m) catch {};
        return;
    }
    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const idx = self.git_diff.hunkAt(cursor_line) orelse {
        if (self.git_diff.untracked) {
            self.spawnGitJob(.apply, path, 0, op) catch {};
            return;
        }
        if (dupOrNull(self.alloc, "cursor not in a hunk")) |m| self.setMsg(m) catch {};
        return;
    };
    const start = self.git_diff.hunks.items[idx].start_line;
    self.spawnGitJob(.apply, path, start, op) catch {};
}

/// <leader>hp — show the hunk under the cursor in a floating window.
pub fn previewHunk(self: *App) void {
    const path = self.cur().path orelse return;
    if (self.cur().dirty) {
        if (dupOrNull(self.alloc, "save first (hunk ops apply to the file on disk)")) |m| self.setMsg(m) catch {};
        return;
    }
    if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
        self.git_preview_pending = true;
        self.spawnGitJob(.status, path, 0, .stage) catch {};
        return;
    }
    self.showHunkPreview();
}

pub fn showHunkPreview(self: *App) void {
    const path = self.cur().path orelse return;
    if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) return;
    if (self.git_diff.untracked) {
        if (dupOrNull(self.alloc, "untracked file — no diff to preview")) |m| self.setMsg(m) catch {};
        return;
    }
    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const idx = self.git_diff.hunkAt(cursor_line) orelse {
        if (dupOrNull(self.alloc, "cursor not in a hunk")) |m| self.setMsg(m) catch {};
        return;
    };
    const patch = self.git_diff.hunks.items[idx].patch;
    const copy = dupOrNull(self.alloc, patch) orelse return;
    self.git_preview = .{ .text = copy, .top = 0 };
}

/// Keys while the hunk preview float is open. Returns true when consumed.
pub fn gitPreviewKey(self: *App, key: vaxis.Key) bool {
    switch (key.codepoint) {
        vaxis.Key.escape, vaxis.Key.enter, 'q' => {
            self.closeGitPreview();
            return true;
        },
        'j', vaxis.Key.down => {
            if (self.git_preview) |*p| {
                if (p.top + 1 < gitPreviewLineCount(p.text)) p.top += 1;
            }
            return true;
        },
        'k', vaxis.Key.up => {
            if (self.git_preview) |*p| {
                if (p.top > 0) p.top -= 1;
            }
            return true;
        },
        else => return false,
    }
}

pub fn closeGitPreview(self: *App) void {
    if (self.git_preview) |p| self.alloc.free(p.text);
    self.git_preview = null;
}

/// <leader>tb — toggle the current-line blame ghost (end-of-line dim
/// text on the cursor line, 1s CursorHold delay — nvim gitsigns style).
/// ON by default, like the nvim config's current_line_blame = true.
pub fn toggleBlame(self: *App) void {
    if (self.blame_active) {
        self.blame_active = false;
        return;
    }
    self.blame_active = true;
    self.maybeLoadBlame();
}

/// Drop the cached blame-ghost label — called whenever git_blame is
/// replaced or invalidated so the cache never outlives its data.
pub fn clearBlameGhostLabel(self: *App) void {
    if (self.blame_ghost_label) |g| self.alloc.free(g.label);
    self.blame_ghost_label = null;
}

/// Drop `buf`'s cached syntax spans (owned). Called when the buffer's
/// text is replaced in place (a new file loaded into the same slot):
/// the cache key would otherwise collide across files (a fresh history
/// starts at revision 0 with an identical byte range).
pub fn clearSpanCache(self: *App, buf: *Buffer) void {
    if (buf.span_cache) |*sc| self.alloc.free(sc.spans);
    buf.span_cache = null;
}

/// Load blame for the current file when current-line blame is active,
/// the repo check has passed (git_branch set), the file is under the
/// big-file limit, and the cached blame is stale/missing. No-op
/// otherwise — this is the auto-behavior behind current_line_blame.
pub fn maybeLoadBlame(self: *App) void {
    if (!self.blame_active) return;
    if (self.git_branch == null) return; // not a repo — no blame
    const path = self.cur().path orelse return;
    if (self.cur().pt.lineCount() > max_blame_lines) return; // degrade
    const stale = if (self.git_blame_path) |bp|
        !std.mem.eql(u8, bp, path)
    else
        true;
    if (stale) self.spawnGitJob(.blame, path, 0, .stage) catch {};
}
