//! Stable disk baselines and conflict-checked saves. Document bytes are owned
//! by the piece table, never backed by a mutable file mapping.
const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;

const OwnedOrigin = @import("piece_table.zig").OwnedOrigin;

const Hash = [32]u8;

pub fn hash(bytes: []const u8) Hash {
    var result: Hash = undefined;
    std.crypto.hash.Blake3.hash(bytes, &result, .{});
    return result;
}

/// Compare full blocks explicitly: the scalar early-exit loop used by some
/// Zig backends spends more CPU on unchanged files than the original digest.
fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    const lanes = std.simd.suggestVectorLength(u8) orelse 1;
    var pos: usize = 0;
    if (lanes > 1) {
        const Block = @Vector(lanes, u8);
        while (a.len - pos >= lanes) : (pos += lanes) {
            const left: Block = a[pos..][0..lanes].*;
            const right: Block = b[pos..][0..lanes].*;
            if (!@reduce(.And, left == right)) return false;
        }
    }
    return std.mem.eql(u8, a[pos..], b[pos..]);
}

const PathError = std.Io.Dir.RealPathFileAllocError || std.Io.Dir.StatFileError || error{PathChanged};

fn targetPath(alloc: std.mem.Allocator, io: std.Io, path: []const u8) PathError![]u8 {
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch |err| {
        if (err != error.FileNotFound) return err;
        // A dangling symlink is not a new file. Never replace the link itself.
        if (std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| {
            return error.PathChanged;
        } else |stat_err| if (stat_err != error.FileNotFound) return stat_err;
        // A new buffer may name a file whose parent is not created yet.
        // Resolve existing ancestors and retain the missing suffix, then
        // recheck the resulting target when the user eventually saves.
        const parent = try targetPath(alloc, io, std.fs.path.dirname(path) orelse ".");
        defer alloc.free(parent);
        return std.Io.Dir.path.join(alloc, &.{ parent, std.fs.path.basename(path) });
    };
    // realPathFileAlloc owns a sentinel byte; keep its slice type until
    // freeing it rather than losing that byte through a []u8 coercion.
    defer alloc.free(resolved);
    return alloc.dupe(u8, resolved);
}

/// The initial snapshot shares the immutable bytes already loaded for editing.
/// Later saves accept borrowed text and retain only its digest.
const Content = union(enum) {
    missing,
    origin: *OwnedOrigin,
    digest: Hash,
};

pub const Baseline = struct {
    /// Canonical target, while Buffer.path retains the user's spelling/URI.
    target: []u8,
    content: Content = .missing,
    saved_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, path: []const u8, bytes: ?[]const u8) !Baseline {
        var baseline = Baseline{ .target = try targetPath(alloc, io, path) };
        if (bytes) |b| baseline.didWrite(b);
        return baseline;
    }

    pub fn deinit(self: *Baseline, alloc: std.mem.Allocator) void {
        if (self.content == .origin) self.content.origin.release();
        alloc.free(self.target);
        self.* = undefined;
    }

    pub fn fromOrigin(alloc: std.mem.Allocator, io: std.Io, path: []const u8, pt: *PieceTable) !Baseline {
        if (pt.origin_mapping != null) return init(alloc, io, path, pt.origin);
        const target = try targetPath(alloc, io, path);
        errdefer alloc.free(target);
        return .{ .target = target, .saved_len = pt.origin.len, .content = .{ .origin = try pt.retainOwnedOrigin() } };
    }

    pub fn didWrite(self: *Baseline, bytes: []const u8) void {
        if (self.content == .origin and sameBytes(self.content.origin.bytes, bytes)) return;
        const digest = hash(bytes);
        if (self.content == .origin) self.content.origin.release();
        self.content = .{ .digest = digest };
        self.saved_len = bytes.len;
    }

    pub fn matchesBytes(self: *const Baseline, bytes: []const u8) bool {
        if (self.saved_len != bytes.len) return false;
        return switch (self.content) {
            .missing => false,
            .origin => |owner| sameBytes(owner.bytes, bytes),
            .digest => |expected| std.mem.eql(u8, &expected, &hash(bytes)),
        };
    }

    /// Compare history against the last successful write, without disk I/O
    /// or flattening the document. Undo usually restores original pieces.
    pub fn matchesBuffer(self: *const Baseline, pt: *const PieceTable) bool {
        if (pt.len() != self.saved_len) return false;
        switch (self.content) {
            .missing => return pt.len() == 0,
            .origin => |owner| {
                var offset: usize = 0;
                for (pt.pieces.items) |piece| {
                    const same_span = pt.shared_origin == owner and piece.source == .origin and piece.start == offset;
                    if (!same_span and !sameBytes(pt.pieceBytes(piece), owner.bytes[offset..][0..piece.len])) return false;
                    offset += piece.len;
                }
                return true;
            },
            .digest => |expected| {
                var hasher = std.crypto.hash.Blake3.init(.{});
                var it = pt.iterator();
                while (it.next()) |p| hasher.update(pt.pieceBytes(p));
                var actual: Hash = undefined;
                hasher.final(&actual);
                return std.mem.eql(u8, &expected, &actual);
            },
        }
    }

    fn verify(self: *const Baseline, alloc: std.mem.Allocator, io: std.Io, path: []const u8, force: bool) !void {
        const now = try targetPath(alloc, io, path);
        defer alloc.free(now);
        if (!std.mem.eql(u8, now, self.target)) return error.PathChanged;
        if (force) return;

        const file = std.Io.Dir.cwd().openFile(io, self.target, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (self.content == .missing) return;
            return error.FileChanged;
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotAFile;
        if (self.content == .missing or stat.size != self.saved_len) return error.FileChanged;

        var hasher = std.crypto.hash.Blake3.init(.{});
        var buf: [64 * 1024]u8 = undefined;
        var pos: usize = 0;
        while (true) {
            const n = file.readStreaming(io, &.{&buf}) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            if (n > self.saved_len - pos) return error.FileChanged;
            switch (self.content) {
                .origin => |owner| if (!sameBytes(owner.bytes[pos..][0..n], buf[0..n])) return error.FileChanged,
                .digest => hasher.update(buf[0..n]),
                .missing => unreachable,
            }
            pos += n;
        }
        if (pos != self.saved_len) return error.FileChanged;
        if (self.content == .digest) {
            var actual: Hash = undefined;
            hasher.final(&actual);
            if (!std.mem.eql(u8, &actual, &self.content.digest)) return error.FileChanged;
        }
    }

    pub fn write(self: *Baseline, alloc: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8, force: bool) !void {
        try self.verify(alloc, io, path, force);
        // Resolve the link to its target, then rename beside that target. The
        // symlink and its spelling in the buffer/LSP remain intact.
        const tmp = try std.fmt.allocPrint(alloc, "{s}.oztmp{d}.{d}", .{
            self.target, std.c.getpid(), std.Io.Timestamp.now(io, .awake).nanoseconds,
        });
        defer alloc.free(tmp);
        var flags: std.Io.Dir.CreateFileOptions = .{ .exclusive = true };
        var permissions: ?std.Io.File.Permissions = null;
        if (std.Io.Dir.cwd().statFile(io, self.target, .{})) |st| {
            flags.permissions = st.permissions;
            permissions = st.permissions;
        } else |err| if (err != error.FileNotFound) return err;
        const file = try std.Io.Dir.cwd().createFile(io, tmp, flags);
        defer file.close(io);
        defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try file.writeStreamingAll(io, bytes);
        // Creation applies umask; restore the exact original permission bits.
        if (permissions) |mode| try file.setPermissions(io, mode);
        try file.sync(io);
        // Recheck after writing the temp as well, so changes during a large
        // save are not silently replaced. This is optimistic conflict
        // detection, not a filesystem compare-and-swap primitive.
        try self.verify(alloc, io, path, force);
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.target, io);
        self.didWrite(bytes);
    }
};

