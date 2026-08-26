//! Text objects (DESIGN.md §1.1): resolve a vim text object at a byte offset
//! into a range. Pure logic over a PieceTable.
//!
//! Word classification follows motion.zig: cword = [a-zA-Z0-9_] and any
//! non-ASCII byte (CJK etc. count as word characters). Blanks are space, tab,
//! '\n' and '\r' (the same set motion.zig uses).
//!
//! All offsets are byte offsets; `pos` need not be a character boundary — every
//! scan is byte-wise and bounds-checked, so a `pos` in the middle of a
//! multibyte character still behaves (the byte there is a non-ASCII word byte,
//! or falls through the bracket/quote scans harmlessly). The returned Range is
//! [start, end) and always satisfies start <= end <= pt.len().
//!
//! M0 simplifications vs vim (each noted at the function that differs):
//! - Words: the cursor on whitespace always targets the NEXT word, crossing
//!   newlines like motion.zig's `w`. Vim instead selects the whitespace run
//!   itself (trailing blanks / blank lines) or the previous word (on a '\n'
//!   between two words). `aw` includes trailing blanks up to the end of the
//!   line, never the '\n' itself; vim's `aw` on blanks includes the blanks
//!   BEFORE the word.
//! - Brackets: the search is "nearest opener to the left, then match forward;
//!   fall back to nearest closer to the right, then match backward", per the
//!   contract, plus a vim-compatibility refinement for a closer under the
//!   cursor. Vim's backward search finds the innermost ENCLOSING opener
//!   (e.g. "(a(b)c)" with the cursor between the inner ')' and the outer ')'
//!   selects the outer pair), and does nothing when the cursor sits outside a
//!   pair; M0 always pairs the nearest opener/closer it finds. Only brackets
//!   of the requested kind affect the nesting depth (vim's 'smartmatch').
//! - Quotes: pairs are confined to one line (vim's quote objects are too) and
//!   escaped quotes are not treated specially (vim skips quotes escaped with
//!   the 'quoteescape' char). `a'` includes only the quotes; vim's `a'` also
//!   absorbs adjacent whitespace.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Kind = enum {
    inner_word, // iw
    around_word, // aw
    inner_paren, // i(
    around_paren, // a(
    inner_bracket, // i[
    around_bracket, // a[
    inner_brace, // i{
    around_brace, // a{
    inner_angle, // i<
    around_angle, // a<
    inner_quote, // i'
    around_quote, // a'
    inner_dquote, // i"
    around_dquote, // a"
    inner_tick, // i`
    around_tick, // a`
};

/// Byte range [start, end). For around_* kinds the delimiters are included.
pub const Range = struct {
    start: u32,
    end: u32,
};

/// Resolve the text object at byte offset `pos` (a character boundary).
/// Returns an empty range {pos, pos} when the object cannot be resolved.
pub fn range(pt: *const PieceTable, kind: Kind, pos: u32) Range {
    return switch (kind) {
        .inner_word => wordRange(pt, false, pos),
        .around_word => wordRange(pt, true, pos),
        .inner_paren => bracketRange(pt, '(', ')', false, pos),
        .around_paren => bracketRange(pt, '(', ')', true, pos),
        .inner_bracket => bracketRange(pt, '[', ']', false, pos),
        .around_bracket => bracketRange(pt, '[', ']', true, pos),
        .inner_brace => bracketRange(pt, '{', '}', false, pos),
        .around_brace => bracketRange(pt, '{', '}', true, pos),
        .inner_angle => bracketRange(pt, '<', '>', false, pos),
        .around_angle => bracketRange(pt, '<', '>', true, pos),
        .inner_quote => quoteRange(pt, '\'', false, pos),
        .around_quote => quoteRange(pt, '\'', true, pos),
        .inner_dquote => quoteRange(pt, '"', false, pos),
        .around_dquote => quoteRange(pt, '"', true, pos),
        .inner_tick => quoteRange(pt, '`', false, pos),
        .around_tick => quoteRange(pt, '`', true, pos),
    };
}

// ------------------------------ word objects --------------------------------

/// Word characters: [a-zA-Z0-9_] plus any non-ASCII byte (mirrors
/// motion.zig::isWordByte, which is private there).
fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80;
}

