//! Language-aware insertion indentation (editing-reliability issues 2 and 3).
//!
//! This module is pure: it only sees document bytes (`[]const u8`), a byte
//! cursor/insertion offset, a filetype string and an indentation config. It
//! never imports App, vaxis, LSP or the piece table, so every rule here is
//! unit-testable with `zig test src/editor/indent.zig`.
//!
//! Two entry points share the same language/style policy:
//!
//! - `planEnter` answers "what should Insert-Enter insert here?" without
//!   touching the buffer. It returns one insertion string plus the cursor's
//!   offset inside it, so the caller can perform ONE `history.record` (one
//!   undo step, one LSP pre-edit range).
//! - `reindentInsertion` answers "what should this pasted/put text look like
//!   in this context?" It only ever changes leading whitespace of
//!   structurally reindented lines; string/comment bodies, unknown languages
//!   and (for YAML) block scalars are preserved. The caller inserts the
//!   returned bytes as one edit.
//!
//! Scope by language (see `languageForFiletype`):
//! - brace  (Zig/C/C++/Rust/Go/Java/JS/TS/…): real block braces, strings,
//!   comments, Zig multiline `\\` strings.
//! - python: colon + relative-indent reindent, triple-quoted bodies kept.
//! - yaml: colon + relative-indent reindent, block scalars kept.
//! - markdown/plain/unknown: no structural change (Enter keeps the old
//!   copy-leading-indent behaviour; paste keeps its content).

const std = @import("std");

pub const Language = enum { brace, python, yaml, markdown, plain };

pub const Config = struct {
    indent_width: u8 = 4,
    use_tabs: bool = false,
};

/// Owned newline insertion plan. `cursor_after` is the cursor's byte offset
/// from the insertion start (always <= text.len, so the tail after it is the
/// existing line content, e.g. an aligned closing brace).
pub const NewlinePlan = struct {
    text: []u8,
    cursor_after: u32,
};

/// Hard bounds for structural paste reindent. Larger insertions are returned
/// verbatim (only line endings normalized): a huge paste must never run an
/// unbounded structural scan.
pub const max_insert_bytes: usize = 1 << 20;
pub const max_insert_lines: usize = 16384;

// ============================== languages ==================================

pub fn languageForFiletype(ft: []const u8) Language {
    const table = [_]struct { ext: []const u8, lang: Language }{
        .{ .ext = "zig", .lang = .brace },
        .{ .ext = "c", .lang = .brace },
        .{ .ext = "h", .lang = .brace },
        .{ .ext = "cc", .lang = .brace },
        .{ .ext = "cpp", .lang = .brace },
        .{ .ext = "cxx", .lang = .brace },
        .{ .ext = "hpp", .lang = .brace },
        .{ .ext = "hh", .lang = .brace },
        .{ .ext = "rs", .lang = .brace },
        .{ .ext = "go", .lang = .brace },
        .{ .ext = "java", .lang = .brace },
        .{ .ext = "kt", .lang = .brace },
        .{ .ext = "kts", .lang = .brace },
        .{ .ext = "scala", .lang = .brace },
        .{ .ext = "cs", .lang = .brace },
        .{ .ext = "swift", .lang = .brace },
        .{ .ext = "php", .lang = .brace },
        .{ .ext = "m", .lang = .brace },
        .{ .ext = "mm", .lang = .brace },
        .{ .ext = "js", .lang = .brace },
        .{ .ext = "mjs", .lang = .brace },
        .{ .ext = "cjs", .lang = .brace },
        .{ .ext = "jsx", .lang = .brace },
        .{ .ext = "ts", .lang = .brace },
        .{ .ext = "tsx", .lang = .brace },
        .{ .ext = "json", .lang = .brace },
        .{ .ext = "jsonc", .lang = .brace },
        .{ .ext = "css", .lang = .brace },
        .{ .ext = "scss", .lang = .brace },
        .{ .ext = "less", .lang = .brace },
        .{ .ext = "py", .lang = .python },
        .{ .ext = "pyi", .lang = .python },
        .{ .ext = "pyw", .lang = .python },
        .{ .ext = "yaml", .lang = .yaml },
        .{ .ext = "yml", .lang = .yaml },
        .{ .ext = "md", .lang = .markdown },
        .{ .ext = "markdown", .lang = .markdown },
        .{ .ext = "mdx", .lang = .markdown },
        .{ .ext = "mdown", .lang = .markdown },
    };
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(ft, t.ext)) return t.lang;
    }
    return .plain;
}

// ============================ line/ending helpers ==========================

const Ending = enum { lf, crlf };

fn endingBytes(e: Ending) []const u8 {
    return switch (e) {
        .lf => "\n",
        .crlf => "\r\n",
    };
}

fn lineStartOf(doc: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    const p = std.mem.lastIndexOfScalar(u8, doc[0..@min(pos, doc.len)], '\n') orelse return 0;
    return p + 1;
}

/// End of the line's TEXT (excludes the '\r' of a CRLF terminator and the
/// terminator itself).
fn lineContentEndOf(doc: []const u8, start: usize) usize {
    var i = start;
    while (i < doc.len and doc[i] != '\n') : (i += 1) {}
    if (i > start and doc[i - 1] == '\r') return i - 1;
    return i;
}

fn lineEndIncludingTerminator(doc: []const u8, start: usize) usize {
    var i = start;
    while (i < doc.len and doc[i] != '\n') : (i += 1) {}
    return if (i < doc.len) i + 1 else i;
}

fn leadingWsLen(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i;
}

fn isBlank(text: []const u8) bool {
    for (text) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn hasTab(text: []const u8) bool {
    for (text) |c| {
        if (c == '\t') return true;
    }
    return false;
}

/// Line ending to use for a newline inserted at `cursor`: the current line's
/// own terminator, else the nearest earlier terminator, else LF. Mirrors
/// `editor.line_open.preferredEnding` (kept here so this module stays pure).
fn preferredEnding(doc: []const u8, cursor: usize) Ending {
    const pos = @min(cursor, doc.len);
    const line_start = lineStartOf(doc, pos);
    const end = lineEndIncludingTerminator(doc, line_start);
    if (end > pos and end > line_start) {
        // current line has a terminator
        if (end - line_start >= 2 and doc[end - 2] == '\r' and doc[end - 1] == '\n') return .crlf;
        if (end - line_start >= 1 and doc[end - 1] == '\n') return .lf;
    }
    // Last line: inherit the nearest earlier line's terminator.
    var line = line_start;
    while (line > 0) {
        const prev_nl = line - 1;
        const prev_start = lineStartOf(doc, prev_nl);
        const prev_end = prev_nl + 1; // include '\n'
        if (prev_end - prev_start >= 2 and doc[prev_end - 2] == '\r') return .crlf;
        if (prev_end > prev_start) return .lf;
        line = prev_start;
    }
    return .lf;
}

/// Dominant buffer line ending: CRLF when it is at least as common as bare
/// LF, otherwise LF. An empty buffer uses LF.
fn dominantEnding(doc: []const u8) Ending {
    var crlf: usize = 0;
    var lf_total: usize = 0;
    var i: usize = 0;
    while (i < doc.len) : (i += 1) {
        if (doc[i] != '\n') continue;
        lf_total += 1;
        if (i > 0 and doc[i - 1] == '\r') crlf += 1;
    }
    const lf_only = lf_total - crlf;
    if (crlf > 0 and crlf >= lf_only) return .crlf;
    return .lf;
}

fn normalizeLf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
        out_len += 1;
    }
    const out = try alloc.alloc(u8, out_len);
    var n: usize = 0;
    i = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') {
                i += 1; // fold CRLF to the following LF
            }
            out[n] = '\n';
            n += 1;
        } else {
            out[n] = text[i];
            n += 1;
        }
    }
    return out;
}

