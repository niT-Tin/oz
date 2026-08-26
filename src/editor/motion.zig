//! Motions: cursor movement over a PieceTable (DESIGN.md §1.1, §6.3).
//! Pure logic — a motion transforms a byte offset.
//!
//! M0 scope notes:
//! - `down`/`up` preserve the column as a *byte* offset within the line
//!   (display column ≈ byte column; no wide-char handling) and recompute it
//!   from the current position on every step — no vim `curswant` memory. A
//!   target line shorter than the current column clamps to its last
//!   character (line start when empty).
//! - Page motions use fixed line counts because the motion layer does not
//!   know the terminal height: `page_up`/`page_down` (ctrl-b/f) move 24
//!   lines, `half_page_up`/`half_page_down` (ctrl-u/d) move 12. Count
//!   multiplies the page.
//! - `first_line`/`last_line` (gg/G) ignore the count (always first/last
//!   line); vim's `{count}gg`/`{count}G` line targeting is out of M0 scope.
//! - `apply` does not handle ';'/',' — the Mode layer expands those into the
//!   remembered find/till motion + char, so only the find/till family lives
//!   here.
//! - `target` returns exactly the position `apply` would land on (pure, no
//!   mutation); the caller's operator decides inclusive/exclusive handling.
//! - UTF-8 boundary helpers are local to this file (the buffer/utf8 module is
//!   owned by another agent). Malformed sequences count as 1-byte characters,
//!   mirroring the utf8 module's decode contract.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Motion = enum {
    left,
    right,
    down,
    up,
    word_next, // w
    word_next_end, // e
    word_prev, // b
    word_prev_end, // ge (emitted by Mode's 'g' prefix)
    line_start, // ^ (first non-blank)
    line_start_bol, // 0 (column 0)
    line_end, // $ (last non-newline char)
    first_line, // gg
    last_line, // G
    paragraph_prev, // {
    paragraph_next, // }
    page_up, // ctrl-b (full page; M0 fixed 24 lines)
    page_down, // ctrl-f
    half_page_up, // ctrl-u (half page; M0 fixed 12 lines)
    half_page_down, // ctrl-d
    find, // f{ch}
    find_back, // F{ch}
    till, // t{ch}
    till_back, // T{ch}
    match_pair, // %
};

pub const Args = struct {
    /// target char for find/till motions
    ch: u8 = 0,
    /// last find/till motion + char for ';'/',' repeat
    last: ?struct { motion: Motion, ch: u8 } = null,
};

/// Apply `motion` `count` times to `cursor` (byte offset, in place).
/// Clamps to valid range; never moves outside the document.
pub fn apply(
    pt: *const PieceTable,
    motion: Motion,
    args: Args,
    cursor: *u32,
    count: u32,
) void {
    var pos = @min(cursor.*, pt.len());
    const n = @max(count, 1);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        pos = moveOnce(pt, motion, args, pos);
    }
    cursor.* = pos;
}

/// Compute where `cursor` would land after the motion (no mutation).
/// Identical to `apply`'s result; used by operators: d{motion} targets
/// [cursor, target) and the caller applies its own inclusive/exclusive rule.
pub fn target(
    pt: *const PieceTable,
    motion: Motion,
    args: Args,
    from: u32,
    count: u32,
) u32 {
    var pos = @min(from, pt.len());
    apply(pt, motion, args, &pos, count);
    return pos;
}

// ============================ one motion step ===============================

/// One motion step: transform `pos` into the new position. Always returns a
/// value in [0, pt.len()]; stays put when the motion has nowhere to go.
fn moveOnce(pt: *const PieceTable, motion: Motion, args: Args, pos_in: u32) u32 {
    const pos = @min(pos_in, pt.len());
    return switch (motion) {
        .left => moveLeft(pt, pos),
        .right => moveRight(pt, pos),
        .down => moveVert(pt, pos, 1),
        .up => moveVert(pt, pos, -1),
        .word_next => wordNext(pt, pos),
        .word_next_end => wordNextEnd(pt, pos),
        .word_prev => wordPrev(pt, pos),
        .word_prev_end => wordPrevEnd(pt, pos),
        .line_start => lineFirstNonBlank(pt, pos),
        .line_start_bol => pt.lineStart(pt.lineOf(pos)),
        .line_end => lineEnd(pt, pos),
        .first_line => 0,
        .last_line => pt.lineStart(pt.lineCount() - 1),
        .paragraph_prev => paragraph(pt, pos, -1),
        .paragraph_next => paragraph(pt, pos, 1),
        .page_up => pageMove(pt, pos, 24, -1),
        .page_down => pageMove(pt, pos, 24, 1),
        .half_page_up => pageMove(pt, pos, 12, -1),
        .half_page_down => pageMove(pt, pos, 12, 1),
        .find => findInLine(pt, pos, args.ch, 1, false),
        .find_back => findInLine(pt, pos, args.ch, -1, false),
        .till => findInLine(pt, pos, args.ch, 1, true),
        .till_back => findInLine(pt, pos, args.ch, -1, true),
        .match_pair => matchPair(pt, pos),
    };
}

// ------------------------- UTF-8 char boundaries ----------------------------

/// Length of the UTF-8 sequence a lead byte starts (1 for ASCII, stray
/// continuation bytes, and invalid leads 0xF8..0xFF).
fn utf8SeqLen(lead: u8) u32 {
    if (lead < 0x80) return 1;
    if (lead < 0xC0) return 1; // stray continuation byte
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    if (lead < 0xF8) return 4;
    return 1;
}

/// Index of the previous character boundary strictly before `pos`
/// (0 when none). Malformed sequences count as 1-byte characters.
fn prevCharBoundary(pt: *const PieceTable, pos: u32) u32 {
    std.debug.assert(pos > 0 and pos <= pt.len());
    const i = pos - 1;
    const b = pt.byteAt(i);
    if (b < 0x80 or b >= 0xC0) return i; // ASCII or stray lead: its own char
    // b is a continuation byte: walk back to a lead byte (max 3 steps).
    var lead: u32 = i;
    while (lead > 0 and i - lead < 3) {
        lead -= 1;
        const c = pt.byteAt(lead);
        if (c < 0x80) return i; // orphaned continuation before ASCII
        if (c >= 0xC0) {
            // Well-formed iff the sequence starting at `lead` ends at `pos`.
            if (lead + utf8SeqLen(c) == pos) return lead;
            return i; // malformed sequence: the byte at i is its own char
        }
    }
    return i;
}

/// Index of the next character boundary strictly after `pos`
/// (pt.len() when none). Malformed sequences count as 1-byte characters.
fn nextCharBoundary(pt: *const PieceTable, pos: u32) u32 {
    std.debug.assert(pos < pt.len());
    const b = pt.byteAt(pos);
    if (b < 0xC0) return pos + 1; // ASCII or stray continuation
    const seq_len = utf8SeqLen(b);
    const end = pos + seq_len;
    if (end > pt.len()) return pos + 1; // truncated sequence
    var k: u32 = 1;
    while (k < seq_len) : (k += 1) {
        const c = pt.byteAt(pos + k);
        if (c < 0x80 or c >= 0xC0) return pos + 1; // malformed continuation
    }
    return end;
}