/// Blanks separate words: space, tab, '\n' and '\r' (mirrors motion.zig).
fn isBlankByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// iw/aw. Cursor inside a word selects that word (a cword run, so underscores,
/// digits and multibyte CJK stay together). Cursor on blanks selects the next
/// word (crossing newlines, like `w`); with no next word (trailing blanks, end
/// of document) the range is empty. Punctuation is a one-character word, so
/// `iw` on '.' selects only '.'.
///
/// aw = the word plus any blanks immediately after it, clamped to the end of
/// the word's line (the trailing '\n' is never included); a word with no
/// trailing blanks selects just the word. When the cursor is on blanks, aw
/// targets the same next word as iw (vim would instead take the blanks).
fn wordRange(pt: *const PieceTable, include: bool, pos_in: u32) Range {
    const len = pt.len();
    const pos = @min(pos_in, len);
    const empty = Range{ .start = pos, .end = pos };
    if (pos >= len) return empty; // nothing under (or after) the cursor

    var word_start: u32 = undefined;
    var word_end: u32 = undefined;
    const b = pt.byteAt(pos);
    if (isWordByte(b)) {
        // Expand to the full cword run around `pos`. Multibyte chars are
        // entirely word bytes, so the run always covers whole characters even
        // when `pos` lands inside one.
        var s = pos;
        while (s > 0 and isWordByte(pt.byteAt(s - 1))) : (s -= 1) {}
        var e = pos + 1;
        while (e < len and isWordByte(pt.byteAt(e))) : (e += 1) {}
        word_start = s;
        word_end = e;
    } else if (isBlankByte(b)) {
        // Next word: skip the blank run (crossing newlines, like `w`).
        var p = pos;
        while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
        if (p >= len) return empty; // trailing blanks / end of document
        if (isWordByte(pt.byteAt(p))) {
            var s = p;
            while (s > 0 and isWordByte(pt.byteAt(s - 1))) : (s -= 1) {}
            var e = p + 1;
            while (e < len and isWordByte(pt.byteAt(e))) : (e += 1) {}
            word_start = s;
            word_end = e;
        } else {
            // Punctuation run: a run of punctuation is one word (vim, and
            // matches motion.zig's w/e/b/ge) — expand to the whole run so
            // diw on "a->b" deletes "->", not a single byte.
            var s = p;
            while (s > 0 and !isWordByte(pt.byteAt(s - 1)) and !isBlankByte(pt.byteAt(s - 1))) : (s -= 1) {}
            var e = p + 1;
            while (e < len and !isWordByte(pt.byteAt(e)) and !isBlankByte(pt.byteAt(e))) : (e += 1) {}
            word_start = s;
            word_end = e;
        }
    } else {
        // Punctuation run under the cursor: the whole run is one word.
        var s = pos;
        while (s > 0 and !isWordByte(pt.byteAt(s - 1)) and !isBlankByte(pt.byteAt(s - 1))) : (s -= 1) {}
        var e = pos + 1;
        while (e < len and !isWordByte(pt.byteAt(e)) and !isBlankByte(pt.byteAt(e))) : (e += 1) {}
        word_start = s;
        word_end = e;
    }

    if (!include) return .{ .start = word_start, .end = word_end };

    // aw: append the blanks right after the word, up to the end of the line
    // (line content excludes the '\n', so it can never slip in).
    const line = pt.lineOf(word_end - 1);
    const line_end = pt.lineStart(line) + pt.lineLen(line);
    var e = word_end;
    while (e < line_end and isBlankByte(pt.byteAt(e))) : (e += 1) {}
    return .{ .start = word_start, .end = e };
}

// ----------------------------- bracket objects ------------------------------

