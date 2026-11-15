//! Quote pairing policy shared by Insert and its pure regressions.
//! Double quotes/backticks can open after a word. Apostrophes after a word
//! stay literal (don't); an already-open quote closes literally instead of
//! causing the second physical keypress to manufacture a fresh pair.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

pub fn escaped(pt: *const PieceTable, pos: u32) bool {
    var p = @min(pos, pt.len());
    var odd = false;
    while (p > 0 and pt.byteAt(p - 1) == '\\') : (p -= 1) odd = !odd;
    return odd;
}

pub fn quoteShouldPair(pt: *const PieceTable, pos: u32, quote: u8) bool {
    if (escaped(pt, pos)) return false;
    if (quote == '\'' and pos > 0 and word(pt.byteAt(pos - 1))) return false;
    const line_start = pt.lineStart(pt.lineOf(pos));
    var open = false;
    var p = line_start;
    while (p < pos) : (p += 1) {
        if (pt.byteAt(p) == '\\') {
            if (p + 1 < pos) p += 1;
            continue;
        }
        if (pt.byteAt(p) != quote) continue;
        // A word-internal apostrophe is prose, not a string delimiter.
        if (quote == '\'' and p > line_start and p + 1 < pt.len() and
            word(pt.byteAt(p - 1)) and word(pt.byteAt(p + 1))) continue;
        open = !open;
    }
    return !open;
}

test "auto pair: quotes open, close, escape and preserve prose apostrophes" {
    const a = std.testing.allocator;
    const cases = [_]struct { text: []const u8, quote: u8, pair: bool }{
        .{ .text = "word", .quote = '"', .pair = true },
        .{ .text = "word", .quote = '`', .pair = true },
        .{ .text = "word", .quote = '\'', .pair = false },
        .{ .text = "word'", .quote = '\'', .pair = false },
        .{ .text = "\"word", .quote = '"', .pair = false },
        .{ .text = "`word", .quote = '`', .pair = false },
        .{ .text = "word\\", .quote = '"', .pair = false },
        .{ .text = "word\\\\", .quote = '"', .pair = true },
        .{ .text = "don't ", .quote = '\'', .pair = true },
        .{ .text = "previous'\n", .quote = '\'', .pair = true },
    };
    for (cases) |c| {
        var pt = try PieceTable.init(a, c.text);
        defer pt.deinit();
        try std.testing.expectEqual(c.pair, quoteShouldPair(&pt, pt.len(), c.quote));
    }
}
