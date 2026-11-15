//! Byte offsets to LSP UTF-16 positions without copying the document.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;
const types = @import("types.zig");

pub fn positionAt(pt: *const PieceTable, byte: u32) types.Position {
    const line = pt.lineOf(byte);
    return .{ .line = line, .character = utf16Units(pt, pt.lineStart(line), byte) };
}

pub fn utf16Units(pt: *const PieceTable, from: u32, to: u32) u32 {
    if (to <= from) return 0;
    var units: u32 = 0;
    var carry: [3]u8 = undefined; // lead bytes of a sequence split at a boundary
    var carry_len: usize = 0;
    var doc_off: u32 = 0;
    var first = true;
    for (pt.pieces.items) |p| {
        const piece_end = doc_off + p.len;
        if (piece_end <= from) {
            doc_off = piece_end;
            continue;
        }
        if (doc_off >= to) break;
        const src: []const u8 = if (p.source == .origin) pt.origin else pt.add.items;
        const skip: u32 = if (from > doc_off) from - doc_off else 0;
        // Both bounds are document offsets. Subtract the skipped prefix too,
        // or later-line columns include bytes beyond the requested endpoint.
        const take: u32 = @min(p.len - skip, to - (doc_off + skip));
        const bytes = src[@as(usize, p.start) + skip .. @as(usize, p.start) + skip + take];
        var i: usize = 0;
        if (!first and carry_len > 0 and bytes.len > 0 and (bytes[0] & 0xC0) == 0x80) {
            // The previous window ended mid-sequence: complete it with the
            // continuation bytes that start this window.
            const total: usize = std.unicode.utf8ByteSequenceLength(carry[0]) catch 0;
            if (total > carry_len) {
                const need = total - carry_len;
                if (bytes.len >= need) {
                    units += if (total == 4) 2 else 1;
                    i = need;
                } else {
                    // Still split (tiny pieces): carry everything over.
                    @memcpy(carry[carry_len .. carry_len + bytes.len], bytes);
                    carry_len += bytes.len;
                    doc_off = piece_end;
                    first = false;
                    continue;
                }
            }
        }
        carry_len = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b < 0x80) {
                units += 1;
                i += 1;
                continue;
            }
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + seq_len > bytes.len) {
                const left = bytes.len - i;
                @memcpy(carry[0..left], bytes[i..]);
                carry_len = left;
                break;
            }
            units += if (seq_len == 4) 2 else 1;
            i += seq_len;
        }
        doc_off = piece_end;
        first = false;
    }
    return units;
}

test "LSP positions: later-line columns exclude the skipped piece prefix" {
    var pt = try PieceTable.init(std.testing.allocator, "pub fn peek(\n    aaa: usize,\n) u1 {\n    return 0;\n}\n");
    defer pt.deinit();
    const start = positionAt(&pt, 17);
    const end = positionAt(&pt, 20);
    try std.testing.expectEqual(@as(u32, 1), start.line);
    try std.testing.expectEqual(@as(u32, 4), start.character);
    try std.testing.expectEqual(@as(u32, 7), end.character);
    try std.testing.expectEqual(@as(u32, 0), utf16Units(&pt, 13, 13));
    // Repeat against an edited piece table instead of only a single origin.
    _ = try pt.replace(17, 3, "_");
    try std.testing.expectEqual(@as(u32, 4), positionAt(&pt, 17).character);
    try std.testing.expectEqual(@as(u32, 5), positionAt(&pt, 18).character);
}

test "LSP positions: CJK, astral and combining characters count UTF-16 across pieces" {
    const prefix = "header\n";
    const unicode = "中😀e\u{301}";
    var pt = try PieceTable.init(std.testing.allocator, prefix ++ unicode ++ "aaa\n");
    defer pt.deinit();
    const offset = prefix.len + unicode.len;
    try std.testing.expectEqual(@as(u32, 5), positionAt(&pt, offset).character);
    try std.testing.expectEqual(@as(u32, 8), positionAt(&pt, offset + 3).character);
    // Construct each Unicode byte in a separate piece to exercise carry-over.
    var fragmented = try PieceTable.init(std.testing.allocator, prefix ++ "aaa\n");
    defer fragmented.deinit();
    for (unicode, 0..) |byte, i| {
        _ = try fragmented.replace(@intCast(prefix.len + i), 0, &.{byte});
    }
    try std.testing.expectEqual(@as(u32, 5), positionAt(&fragmented, offset).character);
    try std.testing.expectEqual(@as(u32, 8), positionAt(&fragmented, offset + 3).character);
}
