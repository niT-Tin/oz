//! Character and line ranges shared by operators and visual selections.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;
const utf8 = @import("../buffer/utf8.zig");

pub const Range = struct { start: u32, end: u32 };

/// Snap an interior byte of a valid UTF-8 sequence back to its lead byte.
/// Invalid bytes remain independently addressable, as in the motion layer.
pub fn charStart(pt: *const PieceTable, pos_in: u32) u32 {
    const pos = @min(pos_in, pt.len());
    if (pos == pt.len()) return pos;
    var lead = pos;
    while (lead > 0 and pos - lead < 3 and (pt.byteAt(lead) & 0xC0) == 0x80) lead -= 1;
    if (lead == pos) return pos;
    var bytes: [4]u8 = undefined;
    const n: usize = @min(bytes.len, pt.len() - lead);
    pt.copyRange(lead, bytes[0..n]);
    return if (lead + utf8.decodeAt(bytes[0..n], 0).len > pos) lead else pos;
}

/// Exclusive end of the complete character at pos; EOF stays EOF.
pub fn charEnd(pt: *const PieceTable, pos_in: u32) u32 {
    const pos = charStart(pt, pos_in);
    if (pos == pt.len()) return pos;
    var bytes: [4]u8 = undefined;
    const n: usize = @min(bytes.len, pt.len() - pos);
    pt.copyRange(pos, bytes[0..n]);
    return pos + utf8.decodeAt(bytes[0..n], 0).len;
}

/// Sort both cursor endpoints before including the character on the right.
/// This makes backward inclusive motions include both endpoint characters.
pub fn characterwise(pt: *const PieceTable, from: u32, to: u32, inclusive: bool) Range {
    const start = charStart(pt, @min(from, to));
    const right = charStart(pt, @max(from, to));
    return .{ .start = start, .end = if (inclusive) charEnd(pt, right) else right };
}

/// Whole lines between two cursors, including the final line's terminator.
pub fn linewise(pt: *const PieceTable, from: u32, to: u32) Range {
    const first = pt.lineOf(@min(@min(from, to), pt.len()));
    const last = pt.lineOf(@min(@max(from, to), pt.len()));
    return .{
        .start = pt.lineStart(first),
        .end = if (last + 1 < pt.lineCount()) pt.lineStart(last + 1) else pt.len(),
    };
}

test "edit ranges: inclusive endpoints preserve full CJK and emoji in both directions" {
    var pt = try PieceTable.init(std.testing.allocator, "你😀好\n");
    defer pt.deinit();
    for ([_][2]u32{ .{ 0, 3 }, .{ 3, 0 } }) |ends| {
        try std.testing.expectEqual(Range{ .start = 0, .end = 7 }, characterwise(&pt, ends[0], ends[1], true));
    }
    try std.testing.expectEqual(Range{ .start = 3, .end = 7 }, characterwise(&pt, 3, 3, true));
    try std.testing.expectEqual(Range{ .start = 0, .end = 7 }, characterwise(&pt, 0, 7, false));
    try std.testing.expectEqual(@as(u32, 3), charStart(&pt, 5));
    try std.testing.expectEqual(@as(u32, 7), charEnd(&pt, 5));
    try std.testing.expectEqual(Range{ .start = 7, .end = 11 }, characterwise(&pt, 7, pt.len(), true));
}

test "edit ranges: backward inclusive ASCII, empty and malformed endpoints" {
    var ascii = try PieceTable.init(std.testing.allocator, "abcd");
    defer ascii.deinit();
    try std.testing.expectEqual(Range{ .start = 0, .end = 4 }, characterwise(&ascii, 3, 0, true));
    var empty = try PieceTable.init(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(Range{ .start = 0, .end = 0 }, characterwise(&empty, 0, 0, true));
    var invalid = try PieceTable.init(std.testing.allocator, "x\xE4\xB8");
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u32, 2), charStart(&invalid, 2));
    try std.testing.expectEqual(@as(u32, 2), charEnd(&invalid, 1));
}

test "edit ranges: whole lines are independent of selection direction" {
    var pt = try PieceTable.init(std.testing.allocator, "one\r\ntwo\r\nthree\r\nfour");
    defer pt.deinit();
    const expected = Range{ .start = 5, .end = 17 };
    try std.testing.expectEqual(expected, linewise(&pt, 6, 12));
    try std.testing.expectEqual(expected, linewise(&pt, 12, 6));
    try std.testing.expectEqual(Range{ .start = 17, .end = 21 }, linewise(&pt, 21, 18));
}
