//! Explicit K documentation viewport. Every coordinate is a terminal cell;
//! markup/content parsing is separate from the finite on-screen rectangle.
const std = @import("std");
const Rect = @import("completion_layout.zig").Rect;

pub const Plan = struct {
    rect: Rect,
    visible_rows: u32 = 0,
    scroll_max: u32 = 0,
};

pub fn columns(pane: Rect, preferred: u32) u32 {
    return @min(@min(80, @max(preferred, 20)), pane.width -| 2);
}

pub fn plan(pane: Rect, cursor_row: u32, cursor_col: u32, total_rows: u32, preferred: u32) Plan {
    const empty = Plan{ .rect = .{ .row = pane.row, .col = pane.col, .width = 0, .height = 0 } };
    if (pane.width < 3 or pane.height < 3 or total_rows == 0) return empty;
    const caret = std.math.clamp(cursor_row, pane.row, pane.bottom() - 1);
    const below = pane.bottom() - caret - 1;
    const above = caret - pane.row;
    const wanted = @min(total_rows, 16) + 2;
    const use_below = below >= wanted or (above < wanted and below >= above);
    const height = @min(wanted, if (use_below) below else above);
    if (height < 3) return empty;
    const width = columns(pane, preferred) + 2;
    const visible = height - 2;
    return .{
        .rect = .{
            .row = if (use_below) caret + 1 else caret - height,
            .col = std.math.clamp(cursor_col, pane.col, pane.right() - width),
            .width = width,
            .height = height,
        },
        .visible_rows = visible,
        .scroll_max = total_rows -| visible,
    };
}

/// Bound work without leaving an incomplete scalar at the byte cap. Inspect
/// the byte AT the cut boundary, not the byte before it: the latter would
/// remove complete continuation bytes and keep a dangling leading byte.
pub fn bytePrefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    if (end == text.len) return text;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// Render Markdown link labels as readable text before wrapping, so a long
/// file:// target cannot push "Go to Type" out of a narrow popup. No URL is
/// opened; code spans and escaped '[' stay literal.
pub fn readableLinks(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '[') == null) return line;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var code = false;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            try out.appendSlice(a, line[i .. i + 2]);
            i += 2;
            continue;
        }
        if (line[i] == '`') code = !code;
        if (line[i] == '[' and !code) {
            if (std.mem.indexOf(u8, line[i + 1 ..], "](")) |relative| {
                const close_label = i + 1 + relative;
                var end = close_label + 2;
                var depth: usize = 1;
                while (end < line.len) : (end += 1) {
                    if (line[end] == '(') depth += 1;
                    if (line[end] == ')') depth -= 1;
                    if (depth == 0) break;
                }
                if (depth == 0) {
                    try out.appendSlice(a, line[i + 1 .. close_label]);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.append(a, line[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

test "hover layout: wraps a scroll viewport inside every short/narrow split without covering caret" {
    const t = std.testing;
    for ([_]u32{ 1, 2, 3, 20, 40, 59, 80, 120 }) |width| {
        for (1..35) |height| {
            const pane = Rect{ .row = 2, .col = 9, .width = width, .height = @intCast(height) };
            for (0..height) |offset| {
                const caret = pane.row + @as(u32, @intCast(offset));
                const p = plan(pane, caret, pane.right() - 1, 200, 80);
                if (p.visible_rows == 0) continue;
                try t.expect(p.rect.col >= pane.col and p.rect.right() <= pane.right());
                try t.expect(p.rect.row >= pane.row and p.rect.bottom() <= pane.bottom());
                try t.expect(caret < p.rect.row or caret >= p.rect.bottom());
                try t.expect(p.visible_rows <= 16);
                try t.expectEqual(@as(u32, 200), p.visible_rows + p.scroll_max);
            }
        }
    }
}

test "hover layout: byte caps preserve complete Unicode scalars" {
    const t = std.testing;
    const text = "A中文🐱Z";
    try t.expectEqualStrings("A", bytePrefix(text, 2));
    try t.expectEqualStrings("A中", bytePrefix(text, 4));
    try t.expectEqualStrings("A中文", bytePrefix(text, 8));
    try t.expectEqualStrings(text, bytePrefix(text, text.len));
}

test "hover layout: link labels survive wrapping without consuming code spans" {
    const a = std.testing.allocator;
    const line = "See [Go to `File`](file:///a/File.zig#L1) and [site](https://e/x_(a)).";
    const shown = try readableLinks(a, line);
    defer a.free(shown);
    try std.testing.expectEqualStrings("See Go to `File` and site.", shown);
    const literal = try readableLinks(a, "`[literal](x)` \\[literal](x)");
    defer a.free(literal);
    try std.testing.expectEqualStrings("`[literal](x)` \\[literal](x)", literal);
}
