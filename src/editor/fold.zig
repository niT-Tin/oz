//! Indent-based code folding (za/zo/zc/zR/zM).
//!
//! Pure detection logic over a PieceTable — no editor state lives here; the
//! set of CLOSED folds is owned by the app (one per buffer, see main.zig).
//!
//! Why indent and not tree-sitter: the highlighter's parse tree is
//! per-buffer and lazily built, but walking it for "block-ish node spanning
//! multiple lines" needs per-language node-name rules plus a generic
//! fallback anyway. The indent rule below is language-agnostic, works for
//! brace languages (zig/rust/c), python and yaml alike, needs no parse, and
//! is trivially testable. A tree-sitter refinement can later replace
//! `rangeAt`/`allRanges` behind the same interface (the fold STATE and
//! rendering do not care how a range was found).
//!
//! Rule: a line opens a fold when the next non-blank line is indented
//! deeper. The fold body is the maximal run of deeper-indented lines; blank
//! lines never break the run, but trailing blank lines are not part of the
//! fold body (so folding a function does not swallow the empty separator
//! line after it). `end` is inclusive: lines `start + 1 ..= end` are hidden
//! when the fold is closed.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// Expanded indent column: tabs count as 4, matching the editor's
/// tab_width (indent guides render at the same width).
pub const tab_width: u32 = 4;

/// A foldable range of document lines. `start` holds the header line (the
/// one that stays visible with the "N lines" marker); `start + 1 ..= end`
/// is the hidden body.
pub const Range = struct {
    start: u32,
    end: u32, // inclusive; always > start

    pub fn hiddenCount(self: Range) u32 {
        return self.end - self.start;
    }
};

/// Leading-whitespace column of `line` (tabs expand to `tab_width`).
pub fn indentOf(pt: *const PieceTable, line: u32) u32 {
    const start = pt.lineStart(line);
    const len = pt.lineLen(line);
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const c = pt.byteAt(start + i);
        switch (c) {
            ' ' => col += 1,
            '\t' => col += tab_width,
            else => break,
        }
    }
    return col;
}

/// true when `line` has no non-whitespace characters.
pub fn isBlank(pt: *const PieceTable, line: u32) bool {
    const start = pt.lineStart(line);
    const len = pt.lineLen(line);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const c = pt.byteAt(start + i);
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// The fold range opened by `line`, or null when the line cannot fold
/// (blank, last line, or the next non-blank line is not indented deeper).
pub fn rangeAt(pt: *const PieceTable, line: u32) ?Range {
    const line_count = pt.lineCount();
    if (line >= line_count or isBlank(pt, line)) return null;
    const base = indentOf(pt, line);
    var end: ?u32 = null; // last non-blank deeper-indented line seen
    var l = line + 1;
    while (l < line_count) : (l += 1) {
        if (isBlank(pt, l)) continue; // blanks neither extend nor break the run
        if (indentOf(pt, l) <= base) break;
        end = l;
    }
    const e = end orelse return null;
    if (e == line) return null; // only blank lines followed
    return .{ .start = line, .end = e };
}

/// Every foldable range in the document (nested ranges included), sorted by
/// `start`, ascending. One pass with an indent stack, O(lines). Used by zM
/// (close all) and by "innermost range containing the cursor" lookups.
pub fn allRanges(pt: *const PieceTable, alloc: std.mem.Allocator) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(alloc);
    // open fold headers awaiting their end line: indent + start line
    var stack: std.ArrayList(struct { indent: u32, start: u32 }) = .empty;
    defer stack.deinit(alloc);

    const line_count = pt.lineCount();
    var last_nonblank: ?u32 = null;
    var l: u32 = 0;
    while (l < line_count) : (l += 1) {
        if (isBlank(pt, l)) continue;
        const ind = indentOf(pt, l);
        // A line at/shallower than an open header closes it; the body ends
        // at the last non-blank line (trailing blanks stay outside).
        while (stack.items.len > 0 and ind <= stack.items[stack.items.len - 1].indent) {
            const open = stack.pop().?;
            if (last_nonblank) |nb| {
                if (nb > open.start) try ranges.append(alloc, .{ .start = open.start, .end = nb });
            }
        }
        // This line opens a fold iff the next non-blank line is deeper —
        // known only later, so push every line as a candidate; lines that
        // never get a deeper follower pop out with end == start and are
        // dropped by the `nb > open.start` check... except a candidate
        // whose body IS deeper must be on the stack with its own indent,
        // which is exactly what pushing unconditionally does.
        try stack.append(alloc, .{ .indent = ind, .start = l });
        last_nonblank = l;
    }
    while (stack.items.len > 0) {
        const open = stack.pop().?;
        if (last_nonblank) |nb| {
            if (nb > open.start) try ranges.append(alloc, .{ .start = open.start, .end = nb });
        }
    }
    // pops emit deeper (later-start) ranges first — restore start order
    std.mem.reverse(Range, ranges.items);
    return ranges.toOwnedSlice(alloc);
}

