//! File picker enumeration. Unavailable children do not invalidate readable
//! siblings; failure to enumerate the root remains an actionable error.
const std = @import("std");

pub fn deinit(alloc: std.mem.Allocator, files: *std.ArrayList([]u8)) void {
    for (files.items) |path| alloc.free(path);
    files.deinit(alloc);
    files.* = .empty;
}

pub fn collect(alloc: std.mem.Allocator, io: std.Io, root: []const u8) !std.ArrayList([]u8) {
    var files: std.ArrayList([]u8) = .empty;
    errdefer deinit(alloc, &files);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    try walk(alloc, io, dir, "", &files);
    return files;
}

fn unavailable(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        error.NoDevice,
        error.NetworkNotFound,
        => true,
        else => false,
    };
}

fn walk(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, files: *std.ArrayList([]u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        var retained = false;
        defer if (!retained) alloc.free(path);
        switch (entry.kind) {
            .directory => {
                // An entry can disappear, change type or permissions between
                // readdir and open. Do not follow a replacement symlink.
                var sub = dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                    if (unavailable(err)) continue;
                    return err;
                };
                defer sub.close(io);
                const sub_prefix = try std.fmt.allocPrint(alloc, "{s}/", .{path});
                defer alloc.free(sub_prefix);
                walk(alloc, io, sub, sub_prefix, files) catch |err| {
                    if (!unavailable(err)) return err;
                };
            },
            .file => {
                try files.append(alloc, path);
                retained = true;
            },
            else => {},
        }
    }
}

fn allocationProbe(alloc: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    var files = try collect(alloc, io, root);
    defer deinit(alloc, &files);
    try std.testing.expectEqual(@as(usize, 2), files.items.len);
    for ([_][]const u8{ "visible.txt", "nested/中.txt" }) |expected| {
        var found = false;
        for (files.items) |path| {
            if (std.mem.eql(u8, expected, path)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "picker permissions: enumeration preserves filters and releases partial results on allocation failure" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.createDirPath(io, ".hidden");
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.createDirPath(io, "zig-pkg");
    for ([_][]const u8{ "visible.txt", "nested/中.txt", ".hidden/secret", ".dotfile", "node_modules/package", "zig-out/binary", "zig-pkg/package" }) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "fixture" });
    }
    try tmp.dir.symLink(io, ".", "loop", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try std.testing.checkAllAllocationFailures(alloc, allocationProbe, .{ io, root });
}
