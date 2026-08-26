//! Text editing helpers over a PieceTable (pure logic, DESIGN.md §1.3).
//! Used by insert-mode editing: backspace and Ctrl-w word deletion.
const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;
const utf8 = @import("utf8.zig");

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Byte offset of the start of the UTF-8 character ending just before `pos`.
/// `pos` must be > 0. Continuation bytes (10xxxxxx) are walked back as part
/// of the same character — but only when they are actually consumed by a
/// valid leading byte: an orphan continuation run is its own character, and
/// the walk must stop at the run's start (same contract as utf8.charStart),
/// otherwise backspace would also erase the character before the run.
pub fn prevCharStart(pt: *const PieceTable, pos: u32) u32 {
    std.debug.assert(pos > 0 and pos <= pt.len());
    var i = pos - 1;
    while (i > 0 and (pt.byteAt(i) & 0xC0) == 0x80) : (i -= 1) {}
    const lead = pt.byteAt(i);
    // Doc starts with an orphan continuation run: the whole run is one char.
    if ((lead & 0xC0) == 0x80) return 0;
    // Decode the candidate character at the lead byte (a UTF-8 sequence is at
    // most 4 bytes, so a 4-byte window always suffices). If it does not cover
    // the bytes up to `pos` (invalid lead, truncated/overlong sequence), the
    // continuation bytes after it form an orphan run that starts at `end`.
    var win: [4]u8 = undefined;
    const n: usize = @min(4, @as(usize, pt.len() - i));
    pt.copyRange(i, win[0..n]);
    const end = i + @as(u32, utf8.decodeAt(win[0..n], 0).len);
    return if (end >= pos) i else end;
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

test "prevCharStart does not swallow the char before an orphan continuation run" {
    // Invalid UTF-8: a run of continuation bytes not consumed by a valid
    // leading byte is ONE character of its own (utf8.zig charStart contract).
    // Deleting backward over it must leave the preceding valid char intact.
    var pt = try PieceTable.init(std.testing.allocator, "a\x80\x80b");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 1), prevCharStart(&pt, 3)); // before 'b': run start, 'a' kept
    try std.testing.expectEqual(@as(u32, 1), prevCharStart(&pt, 2)); // mid-run -> run start
    try std.testing.expectEqual(@as(u32, 0), prevCharStart(&pt, 1)); // 'a'
    try std.testing.expectEqual(@as(u32, 3), prevCharStart(&pt, 4)); // 'b'

    // Truncated multi-byte sequence at end of doc: the lead byte decodes to
    // U+FFFD (len 1) and the trailing continuation byte is an orphan run —
    // two characters per utf8.zig, so backspace steps over them one at a time.
    var pt2 = try PieceTable.init(std.testing.allocator, "x\xE4\xB8");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(u32, 2), prevCharStart(&pt2, 3)); // orphan run start
    try std.testing.expectEqual(@as(u32, 1), prevCharStart(&pt2, 2)); // the U+FFFD lead
    try std.testing.expectEqual(@as(u32, 0), prevCharStart(&pt2, 1)); // 'x'

    // Document starting with an orphan run: the whole run is one char.
    var pt3 = try PieceTable.init(std.testing.allocator, "\x80\x80x");
    defer pt3.deinit();
    try std.testing.expectEqual(@as(u32, 0), prevCharStart(&pt3, 2)); // run start (doc start)
    try std.testing.expectEqual(@as(u32, 2), prevCharStart(&pt3, 3)); // before 'x'
}

test "prevCharStart matches utf8.prevBoundary (fuzz incl. invalid bytes)" {
    var prng = std.Random.DefaultPrng.init(0xC0FF_EE00);
    const rng = prng.random();
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        var buf: [16]u8 = undefined;
        const n = rng.uintLessThan(usize, 16);
        for (buf[0..n]) |*b| b.* = rng.int(u8);
        const s = buf[0..n];
        var pt = try PieceTable.init(std.testing.allocator, s);
        defer pt.deinit();
        var pos: u32 = 1;
        while (pos <= n) : (pos += 1) {
            try std.testing.expectEqual(
                utf8.prevBoundary(s, pos),
                prevCharStart(&pt, pos),
            );
        }
    }
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