// ------------------------------ left / right --------------------------------

/// h — previous character; does not wrap at the start of a line (vim
/// 'whichwrap' default: col 0 stays).
fn moveLeft(pt: *const PieceTable, pos: u32) u32 {
    if (pos == 0) return 0;
    if (pos == pt.lineStart(pt.lineOf(pos))) return pos;
    return prevCharBoundary(pt, pos);
}

/// l — next character; clamps at the end of the line (no wrap).
fn moveRight(pt: *const PieceTable, pos: u32) u32 {
    const line = pt.lineOf(pos);
    const start = pt.lineStart(line);
    const line_len = pt.lineLen(line);
    // At the last char (multibyte-aware), on the '\n', or past the line
    // end: stay. The byte-based col+1 check would treat a CJK continuation
    // byte as a normal column and walk past the line end.
    const last = lastCharStart(pt, start, line_len);
    if (pos >= last) return pos;
    return nextCharBoundary(pt, pos);
}

// -------------------------------- down / up ---------------------------------

/// j/k — one line down (dir > 0) or up (dir < 0), preserving the byte column.
/// A shorter target line clamps to its last character (line start if empty).
fn moveVert(pt: *const PieceTable, pos: u32, dir: i8) u32 {
    const line = pt.lineOf(pos);
    if (dir > 0 and line + 1 >= pt.lineCount()) return pos;
    if (dir < 0 and line == 0) return pos;
    const target_line = if (dir > 0) line + 1 else line - 1;
    const start = pt.lineStart(line);
    var col = pos - start;
    const line_len = pt.lineLen(line);
    if (col > line_len) col = line_len; // defensive clamp
    const t_start = pt.lineStart(target_line);
    const t_len = pt.lineLen(target_line);
    var t_col = col;
    if (t_col >= t_len) t_col = if (t_len == 0) 0 else lastCharStart(pt, t_start, t_len) - t_start;
    return t_start + t_col;
}

// ------------------------------- word motions -------------------------------

/// Word characters: [a-zA-Z0-9_] plus any non-ASCII byte (groups multibyte
/// text like vim's default iskeyword range, so CJK doesn't split per byte).
fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80;
}

/// Blanks separate words: space, tab, '\n' (word motions cross lines) and
/// '\r'. Every other non-word byte is a single-character punctuation word.
fn isBlankByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// Byte at `pos`, or a space when `pos` is at the end of the document
/// (end of text behaves like trailing whitespace for word motions).
fn byteOrSpace(pt: *const PieceTable, pos: u32) u8 {
    if (pos >= pt.len()) return ' ';
    return pt.byteAt(pos);
}

/// The start of the last character in the line segment [start, start+line_len).
/// Multibyte-safe: lineEnd/$/j/k/}/e must land on a character boundary, not
/// the last byte (a CJK char's continuation byte would corrupt the cursor).
fn lastCharStart(pt: *const PieceTable, start: u32, line_len: u32) u32 {
    if (line_len == 0) return start;
    return prevCharBoundary(pt, start + line_len);
}

/// w — start of the next word (crosses newlines; each punctuation char is a
/// word of its own). With no next word, vim lands on the last character of
/// the buffer; `lastCharOfDoc` computes that position.
fn wordNext(pt: *const PieceTable, pos: u32) u32 {
    const len = pt.len();
    if (pos >= len) return pos;
    const c = pt.byteAt(pos);
    if (isWordByte(c)) {
        // Skip the rest of the current word, then any blanks.
        var p = pos;
        while (p < len and isWordByte(pt.byteAt(p))) : (p += 1) {}
        while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
        return if (p >= len) wordEndFallback(pt, pos) else p;
    }
    if (isBlankByte(c)) {
        var p = pos;
        while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
        return if (p >= len) wordEndFallback(pt, pos) else p;
    }
    // On punctuation: a run of punctuation is one word (vim: "..." is one
    // word). Skip the whole run, then blanks, landing on the next word.
    var p = pos;
    while (p < len and !isWordByte(pt.byteAt(p)) and !isBlankByte(pt.byteAt(p))) : (p += 1) {}
    while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
    return if (p >= len) wordEndFallback(pt, pos) else p;
}

/// vim `w` with no word ahead: the last character of the buffer — the last
/// line's last char. A trailing '\n' only terminates the last content line,
/// so an empty artificial last line is skipped. Never moves the cursor
/// backward (already at/past it: stay).
fn wordEndFallback(pt: *const PieceTable, pos: u32) u32 {
    var last = pt.lineCount() - 1;
    if (last > 0 and pt.lineLen(last) == 0) last -= 1;
    const start = pt.lineStart(last);
    const l = pt.lineLen(last);
    const end_pos = lastCharStart(pt, start, l);
    return if (end_pos > pos) end_pos else pos;
}

/// e — end of the next word (end of the current word when mid-word).
fn wordNextEnd(pt: *const PieceTable, pos: u32) u32 {
    const len = pt.len();
    if (pos >= len) return pos;
    const c = pt.byteAt(pos);
    if (isWordByte(c)) {
        if (pos + 1 < len and isWordByte(pt.byteAt(pos + 1))) {
            // Mid-word: end of the current word.
            var p = pos + 1;
            while (p < len and isWordByte(pt.byteAt(p))) : (p += 1) {}
            return prevCharBoundary(pt, p);
        }
        // On the last char of a word: end of the NEXT word.
        var p = pos + 1;
        while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
        if (p >= len) return pos;
        if (isWordByte(pt.byteAt(p))) {
            while (p < len and isWordByte(pt.byteAt(p))) : (p += 1) {}
            return prevCharBoundary(pt, p);
        }
        // punctuation run: e lands on its last char (vim: "..." -> last dot)
        while (p < len and !isWordByte(pt.byteAt(p)) and !isBlankByte(pt.byteAt(p))) : (p += 1) {}
        return prevCharBoundary(pt, p);
    }
    if (isBlankByte(c)) {
        var p = pos;
        while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
        if (p >= len) return pos;
        if (isWordByte(pt.byteAt(p))) {
            while (p < len and isWordByte(pt.byteAt(p))) : (p += 1) {}
            return prevCharBoundary(pt, p);
        }
        while (p < len and !isWordByte(pt.byteAt(p)) and !isBlankByte(pt.byteAt(p))) : (p += 1) {}
        return prevCharBoundary(pt, p);
    }
    // On punctuation: end of the next punctuation run (vim: e over "..."
    // stops on the last dot), skipping any blanks after the run.
    var p = pos + 1;
    while (p < len and isBlankByte(pt.byteAt(p))) : (p += 1) {}
    if (p >= len) return pos;
    if (isWordByte(pt.byteAt(p))) {
        while (p < len and isWordByte(pt.byteAt(p))) : (p += 1) {}
        return prevCharBoundary(pt, p);
    }
    // punctuation run: land on its last character
    while (p < len and !isWordByte(pt.byteAt(p)) and !isBlankByte(pt.byteAt(p))) : (p += 1) {}
    return prevCharBoundary(pt, p);
}