fn withEnding(alloc: std.mem.Allocator, text_lf: []const u8, ending: Ending) ![]u8 {
    var newlines: usize = 0;
    for (text_lf) |c| {
        if (c == '\n') newlines += 1;
    }
    const extra_per_nl: usize = if (ending == .crlf) 1 else 0;
    const out = try alloc.alloc(u8, text_lf.len + newlines * extra_per_nl);
    var n: usize = 0;
    for (text_lf) |c| {
        if (c == '\n' and ending == .crlf) {
            out[n] = '\r';
            n += 1;
        }
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

fn appendNewline(alloc: std.mem.Allocator, out: *std.ArrayList(u8), ending: Ending) !void {
    try out.appendSlice(alloc, endingBytes(ending));
}

// ============================== lexer ======================================

const LexKind = enum { code, line_comment, block_comment, string, triple };

const LexState = struct {
    kind: LexKind = .code,
    block_depth: u32 = 0,
    quote: u8 = 0,
    triple: u8 = 0,
};

const Step = struct {
    n: usize = 1,
    code: bool = false,
};

/// One state-machine step. `code` is true when the byte at `i` is code
/// (only brace languages need that for brace counting). `n` is the number
/// of bytes consumed (2/3 for comment/string openers and escapes).
fn lexStep(s: []const u8, i: usize, st: *LexState, lang: Language) Step {
    const c = s[i];
    switch (st.kind) {
        .code => switch (lang) {
            .brace => {
                if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
                    st.kind = .line_comment;
                    return .{ .n = 2 };
                }
                if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                    st.kind = .block_comment;
                    st.block_depth = 1;
                    return .{ .n = 2 };
                }
                if (c == '"' or c == '\'' or c == '`') {
                    st.kind = .string;
                    st.quote = c;
                    return .{ .n = 1 };
                }
                return .{ .n = 1, .code = true };
            },
            .python => {
                if (c == '#') {
                    st.kind = .line_comment;
                    return .{ .n = 1 };
                }
                if (c == '"' or c == '\'') {
                    if (i + 2 < s.len and s[i + 1] == c and s[i + 2] == c) {
                        st.kind = .triple;
                        st.triple = c;
                        return .{ .n = 3 };
                    }
                    st.kind = .string;
                    st.quote = c;
                    return .{ .n = 1 };
                }
                return .{ .n = 1, .code = true };
            },
            .yaml => {
                if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
                    st.kind = .line_comment;
                    return .{ .n = 1 };
                }
                if (c == '"' or c == '\'') {
                    st.kind = .string;
                    st.quote = c;
                    return .{ .n = 1 };
                }
                return .{ .n = 1, .code = true };
            },
            else => return .{ .n = 1 },
        },
        .line_comment => {
            if (c == '\n') st.* = .{};
            return .{ .n = 1 };
        },
        .block_comment => {
            if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                st.block_depth += 1;
                return .{ .n = 2 };
            }
            if (c == '*' and i + 1 < s.len and s[i + 1] == '/') {
                st.block_depth -= 1;
                if (st.block_depth == 0) st.* = .{};
                return .{ .n = 2 };
            }
            return .{ .n = 1 };
        },
        .string => {
            if (c == '\\' and (lang == .brace or lang == .python or (lang == .yaml and st.quote == '"'))) {
                return .{ .n = 2 };
            }
            if (c == st.quote) {
                st.* = .{};
                return .{ .n = 1 };
            }
            if (c == '\n' and lang == .python) st.* = .{};
            return .{ .n = 1 };
        },
        .triple => {
            if (c == '\\') return .{ .n = 2 };
            if (c == st.triple and i + 2 < s.len and s[i + 1] == st.triple and s[i + 2] == st.triple) {
                st.* = .{};
                return .{ .n = 3 };
            }
            return .{ .n = 1 };
        },
    }
}

/// Lexer state at byte offset `end` (exclusive). Zig multiline `\\` lines are
/// skipped as literal lines so their contents cannot open strings/comments.
fn scanState(doc: []const u8, end_in: usize, lang: Language, st0: LexState) LexState {
    const end = @min(end_in, doc.len);
    var st = st0;
    var i: usize = 0;
    var line_start: usize = 0;
    while (i < end) {
        if (lang == .brace and st.kind == .code and i == line_start) {
            var k = i;
            while (k < end and (doc[k] == ' ' or doc[k] == '\t')) k += 1;
            if (k + 1 < end and doc[k] == '\\' and doc[k + 1] == '\\') {
                var j = k + 2;
                while (j < end and doc[j] != '\n') j += 1;
                if (j >= end) break;
                line_start = j + 1;
                i = j + 1;
                continue;
            }
        }
        const from = i;
        const step = lexStep(doc[0..end], i, &st, lang);
        i = @min(i + step.n, end);
        var j = from;
        while (j < i) : (j += 1) {
            if (doc[j] == '\n') line_start = j + 1;
        }
    }
    return st;
}

const LineScan = struct {
    st: LexState = .{},
    delta: i32 = 0,
    leading_closes: i32 = 0,
    zig_literal: bool = false,
};

/// Scan one line (no terminating newline) from `st0`, optionally counting
/// braces. `leading_closes` counts `}` before any other code token (used to
/// de-indent a line that closes a block). A Zig `\\` line is reported as
/// `zig_literal` and must be emitted verbatim.
fn scanLine(line: []const u8, lang: Language, st0: LexState, count_braces: bool) LineScan {
    var st = st0;
    if (st.kind == .line_comment) st = .{};
    var res = LineScan{ .st = st };
    if (lang == .brace and st.kind == .code) {
        var k: usize = 0;
        while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
        if (k + 1 < line.len and line[k] == '\\' and line[k + 1] == '\\') {
            res.zig_literal = true;
            return res;
        }
    }
    var i: usize = 0;
    var seen_other = false;
    while (i < line.len) {
        const before = st;
        const step = lexStep(line, i, &st, lang);
        if (count_braces and lang == .brace and before.kind == .code and step.code) {
            const c = line[i];
            if (c == '{') {
                res.delta += 1;
            } else if (c == '}') {
                res.delta -= 1;
                if (!seen_other) res.leading_closes += 1;
            } else if (c != ' ' and c != '\t' and c != '\r') {
                seen_other = true;
            }
        }
        i = @min(i + step.n, line.len);
    }
    if (st.kind == .line_comment) st = .{};
    res.st = st;
    return res;
}

/// Net brace delta of one line's code (strings/comments/line strings ignored).
fn netBraces(text: []const u8, lang: Language) i32 {
    if (lang != .brace or text.len == 0) return 0;
    var k: usize = 0;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    if (k + 1 < text.len and text[k] == '\\' and text[k + 1] == '\\') return 0;
    var st = LexState{};
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const before = st;
        const step = lexStep(text, i, &st, lang);
        if (before.kind == .code and step.code) {
            const c = text[i];
            if (c == '{') delta += 1;
            if (c == '}') delta -= 1;
        }
        i = @min(i + step.n, text.len);
    }
    return delta;
}

