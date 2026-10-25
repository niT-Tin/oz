//! Inline assistant (M2b2): pure request, replacement, diff and pending-edit
//! model.
//!
//! Deliberately App/vaxis-independent: `src/app/inline_ui.zig` owns the
//! prompt, the background client, apply/reject and rendering. Everything
//! here is unit-testable without constructing an editor or a terminal.
//!
//! The inline request is *not* a chat-thread turn: the request body contains
//! only the fixed edit system prompt and one user message built from the
//! selected range. No `Threads` state is read or written.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;
const utf8 = @import("../buffer/utf8.zig");
const openai = @import("../ai/openai.zig");

/// Selected text included in the request is bounded so a huge visual
/// selection cannot turn one keystroke into a multi-megabyte prompt. The
/// bound is applied on a UTF-8 boundary; the full selection is still stored
/// for the pending edit/diff/approval.
pub const max_selection_bytes: usize = 16 * 1024;

/// Hard cap on a streamed replacement. A runaway model must not exhaust the
/// editor's memory; the request fails with an explicit error instead.
pub const max_replacement_bytes: usize = 256 * 1024;

/// Line-diff LCS is only attempted up to this many lines per side; bigger
/// selections fall back to a truthful "all removed, all added" diff.
pub const max_diff_lines: usize = 400;

/// Fixed system prompt: replacement text only, no fences/explanations.
pub const system_prompt =
    "You are an inline code editor. Replace the selected code with the replacement requested by the user.\n" ++
    "Return ONLY the replacement text for the selected code. Do not wrap it in code fences, do not add explanations, and do not repeat the surrounding file unless the instruction explicitly asks for it.";

/// One resolved byte/line range in a buffer.
pub const Range = struct {
    /// Half-open byte range [start, end).
    start: u32,
    end: u32,
    /// 0-based first/last line covered by the range (inclusive last).
    first_line: u32,
    last_line: u32,
    linewise: bool,

    pub fn lineCount(self: Range) u32 {
        return self.last_line - self.first_line + 1;
    }
};

fn clampPos(pt: *const PieceTable, pos: u32) u32 {
    return @min(pos, pt.len());
}

fn charLenAt(pt: *const PieceTable, pos: u32) u32 {
    if (pos >= pt.len()) return 1;
    var buf: [4]u8 = undefined;
    const n: usize = @intCast(@min(@as(u32, 4), pt.len() - pos));
    pt.copyRange(pos, buf[0..n]);
    return @max(@as(u32, utf8.decodeAt(buf[0..n], 0).len), 1);
}

/// Vim visual-selection semantics in one place.
///
/// Linewise selection covers whole lines from the anchor line through the
/// cursor line, including the trailing newline when one exists. Character
/// selection is inclusive of the character under the cursor.
pub fn computeRange(pt: *const PieceTable, visual_line: bool, anchor: u32, cursor: u32) Range {
    const a = clampPos(pt, anchor);
    const c = clampPos(pt, cursor);
    if (visual_line) {
        const first = pt.lineOf(@min(a, c));
        const last = pt.lineOf(@max(a, c));
        const start = pt.lineStart(first);
        var end = pt.lineStart(last) + pt.lineLen(last);
        if (end < pt.len()) end += 1; // include the selected lines' newline
        return .{ .start = start, .end = end, .first_line = first, .last_line = last, .linewise = true };
    }
    const start = @min(a, c);
    var end = @max(a, c);
    if (end < pt.len()) end = @min(end + charLenAt(pt, end), pt.len());
    return .{
        .start = start,
        .end = end,
        .first_line = pt.lineOf(start),
        .last_line = pt.lineOf(start +| (end -| start) -| 1),
        .linewise = false,
    };
}

/// Copy the selected bytes. Caller owns the result.
pub fn selectionText(alloc: std.mem.Allocator, pt: *const PieceTable, range: Range) ![]u8 {
    const len = range.end - range.start;
    const out = try alloc.alloc(u8, len);
    if (len > 0) pt.copyRange(range.start, out);
    return out;
}

/// Largest prefix of `text` that is at most `max_bytes` and ends on a UTF-8
/// boundary (0 when the first character alone is already too large).
pub fn boundedUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and !utf8.isBoundary(text, end)) end -= 1;
    return text[0..end];
}

/// Human/request-facing one-based line label.
pub fn lineLabel(range: Range) struct { first: u32, last: u32 } {
    return .{ .first = range.first_line + 1, .last = range.last_line + 1 };
}