/// The innermost foldable range containing `line` (`start <= line <= end`),
/// or null. `exclude_closed` skips ranges already in `closed` (used by zc
/// to walk out to the next open enclosing fold).
pub fn innermostContaining(pt: *const PieceTable, alloc: std.mem.Allocator, line: u32) !?Range {
    const ranges = try allRanges(pt, alloc);
    defer alloc.free(ranges);
    var best: ?Range = null;
    for (ranges) |r| {
        if (line >= r.start and line <= r.end) {
            // ranges are start-sorted, so the last containing one is the
            // innermost (a later start inside the same body nests deeper)
            best = r;
        }
    }
    return best;
}

// ---- tests ----

const testing = std.testing;

fn table(text: []const u8) !PieceTable {
    return PieceTable.init(testing.allocator, text);
}

test "indentOf: spaces and tabs" {
    var pt = try table("    four\n\ttab\n  \tmixed\nnone");
    defer pt.deinit();
    try testing.expectEqual(@as(u32, 4), indentOf(&pt, 0));
    try testing.expectEqual(@as(u32, 4), indentOf(&pt, 1));
    try testing.expectEqual(@as(u32, 6), indentOf(&pt, 2)); // 2 spaces + tab
    try testing.expectEqual(@as(u32, 0), indentOf(&pt, 3));
}

test "rangeAt: simple block" {
    var pt = try table("fn a() {\n    body;\n}\n");
    defer pt.deinit();
    const r = rangeAt(&pt, 0).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 1), r.end); // `}` is NOT deeper → outside
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 1));
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 2));
}

test "rangeAt: blank lines inside the body, trailing blank excluded" {
    var pt = try table("def f():\n    a\n\n    b\n\ndef g():\n    c\n");
    defer pt.deinit();
    const r = rangeAt(&pt, 0).?;
    try testing.expectEqual(@as(u32, 3), r.end); // body a..b, blank included mid-run
    const r2 = rangeAt(&pt, 5).?;
    try testing.expectEqual(@as(u32, 6), r2.end);
}

test "rangeAt: non-foldable lines return null" {
    var pt = try table("a\nb\n\n  \n");
    defer pt.deinit();
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 0)); // next not deeper
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 1));
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 2)); // blank
    try testing.expectEqual(@as(?Range, null), rangeAt(&pt, 3)); // whitespace-only
}

test "allRanges: nested blocks, start-sorted" {
    const text =
        "fn outer() {\n" ++ // 0
        "    if (x) {\n" ++ // 1
        "        deep();\n" ++ // 2
        "    }\n" ++ // 3
        "    tail();\n" ++ // 4
        "}\n"; // 5
    var pt = try table(text);
    defer pt.deinit();
    const ranges = try allRanges(&pt, testing.allocator);
    defer testing.allocator.free(ranges);
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual(Range{ .start = 0, .end = 4 }, ranges[0]);
    try testing.expectEqual(Range{ .start = 1, .end = 2 }, ranges[1]);
}

test "allRanges: no folds in flat text" {
    var pt = try table("a\nb\nc\n");
    defer pt.deinit();
    const ranges = try allRanges(&pt, testing.allocator);
    defer testing.allocator.free(ranges);
    try testing.expectEqual(@as(usize, 0), ranges.len);
}

test "innermostContaining: picks the deepest range" {
    const text = "fn o() {\n    if (x) {\n        d();\n    }\n}\n";
    var pt = try table(text);
    defer pt.deinit();
    try testing.expectEqual(Range{ .start = 0, .end = 3 }, (try innermostContaining(&pt, testing.allocator, 0)).?);
    try testing.expectEqual(Range{ .start = 1, .end = 2 }, (try innermostContaining(&pt, testing.allocator, 2)).?);
    try testing.expectEqual(@as(?Range, null), try innermostContaining(&pt, testing.allocator, 4));
}