fn lineCommentStart(text: []const u8, lang: Language) ?usize {
    var st = LexState{};
    var i: usize = 0;
    while (i < text.len) {
        if (st.kind == .code and lang == .python and text[i] == '#') return i;
        if (st.kind == .code and lang == .yaml and text[i] == '#' and
            (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t')) return i;
        const step = lexStep(text, i, &st, lang);
        i = @min(i + step.n, text.len);
    }
    return null;
}

fn codeEndsWithColon(text: []const u8, lang: Language) bool {
    const cut = lineCommentStart(text, lang) orelse text.len;
    const code = std.mem.trimEnd(u8, text[0..cut], " \t\r");
    return std.mem.endsWith(u8, code, ":");
}

fn yamlLineIsBlockHeader(line: []const u8) bool {
    const cut = lineCommentStart(line, .yaml) orelse line.len;
    const t = std.mem.trimEnd(u8, line[0..cut], " \t\r");
    if (t.len == 0) return false;
    var i = t.len - 1;
    while (i > 0 and (t[i] == '+' or t[i] == '-' or (t[i] >= '0' and t[i] <= '9'))) i -= 1;
    return t[i] == '|' or t[i] == '>';
}

fn isZigFiletype(ft: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ft, "zig");
}

fn lineStartsWithZigString(doc: []const u8, line_start: usize, line_end: usize) bool {
    var k = line_start;
    while (k < line_end and (doc[k] == ' ' or doc[k] == '\t')) k += 1;
    return k + 1 < line_end and doc[k] == '\\' and doc[k + 1] == '\\';
}

fn yamlInBlockScalar(doc: []const u8, cursor: usize) bool {
    const line_start = lineStartOf(doc, cursor);
    const line_end = lineContentEndOf(doc, line_start);
    const cur_indent = leadingWsLen(doc[line_start..line_end]);
    var ls = line_start;
    while (ls > 0) {
        const prev_start = lineStartOf(doc, ls - 1);
        const prev_end = lineContentEndOf(doc, prev_start);
        const content = doc[prev_start..prev_end];
        if (isBlank(content)) {
            ls = prev_start;
            continue;
        }
        if (yamlLineIsBlockHeader(content)) {
            return cur_indent > leadingWsLen(content);
        }
        return false;
    }
    return false;
}

fn yamlInsertHasBlockScalar(norm: []const u8) bool {
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, norm, i, '\n');
        const end = nl orelse norm.len;
        if (yamlLineIsBlockHeader(norm[i..end])) return true;
        if (nl == null) return false;
        i = end + 1;
    }
}

// ============================== Enter plans ================================

fn appendIndentUnit(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cfg: Config) !void {
    if (cfg.use_tabs) {
        try out.append(alloc, '\t');
    } else {
        try out.appendNTimes(alloc, ' ', cfg.indent_width);
    }
}

fn makePlan(
    alloc: std.mem.Allocator,
    ending: Ending,
    indent: []const u8,
    two_lines: bool,
    closer_indent: []const u8,
) !NewlinePlan {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, endingBytes(ending));
    try out.appendSlice(alloc, indent);
    const cursor_after: u32 = @intCast(out.items.len);
    if (two_lines) {
        // The existing closer is left in the tail; give it the current
        // line's indent so it lands aligned with the block, not at column 0
        // (nested one-liners like `    if (x) {}`).
        try out.appendSlice(alloc, endingBytes(ending));
        try out.appendSlice(alloc, closer_indent);
    }
    return .{ .text = try out.toOwnedSlice(alloc), .cursor_after = cursor_after };
}

/// The previous behaviour: newline plus a verbatim copy of the current line's
/// leading whitespace (bounded by the cursor). This is also the safe fallback
/// inside strings/comments and for unknown/plain filetypes.
fn fallbackPlan(alloc: std.mem.Allocator, doc: []const u8, cursor: usize, ending: Ending) !NewlinePlan {
    const line_start = lineStartOf(doc, cursor);
    const line_end = lineContentEndOf(doc, line_start);
    const upto = @min(cursor, line_end);
    var n: usize = line_start;
    while (n < upto and (doc[n] == ' ' or doc[n] == '\t')) : (n += 1) {}
    return makePlan(alloc, ending, doc[line_start..n], false, "");
}

/// Brace-language Enter: when the cursor follows an opening `{` (ignoring
/// spaces/tabs on the same line), open one deeper indented line. If the
/// closer is immediately after the cursor on the same line, also insert a
/// newline so that existing closer becomes the aligned block closer.
fn planBrace(
    alloc: std.mem.Allocator,
    doc: []const u8,
    cursor: usize,
    cfg: Config,
    ft: []const u8,
) !?NewlinePlan {
    const line_start = lineStartOf(doc, cursor);
    const line_end = lineContentEndOf(doc, line_start);
    if (cursor > line_end) return null;
    if (scanState(doc, cursor, .brace, .{}).kind != .code) return null;
    if (isZigFiletype(ft) and lineStartsWithZigString(doc, line_start, line_end)) return null;

    var open = cursor;
    while (open > line_start and (doc[open - 1] == ' ' or doc[open - 1] == '\t')) open -= 1;
    if (open == line_start or doc[open - 1] != '{') return null;

    var indent_end = line_start;
    while (indent_end < line_end and (doc[indent_end] == ' ' or doc[indent_end] == '\t')) indent_end += 1;
    var inner = std.ArrayList(u8).empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, doc[line_start..indent_end]);
    try appendIndentUnit(&inner, alloc, cfg);

    var next = cursor;
    while (next < line_end and (doc[next] == ' ' or doc[next] == '\t')) next += 1;
    var two_lines = false;
    if (next < line_end and doc[next] == '}') {
        // Only a real code closer (not `}` inside a string/comment) counts.
        two_lines = scanState(doc, next, .brace, .{}).kind == .code;
    }
    const base_indent = doc[line_start..indent_end];
    return try makePlan(alloc, preferredEnding(doc, cursor), inner.items, two_lines, base_indent);
}

/// Python Enter: a line whose code ends with `:` opens one deeper line.
/// Cursor inside a triple-quoted body keeps the copy-indent fallback.
fn planPython(
    alloc: std.mem.Allocator,
    doc: []const u8,
    cursor: usize,
    cfg: Config,
) !?NewlinePlan {
    const line_start = lineStartOf(doc, cursor);
    const line_end = lineContentEndOf(doc, line_start);
    if (cursor > line_end) return null;
    const st = scanState(doc, cursor, .python, .{});
    if (st.kind == .string or st.kind == .triple or st.kind == .block_comment) return null;
    if (!codeEndsWithColon(doc[line_start..cursor], .python)) return null;

    var indent_end = line_start;
    while (indent_end < line_end and (doc[indent_end] == ' ' or doc[indent_end] == '\t')) indent_end += 1;
    var inner = std.ArrayList(u8).empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, doc[line_start..indent_end]);
    try appendIndentUnit(&inner, alloc, cfg);
    return try makePlan(alloc, preferredEnding(doc, cursor), inner.items, false, "");
}