/// b — start of the word the byte before the cursor belongs to (skipping
/// blanks). Mid-word (or mid punctuation run) this is the current word's
/// start; at a word start it is the previous word's start — a run of
/// punctuation is one word, same as `w` (vim semantics).
fn wordPrev(pt: *const PieceTable, pos: u32) u32 {
    if (pos == 0) return 0;
    var p = pos - 1;
    // Skip blanks backwards; if only blanks precede the cursor, land on the
    // first byte of the document.
    while (p > 0 and isBlankByte(pt.byteAt(p))) : (p -= 1) {}
    if (isBlankByte(pt.byteAt(p))) return 0;
    // Land on the start of the word/punctuation run containing p.
    const word_run = isWordByte(pt.byteAt(p));
    while (p > 0) : (p -= 1) {
        const b = pt.byteAt(p - 1);
        if (isBlankByte(b) or isWordByte(b) != word_run) break;
    }
    return p;
}

/// ge — end of the word strictly before the cursor (vim semantics): the
/// nearest position p < pos whose byte is non-blank and whose right neighbor
/// is blank, of the other class (word vs punctuation), or past the document
/// end. With no word end before the cursor (inside/at the first word), vim
/// lands on the first byte of the buffer.
fn wordPrevEnd(pt: *const PieceTable, pos: u32) u32 {
    var p = pos;
    while (p > 0) {
        p = prevCharBoundary(pt, p); // previous character's start
        const c = pt.byteAt(p);
        if (isBlankByte(c)) continue;
        // p is a word's last character iff the next character starts a
        // different class (word/blank/punct) or p is the doc's last char.
        // Multibyte-safe: walking char-by-char (not byte-by-byte) so CJK
        // words don't fall through to 0.
        const next = nextCharBoundary(pt, p);
        if (next >= pt.len()) return p;
        const nc = pt.byteAt(next);
        if (isBlankByte(nc) or isWordByte(nc) != isWordByte(c)) return p;
    }
    return 0;
}

// ------------------------------ line motions --------------------------------

/// ^ — first non-blank (space/tab) character of the line. A blank-only line
/// ends on its last character (vim behavior).
fn lineFirstNonBlank(pt: *const PieceTable, pos: u32) u32 {
    const line = pt.lineOf(pos);
    const start = pt.lineStart(line);
    const line_len = pt.lineLen(line);
    var p = start;
    const end = start + line_len;
    while (p < end) : (p += 1) {
        const b = pt.byteAt(p);
        if (b != ' ' and b != '\t') return p;
    }
    if (line_len == 0) return start;
    return end - 1; // all blanks: last character
}

/// $ — last non-newline character of the line; an empty line stays put.
fn lineEnd(pt: *const PieceTable, pos: u32) u32 {
    const line = pt.lineOf(pos);
    const start = pt.lineStart(line);
    const line_len = pt.lineLen(line);
    if (line_len == 0) return pos;
    return lastCharStart(pt, start, line_len);
}

// ----------------------------- paragraph motions ----------------------------

/// { / } — jump to the previous/next empty line. A run of consecutive empty
/// lines is a single paragraph boundary, so starting inside a run skips past
/// it. With no empty line found: the first/last line. Landing column (vim):
/// { always lands on column 0; } lands on column 0 of the empty line it
/// found, or on the last character of the last line when no boundary exists.
fn paragraph(pt: *const PieceTable, pos: u32, dir: i8) u32 {
    const line = pt.lineOf(pos);
    const target_line = paragraphTarget(pt, line, dir);
    const start = pt.lineStart(target_line);
    const len = pt.lineLen(target_line);
    if (dir < 0 or len == 0) return start;
    return lastCharStart(pt, start, len);
}

fn lineIsEmpty(pt: *const PieceTable, line: u32) bool {
    return pt.lineLen(line) == 0;
}

fn paragraphTarget(pt: *const PieceTable, line: u32, dir: i8) u32 {
    // The piece table counts a trailing '\n' as an extra empty line; vim has
    // no such line, so it is neither a paragraph boundary nor a target.
    var line_count = pt.lineCount();
    if (line_count > 1 and lineIsEmpty(pt, line_count - 1)) line_count -= 1;
    if (dir > 0) {
        var l = line;
        if (lineIsEmpty(pt, l)) {
            while (l + 1 < line_count and lineIsEmpty(pt, l + 1)) : (l += 1) {}
        }
        var next = l + 1;
        while (next < line_count and !lineIsEmpty(pt, next)) : (next += 1) {}
        return if (next < line_count) next else line_count - 1;
    } else {
        var l = line;
        if (lineIsEmpty(pt, l)) {
            while (l > 0 and lineIsEmpty(pt, l - 1)) : (l -= 1) {}
        }
        if (l == 0) return 0;
        var prev = l - 1;
        while (prev > 0 and !lineIsEmpty(pt, prev)) : (prev -= 1) {}
        return prev;
    }
}

// ------------------------------- page motions -------------------------------

/// Page motions (M0): move `lines` lines up/down preserving the column,
/// implemented as repeated vertical steps; clamps at the first/last line.
fn pageMove(pt: *const PieceTable, pos: u32, lines: u32, dir: i8) u32 {
    var p = pos;
    var i: u32 = 0;
    while (i < lines) : (i += 1) {
        const next = moveVert(pt, p, dir);
        if (next == p) break; // reached the edge
        p = next;
    }
    return p;
}

// ------------------------------ find / till ---------------------------------

/// f/F/t/T — search `ch` within the current line only (never across '\n').
/// dir: +1 searches forward from pos+1, -1 backward from pos-1.
/// till: land one char before the match (forward) / after it (backward).
/// Not found (or no target char): stays put.
fn findInLine(pt: *const PieceTable, pos: u32, ch: u8, dir: i8, till: bool) u32 {
    if (ch == 0) return pos;
    const line = pt.lineOf(pos);
    const start = pt.lineStart(line);
    const end = start + pt.lineLen(line);
    if (dir > 0) {
        var i = pos + 1;
        while (i < end) : (i += 1) {
            if (pt.byteAt(i) == ch) {
                if (till) {
                    const t = i - 1;
                    return if (t < start) start else t; // can't land before col 0
                }
                return i;
            }
        }
    } else {
        var i = pos;
        while (i > start) : (i -= 1) {
            if (pt.byteAt(i - 1) == ch) {
                if (till) return i; // one char after the match
                return i - 1;
            }
        }
    }
    return pos;
}

// ------------------------------ match pair (%) ------------------------------

