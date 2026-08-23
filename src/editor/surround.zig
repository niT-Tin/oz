//! Surround operations (DESIGN.md §1.3): ys{motion}{c} add, ds{c} delete,
//! cs{old}{new} change. Pure functions computing edit ranges + replacement
//! text; the caller applies them through the History.
//!
//! Supported delimiters: () [] {} <> and quotes ' " `.
//!
//! M0 simplifications vs. the vim surround plugin (please read before use):
//! - Pair search scans backward from the cursor for the *nearest* opener and
//!   pairs it forward; it does not resolve which of several nested openers
//!   encloses the cursor.
//! - Bracket nesting is tracked per delimiter type only (same opener char),
//!   so mixed-type nesting like "( [ ) ]" is not understood.
//! - Quote pairs must close on the same line; a quote's closer is the next
//!   occurrence of the same byte on that line. Apostrophes inside words
//!   ("it's") can be mistaken for a pair opener.
//! - The cursor is matched inclusively: sitting exactly on an opener or
//!   closer still finds the pair; a cursor at end-of-buffer is clamped one
//!   byte back for the search.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// A single replacement: replace [start, end) with `text`.
///
/// Ownership: `text` is allocated with the allocator passed to the operation
/// and is owned by the caller — the History copies it, then the caller frees
/// it with the same allocator (same model as `comment.Toggle`).
pub const Result = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

/// Left/right bytes of a delimiter pair.
const Delim = struct {
    left: u8,
    right: u8,
};

/// Delimiter pair for `ch`: either byte of a bracket pair or a quote char
/// selects one pair. Returns null for unsupported bytes.
fn delimFor(ch: u8) ?Delim {
    return switch (ch) {
        '(', ')' => .{ .left = '(', .right = ')' },
        '[', ']' => .{ .left = '[', .right = ']' },
        '{', '}' => .{ .left = '{', .right = '}' },
        '<', '>' => .{ .left = '<', .right = '>' },
        '\'', '"', '`' => .{ .left = ch, .right = ch },
        else => null,
    };
}

fn isOpener(b: u8) bool {
    return switch (b) {
        '(', '[', '{', '<', '\'', '"', '`' => true,
        else => false,
    };
}

/// A found delimiter pair: opener at byte `open`, closer at byte `close`.
/// The replaced range is [open, close + 1).
const Pair = struct {
    open: u32,
    close: u32,
};

/// Pair the opener at `open` with its closer, scanning forward. Brackets may
/// span lines; nesting of the same opener type is tracked so that for
/// "(a(b)c)" pairing the inner "(" finds the inner ")". Quotes must close on
/// the same line (M0, no nesting).
fn pairFrom(pt: *const PieceTable, open: u32) ?Pair {
    const b = pt.byteAt(open);
    const d = delimFor(b) orelse return null;
    if (d.left != d.right) {
        // Bracket: first same-type closer at nesting depth 0.
        var depth: u32 = 0;
        var j: u32 = open + 1;
        while (j < pt.len()) : (j += 1) {
            const c = pt.byteAt(j);
            if (c == b) {
                depth += 1;
            } else if (c == d.right) {
                if (depth == 0) return .{ .open = open, .close = j };
                depth -= 1;
            }
        }
        return null;
    }
    // Quote: next occurrence of the same byte on the same line.
    const line = pt.lineOf(open);
    var j: u32 = open + 1;
    while (j < pt.len()) : (j += 1) {
        if (pt.byteAt(j) != b) continue;
        if (pt.lineOf(j) != line) return null; // crossed the line: no closer
        return .{ .open = open, .close = j };
    }
    return null;
}