/// i(/a( etc. Search order (contract + vim-compat refinement):
///   1. A bracket under the cursor wins: an opener is matched forward, a
///      closer backward. Matching the closer itself (rather than scanning past
///      it for an opener) is a vim-compatibility refinement: without it the
///      outer ')' of "((a))" would pair with the inner '(' and select the
///      inner pair, while vim pairs the closer with its own opener.
///   2. Otherwise the nearest opener to the left is matched forward with
///      nesting depth (same kind only).
///   3. If no opener is found, the nearest closer to the right is matched
///      backward.
/// No pair: {pos, pos}. Different bracket kinds never affect each other's
/// depth. M0 deviation from vim: vim's backward search picks the innermost
/// ENCLOSING opener ("(a(b)c)" with the cursor between the inner ')' and the
/// outer ')' selects the outer pair) and fails when the cursor is outside any
/// pair ("ab(cd)ef" with the cursor after it); M0 takes the nearest opener or
/// closer it can find instead.
fn bracketRange(pt: *const PieceTable, open: u8, close: u8, include: bool, pos_in: u32) Range {
    const len = pt.len();
    const pos = @min(pos_in, len);
    const empty = Range{ .start = pos, .end = pos };

    if (pos < len) {
        const b = pt.byteAt(pos);
        if (b == close) {
            if (backwardMatch(pt, pos, open, close)) |o| return pairResult(o, pos, include);
        } else if (b == open) {
            if (forwardMatch(pt, pos, open, close)) |c| return pairResult(pos, c, include);
        }
    }

    // Nearest opener to the left; match it forward.
    var p = pos;
    while (p > 0) {
        p -= 1;
        if (pt.byteAt(p) == open) {
            const c = forwardMatch(pt, p, open, close) orelse return empty;
            return pairResult(p, c, include);
        }
    }

    // No opener on the left: nearest closer to the right; match it backward.
    var q = pos;
    while (q < len) : (q += 1) {
        if (pt.byteAt(q) == close) {
            const o = backwardMatch(pt, q, open, close) orelse return empty;
            return pairResult(o, q, include);
        }
    }
    return empty;
}

/// Nesting-aware scan right from an opener for its matching closer. Only
/// `open`/`close` count; other bracket kinds are ignored (vim 'smartmatch').
fn forwardMatch(pt: *const PieceTable, from: u32, open: u8, close: u8) ?u32 {
    const len = pt.len();
    var depth: u32 = 1;
    var p = from + 1;
    while (p < len) : (p += 1) {
        const c = pt.byteAt(p);
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return p;
        }
    }
    return null;
}

/// Nesting-aware scan left from a closer for its matching opener.
fn backwardMatch(pt: *const PieceTable, from: u32, open: u8, close: u8) ?u32 {
    var depth: u32 = 1;
    var p = from;
    while (p > 0) {
        p -= 1;
        const c = pt.byteAt(p);
        if (c == close) {
            depth += 1;
        } else if (c == open) {
            depth -= 1;
            if (depth == 0) return p;
        }
    }
    return null;
}

/// around_* includes both delimiters; inner_* strips them.
fn pairResult(open: u32, close: u32, include: bool) Range {
    return if (include)
        .{ .start = open, .end = close + 1 }
    else
        .{ .start = open + 1, .end = close };
}

// ------------------------------ quote objects -------------------------------

/// i'/a', i"/a", i`/a`. Pairs are confined to the line containing `pos`
/// (vim's quote objects do not cross lines either). Pairing, mirroring vim:
///   - cursor on a quote character: consecutive pairs from the start of the
///     line; the first pair containing the cursor wins;
///   - otherwise the nearest quote at or before the cursor is the opener
///     (falling back to the nearest quote after it), paired with the next
///     quote after it.
/// M0: escaped quotes ('\' inside a string) are not handled specially — every
/// quote byte counts, so "\"a\"" style content still pairs positionally.
/// a' includes only the quotes; vim's a' additionally absorbs adjacent
/// whitespace. No pair: {pos, pos}.
fn quoteRange(pt: *const PieceTable, q: u8, include: bool, pos_in: u32) Range {
    const len = pt.len();
    const pos = @min(pos_in, len);
    const empty = Range{ .start = pos, .end = pos };
    const line = pt.lineOf(pos);
    const ls = pt.lineStart(line);
    const le = ls + pt.lineLen(line); // one past the last content byte

    if (pos < le and pt.byteAt(pos) == q) {
        // On a quote: walk consecutive pairs from the line start.
        var i = ls;
        while (i < le) : (i += 1) {
            if (pt.byteAt(i) != q) continue;
            var j = i + 1;
            while (j < le and pt.byteAt(j) != q) : (j += 1) {}
            if (j >= le) return empty; // unpaired opener
            if (i <= pos and pos <= j) return pairResult(i, j, include);
            i = j; // try the next pair
        }
        return empty;
    }

    // Not on a quote: nearest quote before the cursor is the opener.
    var open: ?u32 = null;
    var s = @min(pos, le);
    while (s > ls) {
        s -= 1;
        if (pt.byteAt(s) == q) {
            open = s;
            break;
        }
    }
    if (open == null) {
        // None before: the nearest quote after the cursor.
        var t = pos;
        while (t < le) : (t += 1) {
            if (pt.byteAt(t) == q) {
                open = t;
                break;
            }
        }
    }
    const o = open orelse return empty;

    // The closing quote is the next quote after the opener.
    var t = o + 1;
    while (t < le) : (t += 1) {
        if (pt.byteAt(t) == q) return pairResult(o, t, include);
    }
    return empty;
}