/// Build the single user message for an inline edit request. `selected` is
/// already display-safe; it is bounded again here so callers cannot forget.
pub fn buildUserMessage(
    alloc: std.mem.Allocator,
    path: ?[]const u8,
    range: Range,
    instruction: []const u8,
    selected: []const u8,
) ![]u8 {
    const lines = lineLabel(range);
    const bounded = boundedUtf8(selected, max_selection_bytes);
    const truncated = bounded.len < selected.len;
    const name = path orelse "[No Name]";
    return std.fmt.allocPrint(
        alloc,
        "File: {s}\nSelection: lines {d}-{d} (1-based, inclusive)\nInstruction:\n{s}\nSelected text ({d} bytes{s}):\n{s}",
        .{
            name,
            lines.first,
            lines.last,
            instruction,
            selected.len,
            if (truncated) ", truncated for the request" else "",
            bounded,
        },
    );
}

/// Build the complete inline request body: fixed system prompt + one user
/// message. This never consults chat-thread messages.
pub fn buildRequestBody(
    alloc: std.mem.Allocator,
    model: []const u8,
    path: ?[]const u8,
    range: Range,
    instruction: []const u8,
    selected: []const u8,
) ![]u8 {
    const user = try buildUserMessage(alloc, path, range, instruction, selected);
    defer alloc.free(user);
    const msgs = [_]openai.Message{.{ .role = "user", .content = user }};
    return openai.buildRequestBody(alloc, model, system_prompt, &msgs);
}

/// Strip a *clearly fenced* replacement: the first non-empty line is a
/// ```[lang] fence *and* the last non-empty line is a closing ```. Anything
/// else is returned byte-for-byte (models sometimes use a fence mid-text, and
/// silently deleting that would corrupt the replacement).
pub fn stripFences(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var start: usize = 0;
    while (start < raw.len and (raw[start] == '\n' or raw[start] == '\r')) start += 1;
    var end: usize = raw.len;
    while (end > start and (raw[end - 1] == '\n' or raw[end - 1] == '\r' or raw[end - 1] == ' ' or raw[end - 1] == '\t')) end -= 1;
    if (start >= end) return alloc.dupe(u8, raw);

    const first_nl_rel = std.mem.indexOfScalar(u8, raw[start..end], '\n');
    const first_nl = if (first_nl_rel) |i| start + i else null;
    const open_end = first_nl orelse end;
    const open = std.mem.trim(u8, raw[start..open_end], " \t\r");
    if (!isOpeningFence(open)) return alloc.dupe(u8, raw);

    // Last non-empty line.
    var last_end = end;
    while (last_end > start and (raw[last_end - 1] == ' ' or raw[last_end - 1] == '\t')) last_end -= 1;
    const last_line_start = if (std.mem.lastIndexOfScalar(u8, raw[start..last_end], '\n')) |i| start + i + 1 else start;
    const close = std.mem.trim(u8, raw[last_line_start..last_end], " \t\r");
    if (last_line_start <= start or !std.mem.eql(u8, close, "```")) return alloc.dupe(u8, raw);

    // Content is between the opening fence's newline and the newline that
    // precedes the closing fence (the closing fence's own line break is not
    // part of the replacement).
    const content_start = (first_nl orelse return alloc.dupe(u8, raw)) + 1;
    var content_end = last_line_start;
    if (content_end > content_start and raw[content_end - 1] == '\n') content_end -= 1;
    if (content_end > content_start and raw[content_end - 1] == '\r') content_end -= 1;
    if (content_start > content_end) return alloc.dupe(u8, raw);
    return alloc.dupe(u8, raw[content_start..content_end]);
}