test "disk baseline: original spans, equal-length edits and subsequent saves" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original", .data = "abcdef" });
    const path = try tmp.dir.realPathFileAlloc(io, "original", alloc);
    defer alloc.free(path);
    var pt = try PieceTable.init(alloc, "abcdef");
    defer pt.deinit();
    var disk = try Baseline.fromOrigin(alloc, io, path, &pt);
    defer disk.deinit(alloc);
    _ = try pt.replace(1, 1, "X");
    try std.testing.expect(!disk.matchesBuffer(&pt));
    _ = try pt.replace(1, 1, "b");
    try std.testing.expect(disk.matchesBuffer(&pt));
    // Same length and pieces from the original, but at the wrong offset.
    _ = try pt.replace(0, 1, "");
    _ = try pt.replace(pt.len(), 0, "a");
    try std.testing.expect(!disk.matchesBuffer(&pt));
    try disk.write(alloc, io, path, "bcdefa", false);
    try std.testing.expect(disk.matchesBuffer(&pt));
    _ = try pt.replace(0, pt.len(), "abcdef");
    try std.testing.expect(!disk.matchesBuffer(&pt));
}

test "disk baseline: history compares pieces against the last successful write" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "new.txt" });
    defer alloc.free(path);
    var disk = try Baseline.init(alloc, io, path, null);
    defer disk.deinit(alloc);
    var pt = try PieceTable.init(alloc, "");
    defer pt.deinit();
    try std.testing.expect(disk.matchesBuffer(&pt));
    _ = try pt.replace(0, 0, "abc");
    try std.testing.expect(!disk.matchesBuffer(&pt));
    try disk.write(alloc, io, path, "abc", false);
    try std.testing.expect(disk.matchesBuffer(&pt));
    _ = try pt.replace(1, 1, "X");
    try std.testing.expect(!disk.matchesBuffer(&pt));
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "external" });
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "aXc", false));
    try std.testing.expect(!disk.matchesBuffer(&pt));
    _ = try pt.replace(1, 1, "b");
    try std.testing.expect(disk.matchesBuffer(&pt));
}

