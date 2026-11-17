//! Filesystem argument spelling, independent from the UI and directory IO.
const std = @import("std");

pub const Prefix = struct { directory: []const u8, name: []const u8 };

pub fn split(prefix: []const u8) Prefix {
    if (std.mem.eql(u8, prefix, "~")) return .{ .directory = "~/", .name = "" };
    if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |slash|
        return .{ .directory = prefix[0 .. slash + 1], .name = prefix[slash + 1 ..] };
    return .{ .directory = "", .name = prefix };
}

/// Only the user's leading `~` is expanded; `~someone` and `./~/` stay literal.
/// A null result means the caller may keep borrowing the original spelling.
pub fn homeExpansion(a: std.mem.Allocator, path: []const u8, home: ?[]const u8) !?[]u8 {
    if (path.len == 0 or path[0] != '~' or (path.len > 1 and path[1] != '/')) return null;
    const h = home orelse return null;
    if (h.len == 0) return null;
    const base = std.mem.trimEnd(u8, h, "/");
    if (path.len == 1) return try a.dupe(u8, if (base.len == 0) "/" else base);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ base, path[2..] });
}

pub fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const left_dir = std.mem.endsWith(u8, lhs, "/");
    const right_dir = std.mem.endsWith(u8, rhs, "/");
    if (left_dir != right_dir) return left_dir;
    return std.mem.lessThan(u8, lhs, rhs);
}

test "path completion: directory and filename retain absolute, home and Unicode spelling" {
    for ([_][]const u8{ "", "ab", "../ab", "/tmp/新 文件", "~/src/ab", "folder/", "~" }, [_][]const u8{ "", "", "../", "/tmp/", "~/src/", "folder/", "~/" }, [_][]const u8{ "", "ab", "ab", "新 文件", "ab", "", "" }) |input, dir, name| {
        const p = split(input);
        try std.testing.expectEqualStrings(dir, p.directory);
        try std.testing.expectEqualStrings(name, p.name);
    }
    try std.testing.expect(lessThan({}, "folder/", "a.txt"));
    try std.testing.expect(lessThan({}, "a.txt", "b.txt"));
}

test "path completion: home expansion preserves literal tildes and root homes" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "~", "~/新 文件", "~/src/", "~" }, [_][]const u8{ "/home/u/", "/home/u/", "/", "/" }, [_][]const u8{ "/home/u", "/home/u/新 文件", "/src/", "/" }) |input, home, expected| {
        const expanded = (try homeExpansion(a, input, home)).?;
        defer a.free(expanded);
        try std.testing.expectEqualStrings(expected, expanded);
    }
    try std.testing.expect(try homeExpansion(a, "~other/a", "/home/u") == null);
    try std.testing.expect(try homeExpansion(a, "./~/a", "/home/u") == null);
    try std.testing.expect(try homeExpansion(a, "~/a", null) == null);
}