/// YAML Enter: `key:` opens one deeper line; block-scalar bodies keep their
/// existing indentation.
fn planYaml(
    alloc: std.mem.Allocator,
    doc: []const u8,
    cursor: usize,
    cfg: Config,
) !?NewlinePlan {
    const line_start = lineStartOf(doc, cursor);
    const line_end = lineContentEndOf(doc, line_start);
    if (cursor > line_end) return null;
    const st = scanState(doc, cursor, .yaml, .{});
    if (st.kind == .string or st.kind == .block_comment) return null;
    if (yamlInBlockScalar(doc, cursor)) return null;
    if (!codeEndsWithColon(doc[line_start..cursor], .yaml)) return null;

    var indent_end = line_start;
    while (indent_end < line_end and (doc[indent_end] == ' ' or doc[indent_end] == '\t')) indent_end += 1;
    var inner = std.ArrayList(u8).empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, doc[line_start..indent_end]);
    try appendIndentUnit(&inner, alloc, cfg);
    return try makePlan(alloc, preferredEnding(doc, cursor), inner.items, false, "");
}

pub fn planEnter(
    alloc: std.mem.Allocator,
    doc: []const u8,
    cursor_in: u32,
    ft: []const u8,
    cfg: Config,
) !NewlinePlan {
    const cursor = @min(@as(usize, cursor_in), doc.len);
    switch (languageForFiletype(ft)) {
        .brace => {
            if (try planBrace(alloc, doc, cursor, cfg, ft)) |p| return p;
        },
        .python => {
            if (try planPython(alloc, doc, cursor, cfg)) |p| return p;
        },
        .yaml => {
            if (try planYaml(alloc, doc, cursor, cfg)) |p| return p;
        },
        .markdown, .plain => {},
    }
    return fallbackPlan(alloc, doc, cursor, preferredEnding(doc, cursor));
}

// ========================= paste reindentation ============================

/// Structural anchor for an insertion: the line the pasted text is attached
/// to. For a line-start insertion the previous non-blank line is the anchor
/// (its open braces decide the first pasted line's depth); for a mid-line
/// charwise insertion the current line and its code prefix are the anchor.
const Anchor = struct {
    indent: []const u8,
    net: i32 = 0,
    ends_colon: bool = false,
};

fn previousNonBlankLine(doc: []const u8, line_start: usize) ?struct { start: usize, end: usize } {
    var ls = line_start;
    while (ls > 0) {
        const prev_start = lineStartOf(doc, ls - 1);
        const prev_end = lineContentEndOf(doc, prev_start);
        if (!isBlank(doc[prev_start..prev_end])) return .{ .start = prev_start, .end = prev_end };
        ls = prev_start;
    }
    return null;
}

fn anchorFor(doc: []const u8, at: usize, at_line_start: bool, lang: Language) Anchor {
    const line_start = lineStartOf(doc, at);
    const line_end = lineContentEndOf(doc, line_start);
    if (at_line_start) {
        // Prefer the line the insertion is attached to when it is real code:
        // its own indentation is exactly where the pasted lines should land
        // (a `p` below / `P` above a body line). A closer line is the
        // exception — pasted content belongs one level in, so anchor on the
        // previous non-blank line instead. This also avoids inheriting the
        // indent of a Zig multiline `\\` string line.
        const cur = doc[line_start..line_end];
        const cur_ws = leadingWsLen(cur);
        if (!isBlank(cur) and cur_ws < cur.len and
            cur[cur_ws] != '}' and cur[cur_ws] != ')' and cur[cur_ws] != ']')
        {
            const prefix = doc[line_start..@min(at, line_end)];
            return .{
                .indent = cur[0..cur_ws],
                .net = netBraces(prefix, lang),
                .ends_colon = codeEndsWithColon(prefix, lang),
            };
        }
        if (previousNonBlankLine(doc, line_start)) |p| {
            const line = doc[p.start..p.end];
            return .{
                .indent = line[0..leadingWsLen(line)],
                .net = netBraces(line, lang),
                .ends_colon = codeEndsWithColon(line, lang),
            };
        }
        return .{ .indent = "" };
    }
    const line = doc[line_start..line_end];
    const prefix = doc[line_start..@min(at, line_end)];
    return .{
        .indent = line[0..leadingWsLen(line)],
        .net = netBraces(prefix, lang),
        .ends_colon = codeEndsWithColon(prefix, lang),
    };
}

/// Longest common leading-whitespace prefix of the pasted block's non-blank
/// code-starting lines. Used to dedent a relative-indent language (Python/
/// YAML) before re-anchoring it at the insertion point. Literal-body lines
/// (inside triple quotes / block scalars) are excluded.
fn commonIndent(norm: []const u8, lang: Language, skip_first: bool) []const u8 {
    var common: ?[]const u8 = null;
    var st = LexState{};
    var i: usize = 0;
    var idx: usize = 0;
    while (i <= norm.len) {
        const nl = std.mem.indexOfScalarPos(u8, norm, i, '\n');
        const end = nl orelse norm.len;
        const line = norm[i..end];
        const usable = !(skip_first and idx == 0) and st.kind == .code and !isBlank(line);
        if (usable) {
            const ws = line[0..leadingWsLen(line)];
            if (common) |c| {
                var n: usize = 0;
                while (n < c.len and n < ws.len and c[n] == ws[n]) n += 1;
                common = c[0..n];
            } else {
                common = ws;
            }
        }
        st = scanLine(line, lang, st, false).st;
        if (nl == null) break;
        i = end + 1;
        idx += 1;
    }
    return common orelse "";
}

fn appendLevel(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cfg: Config, use_tabs: bool, levels: i32) !void {
    var d: i32 = 0;
    while (d < levels) : (d += 1) {
        if (use_tabs) {
            try out.append(alloc, '\t');
        } else {
            try out.appendNTimes(alloc, ' ', cfg.indent_width);
        }
    }
}

fn reindentBraceLf(
    alloc: std.mem.Allocator,
    norm: []const u8,
    at_line_start: bool,
    anchor: Anchor,
    cfg: Config,
    out: *std.ArrayList(u8),
) !void {
    const use_tabs = cfg.use_tabs or hasTab(anchor.indent);
    var depth: i32 = @max(anchor.net, 0);
    var st = LexState{};
    var first = true;
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, norm, i, '\n');
        const end = nl orelse norm.len;
        const line = norm[i..end];
        const has_nl = nl != null;
        if (!first) try out.append(alloc, '\n');
        if (st.kind == .line_comment) st = .{};

        if (first and !at_line_start) {
            // The pasted text continues the current line: keep it verbatim.
            try out.appendSlice(alloc, line);
            const scan = scanLine(line, .brace, st, true);
            depth = @max(depth + scan.delta, 0);
            st = scan.st;
        } else if (st.kind != .code) {
            // Continuation of a block comment / unterminated string: literal.
            try out.appendSlice(alloc, line);
            st = scanLine(line, .brace, st, true).st;
        } else {
            const scan = scanLine(line, .brace, st, true);
            if (scan.zig_literal) {
                // Zig multiline `\\` line: literal content, never re-indented
                // and never counted for braces.
                try out.appendSlice(alloc, line);
                st = scan.st;
            } else if (isBlank(line)) {
                // Structural blank line: strip indentation (no trailing ws).
                st = scan.st;
            } else {
                const ls = leadingWsLen(line);
                const indent_depth = @max(depth - scan.leading_closes, 0);
                try out.appendSlice(alloc, anchor.indent);
                try appendLevel(out, alloc, cfg, use_tabs, indent_depth);
                try out.appendSlice(alloc, line[ls..]);
                depth = @max(depth + scan.delta, 0);
                st = scan.st;
            }
        }
        if (!has_nl) break;
        i = end + 1;
        first = false;
    }
}

