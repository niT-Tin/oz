//! Single-directory completion for explicit paths in Insert mode. Queries use
//! expanded HOME / a caller-provided base; insertion preserves the typed path.
const std = @import("std");

pub const Context = struct {
    token_start: usize,
    component_start: usize,
    directory: []const u8,
    prefix: []const u8,
    home: bool,
    bare_home: bool,
    quote: ?u8 = null,
};

/// The caller supplies source text up to the insertion point, on one line.
/// Quotes delimit a path and permit spaces; ordinary code division/member
/// expressions do not become paths merely because they contain a slash.
pub fn context(prefix: []const u8) ?Context {
    var start: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (prefix, 0..) |byte, index| {
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == q) {
                quote = null;
                start = index + 1;
            }
        } else if (byte == '"' or byte == '\'' or byte == '`') {
            quote = byte;
            start = index + 1;
        } else if (std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, "=,;(){}[]<>", byte) != null) {
            start = index + 1;
        }
    }
    const token = prefix[start..];
    if (token.len == 0) return null;
    const home = token[0] == '~';
    if (home and token.len == 1) return .{
        .token_start = start,
        .component_start = start + 1,
        .directory = "",
        .prefix = "",
        .home = true,
        .bare_home = true,
        .quote = quote,
    };
    if (!(token[0] == '/' or std.mem.startsWith(u8, token, "~/") or
        std.mem.startsWith(u8, token, "./") or std.mem.startsWith(u8, token, "../"))) return null;
    const slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse return null;
    return .{
        .token_start = start,
        .component_start = start + slash + 1,
        .directory = if (home) token[2 .. slash + 1] else token[0 .. slash + 1],
        .prefix = token[slash + 1 ..],
        .home = home,
        .bare_home = false,
        .quote = quote,
    };
}

/// Bytes after the insertion point belonging to the same basename.
/// Keep later path components and language delimiters outside replacement.
/// Spaces/punctuation belong to a quoted filename until its closing quote.
pub fn componentSuffixLen(suffix: []const u8, quote: ?u8) usize {
    var p: usize = 0;
    while (p < suffix.len) : (p += 1) {
        const byte = suffix[p];
        if (byte == '/') break;
        if (quote) |q| {
            if (byte == q) break;
            if (byte == '\\' and p + 1 < suffix.len and
                (suffix[p + 1] == q or suffix[p + 1] == '\\')) p += 1;
        } else if (std.ascii.isWhitespace(byte) or
            std.mem.indexOfScalar(u8, "\"'`=,;(){}[]<>", byte) != null) break;
    }
    return p;
}

pub fn directoryPath(a: std.mem.Allocator, ctx: Context, home: ?[]const u8, base: []const u8) !?[]u8 {
    if (ctx.home) return try std.fs.path.join(a, &.{ home orelse return null, ctx.directory });
    if (std.fs.path.isAbsolute(ctx.directory)) return try a.dupe(u8, ctx.directory);
    return try std.fs.path.join(a, &.{ base, ctx.directory });
}

pub const Entry = struct { name: []u8, is_dir: bool };

/// Cache only the directory while its menu session is alive. Filtering a new
/// basename prefix never rescans the filesystem, and close/movement drops it.
pub const Cache = struct {
    directory: ?[]u8 = null,
    entries: std.ArrayList(Entry) = .empty,
    pub const max_entries = 4096;
    pub const max_candidates = 200;

    pub fn deinit(self: *Cache, a: std.mem.Allocator) void {
        for (self.entries.items) |entry| a.free(entry.name);
        self.entries.deinit(a);
        if (self.directory) |path| a.free(path);
        self.* = .{};
    }

    pub fn load(self: *Cache, a: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
        if (self.directory) |old| if (std.mem.eql(u8, old, directory)) return;
        self.deinit(a);
        errdefer self.deinit(a);
        var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer dir.close(io);
        self.directory = try a.dupe(u8, directory);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (self.entries.items.len >= max_entries) break;
            // A terminal menu is one row per filename; control characters do
            // not provide a selectable single-row representation.
            var printable = true;
            for (entry.name) |b| if (b < 0x20 or b == 0x7f) {
                printable = false;
                break;
            };
            if (!printable) continue;
            var is_dir = entry.kind == .directory;
            if (entry.kind == .sym_link) {
                if (dir.openDir(io, entry.name, .{})) |link_dir| {
                    var owned = link_dir;
                    owned.close(io);
                    is_dir = true;
                } else |_| {}
            }
            const name = try a.dupe(u8, entry.name);
            errdefer a.free(name);
            try self.entries.append(a, .{ .name = name, .is_dir = is_dir });
        }
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn less(_: void, left: Entry, right: Entry) bool {
                if (left.is_dir != right.is_dir) return left.is_dir;
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.less);
    }
};