/// Find the delimiter pair containing `pos`: scan backward for the nearest
/// opener, then pair it forward. A pair is accepted only if it actually
/// contains the cursor (its closer is not before it); otherwise the scan
/// keeps going further back.
fn findPair(pt: *const PieceTable, pos: u32) ?Pair {
    const doc_len = pt.len();
    if (doc_len == 0) return null;
    std.debug.assert(pos <= doc_len);
    const search: u32 = @min(pos, doc_len - 1); // end-of-buffer clamp (M0)
    var i: u32 = search;
    while (true) {
        if (isOpener(pt.byteAt(i))) {
            if (pairFrom(pt, i)) |p| {
                if (p.close >= search) return p;
            }
        }
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

/// Byte range [start, end) of the document, produced by a motion/text object.
/// (The contract stub used an inline anonymous struct for `add`'s `inner`
/// param; an anonymous type cannot be named by callers in Zig 0.16, so the
/// range gets a named public type here. Callers pass a struct literal or a
/// `Range` value — same call shape.)
pub const Range = struct {
    start: u32,
    end: u32,
};

/// ys: wrap `inner` (the range produced by a motion/text object) with
/// delimiter `ch`. Returns the wrapped text (content unchanged).
/// `ch` may be either byte of a bracket pair, or a quote char.
pub fn add(allocator: std.mem.Allocator, pt: *const PieceTable, inner: Range, ch: u8) !Result {
    std.debug.assert(inner.start <= inner.end and inner.end <= pt.len());
    const d = delimFor(ch) orelse return error.UnsupportedDelimiter;
    const content_len = inner.end - inner.start;
    const text = try allocator.alloc(u8, content_len + 2);
    text[0] = d.left;
    pt.copyRange(inner.start, text[1 .. 1 + content_len]);
    text[text.len - 1] = d.right;
    return .{ .start = inner.start, .end = inner.end, .text = text };
}

/// ds: find the delimiter pair surrounding the range containing `pos` and
/// delete it (leaving the inner content). Returns null if none found.
pub fn delete(allocator: std.mem.Allocator, pt: *const PieceTable, pos: u32) !?Result {
    const pair = findPair(pt, pos) orelse return null;
    const mid_len = pair.close - pair.open - 1;
    const text = try allocator.alloc(u8, mid_len);
    pt.copyRange(pair.open + 1, text);
    return .{ .start = pair.open, .end = pair.close + 1, .text = text };
}

/// cs: find the delimiter pair around `pos`, replace both delimiters with
/// `new_ch`. Returns null if none found.
pub fn change(allocator: std.mem.Allocator, pt: *const PieceTable, pos: u32, new_ch: u8) !?Result {
    const pair = findPair(pt, pos) orelse return null;
    const d = delimFor(new_ch) orelse return error.UnsupportedDelimiter;
    const mid_len = pair.close - pair.open - 1;
    const text = try allocator.alloc(u8, mid_len + 2);
    text[0] = d.left;
    pt.copyRange(pair.open + 1, text[1 .. 1 + mid_len]);
    text[text.len - 1] = d.right;
    return .{ .start = pair.open, .end = pair.close + 1, .text = text };
}

// =============================== tests ======================================

fn expectResult(r: Result, exp_start: u32, exp_end: u32, exp_text: []const u8) !void {
    try std.testing.expectEqual(exp_start, r.start);
    try std.testing.expectEqual(exp_end, r.end);
    try std.testing.expectEqualStrings(exp_text, r.text);
}

fn expectDocEqual(pt: *PieceTable, allocator: std.mem.Allocator, expected: []const u8) !void {
    const buf = try allocator.alloc(u8, pt.len());
    defer allocator.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualStrings(expected, buf);
}

fn checkAdd(
    alloc: std.mem.Allocator,
    pt: *const PieceTable,
    inner: Range,
    ch: u8,
    exp_start: u32,
    exp_end: u32,
    exp_text: []const u8,
) !void {
    const r = try add(alloc, pt, inner, ch);
    defer alloc.free(r.text);
    try expectResult(r, exp_start, exp_end, exp_text);
}

fn checkDelete(
    alloc: std.mem.Allocator,
    pt: *const PieceTable,
    pos: u32,
    exp_start: u32,
    exp_end: u32,
    exp_text: []const u8,
) !void {
    const r = (try delete(alloc, pt, pos)).?;
    defer alloc.free(r.text);
    try expectResult(r, exp_start, exp_end, exp_text);
}

fn checkChange(
    alloc: std.mem.Allocator,
    pt: *const PieceTable,
    pos: u32,
    new_ch: u8,
    exp_start: u32,
    exp_end: u32,
    exp_text: []const u8,
) !void {
    const r = (try change(alloc, pt, pos, new_ch)).?;
    defer alloc.free(r.text);
    try expectResult(r, exp_start, exp_end, exp_text);
}

test "surround add: wraps content with every delimiter" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "abc");
    defer pt.deinit();

    // both bytes of each bracket pair are accepted as the delimiter specifier
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '(', 0, 3, "(abc)");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, ')', 0, 3, "(abc)");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '[', 0, 3, "[abc]");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, ']', 0, 3, "[abc]");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '{', 0, 3, "{abc}");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '}', 0, 3, "{abc}");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '<', 0, 3, "<abc>");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '>', 0, 3, "<abc>");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '\'', 0, 3, "'abc'");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '"', 0, 3, "\"abc\"");
    try checkAdd(alloc, &pt, .{ .start = 0, .end = 3 }, '`', 0, 3, "`abc`");
}

