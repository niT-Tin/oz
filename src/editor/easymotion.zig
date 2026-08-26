//! EasyMotion matching (DESIGN.md §6.4): scan for a 1–2 character query and
//! assign jump labels. Pure logic; the label overlay UI is wired in the app.
//! `s` = current window, `<leader>f` = all windows (M0: whole document for both).
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Match = struct {
    pos: u32, // byte offset of the match (line + column)
    label: u8, // label character ('a'..'z', then 'A'..'Z')
};

/// Scan the document for occurrences of `query` (one UTF-8 character, 1–4
/// bytes, case-sensitive) and assign labels in reading order (top to bottom,
/// left to right): 'a'..'z', then 'A'..'Z'. At most 52 matches are returned
/// (M0: labels never repeat; further matches are dropped). Matches never span
/// a line boundary — a query containing '\n' yields no matches.
/// Returns a slice owned by the caller (free with `allocator.free`); it may be
/// empty (a 0-length allocation).
pub fn find(allocator: std.mem.Allocator, pt: *const PieceTable, query: []const u8) ![]Match {
    // Single-character queries only (1–4 bytes = one UTF-8 codepoint, incl.
    // CJK). Empty or multi-character queries match nothing.
    if (query.len < 1 or query.len > 4) return allocator.alloc(Match, 0);

    // A query containing a newline can never sit inside a single line, and
    // matches must not cross lines (M0), so reject it outright.
    for (query) |b| {
        if (b == '\n') return allocator.alloc(Match, 0);
    }

    const doc_len = pt.len();
    const qlen: u32 = @intCast(query.len);
    if (doc_len < qlen) return allocator.alloc(Match, 0);

    // Reading order is byte order (lines top-to-bottom, within a line
    // left-to-right), so one forward scan already assigns labels in reading
    // order. No query byte is '\n', hence a byte-wise match never contains the
    // line separator and cannot span a line boundary.
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);

    const limit: u32 = doc_len - qlen;
    var pos: u32 = 0;
    while (pos <= limit) : (pos += 1) {
        var ok = true;
        for (query, 0..) |qb, k| {
            if (pt.byteAt(pos + @as(u32, @intCast(k))) != qb) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        try matches.append(allocator, .{ .pos = pos, .label = labelFor(matches.items.len) });
        // M0: only 52 labels exist (a..z then A..Z); further matches are dropped.
        if (matches.items.len == max_labels) break;
    }

    return matches.toOwnedSlice(allocator);
}

/// Total number of labels: 'a'..'z' plus 'A'..'Z'. M0 simplification: labels
/// never recycle or repeat, so matches beyond this are discarded.
const max_labels: usize = 52;

/// Label for the match at 0-based reading-order index `index` (index < 52).
fn labelFor(index: usize) u8 {
    if (index < 26) return @intCast('a' + index);
    return @intCast('A' + (index - 26));
}

// =============================== tests ======================================

const t = std.testing;

/// Run `find`, then verify count, positions, labels, reading order, and that
/// every Match.pos really holds `query` (via byteAt and copyRange).
fn expectFind(pt: *PieceTable, query: []const u8, expected_pos: []const u32) !void {
    const matches = try find(t.allocator, pt, query);
    defer t.allocator.free(matches);

    try t.expectEqual(expected_pos.len, matches.len);

    var prev: ?u32 = null;
    for (matches, 0..) |m, i| {
        try t.expectEqual(expected_pos[i], m.pos);
        const want: u8 = if (i < 26) @intCast('a' + i) else @intCast('A' + (i - 26));
        try t.expectEqual(want, m.label);
        // strictly increasing offsets == reading order
        if (prev) |p| try t.expect(m.pos > p);
        prev = m.pos;
        // the bytes at Match.pos must be exactly `query`
        var buf: [4]u8 = undefined;
        const qlen = query.len;
        pt.copyRange(m.pos, buf[0..qlen]);
        try t.expectEqualSlices(u8, query, buf[0..qlen]);
        try t.expectEqual(query[0], pt.byteAt(m.pos));
        if (qlen > 1) try t.expectEqualSlices(u8, query[1..], buf[1..qlen]);
    }
}

test "easymotion find: single char, multi-line, line start/end" {
    var pt = try PieceTable.init(t.allocator, "ax\na\nxa");
    defer pt.deinit();
    // a@0 (line 0 start), a@3 (line 1 start), a@6 (line 2, last byte of doc)
    try expectFind(&pt, "a", &.{ 0, 3, 6 });

    // a@1 = last byte of line 0 (right before '\n'); a@3 = line 1 start
    var pt2 = try PieceTable.init(t.allocator, "ba\nab");
    defer pt2.deinit();
    try expectFind(&pt2, "a", &.{ 1, 3 });
    try expectFind(&pt2, "ab", &.{3});
}

