//! One read-only Git status snapshot for the visible Files tree. The worker
//! sleeps between scans so external index, branch and worktree changes arrive
//! without polling the render loop. No editor buffer contents enter the query.
const std = @import("std");
const porcelain = @import("repo_status.zig");
const App = @import("../app.zig").App;
const watch = @import("filetree_watch.zig");
const Allocator = std.mem.Allocator;

pub const Badge = porcelain.Badge;
const Snapshot = porcelain.Snapshot;

fn command(alloc: Allocator, io: std.Io, root: []const u8, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(alloc, io, .{ .argv = argv, .cwd = .{ .path = root } });
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.GitUnavailable;
    return result.stdout;
}

fn read(alloc: Allocator, io: std.Io, root: []const u8) !Snapshot {
    const prefix = try command(alloc, io, root, &.{ "git", "rev-parse", "--show-prefix" });
    errdefer alloc.free(prefix);
    const bytes = try command(alloc, io, root, &porcelain.status_argv);
    errdefer alloc.free(bytes);
    var snap: Snapshot = .{ .bytes = bytes, .prefix = prefix };
    errdefer snap.paths.deinit(alloc);
    try snap.indexPaths(alloc);
    return snap;
}
pub const Monitor = struct {
    // The UI thread owns visible. The worker publishes pending under mutex.
    visible: ?Snapshot = null,
    pending: ?Snapshot = null,
    has_reply: bool = false,
    scope: ?[]u8 = null,
    generation: u64 = 0,
    stopping: bool = false,
    tree_dirty: bool = true,
    targets: ?watch.Targets = null,
    pending_dirs: ?watch.Changes = null,
    scan: u64 = 0,
    reading: bool = false,
    suspended: bool = false,
    mutex: std.Io.Mutex = .init,
    signal: std.Io.Condition = .init,
    task: ?std.Io.Future(void) = null,

    fn matches(self: *const Monitor, root: ?[]const u8) bool {
        if (self.scope) |scope| return root != null and std.mem.eql(u8, scope, root.?);
        return root == null;
    }

    /// Borrowed on the main thread until Job.start copies the scope. Changes
    /// always reads live Git state. Only an idle Navigator can reuse that scan.
    pub fn reviewTarget(self: *Monitor, io: std.Io) ?porcelain.ReviewTarget {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.reading or self.stopping) return null;
        return .{ .scope = self.scope orelse return null, .generation = self.generation, .scan = self.scan };
    }

    fn accepts(self: *Monitor, target: porcelain.ReviewTarget) bool {
        return !self.stopping and !self.reading and self.matches(target.scope) and
            self.generation == target.generation and self.scan == target.scan;
    }

    pub fn acceptReview(self: *Monitor, app: *App, target: porcelain.ReviewTarget, prepared: *?Snapshot) void {
        if (prepared.* == null) return;
        self.mutex.lockUncancelable(app.io);
        defer self.mutex.unlock(app.io);
        if (!self.accepts(target)) return;
        if (self.pending) |*old| old.deinit(app.alloc);
        self.pending = prepared.*;
        prepared.* = null;
        self.has_reply = true;
    }

    pub fn get(self: *const Monitor, root: []const u8, absolute: []const u8) ?Badge {
        // Input can change roots and draw a frame before the next tick.
        if (!self.matches(root) or !std.mem.startsWith(u8, absolute, root)) return null;
        const snapshot = self.visible orelse return null;
        return snapshot.paths.get(std.mem.trimStart(u8, absolute[root.len..], "/"));
    }

    pub fn refresh(self: *Monitor, io: std.Io) void {
        if (self.scope == null) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.generation +%= 1;
        self.signal.signal(io);
    }

    pub fn tick(self: *Monitor, app: *App) bool {
        const root: ?[]const u8 = if (app.filetree_root != null and app.filetree_active and app.navigator_tab == .files and
            (!app.navigatorCompact() or app.navigatorPeekActive())) app.filetree_root.?.path else null;
        if (self.task == null) {
            if (root == null) return false;
            self.task = app.io.concurrent(worker, .{ self, app }) catch return false;
        }
        self.mutex.lockUncancelable(app.io);
        defer self.mutex.unlock(app.io);
        if (root != null and (self.tree_dirty or !self.matches(root))) {
            if (watch.Targets.capture(app)) |targets| {
                if (self.targets) |*old| old.arena.deinit();
                self.targets = targets;
                self.tree_dirty = false;
            } else |_| self.tree_dirty = true;
        }
        // Review covers the Files pane and can publish the same status itself.
        // Keep its scope eligible for that hand-off while periodic reads sleep.
        if (self.suspended != app.review.open) {
            self.suspended = app.review.open;
            if (!self.suspended) self.generation +%= 1;
            self.signal.signal(app.io);
        }
        if (!self.matches(root)) {
            if (self.pending_dirs) |*old| old.arena.deinit();
            self.pending_dirs = null;
            const new = if (root) |dir| app.alloc.dupe(u8, dir) catch null else null;
            if (self.scope) |old| app.alloc.free(old);
            self.scope = new;
            self.generation +%= 1;
            self.signal.signal(app.io);
            if (self.pending) |*s| s.deinit(app.alloc);
            self.pending = null;
            self.has_reply = false;
            const changed = self.visible != null;
            if (self.visible) |*s| s.deinit(app.alloc);
            self.visible = null;
            return changed;
        }
        if (!self.has_reply) return false;
        self.has_reply = false;
        const changed = if (self.visible) |old|
            if (self.pending) |new| !std.mem.eql(u8, old.bytes, new.bytes) or !std.mem.eql(u8, old.prefix, new.prefix) else old.paths.count() != 0
        else
            self.pending != null and self.pending.?.paths.count() != 0;
        if (self.visible) |*s| s.deinit(app.alloc);
        self.visible = self.pending;
        self.pending = null;
        if (self.pending_dirs) |*changes| {
            defer {
                changes.arena.deinit();
                self.pending_dirs = null;
            }
            const rows_changed = @import("filetree.zig").applyDirectoryChanges(app, changes) catch false;
            return changed or rows_changed;
        }
        return changed;
    }

    fn worker(self: *Monitor, app: *App) void {
        const io = app.io;
        var seen: u64 = 0;
        var targets: ?watch.Targets = null;
        defer if (targets) |*t| t.arena.deinit();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.stopping) {
            if (self.suspended or self.scope == null or self.generation == seen) {
                const wait: std.Io.Timeout = if (self.suspended or self.scope == null) .none else .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(1500) } };
                self.signal.waitTimeout(io, &self.mutex, wait) catch |err| switch (err) {
                    error.Canceled => return,
                    error.Timeout => {},
                };
            }
            if (self.stopping) return;
            if (self.suspended) continue;
            const scope = self.scope orelse continue;
            seen = self.generation;
            const dir = app.alloc.dupe(u8, scope) catch continue;
            if (self.targets) |new| {
                if (targets) |*old| old.arena.deinit();
                targets = new;
                self.targets = null;
            }
            self.reading = true;
            self.scan +%= 1;
            self.mutex.unlock(io);
            var dirs = if (targets) |*t| t.scan(app.alloc, io) catch null else null;
            var result: ?Snapshot = read(app.alloc, io, dir) catch null;
            app.alloc.free(dir);
            self.mutex.lockUncancelable(io);
            self.reading = false;
            if (self.stopping or self.generation != seen) {
                if (dirs) |*d| d.arena.deinit();
                if (result) |*s| s.deinit(app.alloc);
                continue;
            }
            if (self.pending_dirs) |*old| old.arena.deinit();
            self.pending_dirs = dirs;
            if (self.pending) |*s| s.deinit(app.alloc);
            self.pending = result;
            self.has_reply = true;
            App.lspWake(app);
        }
    }

    pub fn deinit(self: *Monitor, app: *App) void {
        if (self.task) |*task| {
            self.mutex.lockUncancelable(app.io);
            self.stopping = true;
            self.signal.signal(app.io);
            self.mutex.unlock(app.io);
            task.cancel(app.io);
        }
        if (self.targets) |*t| t.arena.deinit();
        if (self.pending_dirs) |*d| d.arena.deinit();
        if (self.scope) |p| app.alloc.free(p);
        if (self.pending) |*s| s.deinit(app.alloc);
        if (self.visible) |*s| s.deinit(app.alloc);
    }
};

