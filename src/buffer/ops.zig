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

/// Character classes for insert-mode word deletion:
/// - word: ASCII alnum/underscore plus every non-whitespace, non-symbol
///   Unicode codepoint (CJK, accented Latin, Cyrillic, …) — the same class
///   vim's `iskeyword` gives those scripts by default.
/// - punct: a run of non-space, non-word characters (operators, `.`, `::`,
///   `->`, brackets, emoji, symbols and invalid UTF-8 bytes).
/// - space: ASCII whitespace plus Unicode whitespace codepoints.
const CharClass = enum { word, punct, space };

fn isUnicodeSpace(cp: u21) bool {
    return cp == 0xA0 or cp == 0x1680 or
        (cp >= 0x2000 and cp <= 0x200A) or
        cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or
        cp == 0x3000;
}

fn isWordCodepoint(cp: u21) bool {
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or cp == '_';
    }
    if (isUnicodeSpace(cp)) return false;
    // Symbols and the major punctuation blocks are their own class.
    if (cp >= 0x1F000 and cp <= 0x1FAFF) return false; // emoji/symbols
    if (cp >= 0x2190 and cp <= 0x2BFF) return false; // arrows/math/symbols
    if (cp >= 0x1D100 and cp <= 0x1D1FF) return false; // musical
    if (cp >= 0x2000 and cp <= 0x206F) return false; // general punctuation
    if (cp >= 0x2E00 and cp <= 0x2E7F) return false; // supplemental punctuation
    if (cp >= 0x3000 and cp <= 0x303F) return false; // CJK symbols/punctuation
    if (cp >= 0xFE10 and cp <= 0xFE1F) return false; // vertical forms
    if (cp >= 0xFE30 and cp <= 0xFE4F) return false; // compatibility forms
    if (cp >= 0xFF00 and cp <= 0xFF0F) return false; // fullwidth punct
    if (cp >= 0xFF1A and cp <= 0xFF20) return false;
    if (cp >= 0xFF3B and cp <= 0xFF40) return false;
    if (cp >= 0xFF5B and cp <= 0xFF65) return false;
    return true; // letters, digits and marks in every other script
}

/// Classify the single UTF-8 character in [start, end). Invalid/truncated
/// bytes are punctuation, so Ctrl-W steps over them one prevCharStart
/// character at a time and never splits a valid scalar.
fn charClassAt(pt: *const PieceTable, start: u32, end: u32) CharClass {
    const len: usize = @intCast(end - start);
    if (len == 0 or len > 4) return .punct;
    var win: [4]u8 = undefined;
    pt.copyRange(start, win[0..len]);
    // ASCII whitespace (including the cross-line newline/CR) is a space
    // class, never punctuation; otherwise a punctuation run would continue
    // across the space into the previous token.
    if (len == 1 and isSpace(win[0])) return .space;
    const dec = utf8.decodeAt(win[0..len], 0);
    if (dec.len != len or dec.cp == 0xFFFD) return .punct;
    if (isUnicodeSpace(dec.cp)) return .space;
    return if (isWordCodepoint(dec.cp)) .word else .punct;
}

/// Start of the deletion range for "delete word before cursor"
/// (vim i_CTRL-W): walk back over whitespace, then over one contiguous run
/// of a single class — identifier-word characters (ASCII alnum/underscore
/// and Unicode letters) OR punctuation (non-space, non-word) — walking on
/// UTF-8 scalar boundaries via prevCharStart. The deleted range is
/// [result, pos). Invalid/orphan continuation bytes keep the prevCharStart
/// contract: each orphan run is one character and is treated as punctuation.
pub fn wordStartBefore(pt: *const PieceTable, pos: u32) u32 {
    var i = pos;
    while (i > 0 and isSpace(pt.byteAt(i - 1))) i -= 1;
    if (i == 0) return 0;
    const first_start = prevCharStart(pt, i);
    const cls = charClassAt(pt, first_start, i);
    while (i > 0) {
        const start = prevCharStart(pt, i);
        const c = charClassAt(pt, start, i);
        // The character before the run is a space: the run starts at `i`.
        if (c == .space) return i;
        if (c != cls) return i;
        i = start;
    }
    return i;
}