// ================================= tests =====================================

const testing = std.testing;

/// Assert the range boundaries AND that copyRange over the range reproduces
/// exactly `text` — every case doubles as the consistency requirement.
fn expectRange(pt: *const PieceTable, kind: Kind, pos: u32, start: u32, end: u32, text: []const u8) !void {
    const r = range(pt, kind, pos);
    try testing.expectEqual(start, r.start);
    try testing.expectEqual(end, r.end);
    const buf = try testing.allocator.alloc(u8, @intCast(r.end - r.start));
    defer testing.allocator.free(buf);
    if (r.end > r.start) pt.copyRange(r.start, buf);
    try testing.expectEqualSlices(u8, text, buf);
}

test "iw/aw: plain words, punctuation words, underscores, CJK" {
    // "foo_bar baz": f0 o1 o2 _3 b4 a5 r6 ' '7 b8 a9 z10.
    var pt = try PieceTable.init(testing.allocator, "foo_bar baz");
    defer pt.deinit();
    try expectRange(&pt, .inner_word, 1, 0, 7, "foo_bar"); // underscore stays in the word
    try expectRange(&pt, .around_word, 1, 0, 8, "foo_bar "); // word + trailing blank
    try expectRange(&pt, .inner_word, 7, 8, 11, "baz"); // cursor on the blank
    try expectRange(&pt, .around_word, 7, 8, 11, "baz"); // no trailing blanks: just the word
    try expectRange(&pt, .around_word, 8, 8, 11, "baz"); // cursor on the word itself

    // "abc.def": a0 b1 c2 .3 d4 e5 f6.
    var pt2 = try PieceTable.init(testing.allocator, "abc.def");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_word, 3, 3, 4, "."); // punctuation is its own word
    try expectRange(&pt2, .around_word, 3, 3, 4, "."); // no blank after '.' -> word only
    try expectRange(&pt2, .inner_word, 1, 0, 3, "abc");
    try expectRange(&pt2, .around_word, 1, 0, 3, "abc"); // '.' is not a blank: no trailing
    try expectRange(&pt2, .inner_word, 4, 4, 7, "def");

    // "中文 测试": 中=0..3 文=3..6 ' '=6 测=7..10 试=10..13.
    var pt3 = try PieceTable.init(testing.allocator, "中文 测试");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_word, 0, 0, 6, "中文"); // CJK counts as word characters
    try expectRange(&pt3, .around_word, 0, 0, 7, "中文 ");
    try expectRange(&pt3, .inner_word, 7, 7, 13, "测试");
    try expectRange(&pt3, .inner_word, 8, 7, 13, "测试"); // mid-character pos: whole char run
    try expectRange(&pt3, .inner_word, 1, 0, 6, "中文"); // mid-character pos in 中
    try expectRange(&pt3, .around_word, 7, 7, 13, "测试"); // no trailing blank on the line
}