/// % — jump between () [] {}. On a bracket: to its matching partner
/// (nesting-aware, crossing lines; M0: no string/comment awareness). On any
/// other char: vim-like forward scan of the current line for the first
/// bracket, then match it. No match: stays.
fn matchPair(pt: *const PieceTable, pos: u32) u32 {
    const len = pt.len();
    if (pos >= len) return pos;
    const line = pt.lineOf(pos);
    const start = pt.lineStart(line);
    const end = start + pt.lineLen(line);
    var p = pos;
    var b = pt.byteAt(p);
    if (!isOpenBracket(b) and !isCloseBracket(b)) {
        var found: ?u32 = null;
        while (p < end) : (p += 1) {
            const c = pt.byteAt(p);
            if (isOpenBracket(c) or isCloseBracket(c)) {
                found = p;
                break;
            }
        }
        const f = found orelse return pos;
        p = f;
        b = pt.byteAt(p);
    }
    if (isOpenBracket(b)) {
        return matchOpen(pt, p, b) orelse pos;
    }
    return matchClose(pt, p, b) orelse pos;
}

fn isOpenBracket(b: u8) bool {
    return b == '(' or b == '[' or b == '{';
}

fn isCloseBracket(b: u8) bool {
    return b == ')' or b == ']' or b == '}';
}

fn counterpart(b: u8) u8 {
    return switch (b) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        else => unreachable,
    };
}