test "disk baseline: a new file cannot overwrite a later external creation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "new.txt" });
    defer alloc.free(path);
    var disk = try Baseline.init(alloc, io, path, null);
    defer disk.deinit(alloc);
    const external = try tmp.dir.createFile(io, "new.txt", .{});
    try external.writeStreamingAll(io, "external");
    external.close(io);
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "mine", false));
    try disk.write(alloc, io, path, "mine", true);
    try disk.write(alloc, io, path, "mine again", false);
    const saved = try tmp.dir.readFileAlloc(io, "new.txt", alloc, .limited(100));
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("mine again", saved);
}

test "disk baseline: a new file can be opened before its parent is created" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "new", "nested", "file.txt" });
    defer alloc.free(path);
    var disk = try Baseline.init(alloc, io, path, null);
    defer disk.deinit(alloc);
    try tmp.dir.createDirPath(io, "new/nested");
    try disk.write(alloc, io, path, "retained new buffer", false);
    const saved = try tmp.dir.readFileAlloc(io, "new/nested/file.txt", alloc, .limited(100));
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("retained new buffer", saved);
}

test "disk baseline: even a forced write refuses a retargeted or dangling symlink" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "link.txt" });
    defer alloc.free(path);
    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        const f = try tmp.dir.createFile(io, name, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "original");
    }
    try tmp.dir.symLink(io, "a.txt", "link.txt", .{});
    var disk = try Baseline.init(alloc, io, path, "original");
    defer disk.deinit(alloc);
    try tmp.dir.deleteFile(io, "link.txt");
    try tmp.dir.symLink(io, "b.txt", "link.txt", .{});
    try std.testing.expectError(error.PathChanged, disk.write(alloc, io, path, "mine", true));
    try tmp.dir.deleteFile(io, "link.txt");
    try tmp.dir.symLink(io, "missing.txt", "link.txt", .{});
    try std.testing.expectError(error.PathChanged, disk.write(alloc, io, path, "mine", true));
    const saved = try tmp.dir.readFileAlloc(io, "b.txt", alloc, .limited(100));
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("original", saved);
}

test "disk baseline: shared open bytes survive replacing the entire piece table" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "first" });
    const path = try tmp.dir.realPathFileAlloc(io, "file", alloc);
    defer alloc.free(path);

    var disk = blk: {
        var pt = try PieceTable.init(alloc, "first");
        defer pt.deinit();
        const opened = try Baseline.fromOrigin(alloc, io, path, &pt);
        try std.testing.expectEqual(pt.origin.ptr, opened.content.origin.bytes.ptr);
        break :blk opened;
    };
    defer disk.deinit(alloc);
    var other = try PieceTable.init(alloc, "other");
    defer other.deinit();
    try std.testing.expect(!disk.matchesBuffer(&other));
    try std.testing.expect(!disk.matchesBytes("other"));
    _ = try other.replace(0, 5, "first");
    try std.testing.expect(disk.matchesBuffer(&other));
    try disk.write(alloc, io, path, "other", false);
    try std.testing.expect(disk.content == .digest);
    try std.testing.expect(disk.matchesBytes("other"));
    try std.testing.expect(!disk.matchesBuffer(&other));
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "third" });
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "first", false));
}

