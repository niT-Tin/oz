//! File-tree create policy: one leaf name in the captured directory.
//! A trailing slash requests a directory. Existing entries are never replaced.
const std = @import("std");

pub const Name = struct { leaf: []const u8, directory: bool };

pub fn parseName(input: []const u8) error{InvalidName}!Name {
    if (input.len == 0 or !std.unicode.utf8ValidateSlice(input)) return error.InvalidName;
    const directory = input[input.len - 1] == '/';
    const leaf = if (directory) input[0 .. input.len - 1] else input;
    if (leaf.len == 0 or std.mem.trim(u8, leaf, " \t").len == 0 or
        std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or
        std.mem.indexOfAny(u8, leaf, "/\\") != null) return error.InvalidName;
    for (leaf) |b| if (b < 0x20 or b == 0x7f) return error.InvalidName;
    return .{ .leaf = leaf, .directory = directory };
}

pub fn create(io: std.Io, base: []const u8, input: []const u8) !void {
    const name = try parseName(input);
    var dir = try std.Io.Dir.cwd().openDir(io, base, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (name.directory) {
        try dir.createDir(io, name.leaf, .default_dir);
    } else {
        var file = try dir.createFile(io, name.leaf, .{ .exclusive = true, .truncate = false });
        file.close(io);
    }
}

test "file tree create: leaf names and trailing slash policy" {
    const t = std.testing;
    try t.expectEqualStrings("child.txt", (try parseName("child.txt")).leaf);
    try t.expect(!(try parseName("child.txt")).directory);
    try t.expectEqualStrings("子 目录", (try parseName("子 目录/")).leaf);
    try t.expect((try parseName("子 目录/")).directory);
    for ([_][]const u8{ "", " ", ".", "..", "../escape", "/absolute", "a/b", "a//", "a\\b", "x\x00y", "x\ny", "\xff" }) |bad| {
        try t.expectError(error.InvalidName, parseName(bad));
    }
}

test "file tree create: exclusive disk writes preserve files and symlinks" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "KEEP_BYTES" });
    try t.expectError(error.PathAlreadyExists, create(io, base, "keep.txt"));
    try tmp.dir.symLink(io, "keep.txt", "alias.txt", .{});
    try t.expectError(error.PathAlreadyExists, create(io, base, "alias.txt"));
    try create(io, base, "new.txt");
    try create(io, base, "folder/");
    try t.expectError(error.PathAlreadyExists, create(io, base, "folder/"));
    const bytes = try tmp.dir.readFileAlloc(io, "keep.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("KEEP_BYTES", bytes);
    var dir = try tmp.dir.openDir(io, "folder", .{});
    dir.close(io);
    _ = try tmp.dir.statFile(io, "new.txt", .{});
}
