//! File picker enumeration. Unavailable children do not invalidate readable
//! siblings; failure to enumerate the root remains an actionable error.
const std = @import("std");
const fzy = @import("../util/fzy.zig");

pub const HomeSearch = struct {
    const depth_limit = 32;

    alloc: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    fallback: []const u8,
    query: []const u8,
    wake_ctx: *anyopaque,
    wake: *const fn (*anyopaque) void,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    files: std.ArrayList([]u8) = .empty,
    scores: [20]f64 = undefined,
    used_fallback: bool = false,
    err: ?anyerror = null,
    left: usize = 100_000,
    limited: bool = false,
    min_depth: usize = 0,
    max_depth: usize = 1,

    pub fn run(self: *HomeSearch) void {
        defer {
            self.done.store(true, .release);
            self.wake(self.wake_ctx);
        }
        if (self.home) |home| {
            if (self.scan(home)) |_| {
                return;
            } else |err| {
                if (!unavailable(err)) {
                    self.err = err;
                    return;
                }
            }
            deinit(self.alloc, &self.files);
            self.files = .empty;
        }
        self.used_fallback = true;
        self.scan(self.fallback) catch |err| {
            self.err = err;
        };
    }

    fn scan(self: *HomeSearch, root: []const u8) !void {
        if (self.cancelled.load(.acquire)) return;
        var dir = try std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true });
        defer dir.close(self.io);
        self.left = 100_000;
        self.min_depth = 0;
        self.limited = false;
        // Look in shallow folders first, so a large deep directory can't
        // consume the budget before sibling folders are searched.
        for ([_]usize{ 0, 1, 4, depth_limit }) |depth| {
            self.max_depth = depth;
            try walk(self.alloc, self.io, dir, "", &self.files, self, 0);
            if ((self.query.len == 0 and depth == 1) or self.limited or self.cancelled.load(.acquire)) return;
            self.min_depth = depth + 1;
        }
    }

    pub fn destroy(self: *HomeSearch) void {
        self.cancelled.store(true, .release);
        if (self.thread) |t| t.join();
        const alloc = self.alloc;
        deinit(alloc, &self.files);
        if (self.home) |home| alloc.free(home);
        alloc.free(self.fallback);
        alloc.free(self.query);
        alloc.destroy(self);
    }

    fn remember(self: *HomeSearch, path: []u8) !bool {
        const score = if (self.query.len == 0)
            0
        else blk: {
            // Reject non-matches before allocating fzy's scoring tables.
            var matched: usize = 0;
            for (path) |ch| {
                if (std.ascii.toLower(ch) != std.ascii.toLower(self.query[matched])) continue;
                matched += 1;
                if (matched == self.query.len) break;
            }
            if (matched < self.query.len) return false;
            const m = try fzy.match(self.alloc, path, self.query) orelse return false;
            defer self.alloc.free(m.positions);
            break :blk m.score;
        };
        const n = self.files.items.len;
        var at = n;
        while (at > 0 and score > self.scores[at - 1]) at -= 1;
        if (at == self.scores.len) return false;
        if (n == self.scores.len) self.alloc.free(self.files.pop().?);
        try self.files.insert(self.alloc, at, path);
        const end = self.files.items.len - 1;
        std.mem.copyBackwards(f64, self.scores[at + 1 .. end + 1], self.scores[at..end]);
        self.scores[at] = score;
        return true;
    }
};

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
    try walk(alloc, io, dir, "", &files, null, 0);
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

fn walk(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, files: *std.ArrayList([]u8), search: ?*HomeSearch, depth: usize) !void {
    var it = dir.iterate();
    while (true) {
        if (search) |job| {
            if (job.cancelled.load(.acquire)) return;
            if (job.query.len == 0 and job.files.items.len == job.scores.len) return;
        }
        const entry = (try it.next(io)) orelse break;
        if (search) |job| {
            if (job.left == 0) {
                job.limited = true;
                return;
            }
            job.left -= 1;
        }
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        var retained = false;
        defer if (!retained) alloc.free(path);
        switch (entry.kind) {
            .directory => {
                if (search) |job| {
                    if (depth == job.max_depth) {
                        if (depth == HomeSearch.depth_limit) job.limited = true;
                        continue;
                    }
                }
                // An entry can disappear, change type or permissions between
                // readdir and open. Do not follow a replacement symlink.
                var sub = dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                    if (unavailable(err)) continue;
                    return err;
                };
                defer sub.close(io);
                const sub_prefix = try std.fmt.allocPrint(alloc, "{s}/", .{path});
                defer alloc.free(sub_prefix);
                walk(alloc, io, sub, sub_prefix, files, search, depth + 1) catch |err| {
                    if (!unavailable(err)) return err;
                };
            },
            .file => {
                if (search) |job| {
                    if (depth >= job.min_depth) retained = try job.remember(path);
                } else {
                    try files.append(alloc, path);
                    retained = true;
                }
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