fn reindentRelativeLf(
    alloc: std.mem.Allocator,
    norm: []const u8,
    lang: Language,
    at_line_start: bool,
    anchor: Anchor,
    cfg: Config,
    out: *std.ArrayList(u8),
) !void {
    const use_tabs = cfg.use_tabs or hasTab(anchor.indent);
    const common = commonIndent(norm, lang, !at_line_start);
    var base = std.ArrayList(u8).empty;
    defer base.deinit(alloc);
    try base.appendSlice(alloc, anchor.indent);
    if (anchor.ends_colon) try appendLevel(&base, alloc, cfg, use_tabs, 1);
    var st = LexState{};
    var first = true;
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, norm, i, '\n');
        const end = nl orelse norm.len;
        const line = norm[i..end];
        const has_nl = nl != null;
        if (!first) try out.append(alloc, '\n');
        if (st.kind == .line_comment) st = .{};
        if (first and !at_line_start) {
            try out.appendSlice(alloc, line);
        } else if (st.kind != .code) {
            // Triple-quoted/string/comment body: literal, keep exact bytes.
            try out.appendSlice(alloc, line);
        } else if (isBlank(line)) {
            // Structural blank line: strip indentation.
        } else {
            const ls = leadingWsLen(line);
            const rest = if (std.mem.startsWith(u8, line, common)) line[common.len..] else line[ls..];
            try out.appendSlice(alloc, base.items);
            try out.appendSlice(alloc, rest);
        }
        st = scanLine(line, lang, st, false).st;
        if (!has_nl) break;
        i = end + 1;
        first = false;
    }
}

/// True when the normalized insertion at `at` will really be structurally
/// reindented. Used BOTH by reindentInsertion and by planPaste before it
/// decides to replace a whitespace-only line prefix: deleting that prefix in
/// a verbatim/literal fallback would change content (e.g. the spaces inside a
/// Python triple-quoted string).
fn canReindentNormalized(
    doc_before: []const u8,
    at_u32: u32,
    norm: []const u8,
    ft: []const u8,
    linewise: bool,
) bool {
    const lang = languageForFiletype(ft);
    if (norm.len == 0) return false;
    if (lang == .plain or lang == .markdown) return false;
    // A charwise single-line insert is not structurally reindented; only
    // multi-line charwise pastes and whole-line (linewise) puts are.
    if (!linewise and std.mem.indexOfScalar(u8, norm, '\n') == null) return false;
    if (norm.len > max_insert_bytes) return false;
    var line_count: usize = 1;
    for (norm) |c| {
        if (c == '\n') line_count += 1;
    }
    if (line_count > max_insert_lines) return false;
    const at = @min(@as(usize, at_u32), doc_before.len);
    const line_start = lineStartOf(doc_before, at);
    const line_end = lineContentEndOf(doc_before, line_start);
    // Never restructure inside a literal/comment, or inside a Zig multiline
    // line string: leading whitespace there is content.
    if (scanState(doc_before, at, lang, .{}).kind != .code) return false;
    if (lang == .brace and isZigFiletype(ft) and lineStartsWithZigString(doc_before, line_start, line_end)) {
        return false;
    }
    if (lang == .yaml) {
        if (yamlInBlockScalar(doc_before, at)) return false;
        if (yamlInsertHasBlockScalar(norm)) return false;
    }
    return true;
}

pub fn reindentInsertion(
    alloc: std.mem.Allocator,
    doc_before: []const u8,
    at_u32: u32,
    inserted: []const u8,
    ft: []const u8,
    cfg: Config,
    linewise: bool,
) ![]u8 {
    const norm = try normalizeLf(alloc, inserted);
    defer alloc.free(norm);
    const ending = dominantEnding(doc_before);
    const at = @min(@as(usize, at_u32), doc_before.len);
    if (!canReindentNormalized(doc_before, at_u32, norm, ft, linewise)) {
        return withEnding(alloc, norm, ending);
    }
    const lang = languageForFiletype(ft);
    const line_start = lineStartOf(doc_before, at);
    const line_end = lineContentEndOf(doc_before, line_start);
    const prefix = doc_before[line_start..@min(at, line_end)];
    const line_is_blank = isBlank(doc_before[line_start..line_end]);
    const at_line_start = linewise or at == line_start or (isBlank(prefix) and line_is_blank);

    const anchor = anchorFor(doc_before, at, at_line_start, lang);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    switch (lang) {
        .brace => try reindentBraceLf(alloc, norm, at_line_start, anchor, cfg, &out),
        .python, .yaml => try reindentRelativeLf(alloc, norm, lang, at_line_start, anchor, cfg, &out),
        .markdown, .plain => unreachable,
    }
    const lf = try out.toOwnedSlice(alloc);
    defer alloc.free(lf);
    return withEnding(alloc, lf, ending);
}

/// A paste placement: insert `text` at `at`, replacing `delete_len` bytes of
/// the pre-edit document (`delete_len` is always the all-blank prefix of a
/// whitespace-only line; 0 for ordinary inserts).
pub const PastePlan = struct {
    text: []u8,
    at: u32,
    delete_len: u32,
};

/// Plan a paste/put insertion. When the insertion point is inside the leading
/// whitespace of a whitespace-only line (an indented blank line), the caller
/// must REPLACE that prefix instead of inserting after it: otherwise the
/// structural reindent's first-line indent would be added on top of the
/// existing indentation (4 spaces + 4 spaces = 8). The returned `at` is then
/// the line start and `delete_len` is the prefix length. The caller performs
/// one edit replacing [at, at+delete_len) with `text`.
pub fn planPaste(
    alloc: std.mem.Allocator,
    doc_before: []const u8,
    at_u32: u32,
    inserted: []const u8,
    ft: []const u8,
    cfg: Config,
    linewise: bool,
) !PastePlan {
    const at = @min(@as(usize, at_u32), doc_before.len);
    const line_start = lineStartOf(doc_before, at);
    const line_end = lineContentEndOf(doc_before, line_start);
    // Decide BEFORE changing the insertion point/delete range whether this
    // paste is structurally reindented at all. plaintext/Markdown/literal
    // contexts return the inserted bytes verbatim; deleting the line's blank
    // prefix for them would silently change the document (e.g. spaces inside
    // a Python triple-quoted string) and could also eat whitespace after the
    // cursor. Verbatim fallbacks keep at=original and delete_len=0.
    const norm_for_decision = try normalizeLf(alloc, inserted);
    defer alloc.free(norm_for_decision);
    const multi_line = std.mem.indexOfScalar(u8, norm_for_decision, '\n') != null;
    const structurally = canReindentNormalized(doc_before, at_u32, norm_for_decision, ft, linewise);
    var replace_len: u32 = 0;
    var insert_at = at;
    // Only a MULTI-LINE charwise paste into a whitespace-only line replaces
    // that line's indent prefix. A single-line paste is not reindented at all
    // (it must keep the indentation already before the cursor).
    if (structurally and !linewise and multi_line and at >= line_start and at <= line_end and
        isBlank(doc_before[line_start..line_end]))
    {
        replace_len = @intCast(line_end - line_start);
        insert_at = line_start;
    }
    const text = try reindentInsertion(alloc, doc_before, @intCast(insert_at), inserted, ft, cfg, linewise);
    return .{ .text = text, .at = @intCast(insert_at), .delete_len = replace_len };
}

