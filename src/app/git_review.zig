//! Read-only Git Review session. A single worker coalesces rapid navigation.
//! Completed jobs own the immutable repository snapshots borrowed by the view.
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const data = @import("git_review_data.zig");
const patch = @import("git_review_patch.zig");

pub const Tab = enum { changes, history };
const Slot = enum { changes, comparison, history, detail, change_patch, commit_patch };
const Cache = struct {
    job: ?*data.Job = null,
    generation: u64 = 0,
    failure: ?[]const u8 = null,

    fn clear(self: *Cache) void {
        if (self.job) |job| job.deinit();
        self.* = .{ .generation = self.generation +% 1 };
    }
};
const Running = struct { slot: Slot, generation: u64, job: *data.Job };
pub const Cursor = struct { file: usize = 0, row: usize = 0, top: usize = 0 };

pub const State = struct {
    open: bool = false,
    cwd: ?[]u8 = null,
    root: ?[]u8 = null,
    tab: Tab = .changes,
    cache: std.EnumArray(Slot, Cache) = .initFill(.{}),
    running: ?Running = null,
    change: Cursor = .{},
    commit: Cursor = .{},
    change_focus: bool = false,
    detail_open: bool = false,
    history_tip: ?[]u8 = null,
    history_offset: usize = 0,
    timeline: usize = 0,
    timeline_top: usize = 0,
    parent: usize = 0,
    ref_index: usize = 0, // zero = working tree; others index changes.refs
    picker: bool = false,
    pick: usize = 0,
    pick_top: usize = 0,
    help: bool = false,
    message_open: bool = false,
    message_offset: usize = 0,
    message_previous: std.ArrayList(usize) = .empty,
    unified: bool = false,
    notice: ?[]const u8 = null,

    fn close(self: *State, a: std.mem.Allocator) void {
        // Closing is immediate, even if a history or patch is still loading.
        // Its generation will fail the next poll; only shutdown joins it.
        for (self.cache.values[0..]) |*c| c.clear();
        if (self.cwd) |cwd| a.free(cwd);
        if (self.root) |root| a.free(root);
        if (self.history_tip) |tip| a.free(tip);
        self.message_previous.deinit(a);
        const caches = self.cache;
        const running = self.running;
        self.* = .{ .cache = caches, .running = running };
    }

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.close(a);
        if (self.running) |r| r.job.deinit();
        self.running = null;
    }

    pub fn result(self: *const State, slot: Slot) ?*const data.Result {
        return if (self.cache.get(slot).job) |job| &job.result else null;
    }

    fn invalidate(self: *State, slot: Slot) void {
        self.cache.getPtr(slot).clear();
    }

    pub fn listingSlot(self: *const State) Slot {
        if (self.tab == .history) return .detail;
        return if (self.ref_index == 0) .changes else .comparison;
    }

    pub fn cursor(self: *State) *Cursor {
        return if (self.tab == .changes) &self.change else &self.commit;
    }

    pub fn files(self: *const State) []const data.File {
        const r = self.result(self.listingSlot()) orelse return &.{};
        return r.files;
    }

    pub fn file(self: *State) ?data.File {
        const entries = self.files();
        const i = self.cursor().file;
        return if (i < entries.len) entries[i] else null;
    }

    pub fn selectedCommit(self: *const State) ?data.Commit {
        const r = self.result(.history) orelse return null;
        return if (self.timeline < r.commits.len) r.commits[self.timeline] else null;
    }

    pub fn patchSlot(self: *const State) Slot {
        if (self.tab == .changes) return .change_patch;
        return if (self.commit.file == 0) .detail else .commit_patch;
    }

    pub fn view(self: *const State) patch.View {
        const r = self.result(self.patchSlot()) orelse return .{};
        return r.view;
    }

    pub fn status(self: *const State, slot: Slot, empty: []const u8) []const u8 {
        if (self.cache.get(slot).failure) |msg| return msg;
        const r = self.result(slot) orelse return "Loading…";
        return r.problem orelse empty;
    }

    pub fn split(width: usize) bool {
        return width >= 104;
    }

    pub fn listWidth(width: usize) usize {
        const content = width -| 2;
        return if (split(width)) @min(49, content / 3) else content;
    }

    pub fn aligned(self: *const State, width: usize) bool {
        return split(width) and !self.unified;
    }
};

pub fn open(app: *App) !void {
    const s = &app.review;
    s.close(app.alloc);
    s.cwd = if (app.cur().path) |p|
        try app.alloc.dupe(u8, std.fs.path.dirname(p) orelse ".")
    else
        try app.currentRootDir();
    s.open = true;
    schedule(app);
}

fn request(app: *App, slot: Slot, req: data.Request) void {
    const s = &app.review;
    const cache = s.cache.getPtr(slot);
    if (cache.job != null or cache.failure != null) return;
    const job = data.Job.start(app.alloc, app.io, s.root orelse s.cwd.?, req, app, App.lspWake) catch |err| {
        cache.failure = @errorName(err);
        return;
    };
    s.running = .{ .slot = slot, .generation = cache.generation, .job = job };
}