test "easymotion find: Chinese doc, ASCII query matches ASCII only" {
    // 你好a世界 = E4BDA0 E5A5BD 61 E4B896 E7958C -> 13 bytes, 'a' at offset 6
    var pt = try PieceTable.init(t.allocator, "你好a世界");
    defer pt.deinit();
    try t.expectEqual(@as(u32, 13), pt.len());
    try expectFind(&pt, "a", &.{6});
    // multibyte (CJK) queries are single characters now and match their
    // own bytes: 你@0, 好@3; a two-character query (世界, 6 bytes) is
    // still rejected (> one UTF-8 codepoint)
    try expectFind(&pt, "你", &.{0});
    try expectFind(&pt, "好", &.{3});
    try expectFind(&pt, "世界", &.{});

    // ASCII query never matches inside a UTF-8 sequence (lead/continuation
    // bytes are all >= 0x80, ASCII query bytes are < 0x80)
    var pt2 = try PieceTable.init(t.allocator, "a好b");
    defer pt2.deinit();
    try expectFind(&pt2, "ab", &.{});
    try expectFind(&pt2, "好", &.{1});

    // valid ASCII match adjacent to multibyte text
    var pt3 = try PieceTable.init(t.allocator, "ab好a");
    defer pt3.deinit();
    try expectFind(&pt3, "ab", &.{0});
    try expectFind(&pt3, "a", &.{ 0, 5 });
}

test "easymotion find: two-char query, no cross-line, repeats" {
    // "a\nb": the 'a' and 'b' are on different lines -> "ab" must not match
    var pt = try PieceTable.init(t.allocator, "a\nb");
    defer pt.deinit();
    try expectFind(&pt, "ab", &.{});
    try expectFind(&pt, "a", &.{0});
    try expectFind(&pt, "\n", &.{}); // newline query rejected
    try expectFind(&pt, "a\n", &.{}); // query spanning a line rejected

    var pt2 = try PieceTable.init(t.allocator, "ab ab ab");
    defer pt2.deinit();
    try expectFind(&pt2, "ab", &.{ 0, 3, 6 });

    var pt3 = try PieceTable.init(t.allocator, "xab\nyab");
    defer pt3.deinit();
    try expectFind(&pt3, "ab", &.{ 1, 5 });

    var pt4 = try PieceTable.init(t.allocator, "ab");
    defer pt4.deinit();
    try expectFind(&pt4, "ab", &.{0});
}

test "easymotion find: labels a..z then A..Z in reading order, capped at 52" {
    // 30 matches -> 'a'..'z' then 'A','B','C','D'
    var pt = try PieceTable.init(t.allocator, "a" ** 30);
    defer pt.deinit();
    var pos30: [30]u32 = undefined;
    for (&pos30, 0..) |*p, i| p.* = @intCast(i);
    try expectFind(&pt, "a", &pos30);

    // 60 matches -> only the first 52 ('a'..'z' then 'A'..'Z'), extras dropped
    var pt2 = try PieceTable.init(t.allocator, "a" ** 60);
    defer pt2.deinit();
    var pos52: [52]u32 = undefined;
    for (&pos52, 0..) |*p, i| p.* = @intCast(i);
    try expectFind(&pt2, "a", &pos52);

    // labels follow reading order across lines: row 0, then row 1, then row 2
    var pt3 = try PieceTable.init(t.allocator, "aa\naa\naa");
    defer pt3.deinit();
    try expectFind(&pt3, "a", &.{ 0, 1, 3, 4, 6, 7 });
}

test "easymotion find: edge cases (empty doc, no match, invalid query)" {
    var empty = try PieceTable.init(t.allocator, "");
    defer empty.deinit();
    try expectFind(&empty, "a", &.{});
    try expectFind(&empty, "ab", &.{});

    var pt = try PieceTable.init(t.allocator, "xyz");
    defer pt.deinit();
    try expectFind(&pt, "a", &.{}); // no match
    try expectFind(&pt, "", &.{}); // empty query
    try expectFind(&pt, "abc", &.{}); // >2 bytes

    // 1-byte document can't hold a 2-byte query
    var pt2 = try PieceTable.init(t.allocator, "a");
    defer pt2.deinit();
    try expectFind(&pt2, "ab", &.{});
    try expectFind(&pt2, "a", &.{0});
}

test "easymotion find: works across piece boundaries after edits" {
    var pt = try PieceTable.init(t.allocator, "hello\nworld");
    defer pt.deinit();
    _ = try pt.replace(5, 0, " cruel"); // "hello cruel\nworld"
    try expectFind(&pt, "l", &.{ 2, 3, 10, 15 });
    try expectFind(&pt, "wo", &.{12});

    // non-contiguous pieces: origin "ab", add "XY", origin "ef"
    var pt2 = try PieceTable.init(t.allocator, "abcdef");
    defer pt2.deinit();
    _ = try pt2.replace(2, 2, "XY"); // "abXYef"
    try expectFind(&pt2, "XY", &.{2}); // entirely inside add piece
    try expectFind(&pt2, "bX", &.{1}); // origin + add boundary
    try expectFind(&pt2, "Ye", &.{3}); // add + origin boundary
}