fn isOpeningFence(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "```")) return false;
    for (trimmed[3..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+' and c != '.' and c != '#') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

pub const DiffKind = enum { context, removed, added };

pub const DiffLine = struct {
    kind: DiffKind,
    text: []u8,
};

pub const DiffStats = struct { removed: u32 = 0, added: u32 = 0 };

/// Split into display lines without their trailing newline. A trailing
/// newline does not create a phantom empty line; `""` has no lines.
pub fn splitLines(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    if (text.len == 0) return out.toOwnedSlice(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        try out.append(alloc, text[start..i]);
        start = i + 1;
    }
    if (start < text.len) try out.append(alloc, text[start..]);
    return out.toOwnedSlice(alloc);
}

fn freeDiff(alloc: std.mem.Allocator, diff: []DiffLine) void {
    for (diff) |d| alloc.free(d.text);
    alloc.free(diff);
}

/// Diff lines are terminal display text: expand tabs (same four-space width
/// as the editor) and replace other control bytes so a CRLF file or an
/// accidental escape cannot break the rail's cell grid. Shared with the
/// `apply_patch` review preview (`agent_patch.zig`).
pub fn dupeDisplayLine(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (line) |c| {
        switch (c) {
            '\t' => try out.appendSlice(alloc, "    "),
            '\r' => {},
            else => {
                if (c < 0x20) try out.append(alloc, ' ') else try out.append(alloc, c);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Truthful line diff: an LCS over display lines when both sides are small
/// enough, otherwise every original line removed followed by every
/// replacement line added. Never invents equal lines. Caller owns the result.
pub fn buildDiff(alloc: std.mem.Allocator, original: []const u8, replacement: []const u8) ![]DiffLine {
    const orig = try splitLines(alloc, original);
    defer alloc.free(orig);
    const repl = try splitLines(alloc, replacement);
    defer alloc.free(repl);

    var out: std.ArrayList(DiffLine) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d.text);
        out.deinit(alloc);
    }

    if (orig.len > max_diff_lines or repl.len > max_diff_lines) {
        for (orig) |line| try out.append(alloc, .{ .kind = .removed, .text = try dupeDisplayLine(alloc, line) });
        for (repl) |line| try out.append(alloc, .{ .kind = .added, .text = try dupeDisplayLine(alloc, line) });
        return out.toOwnedSlice(alloc);
    }

    const n = orig.len;
    const m = repl.len;
    const width = m + 1;
    const dp = try alloc.alloc(u32, (n + 1) * width);
    defer alloc.free(dp);
    @memset(dp, 0);
    var i = n;
    while (i > 0) {
        i -= 1;
        var j = m;
        while (j > 0) {
            j -= 1;
            dp[i * width + j] = if (std.mem.eql(u8, orig[i], repl[j]))
                dp[(i + 1) * width + (j + 1)] + 1
            else
                @max(dp[(i + 1) * width + j], dp[i * width + (j + 1)]);
        }
    }
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, orig[i], repl[j])) {
            try out.append(alloc, .{ .kind = .context, .text = try dupeDisplayLine(alloc, orig[i]) });
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * width + j] >= dp[i * width + (j + 1)]) {
            try out.append(alloc, .{ .kind = .removed, .text = try dupeDisplayLine(alloc, orig[i]) });
            i += 1;
        } else {
            try out.append(alloc, .{ .kind = .added, .text = try dupeDisplayLine(alloc, repl[j]) });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try out.append(alloc, .{ .kind = .removed, .text = try dupeDisplayLine(alloc, orig[i]) });
    while (j < m) : (j += 1) try out.append(alloc, .{ .kind = .added, .text = try dupeDisplayLine(alloc, repl[j]) });
    return out.toOwnedSlice(alloc);
}

pub fn diffStats(diff: []const DiffLine) DiffStats {
    var s: DiffStats = .{};
    for (diff) |d| switch (d.kind) {
        .removed => s.removed += 1,
        .added => s.added += 1,
        .context => {},
    };
    return s;
}

// ---------------------------------------------------------------------------
// Snapshot / pending edit
// ---------------------------------------------------------------------------

/// Immutable snapshot taken when the prompt opens: the range and bytes the
/// replacement targets. Owns `path`/`text`.
pub const Snapshot = struct {
    buffer_index: usize,
    path: ?[]u8,
    range: Range,
    text: []u8,
    revision: u64,

    pub fn init(
        alloc: std.mem.Allocator,
        buffer_index: usize,
        path: ?[]const u8,
        range: Range,
        text: []const u8,
        revision: u64,
    ) !Snapshot {
        const path_copy = if (path) |p| try alloc.dupe(u8, p) else null;
        errdefer if (path_copy) |p| alloc.free(p);
        const text_copy = try alloc.dupe(u8, text);
        errdefer alloc.free(text_copy);
        return .{
            .buffer_index = buffer_index,
            .path = path_copy,
            .range = range,
            .text = text_copy,
            .revision = revision,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        if (self.path) |p| alloc.free(p);
        alloc.free(self.text);
        self.* = undefined;
    }
};

/// A completed replacement awaiting human approval. Owns every slice and the
/// rendered diff (computed once, on completion — never per frame).
pub const Pending = struct {
    buffer_index: usize,
    path: ?[]u8,
    start: u32,
    end: u32,
    first_line: u32,
    last_line: u32,
    original: []u8,
    replacement: []u8,
    revision: u64,
    diff: []DiffLine,
    removed: u32,
    added: u32,
    /// Set when approval found the buffer revision/path/range changed.
    /// Purely a display/lifecycle marker: apply is refused either way.
    stale: bool = false,

    pub fn init(alloc: std.mem.Allocator, snap: *const Snapshot, replacement: []const u8) !Pending {
        const path_copy = if (snap.path) |p| try alloc.dupe(u8, p) else null;
        errdefer if (path_copy) |p| alloc.free(p);
        const original = try alloc.dupe(u8, snap.text);
        errdefer alloc.free(original);
        const repl = try alloc.dupe(u8, replacement);
        errdefer alloc.free(repl);
        const diff = try buildDiff(alloc, snap.text, replacement);
        errdefer freeDiff(alloc, diff);
        const stats = diffStats(diff);
        return .{
            .buffer_index = snap.buffer_index,
            .path = path_copy,
            .start = snap.range.start,
            .end = snap.range.end,
            .first_line = snap.range.first_line + 1,
            .last_line = snap.range.last_line + 1,
            .original = original,
            .replacement = repl,
            .revision = snap.revision,
            .diff = diff,
            .removed = stats.removed,
            .added = stats.added,
        };
    }

    pub fn deinit(self: *Pending, alloc: std.mem.Allocator) void {
        if (self.path) |p| alloc.free(p);
        alloc.free(self.original);
        alloc.free(self.replacement);
        freeDiff(alloc, self.diff);
        self.* = undefined;
    }

    pub fn lineCount(self: *const Pending) u32 {
        return self.last_line - self.first_line + 1;
    }

    pub fn isStale(self: *const Pending, revision: u64) bool {
        return self.stale or self.revision != revision;
    }
};

/// Pure one-pending policy helper: a new inline request is only allowed when
/// no replacement is waiting for review.
pub fn canStart(pending: bool, prompting: bool) bool {
    return !pending and !prompting;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testPt(alloc: std.mem.Allocator, text: []const u8) !PieceTable {
    return PieceTable.init(alloc, text);
}

test "inline: linewise range includes whole lines and newline" {
    const alloc = testing.allocator;
    var pt = try testPt(alloc, "one\ntwo\nthree\n");
    defer pt.deinit();
    // anchor on "two", cursor on "three"
    const r = computeRange(&pt, true, 4, 8);
    try testing.expect(r.linewise);
    try testing.expectEqual(@as(u32, 4), r.start);
    try testing.expectEqual(@as(u32, 14), r.end); // "two\nthree\n"
    try testing.expectEqual(@as(u32, 1), r.first_line);
    try testing.expectEqual(@as(u32, 2), r.last_line);
    const text = try selectionText(alloc, &pt, r);
    defer alloc.free(text);
    try testing.expectEqualStrings("two\nthree\n", text);
}

test "inline: linewise range on the last line without trailing newline" {
    const alloc = testing.allocator;
    var pt = try testPt(alloc, "a\nb");
    defer pt.deinit();
    const r = computeRange(&pt, true, 0, 2);
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
    try testing.expectEqual(@as(u32, 0), r.first_line);
    try testing.expectEqual(@as(u32, 1), r.last_line);
}

test "inline: charwise range is inclusive of the cursor codepoint" {
    const alloc = testing.allocator;
    var pt = try testPt(alloc, "héllo");
    defer pt.deinit();
    const r = computeRange(&pt, false, 0, 1); // cursor is on é (2 bytes)
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
    const text = try selectionText(alloc, &pt, r);
    defer alloc.free(text);
    try testing.expectEqualStrings("hé", text);
}

test "inline: reversed charwise selection normalizes" {
    const alloc = testing.allocator;
    var pt = try testPt(alloc, "abcdef");
    defer pt.deinit();
    const r = computeRange(&pt, false, 3, 1);
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 4), r.end);
}

test "inline: boundedUtf8 never splits a codepoint" {
    try testing.expectEqualStrings("ab", boundedUtf8("abc", 2));
    try testing.expectEqualStrings("a", boundedUtf8("aé", 2));
    try testing.expectEqualStrings("", boundedUtf8("é", 1));
    try testing.expectEqualStrings("aé", boundedUtf8("aé", 3));
}

test "inline: user message carries path, range, instruction and selection" {
    const alloc = testing.allocator;
    const r = Range{ .start = 0, .end = 3, .first_line = 3, .last_line = 5, .linewise = true };
    const msg = try buildUserMessage(alloc, "src/main.zig", r, "rename answer", "const answer = 42;");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "lines 4-6") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "rename answer") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "const answer = 42;") != null);
}

