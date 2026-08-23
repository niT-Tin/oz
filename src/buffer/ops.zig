//! Text editing helpers over a PieceTable (pure logic, DESIGN.md §1.3).
//! Used by insert-mode editing: backspace and Ctrl-w word deletion.
const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Byte offset of the start of the UTF-8 character ending just before `pos`.
/// `pos` must be a character boundary > 0. Continuation bytes (10xxxxxx) are
/// walked back as part of the same character.
pub fn prevCharStart(pt: *const PieceTable, pos: u32) u32 {
    std.debug.assert(pos > 0);
    var i = pos - 1;
    while (i > 0 and (pt.byteAt(i) & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Start of the deletion range for "delete word before cursor"
/// (vim i_CTRL-W): walk back over whitespace, then over word characters.
/// The deleted range is [result, pos).
pub fn wordStartBefore(pt: *const PieceTable, pos: u32) u32 {
    var i = pos;
    while (i > 0 and isSpace(pt.byteAt(i - 1))) i -= 1;
    while (i > 0 and !isSpace(pt.byteAt(i - 1))) i = prevCharStart(pt, i);
    return i;
}

test "prevCharStart handles multibyte chars" {
    // "a中b" — 中 is 3 bytes (E4 B8 AD)
    var pt = try PieceTable.init(std.testing.allocator, "a中b");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 4), prevCharStart(&pt, 5)); // before 'b'
    try std.testing.expectEqual(@as(u32, 1), prevCharStart(&pt, 4)); // before 中
    try std.testing.expectEqual(@as(u32, 0), prevCharStart(&pt, 1)); // before 中's first byte
}

test "wordStartBefore deletes a word plus trailing whitespace" {
    var pt = try PieceTable.init(std.testing.allocator, "abc def  ghi");
    defer pt.deinit();
    // cursor at end: delete "ghi" → [9, 12)
    try std.testing.expectEqual(@as(u32, 9), wordStartBefore(&pt, 12));
    // after that, cursor at 9 ("abc def  "): delete "def  " → [4, 9)
    try std.testing.expectEqual(@as(u32, 4), wordStartBefore(&pt, 9));
    // second: delete "abc " → [0, 4)
    try std.testing.expectEqual(@as(u32, 0), wordStartBefore(&pt, 4));

    // leading whitespace kept: "  abc|" → delete "abc" → [2, 5)
    var pt2 = try PieceTable.init(std.testing.allocator, "  abc");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(u32, 2), wordStartBefore(&pt2, 5));

    // empty doc / cursor at 0 → 0
    var pt3 = try PieceTable.init(std.testing.allocator, "");
    defer pt3.deinit();
    try std.testing.expectEqual(@as(u32, 0), wordStartBefore(&pt3, 0));
}
