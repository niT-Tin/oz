//! Borrowed records from `git status --porcelain=v1 -z`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const status_argv = [_][]const u8{
    "git",            "--no-optional-locks", "--literal-pathspecs",   "status",
    "--porcelain=v1", "-z",                  "--untracked-files=all", "--find-renames",
};

pub const Record = struct {
    index: u8,
    worktree: u8,
    path: []const u8,
    original_path: ?[]const u8,

    pub fn conflicted(self: Record) bool {
        return self.index == 'U' or self.worktree == 'U' or
            (self.index == 'A' and self.worktree == 'A') or
            (self.index == 'D' and self.worktree == 'D');
    }
};

pub const Iterator = struct {
    remaining: []const u8,

    fn field(self: *Iterator) ![]const u8 {
        const end = std.mem.indexOfScalar(u8, self.remaining, 0) orelse return error.InvalidPorcelain;
        if (end == 0) return error.InvalidPorcelain;
        const value = self.remaining[0..end];
        self.remaining = self.remaining[end + 1 ..];
        return value;
    }

    pub fn next(self: *Iterator) !?Record {
        if (self.remaining.len == 0) return null;
        const entry = try self.field();
        if (entry.len < 4 or entry[2] != ' ') return error.InvalidPorcelain;
        const renamed = std.mem.indexOfAny(u8, entry[0..2], "RC") != null;
        return .{
            .index = entry[0],
            .worktree = entry[1],
            .path = entry[3..],
            .original_path = if (renamed) try self.field() else null,
        };
    }
};

test "repository status: NUL preserves paths and consumes rename/copy sources" {
    var it: Iterator = .{ .remaining = "RM new\n名\x00old name\x00 C copy\x00src\x00UU conflict\x00" };
    const rename = (try it.next()).?;
    try std.testing.expectEqual(@as(u8, 'R'), rename.index);
    try std.testing.expectEqual(@as(u8, 'M'), rename.worktree);
    try std.testing.expectEqualStrings("new\n名", rename.path);
    try std.testing.expectEqualStrings("old name", rename.original_path.?);
    try std.testing.expectEqualStrings("src", (try it.next()).?.original_path.?);
    try std.testing.expect((try it.next()).?.conflicted());
    try std.testing.expectEqual(null, try it.next());
    for ([_][]const u8{ "M", "M  \x00", "R  new\x00", "R  new\x00unfinished" }) |broken| {
        var invalid: Iterator = .{ .remaining = broken };
        try std.testing.expectError(error.InvalidPorcelain, invalid.next());
    }
}

pub const Badge = struct {
    text: [2]u8,
    color: enum { modified, added, deleted, renamed, conflict, directory },

    fn fromRecord(r: Record) Badge {
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

pub const Snapshot = struct {
    /// Map keys are slices of the original NUL-delimited command output.
    bytes: []u8,
    prefix: []u8,
    paths: std.StringHashMapUnmanaged(Badge) = .empty,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
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

    pub fn indexPaths(self: *Snapshot, alloc: Allocator) !void {
        // --show-prefix always appends a newline, even for the empty prefix.
        const prefix = std.mem.trimEnd(u8, self.prefix, "\n");
        var iter: Iterator = .{ .remaining = self.bytes };
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

    /// Build the same badge index from Git Review's fresh porcelain. Both
    /// the copy and indexing run before the worker publishes the result.
    pub fn copy(alloc: Allocator, bytes: []const u8, prefix: []const u8) !Snapshot {
        const owned = try alloc.dupe(u8, bytes);
        errdefer alloc.free(owned);
        const subdir = try alloc.dupe(u8, prefix);
        errdefer alloc.free(subdir);
        var snapshot: Snapshot = .{ .bytes = owned, .prefix = subdir };
        errdefer snapshot.paths.deinit(alloc);
        try snapshot.indexPaths(alloc);
        return snapshot;
    }
};

pub const ReviewTarget = struct {
    scope: []const u8,
    generation: u64,
    scan: u64,
};
