//! Minimal LSP types and URI helpers (DESIGN.md §9). The client talks JSON
//! dynamically via std.json for most payloads; these structs are the typed
//! surface the editor actually consumes (diagnostics, locations, edits).

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// Diagnostic severity codes (LSP): 1=Error 2=Warning 3=Information 4=Hint.
pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    info = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: Severity = .err,
    message: []u8, // owned by the diagnostics store
};

pub const Location = struct {
    uri: []u8, // owned by caller
    range: Range,
};

/// Percent-decode a file:// URI into a plain path (allocated). Handles the
/// common %XX escapes; leaves the rest as-is.
pub fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.InvalidUri;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = "file://".len;
    // file:///path → /path (strip the authority slash when it is empty)
    if (i + 1 < uri.len and uri[i] == '/' and uri[i + 1] == '/') {
        i += 2; // file://host/... — drop host too (local files only)
    }
    while (i < uri.len) : (i += 1) {
        const c = uri[i];
        if (c == '%' and i + 2 < uri.len) {
            const hi = hexVal(uri[i + 1]) orelse {
                try out.append(allocator, c);
                continue;
            };
            const lo = hexVal(uri[i + 2]) orelse {
                try out.append(allocator, c);
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 2;
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Convert an absolute path to a file:// URI (allocated). No percent-encoding
/// beyond spaces (kept minimal for local paths).
pub fn pathToFileUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |c| {
        if (c == ' ') {
            try out.appendSlice(allocator, "%20");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a Position from a byte offset in `text` (line = newline count).
pub fn positionAt(text: []const u8, byte: usize) Position {
    var line: u32 = 0;
    var col: u32 = 0;
    const b = @min(byte, text.len);
    for (text[0..b]) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

test "types: file URI round-trip" {
    const alloc = std.testing.allocator;
    const p = try fileUriToPath(alloc, "file:///home/u/src/main.zig");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/home/u/src/main.zig", p);
    const p2 = try fileUriToPath(alloc, "file:///a%20b%2Fc.txt");
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("/a b/c.txt", p2);
    const u = try pathToFileUri(alloc, "/tmp/x y.zig");
    defer alloc.free(u);
    try std.testing.expectEqualStrings("file:///tmp/x%20y.zig", u);
    try std.testing.expectError(error.InvalidUri, fileUriToPath(alloc, "http://x"));
}

test "types: positionAt counts lines and columns" {
    const t = "ab\ncd\nef";
    const pos = positionAt(t, 4); // 'd'
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.character);
    const end = positionAt(t, t.len);
    try std.testing.expectEqual(@as(u32, 2), end.line);
    try std.testing.expectEqual(@as(u32, 2), end.character);
}