fn schedule(app: *App) void {
    const s = &app.review;
    if (!s.open or s.running != null) return;
    if (s.tab == .changes) {
        const changes = s.result(.changes) orelse return request(app, .changes, .changes);
        if (s.picker or changes.problem != null) return;
        if (s.ref_index > 0 and s.result(.comparison) == null) {
            return request(app, .comparison, .{ .comparison = changes.refs[s.ref_index - 1] });
        }
    } else {
        if (s.result(.history) == null) {
            if (s.history_tip) |tip| return request(app, .history, .{ .history_page = .{ .tip = tip, .offset = s.history_offset } });
            return request(app, .history, .history);
        }
        if (!s.detail_open) return;
        const current = s.selectedCommit() orelse return;
        if (s.result(.detail) == null) return request(app, .detail, .{ .detail = .{ .hash = current.hash, .parent_index = s.parent } });
        if (s.commit.file == 0) return; // detail already includes this patch
    }
    const f = s.file() orelse return;
    request(app, s.patchSlot(), .{ .patch = f });
}

pub fn poll(app: *App) bool {
    const s = &app.review;
    const r = s.running orelse return false;
    if (!r.job.done.load(.acquire)) return false;
    s.running = null;
    const cache = s.cache.getPtr(r.slot);
    if (s.open and cache.generation == r.generation) {
        const root = r.job.result.root;
        if (root.len > 0 and s.root == null) s.root = app.alloc.dupe(u8, root) catch null;
        if (s.root != null and root.len > 0 and !std.mem.eql(u8, root, s.root.?)) {
            cache.failure = "Repository changed. Reopen Git Review.";
            r.job.deinit();
        } else cache.job = r.job;
    } else r.job.deinit();
    schedule(app);
    return s.open;
}

fn step(at: usize, count: usize, amount: i32) usize {
    return if (amount < 0) at -| @as(usize, @intCast(-amount)) else @min(count -| 1, at +| @as(usize, @intCast(amount)));
}

fn moveFile(s: *State, amount: i32) void {
    const cursor = s.cursor();
    const next = step(cursor.file, s.files().len, amount);
    if (next == cursor.file) return;
    cursor.file = next;
    cursor.row = 0;
    s.invalidate(if (s.tab == .changes) .change_patch else .commit_patch);
}

/// One soft-wrapped message row, with a byte offset for the next row.
pub fn messageRow(text: []const u8, at: usize, win: vaxis.Window, width: usize) struct { text: []const u8, next: usize } {
    const rest = text[at..];
    const prefix = rest[0..@min(rest.len, @max(width, 1) * 8)];
    const end = std.mem.indexOfScalar(u8, prefix, '\n') orelse prefix.len;
    var it = vaxis.unicode.graphemeIterator(prefix[0..end]);
    var cells: usize = 0;
    var size: usize = 0;
    while (it.next()) |g| {
        const bytes = g.bytes(prefix);
        const w = if (bytes[0] == '\t') 4 else @max(win.gwidth(bytes), 1);
        if (size > 0 and cells + w > width) break;
        size += g.len;
        cells += w;
    }
    const newline = size < rest.len and rest[size] == '\n';
    return .{ .text = rest[0..size], .next = at + size + @intFromBool(newline) };
}

fn move(app: *App, amount: i32) !void {
    const s = &app.review;
    const win = app.vx.window();
    const width: usize = win.width;
    if (s.picker) {
        const r = s.result(.changes) orelse return;
        s.pick = step(s.pick, r.refs.len + 1, amount);
    } else if (s.message_open) {
        const r = s.result(.detail) orelse return;
        const c = r.commit orelse return;
        const pane_width = if (State.split(width)) width -| (State.listWidth(width) + 4) else width -| 2;
        for (0..@abs(amount)) |_| {
            if (amount < 0) {
                s.message_offset = s.message_previous.pop() orelse return;
            } else {
                const line = messageRow(c.message, s.message_offset, win, pane_width);
                if (line.next >= c.message.len) return;
                try s.message_previous.append(app.alloc, s.message_offset);
                s.message_offset = line.next;
            }
        }
    } else if (s.tab == .history and !s.detail_open) {
        const r = s.result(.history) orelse return;
        const next = step(s.timeline, r.commits.len, amount);
        if (next == s.timeline) return;
        s.timeline = next;
        resetDetail(s);
    } else if (s.tab == .changes and !s.change_focus) {
        moveFile(s, amount);
    } else {
        const v = s.view();
        if (v.rows.len == 0) return;
        const cur = s.cursor();
        cur.row = if (s.aligned(width))
            v.pairs[step(v.rows[cur.row].pair, v.pairs.len, amount)].preferred()
        else
            step(cur.row, v.rows.len, amount);
    }
}