/// WORD variant (vim `W` / Alt-b style): skip whitespace then the run of all
/// non-space characters, including punctuation. Kept separate from
/// `wordStartBefore` so callers that want big-word motion can use it.
pub fn bigWordStartBefore(pt: *const PieceTable, pos: u32) u32 {
    var i = pos;
    while (i > 0 and isSpace(pt.byteAt(i - 1))) i -= 1;
    while (i > 0) {
        const start = prevCharStart(pt, i);
        if (charClassAt(pt, start, i) == .space) return i;
        i = start;
    }
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

// ---------------------------------------------------------------------------
// vim word semantics (i_CTRL-W): word run | punctuation run | whitespace.
// The expected start offsets below are a differential table: each row is
// (document, cursor offset, start of the deleted range) and consecutive
// Ctrl-W presses walk the same document to the left.
// ---------------------------------------------------------------------------

fn expectWordStart(text: []const u8, pos: u32, expected: u32) !void {
    var pt = try PieceTable.init(std.testing.allocator, text);
    defer pt.deinit();
    try std.testing.expectEqual(expected, wordStartBefore(&pt, pos));
}

test "wordStartBefore: dot expressions delete one word at a time" {
    const text = "self.word1.word2";
    try expectWordStart(text, 16, 11); // "word2"
    try expectWordStart(text, 11, 10); // "."
    try expectWordStart(text, 10, 5); // "word1"
    try expectWordStart(text, 5, 4); // "."
    try expectWordStart(text, 4, 0); // "self"
    try expectWordStart(text, 0, 0);
}

test "wordStartBefore: snake_case and digit runs are one word" {
    try expectWordStart("foo_bar_baz", 11, 0);
    try expectWordStart("x1_y2", 5, 0);
    try expectWordStart("v2.10", 5, 3); // "10" after the dot
    try expectWordStart("v2.10", 3, 2); // "."
}

test "wordStartBefore: punctuation runs are their own class" {
    // A punctuation run stops at ASCII whitespace: "abc ..." deletes "...".
    try expectWordStart("abc ...", 7, 4);
    try expectWordStart("abc ...", 4, 0);
    // "foo::bar": 5=bar, 3="::", 0=foo
    try expectWordStart("foo::bar", 8, 5);
    try expectWordStart("foo::bar", 5, 3);
    try expectWordStart("foo::bar", 3, 0);
    // "a->b...": 4="...", 3="b", 1="->", 0="a"
    try expectWordStart("a->b...", 7, 4);
    try expectWordStart("a->b...", 4, 3);
    try expectWordStart("a->b...", 3, 1);
    try expectWordStart("a->b...", 1, 0);
    // "call(arg)": 8=")", 5="(arg", no: 5="arg" and 4="("
    try expectWordStart("call(arg)", 9, 8);
    try expectWordStart("call(arg)", 8, 5);
    try expectWordStart("call(arg)", 5, 4);
    try expectWordStart("call(arg)", 4, 0);
}

test "wordStartBefore: paths split on slash punctuation" {
    const text = "/usr/local/bin";
    try expectWordStart(text, 14, 11); // "bin"
    try expectWordStart(text, 11, 10); // "/"
    try expectWordStart(text, 10, 5); // "local"
    try expectWordStart(text, 5, 4); // "/"
    try expectWordStart(text, 4, 1); // "usr"
    try expectWordStart(text, 1, 0); // "/"
}

test "wordStartBefore: trailing spaces and tabs are skipped, then one word" {
    try expectWordStart("abc   ", 6, 0);
    try expectWordStart("abc\t \t", 6, 0);
    try expectWordStart("    abc", 7, 4);
}

test "wordStartBefore: cross-line contract keeps the existing walking" {
    // First press deletes "def"; the second skips the newline and the word
    // before it (the established cross-line behaviour).
    try expectWordStart("abc\ndef", 7, 4);
    try expectWordStart("abc\n", 4, 0);
}

test "wordStartBefore: empty document and document start" {
    try expectWordStart("", 0, 0);
    try expectWordStart("abc", 0, 0);
}

test "wordStartBefore: CJK characters are word characters" {
    const cjk = "中文测试";
    try expectWordStart(cjk, 12, 0);
    // Letters from any script are one word class: "abc中文def" is one run.
    try expectWordStart("abc中文def", 12, 0);
    try expectWordStart("abc中文.def", 13, 10); // "def"
    try expectWordStart("abc中文.def", 10, 9); // "."
    try expectWordStart("abc中文.def", 9, 0); // "abc中文"
    // CJK punctuation is a separate class: "中。文" splits at U+3002.
    try expectWordStart("中。文", 9, 6);
    try expectWordStart("中。文", 6, 3);
    try expectWordStart("中。文", 3, 0);
}

test "wordStartBefore: emoji runs are punctuation and never split" {
    try expectWordStart("hi😀", 6, 2);
    try expectWordStart("hi😀", 2, 0);
    try expectWordStart("😀😀", 8, 0);
}

test "wordStartBefore: invalid UTF-8 keeps prevCharStart boundaries" {
    // Orphan continuation run is one punctuation character, the valid word
    // before it is not swallowed.
    try expectWordStart("a\x80\x80b", 4, 3);
    try expectWordStart("a\x80\x80b", 3, 1);
    try expectWordStart("a\x80\x80b", 1, 0);

    // Truncated sequence: lead (decoded U+FFFD) and trailing continuation
    // form punctuation characters; "x" stays a word.
    try expectWordStart("x\xE4\xB8", 3, 1);
    try expectWordStart("x\xE4\xB8", 2, 1);
    try expectWordStart("x\xE4\xB8", 1, 0);
}

test "wordStartBefore: never returns a non-boundary inside a scalar" {
    const samples = [_][]const u8{
        "a中b😀c",
        "中文.abc",
        "self.word1.word2",
        "a\x80\x80b",
        "x\xE4\xB8",
    };
    for (samples) |text| {
        var pt = try PieceTable.init(std.testing.allocator, text);
        defer pt.deinit();
        var pos: u32 = 1;
        while (pos <= text.len) : (pos += 1) {
            const start = wordStartBefore(&pt, pos);
            try std.testing.expect(start <= pos);
            // The result must be reachable by walking prevCharStart
            // boundaries (orphan continuation runs are boundaries too).
            var boundary: u32 = pos;
            var reachable = start == pos;
            while (boundary > 0) {
                boundary = prevCharStart(&pt, boundary);
                if (boundary == start) {
                    reachable = true;
                    break;
                }
            }
            try std.testing.expect(reachable);
        }
    }
}

test "bigWordStartBefore: WORD runs include punctuation" {
    var pt = try PieceTable.init(std.testing.allocator, "self.word1.word2");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&pt, 16));

    var pt2 = try PieceTable.init(std.testing.allocator, "abc def");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(u32, 4), bigWordStartBefore(&pt2, 7));
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&pt2, 4));
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&pt2, 0));

    var pt3 = try PieceTable.init(std.testing.allocator, "中文。abc");
    defer pt3.deinit();
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&pt3, 10));

    // Invalid bytes are non-space WORD characters too.
    var pt4 = try PieceTable.init(std.testing.allocator, "a\x80\x80b");
    defer pt4.deinit();
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&pt4, 4));

    var empty = try PieceTable.init(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, 0), bigWordStartBefore(&empty, 0));
}