test "inline: request body is standalone and never a chat transcript" {
    const alloc = testing.allocator;
    const r = Range{ .start = 0, .end = 4, .first_line = 0, .last_line = 0, .linewise = true };
    const body = try buildRequestBody(alloc, "mock-model", "a.zig", r, "uppercase", "abcd");
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"mock-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, body, "uppercase") != null);
    try testing.expect(std.mem.indexOf(u8, body, "abcd") != null);
    // Only the system + the one inline user turn: no prior chat content.
    try testing.expect(std.mem.indexOf(u8, body, "You are an inline code editor") != null);
    try testing.expect(std.mem.indexOf(u8, body, "assistant") == null);
    try testing.expect(std.mem.indexOf(u8, body, "thread") == null);
}

test "inline: stripFences removes only a clearly fenced replacement" {
    const alloc = testing.allocator;
    const fenced = try stripFences(alloc, "```zig\nconst x = 1;\n```\n");
    defer alloc.free(fenced);
    try testing.expectEqualStrings("const x = 1;", fenced);

    const prose = try stripFences(alloc, "const x = 1;\n```");
    defer alloc.free(prose);
    try testing.expectEqualStrings("const x = 1;\n```", prose);

    const inner = try stripFences(alloc, "a\n```\nb\n");
    defer alloc.free(inner);
    try testing.expectEqualStrings("a\n```\nb\n", inner);

    const plain = try stripFences(alloc, "hello\n");
    defer alloc.free(plain);
    try testing.expectEqualStrings("hello\n", plain);
}