test "iw/aw: cursor on blanks, line start/end, empty lines, document edges" {
    // "foo bar": f0 o1 o2 ' '3 b4 a5 r6.
    var pt = try PieceTable.init(testing.allocator, "foo bar");
    defer pt.deinit();
    try expectRange(&pt, .inner_word, 3, 4, 7, "bar"); // blank -> next word
    try expectRange(&pt, .around_word, 3, 4, 7, "bar");

    // "  foo": ' '0 ' '1 f2 o3 o4.
    var pt2 = try PieceTable.init(testing.allocator, "  foo");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_word, 0, 2, 5, "foo"); // leading blanks -> next word
    try expectRange(&pt2, .inner_word, 1, 2, 5, "foo");
    try expectRange(&pt2, .around_word, 0, 2, 5, "foo");

    // "foo  ": f0 o1 o2 ' '3 ' '4. Trailing blanks: no next word -> empty.
    var pt3 = try PieceTable.init(testing.allocator, "foo  ");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_word, 3, 3, 3, "");
    try expectRange(&pt3, .around_word, 4, 4, 4, "");

    // "foo\nbar": \n at 3. Blank search crosses newlines (like `w`).
    var pt4 = try PieceTable.init(testing.allocator, "foo\nbar");
    defer pt4.deinit();
    try expectRange(&pt4, .inner_word, 3, 4, 7, "bar");
    try expectRange(&pt4, .around_word, 3, 4, 7, "bar");

    // "ab\n\ncd": a0 b1 \n2 \n3 c4 d5. Empty line -> next word after it.
    var pt5 = try PieceTable.init(testing.allocator, "ab\n\ncd");
    defer pt5.deinit();
    try expectRange(&pt5, .inner_word, 2, 4, 6, "cd");
    try expectRange(&pt5, .inner_word, 3, 4, 6, "cd");

    // "hello": h0 e1 l2 l3 o4.
    var pt6 = try PieceTable.init(testing.allocator, "hello");
    defer pt6.deinit();
    try expectRange(&pt6, .inner_word, 2, 0, 5, "hello");
    try expectRange(&pt6, .inner_word, 4, 0, 5, "hello");
    try expectRange(&pt6, .around_word, 4, 0, 5, "hello"); // last char, no trailing blank
    try expectRange(&pt6, .inner_word, 5, 5, 5, ""); // pos == len: nothing under the cursor
    try expectRange(&pt6, .around_word, 5, 5, 5, "");

    // empty document
    var pt7 = try PieceTable.init(testing.allocator, "");
    defer pt7.deinit();
    try expectRange(&pt7, .inner_word, 0, 0, 0, "");
    try expectRange(&pt7, .around_word, 0, 0, 0, "");
}

test "aw: trailing blanks to line end, newline never included" {
    // "abc\ndef": a0 b1 c2 \n3 d4 e5 f6. No trailing blank -> word only.
    var pt = try PieceTable.init(testing.allocator, "abc\ndef");
    defer pt.deinit();
    try expectRange(&pt, .around_word, 1, 0, 3, "abc");

    // "abc \ndef": a0 b1 c2 ' '3 \n4 d5 e6 f7. One trailing blank, then '\n'.
    var pt2 = try PieceTable.init(testing.allocator, "abc \ndef");
    defer pt2.deinit();
    try expectRange(&pt2, .around_word, 1, 0, 4, "abc ");

    // "a. b": a0 .1 ' '2 b3. Punctuation word + trailing blank.
    var pt3 = try PieceTable.init(testing.allocator, "a. b");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_word, 1, 1, 2, ".");
    try expectRange(&pt3, .around_word, 1, 1, 3, ". ");

    // "foo\tbar": f0 o1 o2 \t3 b4 a5 r6. Tab counts as a blank.
    var pt4 = try PieceTable.init(testing.allocator, "foo\tbar");
    defer pt4.deinit();
    try expectRange(&pt4, .inner_word, 3, 4, 7, "bar");
    try expectRange(&pt4, .around_word, 1, 0, 4, "foo\t");

    // "one two\nthree": o0 n1 e2 ' '3 t4 w5 o6 \n7 t8 h9 r10 e11 e12.
    var pt5 = try PieceTable.init(testing.allocator, "one two\nthree");
    defer pt5.deinit();
    try expectRange(&pt5, .inner_word, 3, 4, 7, "two");
    try expectRange(&pt5, .around_word, 3, 4, 7, "two");
}

