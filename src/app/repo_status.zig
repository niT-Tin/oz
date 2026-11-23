//! Borrowed records from `git status --porcelain=v1 -z`.
const std = @import("std");

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
