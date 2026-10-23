//! Editor-context builder for AI chat (M1).
//!
//! The model receives a compact, bounded view of what the user is looking at:
//!   - always the current file path,
//!   - the visual selection and its 1-based line range when one is active,
//!   - otherwise the cursor line plus a small window around it,
//!   - never the whole file; the result is capped (default 8 KiB) and cut on
//!     UTF-8 boundaries.
//!
//! This module is pure: it takes text + byte offsets and never touches App.
const std = @import("std");
const utf8 = @import("../buffer/utf8.zig");

pub const Selection = struct {
    /// Byte offsets into `text`; `end` is exclusive.
    start: u32,
    end: u32,
};

pub const Input = struct {
    /// Absolute (or as-stored) file path; null for an unnamed buffer.
    path: ?[]const u8 = null,
    text: []const u8 = "",
    /// Cursor byte offset (clamped to `text.len`).
    cursor: u32 = 0,
    selection: ?Selection = null,
};

pub const Options = struct {
    /// Total output cap in bytes.
    max_bytes: usize = 8 * 1024,
    /// Lines of context on each side of the cursor line.
    window_lines: u32 = 10,
};

/// Build the context block. Caller owns the result.
pub fn build(alloc: std.mem.Allocator, input: Input, options: Options) ![]u8 {
    const max_bytes = @max(options.max_bytes, 32);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    const text = input.text;
    const cursor: usize = @min(@as(usize, input.cursor), text.len);

    if (input.selection) |sel| {
        const start: usize = @min(sel.start, sel.end);
        const end: usize = @max(sel.start, sel.end);
        const start_off = @min(start, text.len);
        const end_off = @min(end, text.len);
        const start_line = lineOf(text, start_off) + 1;
        const end_line = lineOf(text, if (end_off > start_off) end_off - 1 else start_off) + 1;

        try appendHeader(alloc, &out, input.path, "unsaved buffer");
        try appendFmt(alloc, &out, "Selected lines {d}-{d}:\n", .{ start_line, end_line });
        const budget = max_bytes -| out.items.len;
        try appendTruncated(alloc, &out, text[start_off..end_off], budget);
    } else if (input.path == null and text.len == 0) {
        try appendTruncated(alloc, &out, "No file open.\n", max_bytes);
    } else {
        const cursor_line = lineOf(text, cursor);
        try appendHeader(alloc, &out, input.path, "unsaved buffer");
        try appendFmt(alloc, &out, "Cursor line: {d}\n", .{cursor_line + 1});
        const first = cursor_line -| options.window_lines;
        const last_line: u32 = if (text.len == 0) 0 else @min(cursor_line + options.window_lines, lineCount(text) - 1);
        const start_off = lineStart(text, first);
        const end_off = lineEnd(text, last_line);
        try appendFmt(alloc, &out, "Context (lines {d}-{d}):\n", .{ first + 1, last_line + 1 });
        const budget = max_bytes -| out.items.len;
        try appendTruncated(alloc, &out, text[start_off..end_off], budget);
    }

    // Hard guarantee: even a pathological file path in the header must not
    // push the context block over the cap.
    if (out.items.len > max_bytes) {
        const cut = cutUtf8(out.items, max_bytes);
        out.shrinkRetainingCapacity(cut.len);
    }
    return out.toOwnedSlice(alloc);
}

fn appendHeader(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: ?[]const u8,
    fallback: []const u8,
) !void {
    if (path) |p| {
        if (p.len > 0) {
            try appendFmt(alloc, out, "Current file: {s}\n", .{p});
            return;
        }
    }
    try appendFmt(alloc, out, "Current buffer ({s})\n", .{fallback});
}

