//! Stable disk baselines and conflict-checked saves. Document bytes are owned
//! by the piece table, never backed by a mutable file mapping.
const std = @import("std");

const Hash = [32]u8;

pub fn hash(bytes: []const u8) Hash {
    var result: Hash = undefined;
    std.crypto.hash.Blake3.hash(bytes, &result, .{});
    return result;
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

fn diskHash(io: std.Io, path: []const u8) !?Hash {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotAFile;
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

pub const Baseline = struct {
    /// Canonical target, while Buffer.path retains the user's spelling/URI.
    target: []u8,
    /// null means this buffer was opened as a new, nonexistent file.
    fingerprint: ?Hash,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, path: []const u8, bytes: ?[]const u8) !Baseline {
        return .{ .target = try targetPath(alloc, io, path), .fingerprint = if (bytes) |b| hash(b) else null };
    }

    pub fn deinit(self: *Baseline, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
        self.* = undefined;
    }

    pub fn didWrite(self: *Baseline, bytes: []const u8) void {
        self.fingerprint = hash(bytes);
    }

    fn verify(self: *const Baseline, alloc: std.mem.Allocator, io: std.Io, path: []const u8, force: bool) !void {
        const now = try targetPath(alloc, io, path);
        defer alloc.free(now);
        if (!std.mem.eql(u8, now, self.target)) return error.PathChanged;
        if (!force) {
            const current = try diskHash(io, self.target);
            if (self.fingerprint) |expected| {
                if (current == null or !std.mem.eql(u8, &expected, &current.?)) return error.FileChanged;
            } else if (current != null) return error.FileChanged;
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