// ============================== tests ======================================

const testing = std.testing;

fn expectPlan(
    doc: []const u8,
    cursor: u32,
    ft: []const u8,
    cfg: Config,
    expected: []const u8,
    expected_after: u32,
) !void {
    const alloc = testing.allocator;
    const p = try planEnter(alloc, doc, cursor, ft, cfg);
    defer alloc.free(p.text);
    try testing.expectEqualSlices(u8, expected, p.text);
    try testing.expectEqual(expected_after, p.cursor_after);
}

fn compose(alloc: std.mem.Allocator, doc: []const u8, at: u32, inserted: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, doc.len + inserted.len);
    @memcpy(out[0..at], doc[0..at]);
    @memcpy(out[at .. at + inserted.len], inserted);
    @memcpy(out[at + inserted.len ..], doc[at..]);
    return out;
}

fn cursorBetween(doc: []const u8, open: u8, close: u8) u32 {
    const o = std.mem.indexOfScalar(u8, doc, open).?;
    const c = std.mem.indexOfScalarPos(u8, doc, o + 1, close).?;
    return @intCast(c);
}

test "indent: languageForFiletype maps supported extensions" {
    try testing.expectEqual(Language.brace, languageForFiletype("zig"));
    try testing.expectEqual(Language.brace, languageForFiletype("ZIG"));
    try testing.expectEqual(Language.brace, languageForFiletype("rs"));
    try testing.expectEqual(Language.brace, languageForFiletype("tsx"));
    try testing.expectEqual(Language.python, languageForFiletype("py"));
    try testing.expectEqual(Language.python, languageForFiletype("PY"));
    try testing.expectEqual(Language.yaml, languageForFiletype("yaml"));
    try testing.expectEqual(Language.yaml, languageForFiletype("yml"));
    try testing.expectEqual(Language.markdown, languageForFiletype("md"));
    try testing.expectEqual(Language.plain, languageForFiletype("txt"));
    try testing.expectEqual(Language.plain, languageForFiletype(""));
    try testing.expectEqual(Language.plain, languageForFiletype("lua"));
}

test "indent: Enter between braces closes over an aligned closer" {
    const doc = "fn f() {}";
    const cur = cursorBetween(doc, '{', '}');
    try expectPlan(doc, cur, "zig", .{}, "\n    \n", 5);
    const alloc = testing.allocator;
    const p = try planEnter(alloc, doc, cur, "zig", .{});
    defer alloc.free(p.text);
    const out = try compose(alloc, doc, cur, p.text);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "fn f() {\n    \n}", out);
}

test "indent: Enter after an open brace at EOL indents one level" {
    try expectPlan("fn f() {", 8, "zig", .{}, "\n    ", 5);
    // Only spaces between the brace and the cursor.
    try expectPlan("fn f() {  ", 10, "zig", .{}, "\n    ", 5);
}

test "indent: Enter at EOL of an expanded brace gets an indented blank line" {
    const doc = "fn f() {\n}";
    try expectPlan(doc, 8, "zig", .{}, "\n    ", 5);
    const alloc = testing.allocator;
    const p = try planEnter(alloc, doc, 8, "zig", .{});
    defer alloc.free(p.text);
    const out = try compose(alloc, doc, 8, p.text);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "fn f() {\n    \n}", out);
}

test "indent: nested braces use the line's own indent and align the closer" {
    const doc = "fn f() {\n    if (x) {}\n}\n";
    const cur = cursorBetween(doc, '{', '}');
    try expectPlan(doc, cur, "zig", .{}, "\n        \n    ", 9);
    const alloc = testing.allocator;
    const p = try planEnter(alloc, doc, cur, "zig", .{});
    defer alloc.free(p.text);
    const out = try compose(alloc, doc, cur, p.text);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "fn f() {\n    if (x) {\n        \n    }\n}\n", out);
}

test "indent: an indented one-liner keeps its closer aligned" {
    const doc = "    fn f() {}";
    const cur = cursorBetween(doc, '{', '}');
    try expectPlan(doc, cur, "zig", .{}, "\n        \n    ", 9);
    const alloc = testing.allocator;
    const p = try planEnter(alloc, doc, cur, "zig", .{});
    defer alloc.free(p.text);
    const out = try compose(alloc, doc, cur, p.text);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "    fn f() {\n        \n    }", out);
}

test "indent: Enter on an indented blank line just copies the indent" {
    try expectPlan("    ", 4, "zig", .{}, "\n    ", 5);
}

test "indent: braces inside strings and comments do not indent" {
    // cursor is between the braces inside a string: copy leading indent only
    const s = "const s = \"{|\";";
    try expectPlan(s, 12, "zig", .{}, "\n", 1);
    // line comment
    try expectPlan("// {|}", 5, "zig", .{}, "\n", 1);
    // block comment
    try expectPlan("/* {|}", 5, "zig", .{}, "\n", 1);
    // already-typed string ending: no block pending
    try expectPlan("const s = \"{\";", 13, "zig", .{}, "\n", 1);
    // a `{` inside a string does not make the following `}` a block closer
    try expectPlan("const s = \"{  |}\";", 14, "zig", .{}, "\n", 1);
}

test "indent: tabs and configurable space width" {
    try expectPlan("fn f() {}", 8, "zig", .{ .use_tabs = true }, "\n\t\n", 2);
    try expectPlan("fn f() {}", 8, "zig", .{ .indent_width = 2 }, "\n  \n", 3);
    try expectPlan("fn f() {", 8, "zig", .{ .indent_width = 2 }, "\n  ", 3);
    try expectPlan("\tfn f() {}", 9, "zig", .{ .use_tabs = true }, "\n\t\t\n\t", 3);
}

test "indent: LF and CRLF buffers keep their own line ending" {
    const lf = "fn f() {}\n";
    try expectPlan(lf, 8, "zig", .{}, "\n    \n", 5);
    const crlf = "fn f() {}\r\n";
    try expectPlan(crlf, 8, "zig", .{}, "\r\n    \r\n", 6);
    const crlf_open = "fn f() {\r\n}";
    try expectPlan(crlf_open, 8, "zig", .{}, "\r\n    ", 6);
    // EOF of a CRLF file (last line has no terminator) inherits CRLF.
    try expectPlan("fn f() {\r\n    ok();", 15, "zig", .{}, "\r\n    ", 6);
}

test "indent: UTF-8 text before/after the cursor is preserved" {
    // CJK before the insertion point, emoji after it (not a closer).
    const doc = "fn 中文() {😀}";
    const cur = std.mem.indexOfScalar(u8, doc, '{').? + 1;
    try expectPlan(doc, @intCast(cur), "zig", .{}, "\n    ", 5);
    // CJK/emoji in a string do not affect block detection.
    try expectPlan("const s = \"中😀\"; fn f() {}", cursorBetween("const s = \"中😀\"; fn f() {}", '{', '}'), "zig", .{}, "\n    \n", 5);
}

test "indent: EOF and non-block brackets fall back to copy-indent" {
    try expectPlan("fn f() {", 8, "zig", .{}, "\n    ", 5);
    try expectPlan("call()", 6, "zig", .{}, "\n", 1);
    try expectPlan("let a = [1, 2]", 15, "zig", .{}, "\n", 1);
    try expectPlan("    call()", 10, "zig", .{}, "\n    ", 5);
}