test "brackets: nested pairs across every cursor position" {
    // "(a(b)c)": (0 a1 (2 b3 )4 c5 )6.
    var pt = try PieceTable.init(testing.allocator, "(a(b)c)");
    defer pt.deinit();
    // cursor on 'a' (outside the inner pair): outer pair
    try expectRange(&pt, .inner_paren, 1, 1, 6, "a(b)c");
    try expectRange(&pt, .around_paren, 1, 0, 7, "(a(b)c)");
    // cursor on 'b': nearest (inner) pair
    try expectRange(&pt, .inner_paren, 3, 3, 4, "b");
    try expectRange(&pt, .around_paren, 3, 2, 5, "(b)");
    // cursor on the inner ')': closer under the cursor matches backward
    try expectRange(&pt, .inner_paren, 4, 3, 4, "b");
    try expectRange(&pt, .around_paren, 4, 2, 5, "(b)");
    // cursor on 'c' (between inner ')' and outer ')'): the contract's
    // left-nearest-opener rule picks the inner pair; vim would pick the outer
    // (its backward search finds the innermost ENCLOSING opener) -- M0 note.
    try expectRange(&pt, .inner_paren, 5, 3, 4, "b");
    // cursor on the outer '(' / ')' : the whole block
    try expectRange(&pt, .inner_paren, 0, 1, 6, "a(b)c");
    try expectRange(&pt, .around_paren, 0, 0, 7, "(a(b)c)");
    try expectRange(&pt, .inner_paren, 6, 1, 6, "a(b)c");
    try expectRange(&pt, .around_paren, 6, 0, 7, "(a(b)c)");
}

test "brackets: ((a)) every position" {
    // "((a))": (0 (1 a2 )3 )4.
    var pt = try PieceTable.init(testing.allocator, "((a))");
    defer pt.deinit();
    try expectRange(&pt, .inner_paren, 0, 1, 4, "(a)"); // outer opener -> outer pair
    try expectRange(&pt, .around_paren, 0, 0, 5, "((a))");
    try expectRange(&pt, .inner_paren, 1, 2, 3, "a"); // inner opener -> inner pair
    try expectRange(&pt, .around_paren, 1, 1, 4, "(a)");
    try expectRange(&pt, .inner_paren, 2, 2, 3, "a"); // on 'a': left-nearest opener
    try expectRange(&pt, .inner_paren, 3, 2, 3, "a"); // inner closer matches backward
    // Outer closer: the closer-under-cursor refinement pairs it with the outer
    // opener (a naive "left-nearest opener" would select the inner pair).
    try expectRange(&pt, .inner_paren, 4, 1, 4, "(a)");
    try expectRange(&pt, .around_paren, 4, 0, 5, "((a))");
}

test "brackets: a( vs i(, empty pairs, cross-line pairs" {
    // "(a)": i( excludes the parens, a( includes them.
    var pt = try PieceTable.init(testing.allocator, "(a)");
    defer pt.deinit();
    try expectRange(&pt, .inner_paren, 1, 1, 2, "a");
    try expectRange(&pt, .around_paren, 1, 0, 3, "(a)");

    // "()": i( on an empty pair is an empty range; a( selects "()".
    var pt2 = try PieceTable.init(testing.allocator, "()");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_paren, 0, 1, 1, "");
    try expectRange(&pt2, .around_paren, 0, 0, 2, "()");
    try expectRange(&pt2, .inner_paren, 1, 1, 1, "");
    try expectRange(&pt2, .around_paren, 1, 0, 2, "()");

    // "(a\nb)": (0 a1 \n2 b3 )4 -- pairs cross lines.
    var pt3 = try PieceTable.init(testing.allocator, "(a\nb)");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_paren, 1, 1, 4, "a\nb");
    try expectRange(&pt3, .around_paren, 1, 0, 5, "(a\nb)");
    try expectRange(&pt3, .inner_paren, 2, 1, 4, "a\nb"); // cursor on the '\n'
}