test "path completion: contexts preserve exact basename range and quoted spaces" {
    const t = std.testing;
    const root = context("const p = \"/tmp/中文 dir/na").?;
    try t.expectEqualStrings("na", root.prefix);
    try t.expectEqualStrings("/tmp/中文 dir/", root.directory);
    try t.expectEqualStrings("na", "const p = \"/tmp/中文 dir/na"[root.component_start..]);
    const home = context("~").?;
    try t.expect(home.bare_home and home.home);
    try t.expectEqual(@as(usize, 1), home.component_start);
    const nested = context("'~/Documents/lo").?;
    try t.expectEqualStrings("Documents/", nested.directory);
    try t.expectEqualStrings("lo", nested.prefix);
    const relative = context("./sub/fi").?;
    try t.expectEqualStrings("./sub/", relative.directory);
    try t.expect(context("a/b") == null);
    try t.expect(context("~user") == null);
    try t.expect(context("\"/tmp/closed\"") == null);
}

test "path completion: HOME is expanded only for lookup and relative paths use caller base" {
    const a = std.testing.allocator;
    const path = (try directoryPath(a, context("~/sub/f").?, "/tmp/home", "/project")).?;
    defer a.free(path);
    try std.testing.expectEqualStrings("/tmp/home/sub/", path);
    const relative = (try directoryPath(a, context("../lib/f").?, null, "/project/src")).?;
    defer a.free(relative);
    try std.testing.expectEqualStrings("/project/src/../lib/", relative);
    try std.testing.expect(try directoryPath(a, context("~").?, null, "/project") == null);
}

test "path completion: cache is owned, sorted, reused until close and fails cleanly" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "中文 file.txt", .data = "content" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    var storage: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &storage);
    var cache = Cache{};
    defer cache.deinit(a);
    try cache.load(a, io, storage[0..len]);
    try std.testing.expectEqual(@as(usize, 3), cache.entries.items.len);
    try std.testing.expect(cache.entries.items[0].is_dir);
    try std.testing.expectEqualStrings("sub", cache.entries.items[0].name);
    try tmp.dir.writeFile(io, .{ .sub_path = "added", .data = "" });
    try cache.load(a, io, storage[0..len]);
    try std.testing.expectEqual(@as(usize, 3), cache.entries.items.len);
    cache.deinit(a);
    try cache.load(a, io, storage[0..len]);
    try std.testing.expectEqual(@as(usize, 4), cache.entries.items.len);
    const missing = try std.fs.path.join(a, &.{ storage[0..len], "missing" });
    defer a.free(missing);
    try std.testing.expectError(error.FileNotFound, cache.load(a, io, missing));
    try std.testing.expect(cache.directory == null);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
}

test "path completion: replacement ends at basename, not next component or delimiter" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 10), componentSuffixLen("ngname.txt/child", null));
    try t.expectEqual(@as(usize, 11), componentSuffixLen("ng file.txt\"; other", '"'));
    try t.expectEqual(@as(usize, 10), componentSuffixLen("ngname.txt other", null));
    try t.expectEqual(@as(usize, 0), componentSuffixLen("/child", null));
    try t.expectEqual(@as(usize, 2), componentSuffixLen("o\\/child", '"'));
    try t.expectEqual(@as(?u8, '"'), context("\"./lo").?.quote);
}