test "indent: unknown filetypes keep today's copy-leading-indent" {
    try expectPlan("    fn f() {}", 13, "txt", .{}, "\n    ", 5);
    try expectPlan("    fn f() {", 13, "txt", .{}, "\n    ", 5);
    try expectPlan("fn f() {}", 8, "", .{}, "\n", 1);
}

test "indent: Python colon adds one level and triple strings do not" {
    try expectPlan("if x:", 5, "py", .{}, "\n    ", 5);
    try expectPlan("if x:  # note", 14, "py", .{}, "\n    ", 5);
    try expectPlan("def f():\n    if x:", 20, "py", .{}, "\n        ", 9);
    // Already indented blank line: Enter keeps the copied indent only.
    try expectPlan("def f():\n    ", 14, "py", .{}, "\n    ", 5);
    // Inside a triple-quoted body there is no structural indentation.
    try expectPlan("s = \"\"\"\nif x:", 14, "py", .{}, "\n", 1);
}

test "indent: YAML key colon adds one level" {
    try expectPlan("key:", 4, "yaml", .{ .indent_width = 2 }, "\n  ", 3);
    try expectPlan("root:\n  key:", 12, "yaml", .{ .indent_width = 2 }, "\n    ", 5);
    // Block scalar body: keep the current indentation, do not add a level.
    try expectPlan("key: |\n  body", 14, "yaml", .{ .indent_width = 2 }, "\n  ", 3);
}

test "indent: paste into a whitespace-only line replaces the prefix exactly once" {
    const alloc = testing.allocator;
    const doc = "fn main() void {\n    \n}\n";
    // cursor is after the four spaces on the otherwise blank body line
    const at: u32 = 21;
    const plan = try planPaste(alloc, doc, at, "if (ok) {\ncall();\n}", "zig", .{}, false);
    defer alloc.free(plan.text);
    try testing.expectEqual(@as(u32, 17), plan.at);
    try testing.expectEqual(@as(u32, 4), plan.delete_len);
    try testing.expectEqualSlices(u8, "    if (ok) {\n        call();\n    }", plan.text);
    // Replacing the blank prefix yields the required final document bytes.
    const out = try alloc.alloc(u8, doc.len - plan.delete_len + plan.text.len);
    defer alloc.free(out);
    @memcpy(out[0..plan.at], doc[0..plan.at]);
    @memcpy(out[plan.at .. plan.at + plan.text.len], plan.text);
    @memcpy(out[plan.at + plan.text.len ..], doc[plan.at + plan.delete_len ..]);
    try testing.expectEqualSlices(
        u8,
        "fn main() void {\n    if (ok) {\n        call();\n    }\n}\n",
        out,
    );

    // Cursor in the MIDDLE of the blank line's whitespace: the whole blank
    // prefix is replaced, not duplicated/left as trailing spaces.
    const mid = "fn main() void {\n    \n}\n";
    const mid_plan = try planPaste(alloc, mid, 19, "if (ok) {\ncall();\n}", "zig", .{}, false);
    defer alloc.free(mid_plan.text);
    try testing.expectEqual(@as(u32, 17), mid_plan.at);
    try testing.expectEqual(@as(u32, 4), mid_plan.delete_len);
    try testing.expectEqualSlices(u8, "    if (ok) {\n        call();\n    }", mid_plan.text);

    // A single-line charwise paste is NOT reindented: keep the spaces that
    // are already before the cursor (no prefix replacement).
    const one = try planPaste(alloc, doc, 21, "X", "zig", .{}, false);
    defer alloc.free(one.text);
    try testing.expectEqual(@as(u32, 21), one.at);
    try testing.expectEqual(@as(u32, 0), one.delete_len);
    try testing.expectEqualSlices(u8, "X", one.text);

    // Same for a tab-indented blank line: the tab prefix is replaced, and
    // the structural indent uses tabs.
    const tab_doc = "fn main() void {\n\t\n}\n";
    const tab_plan = try planPaste(alloc, tab_doc, 18, "if (ok) {\ncall();\n}", "zig", .{ .use_tabs = true }, false);
    defer alloc.free(tab_plan.text);
    try testing.expectEqual(@as(u32, 17), tab_plan.at);
    try testing.expectEqual(@as(u32, 1), tab_plan.delete_len);
    try testing.expectEqualSlices(u8, "\tif (ok) {\n\t\tcall();\n\t}", tab_plan.text);
}

test "indent: reindent a nested Zig block into a 4-space body" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10; // start of the empty body line
    const out = try reindentInsertion(alloc, doc, at, "if (ok) {\ncall();\n}", "zig", .{}, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "    if (ok) {\n        call();\n    }", out);
}

test "indent: already-correct pasted block is unchanged" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10;
    const correct = "    if (ok) {\n        call();\n    }";
    const out = try reindentInsertion(alloc, doc, at, correct, "zig", .{}, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, correct, out);
}

test "indent: paste keeps tabs and configured two-space style" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10;
    const tabs = try reindentInsertion(alloc, doc, at, "if (ok) {\ncall();\n}", "zig", .{ .use_tabs = true }, false);
    defer alloc.free(tabs);
    try testing.expectEqualSlices(u8, "\tif (ok) {\n\t\tcall();\n\t}", tabs);
    const two = try reindentInsertion(alloc, doc, at, "if (ok) {\ncall();\n}", "zig", .{ .indent_width = 2 }, false);
    defer alloc.free(two);
    try testing.expectEqualSlices(u8, "  if (ok) {\n    call();\n  }", two);
}

test "indent: paste preserves CRLF buffers" {
    const alloc = testing.allocator;
    const doc = "fn f() {\r\n\r\n}\r\n";
    const at: u32 = 10; // after "fn f() {\r\n"
    const out = try reindentInsertion(alloc, doc, at, "if (ok) {\r\ncall();\r\n}", "zig", .{}, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "    if (ok) {\r\n        call();\r\n    }", out);
}

test "indent: paste strips blank-line whitespace and reindents trailing line" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10;
    const out = try reindentInsertion(alloc, doc, at, "if (a) {\n   \n    x();", "zig", .{}, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "    if (a) {\n\n        x();", out);
}

test "indent: paste ignores braces in Zig comments and line strings" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10;
    const with_comments = try reindentInsertion(
        alloc,
        doc,
        at,
        "if (a) {\n    // { not a block\n    x(); // } not a closer\n}",
        "zig",
        .{},
        false,
    );
    defer alloc.free(with_comments);
    try testing.expectEqualSlices(
        u8,
        "    if (a) {\n        // { not a block\n        x(); // } not a closer\n    }",
        with_comments,
    );

    // Zig multiline `\\` string lines keep their exact bytes (they are
    // literal content); the closing `;` line is reindented normally.
    const literal = try reindentInsertion(
        alloc,
        doc,
        at,
        "const s =\n      \\\\hello {\n      \\\\world\n;",
        "zig",
        .{},
        false,
    );
    defer alloc.free(literal);
    try testing.expectEqualSlices(
        u8,
        "    const s =\n      \\\\hello {\n      \\\\world\n    ;",
        literal,
    );

    // A block comment body is literal too; the code around it reindents.
    const block = try reindentInsertion(
        alloc,
        doc,
        at,
        "/* {\n   literal body }\n*/\nx();",
        "zig",
        .{},
        false,
    );
    defer alloc.free(block);
    try testing.expectEqualSlices(u8, "    /* {\n   literal body }\n*/\n    x();", block);
}