fn resetDetail(s: *State) void {
    s.invalidate(.detail);
    s.invalidate(.commit_patch);
    s.commit = .{};
    s.parent = 0;
    s.message_open = false;
    s.message_offset = 0;
    s.message_previous.clearRetainingCapacity();
}

fn confirm(s: *State) void {
    if (s.picker) {
        s.picker = false;
        if (s.ref_index == s.pick) return;
        s.ref_index = s.pick;
        s.invalidate(.comparison);
        s.invalidate(.change_patch);
        s.change = .{};
        s.change_focus = false;
    } else if (s.tab == .history) {
        if (s.selectedCommit() != null and !s.detail_open) {
            s.detail_open = true;
            s.commit = .{};
            s.invalidate(.commit_patch);
        }
    } else if (s.file() != null) s.change_focus = true;
}

fn openSource(app: *App) !void {
    const s = &app.review;
    if (s.tab == .history and !s.detail_open) return;
    const f = s.file() orelse return;
    const r = s.result(s.listingSlot()).?;
    const path = try std.fs.path.join(app.alloc, &.{ r.root, f.path });
    defer app.alloc.free(path);
    const stat = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch {
        s.notice = "Source unavailable in this worktree";
        return;
    };
    if (stat.kind != .file) {
        s.notice = "Source unavailable in this worktree";
        return;
    }
    if (s.result(s.patchSlot()) == null) {
        s.notice = "Loading patch…";
        return;
    }
    const v = s.view();
    const row = s.cursor().row;
    const line = if (row < v.rows.len) v.rows[row].source_line else 1;
    // Navigation only opens existing files. Keep the reviewer on this patch
    // if the file was deleted, moved again, or belongs to another workspace.
    try app.openFile(path);
    if (!std.mem.eql(u8, app.cur().path orelse "", path)) {
        s.notice = "Source unavailable in this worktree";
        return;
    }
    app.curCursor().* = app.cur().pt.lineStart(app.cur().pt.clampLine(line -| 1));
    app.clearHover();
    app.focus = .buffer;
    app.ai.focus = .editor;
    s.close(app.alloc);
}

pub fn keyPress(app: *App, key: vaxis.Key) !void {
    const s = &app.review;
    defer schedule(app);
    s.notice = null;
    const page: i32 = @max(@as(i32, app.vx.window().height) - 8, 1);
    if (key.matches('q', .{})) return s.close(app.alloc);
    if (key.matches('?', .{})) {
        s.help = !s.help;
        return;
    }
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('h', .{})) {
        if (s.help) s.help = false else if (s.picker) s.picker = false else if (s.message_open) s.message_open = false else if (s.tab == .history and s.detail_open) s.detail_open = false else if (s.tab == .changes and s.change_focus) s.change_focus = false else s.close(app.alloc);
        return;
    }
    if (s.help) return;
    if (key.matches(vaxis.Key.tab, .{})) {
        s.tab = if (s.tab == .history) .changes else .history;
        s.picker = false;
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return move(app, 1);
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return move(app, -1);
    if (key.matches(vaxis.Key.page_up, .{})) return move(app, -page);
    if (key.matches(vaxis.Key.page_down, .{})) return move(app, page);
    if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{})) return confirm(s);
    if (s.picker) return;
    if (s.tab == .changes and key.matches('b', .{}) and s.result(.changes) != null) {
        s.picker = true;
        s.pick = s.ref_index;
        return;
    }
    if (s.tab == .history and !s.detail_open) {
        const history = s.result(.history) orelse return;
        const older = key.matches('.', .{});
        const newer = key.matches(',', .{});
        if ((older and history.history_more) or (newer and history.history_offset > 0)) {
            if (s.history_tip == null) s.history_tip = try app.alloc.dupe(u8, history.history_tip);
            s.history_offset = if (older) history.history_offset + data.history_page_size else history.history_offset -| data.history_page_size;
            resetDetail(s);
            s.invalidate(.history);
            s.timeline = 0;
            s.timeline_top = 0;
        }
        return;
    }
    if (s.tab == .history and key.matches('m', .{})) {
        s.message_open = !s.message_open;
        return;
    }
    if (s.message_open) return;
    if (key.matches('J', .{})) return moveFile(s, 1);
    if (key.matches('K', .{})) return moveFile(s, -1);
    if (key.matches('o', .{})) return openSource(app);
    if (key.matches('v', .{})) s.unified = !s.unified;
    if (key.matches(']', .{}) or key.matches('[', .{})) {
        if (s.tab == .changes) s.change_focus = true;
        s.cursor().row = s.view().jump(s.cursor().row, key.matches(']', .{}));
    }
    if (s.tab == .history and key.matches('p', .{})) {
        const c = s.selectedCommit() orelse return;
        if (c.parents.len <= 1) return;
        const parent = (s.parent + 1) % c.parents.len;
        resetDetail(s);
        s.parent = parent;
    }
}