test "disk baseline: same-size same-mtime change after temp sync prevents first save" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const size = 2 * 1024 * 1024 + 3;
    const contents = try alloc.alloc(u8, size);
    defer alloc.free(contents);
    @memset(contents, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = contents });
    const path = try tmp.dir.realPathFileAlloc(io, "file", alloc);
    defer alloc.free(path);
    var pt = try PieceTable.init(alloc, contents);
    defer pt.deinit();
    var disk = try Baseline.fromOrigin(alloc, io, path, &pt);
    defer disk.deinit(alloc);

    // Inject a real, same-inode write exactly between verify calls.
    const Race = struct {
        threadlocal var target: std.Io.File = undefined;
        fn sync(_: ?*anyopaque, temp: std.Io.File) std.Io.File.SyncError!void {
            const real_io = std.testing.io;
            try temp.sync(real_io);
            const before = target.stat(real_io) catch return error.InputOutput;
            target.writePositionalAll(real_io, "X", size - 1) catch return error.InputOutput;
            target.setTimestamps(real_io, .{ .modify_timestamp = .{ .new = before.mtime } }) catch return error.InputOutput;
        }
    };
    const external = try tmp.dir.openFile(io, "file", .{ .mode = .read_write });
    defer external.close(io);
    Race.target = external;
    const original_stat = try external.stat(io);
    var vtable = io.vtable.*;
    vtable.fileSync = Race.sync;
    const racing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.FileChanged, disk.write(alloc, racing_io, path, "mine", false));
    const after = try external.stat(io);
    try std.testing.expectEqual(original_stat.size, after.size);
    try std.testing.expectEqual(original_stat.mtime, after.mtime);
    const retained = try tmp.dir.readFileAlloc(io, "file", alloc, .limited(size + 1));
    defer alloc.free(retained);
    try std.testing.expectEqual(@as(u8, 'X'), retained[size - 1]);
    try std.testing.expectEqualSlices(u8, contents[0 .. size - 1], retained[0 .. size - 1]);
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "mine", false));
    try std.testing.expect(disk.matchesBuffer(&pt));
    try external.writePositionalAll(io, "a", size - 1);
    try disk.write(alloc, io, path, "mine", false);
    const saved = try tmp.dir.readFileAlloc(io, "file", alloc, .limited(size));
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("mine", saved);
}

test "disk baseline: absence differs from existing empty open snapshot" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "empty", alloc);
    defer alloc.free(path);
    var pt = try PieceTable.init(alloc, "");
    defer pt.deinit();
    var disk = try Baseline.fromOrigin(alloc, io, path, &pt);
    defer disk.deinit(alloc);
    try tmp.dir.deleteFile(io, "empty");
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "", false));
    var missing = try Baseline.init(alloc, io, path, null);
    defer missing.deinit(alloc);
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try std.testing.expectError(error.FileChanged, missing.write(alloc, io, path, "", false));
    try std.testing.expect(!missing.matchesBytes(""));
    try disk.write(alloc, io, path, "", false);
    try std.testing.expect(disk.matchesBytes(""));
}

test "disk baseline: a shared file mapping never becomes the open snapshot" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(io, "file", alloc);
    defer alloc.free(path);
    const file = try tmp.dir.openFile(io, "file", .{ .mode = .read_write });
    defer file.close(io);
    const mapping = try std.posix.mmap(null, 3, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0);
    var pt = try PieceTable.initMapped(alloc, mapping);
    defer pt.deinit();
    var disk = try Baseline.fromOrigin(alloc, io, path, &pt);
    defer disk.deinit(alloc);
    try file.writePositionalAll(io, "new", 0);
    try std.testing.expectEqualStrings("new", pt.origin);
    try std.testing.expect(!disk.matchesBuffer(&pt));
    try std.testing.expect(disk.matchesBytes("old"));
    try std.testing.expectError(error.FileChanged, disk.write(alloc, io, path, "mine", false));
}

test "disk baseline: unaligned exact comparison checks every SIMD lane and short tail" {
    var left: [164]u8 = @splat(7);
    var right: [164]u8 = @splat(7);
    for (0..161) |len| {
        const a = left[1..][0..len];
        const b = right[3..][0..len];
        try std.testing.expect(sameBytes(a, b));
        try std.testing.expect(!sameBytes(a, right[3..][0 .. len + 1]));
        for (b) |*byte| {
            byte.* = 8;
            try std.testing.expect(!sameBytes(a, b));
            byte.* = 7;
        }
    }
}