test "indent: paste after a Zig multiline string uses the following code line" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n    const s =\n        \\hello\n    ;\n}\n";
    const at: u32 = @intCast(std.mem.indexOf(u8, doc, "    ;").?);
    const out = try reindentInsertion(alloc, doc, at, "if (x) {\nfoo();\n}", "zig", .{}, true);
    defer alloc.free(out);
    // The `;` line is indented 4, not the 8 of the `\\\\hello` literal line.
    try testing.expectEqualSlices(u8, "    if (x) {\n        foo();\n    }", out);
}

test "indent: charwise vs linewise paste rules" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n\n}\n";
    const at: u32 = 10; // start of the empty body line

    // linewise: the single pasted line is a whole line and is anchored.
    const linewise = try reindentInsertion(alloc, doc, at, "call();", "zig", .{}, true);
    defer alloc.free(linewise);
    try testing.expectEqualSlices(u8, "    call();", linewise);

    // charwise single-line: not reindented.
    const charwise = try reindentInsertion(alloc, doc, at, "call();", "zig", .{}, false);
    defer alloc.free(charwise);
    try testing.expectEqualSlices(u8, "call();", charwise);

    // charwise multi-line paste continues the current line and anchors only
    // the following lines.
    const mid_doc = "fn f() {\n    x = \n}\n";
    const mid_at: u32 = 17; // after "    x = " (before the newline)
    const mid = try reindentInsertion(alloc, mid_doc, mid_at, "foo(1,\n2);", "zig", .{}, false);
    defer alloc.free(mid);
    try testing.expectEqualSlices(u8, "foo(1,\n    2);", mid);
}

test "indent: Python paste shifts relative indentation and keeps triple bodies" {
    const alloc = testing.allocator;
    const doc = "def f():\n\n";
    const at: u32 = 9;
    const out = try reindentInsertion(alloc, doc, at, "if x:\n    pass\n", "py", .{}, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "    if x:\n        pass\n", out);

    const already = try reindentInsertion(alloc, doc, at, "    if x:\n        pass\n", "py", .{}, false);
    defer alloc.free(already);
    try testing.expectEqualSlices(u8, "    if x:\n        pass\n", already);

    // Triple-quoted body lines (including the closing delimiter line) are
    // literal and must not be re-indented.
    const triple = try reindentInsertion(
        alloc,
        doc,
        at,
        "s = \"\"\"\n  body {\n\"\"\"\nprint(s)\n",
        "py",
        .{},
        false,
    );
    defer alloc.free(triple);
    try testing.expectEqualSlices(u8, "    s = \"\"\"\n  body {\n\"\"\"\n    print(s)\n", triple);
}

test "indent: YAML paste shifts relative indentation but keeps block scalars" {
    const alloc = testing.allocator;
    const doc = "root:\n\n";
    const at: u32 = 6;
    const out = try reindentInsertion(alloc, doc, at, "a: 1\nb:\n  - x\n", "yaml", .{ .indent_width = 2 }, false);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, "  a: 1\n  b:\n    - x\n", out);

    const scalar = try reindentInsertion(alloc, doc, at, "key: |\n  body\n", "yaml", .{ .indent_width = 2 }, false);
    defer alloc.free(scalar);
    try testing.expectEqualSlices(u8, "key: |\n  body\n", scalar);
}

test "indent: Markdown and unknown filetypes keep pasted content" {
    const alloc = testing.allocator;
    const doc = "text\n\n";
    const at: u32 = 5;
    const md = try reindentInsertion(alloc, doc, at, "```zig\nfn f() {}\n```\n", "md", .{}, false);
    defer alloc.free(md);
    try testing.expectEqualSlices(u8, "```zig\nfn f() {}\n```\n", md);

    const plain = try reindentInsertion(alloc, doc, at, "if (x) {\n  y\n}\n", "txt", .{}, false);
    defer alloc.free(plain);
    try testing.expectEqualSlices(u8, "if (x) {\n  y\n}\n", plain);
}

/// Apply a PastePlan to build the bytes a caller would save. Used to assert
/// the ASSEMBLED result (not only the reindented string), because deleting a
/// blank prefix is part of the plan.
fn applyPastePlan(alloc: std.mem.Allocator, doc: []const u8, plan: PastePlan) ![]u8 {
    std.debug.assert(plan.at + plan.delete_len <= doc.len);
    const out = try alloc.alloc(u8, doc.len - plan.delete_len + plan.text.len);
    const at: usize = plan.at;
    const del: usize = plan.delete_len;
    @memcpy(out[0..at], doc[0..at]);
    @memcpy(out[at .. at + plan.text.len], plan.text);
    @memcpy(out[at + plan.text.len ..], doc[at + del ..]);
    return out;
}

test "indent paste plan: literal contexts keep the blank prefix (P1 regression)" {
    const alloc = testing.allocator;

    // Python triple-quoted body: the four spaces are CONTENT. A verbatim
    // fallback must not delete them (pre-fix save lost all four).
    {
        const doc = "s = \"\"\"\n    \n\"\"\"\n";
        const at: u32 = 12; // after four spaces on the middle line
        const plan = try planPaste(alloc, doc, at, "a\nb", "py", .{}, false);
        defer alloc.free(plan.text);
        try testing.expectEqual(@as(u32, 12), plan.at);
        try testing.expectEqual(@as(u32, 0), plan.delete_len);
        try testing.expectEqualStrings("a\nb", plan.text);
        const saved = try applyPastePlan(alloc, doc, plan);
        defer alloc.free(saved);
        try testing.expectEqualStrings("s = \"\"\"\n    a\nb\n\"\"\"\n", saved);
    }
    // Markdown: no structural reindent, no prefix deletion.
    {
        const doc = "text\n\n";
        const plan = try planPaste(alloc, doc, 5, "a\nb", "md", .{}, false);
        defer alloc.free(plan.text);
        try testing.expectEqual(@as(u32, 5), plan.at);
        try testing.expectEqual(@as(u32, 0), plan.delete_len);
        try testing.expectEqualStrings("a\nb", plan.text);
    }
    // Unknown filetype: same safe fallback.
    {
        const doc = "note\n\n";
        const plan = try planPaste(alloc, doc, 5, "  a\n  b", "txt", .{}, false);
        defer alloc.free(plan.text);
        try testing.expectEqual(@as(u32, 5), plan.at);
        try testing.expectEqual(@as(u32, 0), plan.delete_len);
        try testing.expectEqualStrings("  a\n  b", plan.text);
    }
}

test "indent paste plan: structural blank line replaces only its indent prefix" {
    const alloc = testing.allocator;
    const doc = "fn f() {\n    \n}\n";
    const line2_start: u32 = 9;
    const at: u32 = line2_start + 2; // cursor in the MIDDLE of the 4-space prefix
    const plan = try planPaste(alloc, doc, at, "if (ok) {\ncall();\n}", "zig", .{}, false);
    defer alloc.free(plan.text);
    try testing.expectEqual(line2_start, plan.at);
    try testing.expectEqual(@as(u32, 4), plan.delete_len);
    try testing.expectEqualStrings("    if (ok) {\n        call();\n    }", plan.text);
    const saved = try applyPastePlan(alloc, doc, plan);
    defer alloc.free(saved);
    try testing.expectEqualStrings("fn f() {\n    if (ok) {\n        call();\n    }\n}\n", saved);
}