test "surround add: empty range and CJK content" {
    const alloc = std.testing.allocator;

    // empty inner range -> just the pair, no content
    var pt = try PieceTable.init(alloc, "ab");
    defer pt.deinit();
    try checkAdd(alloc, &pt, .{ .start = 1, .end = 1 }, '{', 1, 1, "{}");

    // CJK: byte-accurate (中 is 3 bytes), content copied verbatim
    var pt2 = try PieceTable.init(alloc, "中文");
    defer pt2.deinit();
    try checkAdd(alloc, &pt2, .{ .start = 0, .end = 6 }, '(', 0, 6, "(中文)");
}

test "surround add: applying the edit through History semantics" {
    // simulate the caller: History replaces [start,end) with the text, then
    // the caller frees the text (History copied it into its own buffer).
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "hello world");
    defer pt.deinit();
    const r = try add(alloc, &pt, .{ .start = 6, .end = 11 }, '(');
    defer alloc.free(r.text);
    _ = try pt.replace(r.start, r.end - r.start, r.text);
    try expectDocEqual(&pt, alloc, "hello (world)");
}

test "surround add: unsupported delimiter is an error" {
    var pt = try PieceTable.init(std.testing.allocator, "abc");
    defer pt.deinit();
    try std.testing.expectError(
        error.UnsupportedDelimiter,
        add(std.testing.allocator, &pt, .{ .start = 0, .end = 3 }, 'x'),
    );
}

test "surround delete: removes the pair containing the cursor" {
    const alloc = std.testing.allocator;

    // (a[b]c) with the cursor on 'b' -> deletes [] -> (abc)
    var pt = try PieceTable.init(alloc, "(a[b]c)");
    defer pt.deinit();
    try checkDelete(alloc, &pt, 3, 2, 5, "b");

    // and applied through the History
    var pt2 = try PieceTable.init(alloc, "(a[b]c)");
    defer pt2.deinit();
    const r = (try delete(alloc, &pt2, 3)).?;
    defer alloc.free(r.text);
    _ = try pt2.replace(r.start, r.end - r.start, r.text);
    try expectDocEqual(&pt2, alloc, "(abc)");
}

test "surround delete: nesting and cursor positions" {
    const alloc = std.testing.allocator;

    // (a(b)c): cursor on the outer 'a' -> delete the outer pair
    var pt = try PieceTable.init(alloc, "(a(b)c)");
    defer pt.deinit();
    try checkDelete(alloc, &pt, 1, 0, 7, "a(b)c");

    // (a(b)c): cursor on the inner 'b' -> nearest opener is the inner "("
    var pt2 = try PieceTable.init(alloc, "(a(b)c)");
    defer pt2.deinit();
    try checkDelete(alloc, &pt2, 3, 2, 5, "b");

    // cursor exactly on the closer still finds the pair
    var pt3 = try PieceTable.init(alloc, "(abc)");
    defer pt3.deinit();
    try checkDelete(alloc, &pt3, 5, 0, 5, "abc");

    // cursor past the inner pair but inside the outer one -> outer pair
    var pt4 = try PieceTable.init(alloc, "(a[b]c)");
    defer pt4.deinit();
    try checkDelete(alloc, &pt4, 5, 0, 7, "a[b]c");

    // cursor at end of buffer clamps back one byte and still finds the pair
    var pt5 = try PieceTable.init(alloc, "(a)");
    defer pt5.deinit();
    try checkDelete(alloc, &pt5, 3, 0, 3, "a");
}

