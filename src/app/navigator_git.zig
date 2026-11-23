//! One read-only Git status snapshot for the visible Files tree. The worker
//! sleeps between scans so external index, branch and worktree changes arrive
//! without polling the render loop. No editor buffer contents enter the query.
const std = @import("std");
const porcelain = @import("repo_status.zig");
const App = @import("../app.zig").App;
const Allocator = std.mem.Allocator;

pub const Badge = struct {
    text: [2]u8,
    color: enum { modified, added, deleted, renamed, conflict, directory },

    fn fromRecord(r: porcelain.Record) Badge {
        const kind = if (r.worktree != ' ') r.worktree else r.index;
        return .{
            .text = .{ if (r.index == ' ') '.' else r.index, if (r.worktree == ' ') '.' else r.worktree },
            .color = if (r.conflicted()) .conflict else switch (kind) {
                'A', '?' => .added,
                'D' => .deleted,
                'R', 'C' => .renamed,
                else => .modified,
            },
        };
    }
};

const Snapshot = struct {
    /// Map keys are slices of the original NUL-delimited command output.
    bytes: []u8,
    prefix: []u8,
    paths: std.StringHashMapUnmanaged(Badge) = .empty,

    fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.paths.deinit(alloc);
        alloc.free(self.bytes);
        alloc.free(self.prefix);
    }

    fn markParents(self: *Snapshot, alloc: Allocator, path: []const u8) !void {
        var parent = std.fs.path.dirname(path);
        while (parent) |dir| : (parent = std.fs.path.dirname(dir)) {
            const slot = try self.paths.getOrPut(alloc, dir);
            if (slot.found_existing) break;
            slot.value_ptr.* = .{ .text = " *".*, .color = .directory };
        }
    }

    fn indexPaths(self: *Snapshot, alloc: Allocator) !void {
        // --show-prefix always appends a newline, even for the empty prefix.
        const prefix = std.mem.trimEnd(u8, self.prefix, "\n");
        var iter: porcelain.Iterator = .{ .remaining = self.bytes };
        while (try iter.next()) |record| {
            if (record.index == '!') continue;
            if (std.mem.startsWith(u8, record.path, prefix)) {
                // Git keeps a trailing slash for embedded, untracked repositories.
                const path = std.mem.trimEnd(u8, record.path[prefix.len..], "/");
                try self.paths.put(alloc, path, Badge.fromRecord(record));
                try self.markParents(alloc, path);
            }
            if (record.index == 'R' or record.worktree == 'R') {
                const source = record.original_path.?;
                if (std.mem.startsWith(u8, source, prefix))
                    try self.markParents(alloc, source[prefix.len..]);
            }
        }
    }

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
};

pub const Monitor = struct {
    // The UI thread owns visible. The worker publishes pending under mutex.
    visible: ?Snapshot = null,
    pending: ?Snapshot = null,
    has_reply: bool = false,
    scope: ?[]u8 = null,
    generation: u64 = 0,
    stopping: bool = false,
    mutex: std.Io.Mutex = .init,
    signal: std.Io.Condition = .init,
    task: ?std.Io.Future(void) = null,

    fn matches(self: *const Monitor, root: ?[]const u8) bool {
        if (self.scope) |scope| return root != null and std.mem.eql(u8, scope, root.?);
        return root == null;
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
        if (!self.matches(root)) {
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
        return changed;
    }

    fn worker(self: *Monitor, app: *App) void {
        const io = app.io;
        var seen: u64 = 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.stopping) {
            if (self.scope == null or self.generation == seen) {
                const wait: std.Io.Timeout = if (self.scope == null) .none else .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(1500) } };
                self.signal.waitTimeout(io, &self.mutex, wait) catch |err| switch (err) {
                    error.Canceled => return,
                    error.Timeout => {},
                };
            }
            if (self.stopping) return;
            const scope = self.scope orelse continue;
            seen = self.generation;
            const dir = app.alloc.dupe(u8, scope) catch continue;
            self.mutex.unlock(io);
            var result: ?Snapshot = Snapshot.read(app.alloc, io, dir) catch null;
            app.alloc.free(dir);
            self.mutex.lockUncancelable(io);
            if (self.stopping or self.generation != seen) {
                if (result) |*s| s.deinit(app.alloc);
                continue;
            }
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