test "repository status: nested tree maps XY changes, deletion and rename parents" {
    const alloc = std.testing.allocator;
    var snapshot: Snapshot = .{
        .prefix = try alloc.dupe(u8, "src/\n"),
        .bytes = try alloc.dupe(u8, " M src/深/a b\x00MM src/both\x00A  src/new\x00R  dest\x00src/old-dir/from\x00 D src/gone/file\x00!! src/ignored\x00AA src/conflict\x00?? src/untracked\x00?? src/embedded/\x00 M src-like/sibling\x00"),
    };
    defer snapshot.deinit(alloc);
    try snapshot.indexPaths(alloc);
    try std.testing.expectEqualStrings(".M", &snapshot.paths.get("深/a b").?.text);
    try std.testing.expectEqualStrings("MM", &snapshot.paths.get("both").?.text);
    try std.testing.expectEqualStrings("A.", &snapshot.paths.get("new").?.text);
    try std.testing.expectEqualStrings(".D", &snapshot.paths.get("gone/file").?.text);
    try std.testing.expectEqualStrings("??", &snapshot.paths.get("untracked").?.text);
    try std.testing.expectEqualStrings("??", &snapshot.paths.get("embedded").?.text);
    try std.testing.expect(snapshot.paths.get("conflict").?.color == .conflict);
    for ([_][]const u8{ "深", "gone", "old-dir" }) |dir|
        try std.testing.expect(snapshot.paths.get(dir).?.color == .directory);
    for ([_][]const u8{ "ignored", "dest", "src-like/sibling" }) |path|
        try std.testing.expect(snapshot.paths.get(path) == null);
}

test "Navigator only accepts Review snapshots for its unchanged scope and scan" {
    var monitor: Monitor = .{ .scope = @constCast("/repo"), .generation = 4, .scan = 8 };
    const target = monitor.reviewTarget(std.testing.io).?;
    try std.testing.expect(monitor.accepts(target));
    monitor.reading = true;
    try std.testing.expect(monitor.reviewTarget(std.testing.io) == null);
    try std.testing.expect(!monitor.accepts(target));
    monitor.reading = false;
    monitor.scan += 1;
    try std.testing.expect(!monitor.accepts(target));
    monitor.scan -= 1;
    monitor.generation += 1;
    try std.testing.expect(!monitor.accepts(target));
    monitor.generation -= 1;
    monitor.scope = @constCast("/another-repo");
    try std.testing.expect(!monitor.accepts(target));
}