test "surround delete: quotes same-line, brackets may span lines" {
    const alloc = std.testing.allocator;

    // "x = \"hello\"" — cursor on 'h' (index 5) -> pair is the two quotes
    var pt = try PieceTable.init(alloc, "x = \"hello\"");
    defer pt.deinit();
    try checkDelete(alloc, &pt, 5, 4, 11, "hello");

    // bracket pair across lines: content includes the '\n'
    var pt2 = try PieceTable.init(alloc, "call(a\nb)");
    defer pt2.deinit();
    try checkDelete(alloc, &pt2, 7, 4, 9, "a\nb");

    // unterminated quote (apostrophe in a word): no closer -> null
    var pt3 = try PieceTable.init(alloc, "it's fine");
    defer pt3.deinit();
    try std.testing.expectEqual(@as(?Result, null), try delete(alloc, &pt3, 3));

    // quote that never closes on the same line -> null
    var pt4 = try PieceTable.init(alloc, "\"a\nb\"");
    defer pt4.deinit();
    try std.testing.expectEqual(@as(?Result, null), try delete(alloc, &pt4, 1));
}

test "surround delete: none found returns null" {
    const alloc = std.testing.allocator;

    // no delimiters at all
    var pt = try PieceTable.init(alloc, "abc");
    defer pt.deinit();
    try std.testing.expectEqual(@as(?Result, null), try delete(alloc, &pt, 1));

    // cursor sits between two pairs (past the only pair) -> null
    var pt2 = try PieceTable.init(alloc, "(a)b");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(?Result, null), try delete(alloc, &pt2, 3));

    // empty document
    var pt3 = try PieceTable.init(alloc, "");
    defer pt3.deinit();
    try std.testing.expectEqual(@as(?Result, null), try delete(alloc, &pt3, 0));
}

test "surround change: swap delimiter pairs" {
    const alloc = std.testing.allocator;

    // (a) -> [a]
    var pt = try PieceTable.init(alloc, "(a)");
    defer pt.deinit();
    try checkChange(alloc, &pt, 1, '[', 0, 3, "[a]");

    // "a" -> (a) (quote to bracket)
    var pt2 = try PieceTable.init(alloc, "\"a\"");
    defer pt2.deinit();
    try checkChange(alloc, &pt2, 1, '(', 0, 3, "(a)");

    // (a) -> "a" (bracket to quote)
    var pt3 = try PieceTable.init(alloc, "(a)");
    defer pt3.deinit();
    try checkChange(alloc, &pt3, 1, '"', 0, 3, "\"a\"");

    // nested: cursor on ')' of "[ (x) ]" -> change the inner () to {}
    var pt4 = try PieceTable.init(alloc, "[ (x) ]");
    defer pt4.deinit();
    try checkChange(alloc, &pt4, 4, '{', 2, 5, "{x}");

    // applied through the History
    var pt5 = try PieceTable.init(alloc, "(a)");
    defer pt5.deinit();
    const r = (try change(alloc, &pt5, 1, '[')).?;
    defer alloc.free(r.text);
    _ = try pt5.replace(r.start, r.end - r.start, r.text);
    try expectDocEqual(&pt5, alloc, "[a]");
}

test "surround change: null when no pair, error on bad new delimiter" {
    const alloc = std.testing.allocator;

    var pt = try PieceTable.init(alloc, "plain");
    defer pt.deinit();
    try std.testing.expectEqual(@as(?Result, null), try change(alloc, &pt, 2, '['));

    var pt2 = try PieceTable.init(alloc, "(a)");
    defer pt2.deinit();
    try std.testing.expectError(error.UnsupportedDelimiter, change(alloc, &pt2, 1, 'x'));
}