test "brackets: all four kinds, mismatched kinds, nesting across kinds" {
    // "[ab]": a[ includes the brackets.
    var pt = try PieceTable.init(testing.allocator, "[ab]");
    defer pt.deinit();
    try expectRange(&pt, .inner_bracket, 1, 1, 3, "ab");
    try expectRange(&pt, .around_bracket, 1, 0, 4, "[ab]");

    var pt2 = try PieceTable.init(testing.allocator, "{ab}");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_brace, 1, 1, 3, "ab");
    try expectRange(&pt2, .around_brace, 1, 0, 4, "{ab}");

    var pt3 = try PieceTable.init(testing.allocator, "<ab>");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_angle, 1, 1, 3, "ab");
    try expectRange(&pt3, .around_angle, 1, 0, 4, "<ab>");

    // "(a[b)c]": different kinds never affect each other's depth -- i( from
    // 'a' matches (0,4) even though a '[' sits inside.
    var pt4 = try PieceTable.init(testing.allocator, "(a[b)c]");
    defer pt4.deinit();
    try expectRange(&pt4, .inner_paren, 1, 1, 4, "a[b");
    try expectRange(&pt4, .around_paren, 1, 0, 5, "(a[b)");

    // "([{}])": (0 [1 {2 }3 ]4 )5. i{ selects the innermost pair; i( treats
    // the other kinds as plain text.
    var pt5 = try PieceTable.init(testing.allocator, "([{}])");
    defer pt5.deinit();
    try expectRange(&pt5, .inner_brace, 2, 3, 3, ""); // "{}" is empty inside
    try expectRange(&pt5, .around_brace, 2, 2, 4, "{}");
    try expectRange(&pt5, .inner_paren, 2, 1, 5, "[{}]");
    try expectRange(&pt5, .around_paren, 2, 0, 6, "([{}])");
}

test "brackets: unbalanced and missing partners" {
    // "(a": opener without a closer -> empty.
    var pt = try PieceTable.init(testing.allocator, "(a");
    defer pt.deinit();
    try expectRange(&pt, .inner_paren, 1, 1, 1, "");
    try expectRange(&pt, .inner_paren, 0, 0, 0, "");

    // "a(b": cursor on the unpaired '(' -> empty; on 'a' no opener left and
    // no closer right -> empty.
    var pt2 = try PieceTable.init(testing.allocator, "a(b");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_paren, 2, 2, 2, "");
    try expectRange(&pt2, .inner_paren, 0, 0, 0, "");

    // "ab)c": closer without an opener -> empty from every position.
    var pt3 = try PieceTable.init(testing.allocator, "ab)c");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_paren, 2, 2, 2, "");
    try expectRange(&pt3, .inner_paren, 1, 1, 1, "");

    // "()(x)": (0 )1 (2 x3 )4. Cursor on the second '(' pairs forward.
    var pt4 = try PieceTable.init(testing.allocator, "()(x)");
    defer pt4.deinit();
    try expectRange(&pt4, .inner_paren, 2, 3, 4, "x");
    try expectRange(&pt4, .inner_paren, 0, 1, 1, ""); // "()" is empty inside
    try expectRange(&pt4, .around_paren, 0, 0, 2, "()");

    // "(a)" with pos == len: the left scan still finds the pair.
    var pt5 = try PieceTable.init(testing.allocator, "(a)");
    defer pt5.deinit();
    try expectRange(&pt5, .inner_paren, 3, 1, 2, "a");

    // "(中文)": (0 中1..3 文4..6 )7 -- a mid-character pos scans correctly.
    var pt6 = try PieceTable.init(testing.allocator, "(中文)");
    defer pt6.deinit();
    try expectRange(&pt6, .inner_paren, 2, 1, 7, "中文");
    try expectRange(&pt6, .around_paren, 2, 0, 8, "(中文)");
}

test "quotes: inner/around, cursor inside and on the quotes" {
    // "'abc'": '0 a1 b2 c3 '4.
    var pt = try PieceTable.init(testing.allocator, "'abc'");
    defer pt.deinit();
    try expectRange(&pt, .inner_quote, 1, 1, 4, "abc");
    try expectRange(&pt, .around_quote, 1, 0, 5, "'abc'");
    try expectRange(&pt, .inner_quote, 0, 1, 4, "abc"); // on the opening quote
    try expectRange(&pt, .inner_quote, 4, 1, 4, "abc"); // on the closing quote
    try expectRange(&pt, .around_quote, 4, 0, 5, "'abc'");

    // "\"abc\"": "0 a1 b2 c3 "4.
    var pt2 = try PieceTable.init(testing.allocator, "\"abc\"");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_dquote, 2, 1, 4, "abc");
    try expectRange(&pt2, .around_dquote, 2, 0, 5, "\"abc\"");

    // "`abc`": `0 a1 b2 c3 `4.
    var pt3 = try PieceTable.init(testing.allocator, "`abc`");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_tick, 2, 1, 4, "abc");
    try expectRange(&pt3, .around_tick, 2, 0, 5, "`abc`");
}