test "inline: diff is a real LCS with context lines" {
    const alloc = testing.allocator;
    const diff = try buildDiff(alloc, "a\nb\nc\n", "a\nB\nc\n");
    defer freeDiff(alloc, diff);
    try testing.expectEqual(@as(usize, 4), diff.len);
    try testing.expectEqual(DiffKind.context, diff[0].kind);
    try testing.expectEqualStrings("a", diff[0].text);
    try testing.expectEqual(DiffKind.removed, diff[1].kind);
    try testing.expectEqualStrings("b", diff[1].text);
    try testing.expectEqual(DiffKind.added, diff[2].kind);
    try testing.expectEqualStrings("B", diff[2].text);
    try testing.expectEqual(DiffKind.context, diff[3].kind);
    const stats = diffStats(diff);
    try testing.expectEqual(@as(u32, 1), stats.removed);
    try testing.expectEqual(@as(u32, 1), stats.added);
}

test "inline: diff handles empty and trailing-newline text" {
    const alloc = testing.allocator;
    const add = try buildDiff(alloc, "", "x\n");
    defer freeDiff(alloc, add);
    try testing.expectEqual(@as(usize, 1), add.len);
    try testing.expectEqual(DiffKind.added, add[0].kind);
    try testing.expectEqualStrings("x", add[0].text);

    const del = try buildDiff(alloc, "x\n", "");
    defer freeDiff(alloc, del);
    try testing.expectEqual(@as(usize, 1), del.len);
    try testing.expectEqual(DiffKind.removed, del[0].kind);

    const blank = try buildDiff(alloc, "a\n\n", "a\n");
    defer freeDiff(alloc, blank);
    try testing.expectEqual(@as(usize, 2), blank.len);
    try testing.expectEqual(DiffKind.removed, blank[1].kind);
    try testing.expectEqualStrings("", blank[1].text);
}

test "inline: diff display lines expand tabs and drop CR" {
    const alloc = testing.allocator;
    const diff = try buildDiff(alloc, "a\tb\r\nold\n", "a\tb\r\nnew\n");
    defer freeDiff(alloc, diff);
    try testing.expectEqual(@as(usize, 3), diff.len);
    try testing.expectEqualStrings("a    b", diff[0].text);
    try testing.expectEqualStrings("old", diff[1].text);
    try testing.expectEqualStrings("new", diff[2].text);
}

test "inline: pending owns its snapshot and detects revision changes" {
    const alloc = testing.allocator;
    var pt = try testPt(alloc, "abcdef");
    defer pt.deinit();
    const range = computeRange(&pt, false, 0, 2);
    var snap = try Snapshot.init(alloc, 0, "f.zig", range, "abc", 7);
    defer snap.deinit(alloc);
    var pending = try Pending.init(alloc, &snap, "XYZ");
    defer pending.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), pending.buffer_index);
    try testing.expectEqual(@as(u32, 0), pending.start);
    try testing.expectEqual(@as(u32, 3), pending.end);
    try testing.expectEqualStrings("abc", pending.original);
    try testing.expectEqualStrings("XYZ", pending.replacement);
    try testing.expect(!pending.isStale(7));
    try testing.expect(pending.isStale(8));
    pending.stale = true;
    try testing.expect(pending.isStale(7));
}

test "inline: one-pending policy" {
    try testing.expect(canStart(false, false));
    try testing.expect(!canStart(true, false));
    try testing.expect(!canStart(false, true));
    try testing.expect(!canStart(true, true));
}