/// Append `text`, capped to `budget` bytes at a UTF-8 boundary, with a
/// trailing truncation marker when something was dropped.
fn appendTruncated(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    budget: usize,
) !void {
    if (text.len <= budget) {
        try out.appendSlice(alloc, text);
        if (text.len == 0 or text[text.len - 1] != '\n') try out.append(alloc, '\n');
        return;
    }
    const marker = "\n… [truncated]\n";
    if (budget <= marker.len + 8) {
        const take = utf8.truncateWidth(text, @intCast(@max(budget -| 1, 1)));
        const fit = cutUtf8(text, @min(take.len, budget));
        try out.appendSlice(alloc, fit);
        return;
    }
    const fit = cutUtf8(text, budget - marker.len);
    try out.appendSlice(alloc, fit);
    try out.appendSlice(alloc, marker);
}

fn cutUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and !utf8.isBoundary(text, end)) end -= 1;
    return text[0..end];
}

fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    try out.print(alloc, fmt, args);
}

pub fn lineCount(text: []const u8) u32 {
    var n: u32 = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

pub fn lineOf(text: []const u8, pos: usize) u32 {
    const end = @min(pos, text.len);
    var n: u32 = 0;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (text[i] == '\n') n += 1;
    }
    return n;
}

fn lineStart(text: []const u8, line: u32) usize {
    if (line == 0) return 0;
    var n: u32 = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            n += 1;
            if (n == line) return i + 1;
        }
    }
    return text.len;
}

/// Byte offset just past the last byte of `line` (before its newline).
fn lineEnd(text: []const u8, line: u32) usize {
    const start = lineStart(text, line);
    if (start >= text.len) return text.len;
    const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len;
    // Include the newline so concatenated context rows keep their breaks.
    return nl + 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "context: path and cursor window" {
    const alloc = std.testing.allocator;
    const text = "line one\nline two\nline three\nline four\n";
    const out = try build(alloc, .{
        .path = "/home/u/src/main.zig",
        .text = text,
        .cursor = 20, // inside "line three"
    }, .{ .window_lines = 1 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Current file: /home/u/src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cursor line: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Context (lines 2-4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line four") != null);
}

test "context: visual selection includes text and 1-based range" {
    const alloc = std.testing.allocator;
    const text = "alpha\nbeta\ngamma\ndelta\n";
    const beta = std.mem.indexOf(u8, text, "beta").?;
    const out = try build(alloc, .{
        .path = "notes.txt",
        .text = text,
        .cursor = 0,
        .selection = .{ .start = @intCast(beta), .end = @intCast(beta + "beta\ngamma".len) },
    }, .{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Current file: notes.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Selected lines 2-3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta\ngamma") != null);
}

test "context: truncation is bounded and UTF-8 safe" {
    const alloc = std.testing.allocator;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    // CJK characters are 3 bytes each; give the cap an awkward value so a
    // naive byte cut would split a sequence.
    var i: usize = 0;
    while (i < 200) : (i += 1) try text.appendSlice(alloc, "一行很长很长的中文文本内容\n");
    const out = try build(alloc, .{
        .path = "/tmp/中文/文件.zig",
        .text = text.items,
        .cursor = 0,
        .selection = .{ .start = 0, .end = @intCast(text.items.len) },
    }, .{ .max_bytes = 137 });
    defer alloc.free(out);
    try std.testing.expect(out.len <= 137);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "Current file: /tmp/中文/文件.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "truncated") != null);
}

test "context: no file open" {
    const alloc = std.testing.allocator;
    const out = try build(alloc, .{}, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("No file open.\n", out);
}

test "context: unnamed buffer gets a path-less header" {
    const alloc = std.testing.allocator;
    const out = try build(alloc, .{ .text = "hello\n", .cursor = 2 }, .{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Current buffer (unsaved buffer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "context: reversed selection is normalized" {
    const alloc = std.testing.allocator;
    const text = "aaa\nbbb\nccc\n";
    const out = try build(alloc, .{
        .path = "x",
        .text = text,
        .selection = .{ .start = 9, .end = 4 },
    }, .{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Selected lines 2-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bbb") != null);
}