test "quotes: unclosed, and no cross-line matching (M0)" {
    // "'abc": opener without a closer -> empty.
    var pt = try PieceTable.init(testing.allocator, "'abc");
    defer pt.deinit();
    try expectRange(&pt, .inner_quote, 1, 1, 1, "");
    try expectRange(&pt, .inner_quote, 0, 0, 0, "");

    // "a'\nb'": a0 '1 \n2 b3 '4. Quotes never match across lines (vim behaves
    // the same way); every position fails or stays inside its own line.
    var pt2 = try PieceTable.init(testing.allocator, "a'\nb'");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_quote, 1, 1, 1, ""); // quote on line 0: no partner on the line
    try expectRange(&pt2, .inner_quote, 2, 2, 2, ""); // on the '\n'
    try expectRange(&pt2, .inner_quote, 3, 3, 3, ""); // line 1 quote has no partner after it
    try expectRange(&pt2, .inner_quote, 0, 0, 0, "");
    try expectRange(&pt2, .around_quote, 3, 3, 3, "");

    // "'ab'": '0 a1 b2 '3. pos == len: no closing quote on the line -> empty.
    var pt3 = try PieceTable.init(testing.allocator, "'ab'");
    defer pt3.deinit();
    try expectRange(&pt3, .inner_quote, 4, 4, 4, "");
}

test "quotes: nearest pair before/after the cursor, several pairs on a line" {
    // "a'b'c": a0 '1 b2 '3 c4. Cursor before the pair: the next pair; after
    // the pair: nothing (the last quote has no partner).
    var pt = try PieceTable.init(testing.allocator, "a'b'c");
    defer pt.deinit();
    try expectRange(&pt, .inner_quote, 0, 2, 3, "b");
    try expectRange(&pt, .around_quote, 0, 1, 4, "'b'");
    try expectRange(&pt, .inner_quote, 2, 2, 3, "b"); // between the quotes
    try expectRange(&pt, .inner_quote, 4, 4, 4, "");

    // "'a'x'y'": '0 a1 '2 x3 '4 y5 '6. Several pairs on one line.
    var pt2 = try PieceTable.init(testing.allocator, "'a'x'y'");
    defer pt2.deinit();
    try expectRange(&pt2, .inner_quote, 1, 1, 2, "a");
    try expectRange(&pt2, .inner_quote, 3, 3, 4, "x"); // between pairs: nearest before + after
    try expectRange(&pt2, .around_quote, 3, 2, 5, "'x'");
    try expectRange(&pt2, .inner_quote, 5, 5, 6, "y");
    try expectRange(&pt2, .inner_quote, 4, 5, 6, "y"); // on a quote: the pair containing it

    // "'a' x": a' includes only the quotes in M0 (vim would also grab the
    // following " x" -- M0 note).
    var pt3 = try PieceTable.init(testing.allocator, "'a' x");
    defer pt3.deinit();
    try expectRange(&pt3, .around_quote, 1, 0, 3, "'a'");
}

test "consistency: every kind at every position stays in bounds and round-trips" {
    const source = "foo(bar 'baz' 中\n[qux]) end";
    var pt = try PieceTable.init(testing.allocator, source);
    defer pt.deinit();
    const kinds = [_]Kind{
        .inner_word,    .around_word,
        .inner_paren,   .around_paren,
        .inner_bracket, .around_bracket,
        .inner_brace,   .around_brace,
        .inner_angle,   .around_angle,
        .inner_quote,   .around_quote,
        .inner_dquote,  .around_dquote,
        .inner_tick,    .around_tick,
    };
    for (kinds) |k| {
        for (0..source.len + 1) |p| {
            const pos: u32 = @intCast(p);
            const r = range(&pt, k, pos);
            try testing.expect(r.start <= r.end);
            try testing.expect(r.end <= pt.len());
            try testing.expect(r.start <= pt.len());
            // copyRange over the range must reproduce the source slice.
            if (r.end > r.start) {
                const buf = try testing.allocator.alloc(u8, @intCast(r.end - r.start));
                defer testing.allocator.free(buf);
                pt.copyRange(r.start, buf);
                try testing.expectEqualSlices(u8, source[r.start..r.end], buf);
            }
        }
    }
}