/// Depth-first scan forward from an opening bracket to its close.
fn matchOpen(pt: *const PieceTable, open_pos: u32, open: u8) ?u32 {
    const close = counterpart(open);
    const len = pt.len();
    var depth: u32 = 1;
    var p = open_pos + 1;
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

/// Depth-first scan backward from a closing bracket to its open.
fn matchClose(pt: *const PieceTable, close_pos: u32, close: u8) ?u32 {
    const open = counterpart(close);
    var depth: u32 = 1;
    var p = close_pos;
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

// ================================= tests =====================================

const testing = std.testing;

/// Apply the motion and check both `apply` (in place) and `target` (pure)
/// land on `expected` — this doubles as the apply/target consistency check.
fn check(pt: *const PieceTable, motion: Motion, args: Args, from: u32, count: u32, expected: u32) !void {
    var cur = from;
    apply(pt, motion, args, &cur, count);
    try testing.expectEqual(expected, cur);
    const t = target(pt, motion, args, from, count);
    try testing.expectEqual(cur, t);
}

test "left/right: UTF-8 boundaries, line-start/end clamps" {
    // "a中b\ncd": 中 = E4 B8 AD (3 bytes). Offsets:
    //   a=0, E4=1, B8=2, AD=3, b=4, \n=5, c=6, d=7. len 8.
    var pt = try PieceTable.init(testing.allocator, "a中b\ncd");
    defer pt.deinit();
    const args = Args{};

    // right walks whole characters, one boundary per step.
    try check(&pt, .right, args, 0, 1, 1); // a -> start of 中
    try check(&pt, .right, args, 1, 1, 4); // 中 (3 bytes) -> b
    try check(&pt, .right, args, 4, 1, 4); // b is the last char of line 0: clamp
    try check(&pt, .right, args, 6, 1, 7); // c -> d
    try check(&pt, .right, args, 7, 1, 7); // last char of doc: clamp
    try check(&pt, .right, args, 5, 1, 5); // on the '\n': line end, clamp

    // left mirrors it.
    try check(&pt, .left, args, 4, 1, 1); // b -> start of 中
    try check(&pt, .left, args, 1, 1, 0); // 中 -> a
    try check(&pt, .left, args, 0, 1, 0); // col 0 of line 0: stay
    try check(&pt, .left, args, 5, 1, 4); // '\n' -> b
    try check(&pt, .left, args, 6, 1, 6); // c is at col 0 of line 1: h stays (no wrap)
    try check(&pt, .left, args, 7, 1, 6); // d -> c

    // count repeats.
    try check(&pt, .left, args, 7, 2, 6); // d -> c -> stays (c is col 0 of line 1)
    try check(&pt, .right, args, 0, 2, 4); // a -> 中 -> b
}

test "left/right: ASCII newline handling" {
    var pt = try PieceTable.init(testing.allocator, "ab\ncd");
    defer pt.deinit();
    const args = Args{};
    // a=0 b=1 \n=2 c=3 d=4.
    try check(&pt, .left, args, 3, 1, 3); // col 0 of line 1: stay
    try check(&pt, .left, args, 2, 1, 1); // '\n' -> b
    try check(&pt, .left, args, 1, 1, 0);
    try check(&pt, .right, args, 1, 1, 1); // b is the last char: clamp
    try check(&pt, .right, args, 3, 1, 4);
    try check(&pt, .right, args, 4, 1, 4); // doc end: clamp
    // left from doc end (no trailing newline) reaches the last char.
    try check(&pt, .left, args, 4, 1, 3);
}

test "down/up: column preservation and line-length clamping" {
    // "abcd\nef\nghijk": starts 0,5,8; len 13.
    //   a0 b1 c2 d3 \n4 e5 f6 \n7 g8 h9 i10 j11 k12.
    var pt = try PieceTable.init(testing.allocator, "abcd\nef\nghijk");
    defer pt.deinit();
    const args = Args{};

    try check(&pt, .down, args, 2, 1, 6); // col 2 -> line "ef" (len 2): clamp to last char f
    try check(&pt, .down, args, 0, 1, 5); // col 0 -> e
    try check(&pt, .down, args, 3, 1, 6); // col 3 -> clamp to f
    try check(&pt, .down, args, 8, 1, 8); // last line: stay
    try check(&pt, .down, args, 13, 1, 13); // doc end (last line): stay

    try check(&pt, .up, args, 9, 1, 6); // col 1 -> f
    try check(&pt, .up, args, 6, 1, 1); // col 1 -> b
    try check(&pt, .up, args, 5, 1, 0); // col 0 -> a
    try check(&pt, .up, args, 0, 1, 0); // first line: stay
    try check(&pt, .up, args, 7, 1, 2); // on '\n' (col 2 of "ef") -> line 0 col 2 = c

    // longer target line: column is preserved, not re-clamped.
    try check(&pt, .down, args, 6, 1, 9); // col 1 -> h

    // counts: step-by-step, clamping at the edges.
    try check(&pt, .down, args, 2, 2, 9); // 2 -> 6 -> 9
    try check(&pt, .down, args, 2, 3, 9); // clamps at the last line
    try check(&pt, .down, args, 2, 10, 9);
    try check(&pt, .up, args, 9, 2, 1); // 9 -> 6 -> 1
    try check(&pt, .up, args, 9, 3, 1); // clamps at the first line
    try check(&pt, .up, args, 9, 50, 1);
}

test "word motions w/e/b/ge: punctuation, underscore, blank lines, cross-line" {
    // "foo_bar, baz\n\nqux": f0 o1 o2 _3 b4 a5 r6 ,7 ' '8 b9 a10 z11 \n12 \n13 q14 u15 x16.
    var pt = try PieceTable.init(testing.allocator, "foo_bar, baz\n\nqux");
    defer pt.deinit();
    const args = Args{};

    // w: underscores stay inside the word; punctuation is its own word.
    try check(&pt, .word_next, args, 0, 1, 7); // foo_bar -> ,
    try check(&pt, .word_next, args, 7, 1, 9); // , -> b of baz
    try check(&pt, .word_next, args, 8, 1, 9); // space -> b
    try check(&pt, .word_next, args, 11, 1, 14); // z -> q, crossing the blank line
    try check(&pt, .word_next, args, 12, 1, 14); // on '\n' -> q
    try check(&pt, .word_next, args, 14, 1, 16); // last word -> last char (vim)
    try check(&pt, .word_next, args, 16, 1, 16); // last char: stay
    try check(&pt, .word_next, args, 0, 2, 9); // count: foo_bar -> , -> b

    // e: end of current word when mid-word, end of next word otherwise.
    try check(&pt, .word_next_end, args, 0, 1, 6); // mid "foo_bar" -> r
    try check(&pt, .word_next_end, args, 6, 1, 7); // at word end -> ,
    try check(&pt, .word_next_end, args, 7, 1, 11); // , -> z
    try check(&pt, .word_next_end, args, 9, 1, 11); // mid "baz" -> z
    try check(&pt, .word_next_end, args, 11, 1, 16); // z -> x, crossing the blank line
    try check(&pt, .word_next_end, args, 16, 1, 16); // last word end: stay
    try check(&pt, .word_next_end, args, 0, 2, 7); // count: r -> ,

    // b: start of current word when mid-word, previous word otherwise.
    try check(&pt, .word_prev, args, 16, 1, 14); // mid "qux" -> q
    try check(&pt, .word_prev, args, 14, 1, 9); // at word start -> b of baz (over blank line)
    try check(&pt, .word_prev, args, 9, 1, 7); // at word start -> ,
    try check(&pt, .word_prev, args, 7, 1, 0); // , -> f
    try check(&pt, .word_prev, args, 5, 1, 0); // mid "foo_bar" -> f
    try check(&pt, .word_prev, args, 13, 1, 9); // on blank line -> b of baz
    try check(&pt, .word_prev, args, 0, 1, 0); // first char: stay
    try check(&pt, .word_prev, args, 16, 2, 9); // count: q -> b

    // ge: end of the PREVIOUS word (vim), even from mid-word or a word end.
    try check(&pt, .word_prev_end, args, 16, 1, 11); // on "qux" -> z (end of baz)
    try check(&pt, .word_prev_end, args, 14, 1, 11); // at word start -> z
    try check(&pt, .word_prev_end, args, 11, 1, 7); // at word end -> ','
    try check(&pt, .word_prev_end, args, 9, 1, 7); // at word start -> ,
    try check(&pt, .word_prev_end, args, 7, 1, 6); // , -> r (end of foo_bar)
    try check(&pt, .word_prev_end, args, 3, 1, 0); // mid "foo_bar": no word end before -> buffer start
    try check(&pt, .word_prev_end, args, 0, 1, 0); // first char: stay
    try check(&pt, .word_prev_end, args, 14, 2, 7); // count: z -> ,
}

test "word motions: w/e/b edge cases" {
    // "abc.def": a0 b1 c2 .3 d4 e5 f6.
    var pt1 = try PieceTable.init(testing.allocator, "abc.def");
    defer pt1.deinit();
    const args = Args{};
    try check(&pt1, .word_next, args, 0, 1, 3); // abc -> .
    try check(&pt1, .word_next, args, 3, 1, 4); // . -> d
    try check(&pt1, .word_next_end, args, 2, 1, 3); // c -> .
    try check(&pt1, .word_next_end, args, 3, 1, 6); // . -> f
    try check(&pt1, .word_prev, args, 4, 1, 3); // d -> .
    try check(&pt1, .word_prev, args, 3, 1, 0); // . -> a
    try check(&pt1, .word_prev_end, args, 4, 1, 3); // d -> .
    try check(&pt1, .word_prev_end, args, 3, 1, 2); // . -> c

    // end of document (no trailing newline): the last char is a boundary.
    var pt2 = try PieceTable.init(testing.allocator, "abc def");
    defer pt2.deinit();
    try check(&pt2, .word_next, args, 6, 1, 6); // f: no next word
    try check(&pt2, .word_prev, args, 7, 1, 4); // from doc end -> d
    try check(&pt2, .word_prev_end, args, 7, 1, 6); // from doc end -> f
    try check(&pt2, .word_prev, args, 4, 1, 0); // d -> a

    // empty document.
    var pt3 = try PieceTable.init(testing.allocator, "");
    defer pt3.deinit();
    try check(&pt3, .word_next, args, 0, 1, 0);
    try check(&pt3, .word_prev, args, 0, 1, 0);
    try check(&pt3, .word_next_end, args, 0, 1, 0);
    try check(&pt3, .word_prev_end, args, 0, 1, 0);
}

test "ge: end of the previous word, even mid-word or at a word end (vim)" {
    // "foo bar": f0 o1 o2 ' '3 b4 a5 r6. All positions verified against vim.
    var pt = try PieceTable.init(testing.allocator, "foo bar");
    defer pt.deinit();
    const args = Args{};
    try check(&pt, .word_prev_end, args, 6, 1, 2); // at end of "bar" -> 'o'
    try check(&pt, .word_prev_end, args, 5, 1, 2); // mid "bar" -> 'o'
    try check(&pt, .word_prev_end, args, 4, 1, 2); // at start of "bar" -> 'o'
    try check(&pt, .word_prev_end, args, 3, 1, 2); // on the blank -> 'o'
    // No word end before the cursor: vim lands on the first byte of the
    // buffer (even when that byte is a blank).
    try check(&pt, .word_prev_end, args, 2, 1, 0); // end of the first word -> 0

    var pt2 = try PieceTable.init(testing.allocator, "foo");
    defer pt2.deinit();
    try check(&pt2, .word_prev_end, args, 2, 1, 0);
    try check(&pt2, .word_prev_end, args, 1, 1, 0);
    try check(&pt2, .word_prev_end, args, 0, 1, 0);

    // "  foo": ' '0 ' '1 f2 o3 o4 — the fallback lands on byte 0 (a blank).
    var pt3 = try PieceTable.init(testing.allocator, "  foo");
    defer pt3.deinit();
    try check(&pt3, .word_prev_end, args, 3, 1, 0);

    // punctuation runs have word ends too: "foo.bar" f0 o1 o2 .3 b4 a5 r6
    var pt4 = try PieceTable.init(testing.allocator, "foo.bar");
    defer pt4.deinit();
    try check(&pt4, .word_prev_end, args, 4, 1, 3); // 'b' -> '.'
    try check(&pt4, .word_prev_end, args, 6, 1, 3); // 'r' -> '.'
}

test "b: from inside/after a punctuation run goes to the run start (vim)" {
    // "a==>b": a0 =1 =2 >3 b4. "==>" is one word; b from anywhere past its
    // start lands on the first '=' (verified against vim).
    var pt = try PieceTable.init(testing.allocator, "a==>b");
    defer pt.deinit();
    const args = Args{};
    try check(&pt, .word_prev, args, 4, 1, 1); // b -> start of "==>"
    try check(&pt, .word_prev, args, 3, 1, 1); // > (run end) -> start
    try check(&pt, .word_prev, args, 2, 1, 1); // mid-run -> start
    try check(&pt, .word_prev, args, 1, 1, 0); // run start -> a

    // "a--  .b": a0 -1 -2 ' '3 ' '4 .5 b6. From '.' the previous word is the
    // "--" run starting at 1 (vim), not the run's last char.
    var pt2 = try PieceTable.init(testing.allocator, "a--  .b");
    defer pt2.deinit();
    try check(&pt2, .word_prev, args, 5, 1, 1);
}

test "b: leading whitespace of a line jumps to the previous line's word" {
    // "foo\n  bar": f0 o1 o2 \n3 ' '4 ' '5 b6 a7 r8. b from the indentation
    // (or the line start) must cross the newline and land on "foo"'s start
    // (vim: b skips blanks including line breaks).
    var pt = try PieceTable.init(testing.allocator, "foo\n  bar");
    defer pt.deinit();
    const args = Args{};
    try check(&pt, .word_prev, args, 6, 1, 0); // on 'b' -> 'f'
    try check(&pt, .word_prev, args, 5, 1, 0); // in the indentation -> 'f'
    try check(&pt, .word_prev, args, 4, 1, 0); // indentation start -> 'f'
    // a line that is entirely blank: b still crosses to the previous line
    var pt2 = try PieceTable.init(testing.allocator, "foo\n   \nbar");
    defer pt2.deinit();
    // mid-word: current word's start; from that start: previous line's word
    try check(&pt2, .word_prev, args, 9, 1, 8); // on 'a' (mid "bar") -> 'b'
    try check(&pt2, .word_prev, args, 8, 1, 0); // on 'b' (word start) -> "foo"
}

test "w: no next word lands on the last character of the buffer (vim)" {
    // "abc def": a0 b1 c2 ' '3 d4 e5 f6. w from the last word -> 'f' (vim),
    // not a stay.
    var pt = try PieceTable.init(testing.allocator, "abc def");
    defer pt.deinit();
    const args = Args{};
    try check(&pt, .word_next, args, 4, 1, 6); // 'd' -> 'f'
    try check(&pt, .word_next, args, 6, 1, 6); // already there: stay
    try check(&pt, .word_next, args, 0, 1, 4); // a next word still wins

    // single-word document: w -> last char
    var pt2 = try PieceTable.init(testing.allocator, "abc");
    defer pt2.deinit();
    try check(&pt2, .word_next, args, 0, 1, 2);
    try check(&pt2, .word_next, args, 1, 1, 2);

    // trailing newline: the artificial empty last line is not a target
    var pt3 = try PieceTable.init(testing.allocator, "abc\n");
    defer pt3.deinit();
    try check(&pt3, .word_next, args, 0, 1, 2); // -> 'c', not the empty line

    // "abc\n\n": vim lands on the (first) empty line after "abc"
    var pt4 = try PieceTable.init(testing.allocator, "abc\n\n");
    defer pt4.deinit();
    try check(&pt4, .word_next, args, 0, 1, 4);
}

test "word motions: consecutive punctuation is one word (a->b)" {
    // "a->b": a0 -1 >2 b3. vim treats a run of punctuation as one word.
    var pt = try PieceTable.init(testing.allocator, "a->b");
    defer pt.deinit();
    const args = Args{};
    // w: a -> start of "->" run; -> -> b (whole run is one word)
    try check(&pt, .word_next, args, 0, 1, 1); // a -> -
    try check(&pt, .word_next, args, 1, 1, 3); // -> -> b
    // e: a -> b end? no: e lands on the punctuation run's last char
    try check(&pt, .word_next_end, args, 0, 1, 2); // a -> > (run end)
    try check(&pt, .word_next_end, args, 2, 1, 3); // > -> b
    // b: b -> start of run; -> -> a
    try check(&pt, .word_prev, args, 3, 1, 1); // b -> -
    try check(&pt, .word_prev, args, 1, 1, 0); // -> -> a
    // ge: b -> run end; > -> a
    try check(&pt, .word_prev_end, args, 3, 1, 2); // b -> >
    try check(&pt, .word_prev_end, args, 2, 1, 0); // > -> a

    // "foo.bar()->baz" — operators as one word each.
    var pt2 = try PieceTable.init(testing.allocator, "foo.bar()->baz");
    defer pt2.deinit();
    try check(&pt2, .word_next, args, 0, 1, 3); // foo -> .
    try check(&pt2, .word_next, args, 3, 1, 4); // . -> b of bar
    try check(&pt2, .word_next, args, 6, 1, 7); // r (bar end) -> (
    try check(&pt2, .word_next, args, 7, 1, 11); // ()-> run -> b of baz
    try check(&pt2, .word_next_end, args, 7, 1, 10); // ( -> > (run end)
    try check(&pt2, .word_next_end, args, 10, 1, 13); // > -> z (baz end)
}

test "line motions ^ 0 $ across indentation" {
    // "  foo\n\tbar\n\nbaz": ' '0 ' '1 f2 o3 o4 \n5 \t6 b7 a8 r9 \n10 \n11 b12 a13 z14.
    var pt = try PieceTable.init(testing.allocator, "  foo\n\tbar\n\nbaz");
    defer pt.deinit();
    const args = Args{};

    try check(&pt, .line_start, args, 0, 1, 2); // ^ skips spaces
    try check(&pt, .line_start, args, 4, 1, 2); // ^ from mid-line moves back
    try check(&pt, .line_start, args, 1, 1, 2);
    try check(&pt, .line_start, args, 6, 1, 7); // ^ skips the tab
    try check(&pt, .line_start, args, 9, 1, 7);
    try check(&pt, .line_start, args, 12, 1, 12); // no leading blanks

    try check(&pt, .line_start_bol, args, 4, 1, 0);
    try check(&pt, .line_start_bol, args, 9, 1, 6);
    try check(&pt, .line_start_bol, args, 13, 1, 12);
    try check(&pt, .line_start_bol, args, 0, 1, 0);

    try check(&pt, .line_end, args, 0, 1, 4); // $ -> last char of "  foo"
    try check(&pt, .line_end, args, 2, 1, 4);
    try check(&pt, .line_end, args, 5, 1, 4); // from the '\n' -> o
    try check(&pt, .line_end, args, 6, 1, 9); // $ -> r
    try check(&pt, .line_end, args, 10, 1, 9);
    try check(&pt, .line_end, args, 11, 1, 11); // empty line: stay
    try check(&pt, .line_end, args, 12, 1, 14); // $ -> z
    try check(&pt, .line_end, args, 15, 1, 14); // doc end -> z

    // blank-only line: ^ lands on the last blank (vim), $ on the same char.
    var pt2 = try PieceTable.init(testing.allocator, "   \nx");
    defer pt2.deinit();
    try check(&pt2, .line_start, args, 1, 1, 2);
    try check(&pt2, .line_start, args, 0, 1, 2);
    try check(&pt2, .line_end, args, 0, 1, 2);
}

test "gg / G: first and last line" {
    var pt = try PieceTable.init(testing.allocator, "a\nb\nc");
    defer pt.deinit();
    const args = Args{};
    try check(&pt, .first_line, args, 4, 1, 0);
    try check(&pt, .first_line, args, 4, 2, 0); // count ignored (M0)
    try check(&pt, .last_line, args, 0, 1, 4); // lineStart(2) = 4
    try check(&pt, .last_line, args, 0, 2, 4);

    var pt2 = try PieceTable.init(testing.allocator, "");
    defer pt2.deinit();
    try check(&pt2, .first_line, args, 0, 1, 0);
    try check(&pt2, .last_line, args, 0, 1, 0);
}

test "paragraph motions { } with consecutive empty lines" {
    // "a\n\n\nb\n\nc": a0 \n1 \n2 \n3 b4 \n5 \n6 c7.
    // lines: 0="a", 1="", 2="", 3="b", 4="", 5="c".
    var pt = try PieceTable.init(testing.allocator, "a\n\n\nb\n\nc");
    defer pt.deinit();
    const args = Args{};

    try check(&pt, .paragraph_next, args, 0, 1, 2); // a -> first empty line
    try check(&pt, .paragraph_next, args, 4, 1, 6); // b -> next empty line
    try check(&pt, .paragraph_next, args, 2, 1, 6); // inside the run -> next boundary
    try check(&pt, .paragraph_next, args, 3, 1, 6); // second empty line -> next boundary
    try check(&pt, .paragraph_next, args, 7, 1, 7); // last line: stay
    try check(&pt, .paragraph_next, args, 7, 3, 7); // count: stays

    try check(&pt, .paragraph_prev, args, 7, 1, 6); // c -> empty line 4
    try check(&pt, .paragraph_prev, args, 4, 1, 3); // b -> empty line 2
    try check(&pt, .paragraph_prev, args, 2, 1, 0); // inside the run -> line 0
    try check(&pt, .paragraph_prev, args, 6, 1, 3); // empty line 4 -> empty line 2
    try check(&pt, .paragraph_prev, args, 0, 1, 0); // first line: stay
    try check(&pt, .paragraph_prev, args, 5, 1, 3); // on '\n' of line 3 -> empty line 2

    // single-line doc: no empty line anywhere — { lands on column 0, } on
    // the last character (vim fwd/bwd_paragraph).
    var pt2 = try PieceTable.init(testing.allocator, "abc");
    defer pt2.deinit();
    try check(&pt2, .paragraph_next, args, 1, 1, 2);
    try check(&pt2, .paragraph_prev, args, 1, 1, 0);
}

test "paragraph: } at the document end lands on the last char, { on column 0 (vim)" {
    const args = Args{};

    // "abc": single line, no empty line anywhere. vim: } -> last char of the
    // line, { -> column 0.
    var pt = try PieceTable.init(testing.allocator, "abc");
    defer pt.deinit();
    try check(&pt, .paragraph_next, args, 1, 1, 2);
    try check(&pt, .paragraph_prev, args, 1, 1, 0);

    // "  abc\ndef": { lands on column 0 even when the first line is indented
    // (vim), not on the first non-blank.
    var pt2 = try PieceTable.init(testing.allocator, "  abc\ndef");
    defer pt2.deinit();
    try check(&pt2, .paragraph_prev, args, 7, 1, 0);

    // "abc\ndef\n": a trailing '\n' only terminates "def" — it is not an
    // extra empty line for vim. } from line 0 finds no boundary -> last char
    // of "def" (f at 6).
    var pt3 = try PieceTable.init(testing.allocator, "abc\ndef\n");
    defer pt3.deinit();
    try check(&pt3, .paragraph_next, args, 0, 1, 6);

    // "abc\n\ndef\n": } -> the real empty line (4); from there, no further
    // boundary -> last char of "def" (7).
    var pt4 = try PieceTable.init(testing.allocator, "abc\n\ndef\n");
    defer pt4.deinit();
    try check(&pt4, .paragraph_next, args, 0, 1, 4);
    try check(&pt4, .paragraph_next, args, 4, 1, 7);
}

test "page motions: fixed rows with clamping (M0)" {
    // 30 lines "x" each: "x\n" x29 + "x"; line k starts at 2k, doc len 59.
    var content: [59]u8 = undefined;
    var ci: usize = 0;
    var li: u32 = 0;
    while (li < 30) : (li += 1) {
        content[ci] = 'x';
        if (li < 29) content[ci + 1] = '\n';
        ci += 2;
    }
    var pt = try PieceTable.init(testing.allocator, &content);
    defer pt.deinit();
    try testing.expectEqual(@as(u32, 59), pt.len());
    const args = Args{};

    try check(&pt, .page_down, args, 0, 1, 48); // +24 lines -> line 24
    try check(&pt, .half_page_down, args, 0, 1, 24); // +12 lines -> line 12
    try check(&pt, .page_up, args, 58, 1, 10); // line 29 - 24 = line 5
    try check(&pt, .half_page_up, args, 58, 1, 34); // line 29 - 12 = line 17
    try check(&pt, .page_down, args, 58, 1, 58); // last line: clamp
    try check(&pt, .page_up, args, 0, 1, 0); // first line: clamp
    try check(&pt, .half_page_up, args, 0, 1, 0);
    try check(&pt, .page_down, args, 0, 3, 58); // count: repeated, clamped
}

test "find/till: direction, duplicates, line confinement, not-found" {
    // "abcabc\nxyz": a0 b1 c2 a3 b4 c5 \n6 x7 y8 z9.
    var pt = try PieceTable.init(testing.allocator, "abcabc\nxyz");
    defer pt.deinit();

    try check(&pt, .find, .{ .ch = 'c' }, 0, 1, 2);
    try check(&pt, .find, .{ .ch = 'c' }, 2, 1, 5); // second occurrence
    try check(&pt, .find, .{ .ch = 'c' }, 3, 1, 5);
    try check(&pt, .find, .{ .ch = 'c' }, 5, 1, 5); // none after: stay
    try check(&pt, .find, .{ .ch = 'x' }, 0, 1, 0); // not in this line: stay
    try check(&pt, .find, .{ .ch = 'x' }, 7, 1, 7); // only the char under the cursor: stay
    try check(&pt, .find, .{ .ch = 'x' }, 6, 1, 6); // on '\n': never crosses lines
    try check(&pt, .find, Args{}, 0, 1, 0); // no target char: stay

    try check(&pt, .find_back, .{ .ch = 'a' }, 5, 1, 3);
    try check(&pt, .find_back, .{ .ch = 'a' }, 3, 1, 0);
    try check(&pt, .find_back, .{ .ch = 'a' }, 0, 1, 0); // first char: stay
    try check(&pt, .find_back, .{ .ch = 'a' }, 7, 1, 7); // not in line 1: stay
    try check(&pt, .find_back, .{ .ch = 'b' }, 4, 1, 1);
    try check(&pt, .find_back, .{ .ch = 'b' }, 1, 1, 1); // none before: stay

    try check(&pt, .till, .{ .ch = 'c' }, 0, 1, 1); // one before the match
    try check(&pt, .till, .{ .ch = 'c' }, 1, 1, 1); // match right next to cursor: no move
    try check(&pt, .till, .{ .ch = 'c' }, 2, 1, 4); // next match at 5 -> 4
    try check(&pt, .till, .{ .ch = 'c' }, 5, 1, 5); // none after: stay

    try check(&pt, .till_back, .{ .ch = 'c' }, 5, 1, 3); // match at 2 -> one after = 3
    try check(&pt, .till_back, .{ .ch = 'c' }, 3, 1, 3); // match at 2 -> one after = 3 == from: no move
    try check(&pt, .till_back, .{ .ch = 'b' }, 5, 1, 5); // match at 4 -> one after = 5: no move
    try check(&pt, .till_back, .{ .ch = 'b' }, 4, 1, 2); // match at 1 -> 2

    // count repeats the search from the new position.
    try check(&pt, .find, .{ .ch = 'b' }, 0, 2, 4); // 1 -> 4
    try check(&pt, .find, .{ .ch = 'b' }, 0, 3, 4); // clamps at the last match
    try check(&pt, .find_back, .{ .ch = 'b' }, 5, 2, 1); // 4 -> 1
}

test "match_pair %: pairs, nesting, non-bracket, unmatched" {
    // "(a[b]c){d}": (0 a1 [2 b3 ]4 c5 )6 {7 d8 }9.
    var pt = try PieceTable.init(testing.allocator, "(a[b]c){d}");
    defer pt.deinit();
    const args = Args{};

    try check(&pt, .match_pair, args, 0, 1, 6); // ( -> )
    try check(&pt, .match_pair, args, 6, 1, 0); // ) -> (
    try check(&pt, .match_pair, args, 2, 1, 4); // [ -> ]
    try check(&pt, .match_pair, args, 4, 1, 2); // ] -> [
    try check(&pt, .match_pair, args, 7, 1, 9); // { -> }
    try check(&pt, .match_pair, args, 9, 1, 7); // } -> {
    try check(&pt, .match_pair, args, 1, 1, 4); // on 'a': vim scans the line -> [ -> ]
    try check(&pt, .match_pair, args, 8, 1, 7); // on 'd': scans -> } -> {
    try check(&pt, .match_pair, args, 5, 1, 0); // on 'c': scans -> ) -> (

    // nesting counts depth.
    var pt2 = try PieceTable.init(testing.allocator, "((x))");
    defer pt2.deinit();
    try check(&pt2, .match_pair, args, 0, 1, 4);
    try check(&pt2, .match_pair, args, 1, 1, 3);
    try check(&pt2, .match_pair, args, 4, 1, 0);

    // mismatched brackets do not pair.
    var pt3 = try PieceTable.init(testing.allocator, "(]");
    defer pt3.deinit();
    try check(&pt3, .match_pair, args, 0, 1, 0);

    // unpaired brackets: no move.
    var pt4 = try PieceTable.init(testing.allocator, "(x");
    defer pt4.deinit();
    try check(&pt4, .match_pair, args, 0, 1, 0); // '(' has no ')' below
    try check(&pt4, .match_pair, args, 1, 1, 1); // 'x': no bracket after it on the line

    var pt5 = try PieceTable.init(testing.allocator, "x)");
    defer pt5.deinit();
    try check(&pt5, .match_pair, args, 0, 1, 0); // scans to ')' but no open
    try check(&pt5, .match_pair, args, 1, 1, 1); // on ')' with no open before: stay

    // % at end of document: stay.
    try check(&pt, .match_pair, args, 10, 1, 10);
}

test "count: repeated motions clamp to the document edges" {
    // "abc\ndef\nghi": a0 b1 c2 \n3 d4 e5 f6 \n7 g8 h9 i10.
    var pt = try PieceTable.init(testing.allocator, "abc\ndef\nghi");
    defer pt.deinit();
    const args = Args{};

    try check(&pt, .word_next, args, 0, 2, 8); // d -> g
    try check(&pt, .word_next, args, 0, 5, 10); // no word after ghi: -> last char (vim)
    try check(&pt, .left, args, 10, 3, 8); // i -> h -> g -> stays at col 0 of line 2 (h doesn't wrap)
    try check(&pt, .left, args, 10, 20, 8); // clamps at the first line-start reached
    try check(&pt, .right, args, 0, 3, 2); // a -> b -> c -> clamp at line end
    try check(&pt, .right, args, 0, 10, 2);
    try check(&pt, .up, args, 8, 2, 0); // g -> d -> a
    try check(&pt, .up, args, 8, 5, 0);

    // count 0 behaves like count 1.
    try check(&pt, .left, args, 5, 0, 4);
}

test "apply clamps an out-of-range cursor" {
    var pt = try PieceTable.init(testing.allocator, "abc\ndef");
    defer pt.deinit();
    var cur: u32 = 1000; // beyond the document
    apply(&pt, .left, .{}, &cur, 1);
    try testing.expectEqual(@as(u32, 6), cur); // clamped to len, then left
    cur = 1000;
    apply(&pt, .right, .{}, &cur, 1);
    try testing.expectEqual(@as(u32, 7), cur); // clamped to len: stays (line end)
}

test "target equals apply for a sweep of motions and positions" {
    // Property-style consistency check: target() must never diverge from
    // apply(), and must not mutate its `from` argument.
    var pt = try PieceTable.init(testing.allocator, "foo_bar, baz\n\nqux(zz)");
    defer pt.deinit();
    const motions = [_]struct { motion: Motion, args: Args }{
        .{ .motion = .left, .args = .{} },
        .{ .motion = .right, .args = .{} },
        .{ .motion = .down, .args = .{} },
        .{ .motion = .up, .args = .{} },
        .{ .motion = .word_next, .args = .{} },
        .{ .motion = .word_next_end, .args = .{} },
        .{ .motion = .word_prev, .args = .{} },
        .{ .motion = .word_prev_end, .args = .{} },
        .{ .motion = .line_start, .args = .{} },
        .{ .motion = .line_start_bol, .args = .{} },
        .{ .motion = .line_end, .args = .{} },
        .{ .motion = .first_line, .args = .{} },
        .{ .motion = .last_line, .args = .{} },
        .{ .motion = .paragraph_prev, .args = .{} },
        .{ .motion = .paragraph_next, .args = .{} },
        .{ .motion = .page_up, .args = .{} },
        .{ .motion = .page_down, .args = .{} },
        .{ .motion = .half_page_up, .args = .{} },
        .{ .motion = .half_page_down, .args = .{} },
        .{ .motion = .find, .args = .{ .ch = 'a' } },
        .{ .motion = .find_back, .args = .{ .ch = 'a' } },
        .{ .motion = .till, .args = .{ .ch = 'a' } },
        .{ .motion = .till_back, .args = .{ .ch = 'a' } },
        .{ .motion = .match_pair, .args = .{} },
    };
    const positions = [_]u32{ 0, 1, 5, 7, 8, 13, 17, 19 };
    const counts = [_]u32{ 1, 2, 5 };
    for (motions) |m| {
        for (positions) |from| {
            for (counts) |count| {
                var cur = from;
                apply(&pt, m.motion, m.args, &cur, count);
                const t = target(&pt, m.motion, m.args, from, count);
                try testing.expectEqual(cur, t);
            }
        }
    }
}
