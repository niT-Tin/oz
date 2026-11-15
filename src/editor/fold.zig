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

// ---- closed-fold bookkeeping across edits ----
//
// `Closed` is the editorial state for one closed fold (App.Buffer.folds).
// Its identity is the header line's byte anchor plus a hash of the header
// text, NOT the line number: an unrelated edit elsewhere shifts every line
// after it while the folded text itself is unchanged, and the fold must stay
// closed. Edits transform the anchor/range through the edit sequence and the
// result is validated against the post-edit document; a fold is dropped only
// when its header/structure really disappeared (or the body no longer opens
// one). Undo/redo/whole-file replacements run the same transform sequence.
//
// The cached `header_end`/`fold_end` byte offsets let an edit be classified
// without the PRE-edit piece table (the document is mutated before bookkeeping
// runs, and re-reading a stale line range from the new table would be wrong).

/// One closed fold plus the anchors needed to carry it through edits.
pub const Closed = struct {
    /// Byte offset of the header line's first byte.
    anchor: u32,
    /// Current line range (`start` kept visible, `start+1 ..= end` hidden).
    range: Range,
    /// FNV-1a of the header line's text; used to re-match the fold when a
    /// whole-document replacement makes byte anchors meaningless.
    signature: u64,
    /// One past the header line's text (before its `\r\n`/`\n` terminator).
    header_end: u32,
    /// One past the last folded line's text (before its terminator).
    fold_end: u32,

    pub fn init(pt: *const PieceTable, range: Range) Closed {
        var f = Closed{ .anchor = 0, .range = range, .signature = 0, .header_end = 0, .fold_end = 0 };
        f.refresh(pt);
        return f;
    }

    /// Recompute the anchor/signature/line-end offsets from `range` against
    /// the current document. Runs after detection and after every revalidated
    /// edit.
    pub fn refresh(self: *Closed, pt: *const PieceTable) void {
        self.refreshOffsets(pt);
        self.signature = signatureOf(pt, self.range.start);
    }

    /// Anchor/line-end offsets only (header text unchanged, e.g. an edit
    /// above the fold moved the whole block).
    fn refreshOffsets(self: *Closed, pt: *const PieceTable) void {
        self.anchor = pt.lineStart(self.range.start);
        self.header_end = self.anchor + pt.lineTextLen(self.range.start);
        self.fold_end = pt.lineStart(self.range.end) + pt.lineTextLen(self.range.end);
    }
};

/// FNV-1a hash of one line's text (terminator excluded).
pub fn signatureOf(pt: *const PieceTable, line: u32) u64 {
    const start = pt.lineStart(line);
    const len = pt.lineTextLen(line);
    var h: u64 = 0xcbf29ce484222325;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        h ^= pt.byteAt(start + i);
        h *%= 0x100000001b3;
    }
    return h;
}

/// One applied text replacement in pre-edit byte coordinates. `removed_*`
/// counts are taken from the PRE-edit document, `inserted_*` from the new
/// text; both are needed to classify structural (line-count-changing) edits.
pub const EditSpan = struct {
    pos: u32,
    removed: u32,
    inserted: u32,
    removed_newlines: u32,
    inserted_newlines: u32,

    pub fn end(self: EditSpan) u32 {
        return self.pos + self.removed;
    }
};

/// '\n' count of a standalone inserted text.
pub fn countNewlines(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |b| {
        if (b == '\n') n += 1;
    }
    return n;
}

/// '\n' count of a document range; call BEFORE the edit is applied.
pub fn newlinesIn(pt: *const PieceTable, pos: u32, len: u32) u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (pt.byteAt(pos + i) == '\n') n += 1;
    }
    return n;
}

/// true when the span replaced the WHOLE document (agent patch / LSP
/// workspace edit / whole-file `:%s`): byte anchors cannot be tracked through
/// it, so the caller must re-anchor by header signature instead.
pub fn isWholeDocument(span: EditSpan, before_len: u32) bool {
    return before_len > 0 and span.pos == 0 and span.removed == before_len;
}

/// What one edit does to a closed fold's identity/anchor.
pub const Move = union(enum) {
    /// Content untouched (possibly shifted as a block); value is the new
    /// header byte anchor. The line range shifts by the edit's line delta.
    keep: u32,
    /// The edit may have changed the fold's structure; value is the new
    /// header byte anchor. The caller re-detects the range at that line and
    /// drops the fold when the line no longer opens one.
    revalidate: u32,
    /// The header line itself was destroyed.
    drop,
};

/// Classify one edit against a closed fold, using only pre-edit bookkeeping.
pub fn moveClosed(f: Closed, span: EditSpan) Move {
    const span_end = span.pos + span.removed;

    // The edit starts after the fold's last text byte: no folded line moved.
    // (An insertion exactly AT fold_end edits the last folded line, so it is
    // "touch" and falls through to the revalidate path below.)
    if (span.pos > f.fold_end) return .{ .keep = f.anchor };

    // The edit ends at or before the header's first byte: everything the fold
    // shows is untouched and shifts as a block with the surrounding lines.
    if (span_end <= f.anchor) {
        if (span.pos == f.anchor and span.removed == 0) {
            // Pure insertion AT the header start (paste/`O` above the block):
            // the header text moves right and may now be indented
            // differently, so re-detect instead of assuming identity.
            return .{ .revalidate = f.anchor + span.inserted };
        }
        if (span.removed > 0 and span_end == f.anchor) {
            // A deletion/replacement ending exactly at the header start
            // removes (or rewrites) the line break before it: the header may
            // have been joined into the previous line.
            return .{ .revalidate = span.pos + span.inserted };
        }
        // Entirely above the fold: both folded lines shift by the line delta;
        // the bytes between anchor and fold end are unchanged.
        return .{ .keep = f.anchor - span.removed + span.inserted };
    }

    // Starts before the header and ends inside/after it: the line break that
    // starts the header line is inside the removed span.
    if (span.pos < f.anchor) return .drop;

    // Starts at the header's first byte and removes whole lines (`dd` on the
    // header): the header line and its terminator are gone.
    if (span.pos == f.anchor and span.removed > 0 and span.removed_newlines > 0) return .drop;

    // The header start byte survives: content before/inside it on the same
    // line may have changed and the body may have shrunk/grown. Re-detect.
    return .{ .revalidate = f.anchor };
}

/// Apply one edit's result to a closed fold against the post-edit document.
/// Returns false when the fold must be dropped.
pub fn transformClosed(f: *Closed, span: EditSpan, after: *const PieceTable) bool {
    switch (moveClosed(f.*, span)) {
        .drop => return false,
        .keep => |new_anchor| {
            const hidden = f.range.end - f.range.start;
            const start = after.lineOf(@min(new_anchor, after.len()));
            const end = start + hidden;
            if (end >= after.lineCount()) return false;
            f.range = .{ .start = start, .end = end };
            // The first dedented non-blank line is a dependency of this
            // range even though it was outside the hidden body. Indenting
            // or deleting that boundary can extend the surviving fold.
            // Check only the boundary; rescan the body only when it changed.
            var boundary = end + 1;
            while (boundary < after.lineCount() and isBlank(after, boundary)) : (boundary += 1) {}
            if (boundary < after.lineCount() and indentOf(after, boundary) > indentOf(after, start)) {
                f.range = rangeAt(after, start) orelse return false;
            }
            // Header text is unchanged; only offsets/line numbers moved.
            f.refreshOffsets(after);
            return true;
        },
        .revalidate => |new_anchor| {
            const start = after.lineOf(@min(new_anchor, after.len()));
            const r = rangeAt(after, start) orelse return false;
            f.range = r;
            f.refresh(after);
            return true;
        },
    }
}

/// Transform every closed fold through one applied edit (in place, no
/// allocation beyond the folds list itself).
pub fn transformFolds(folds: *std.ArrayList(Closed), span: EditSpan, after: *const PieceTable) void {
    var i: usize = 0;
    while (i < folds.items.len) {
        if (transformClosed(&folds.items[i], span, after)) {
            i += 1;
        } else {
            _ = folds.orderedRemove(i);
        }
    }
}

/// Re-anchor closed folds after a WHOLE-document replacement. Byte anchors
/// are meaningless, so match each fold's header signature against the new
/// text and pick the foldable line closest to the old position (first come,
/// first served, so nested/repeated headers stay distinct). A block whose
/// header disappeared is dropped.
pub fn reanchor(alloc: std.mem.Allocator, folds: *std.ArrayList(Closed), after: *const PieceTable) !void {
    var candidates = std.AutoHashMap(u64, std.ArrayListUnmanaged(u32)).init(alloc);
    defer {
        var it = candidates.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        candidates.deinit();
    }
    const line_count = after.lineCount();
    var line: u32 = 0;
    while (line < line_count) : (line += 1) {
        if (rangeAt(after, line) == null) continue;
        const gop = try candidates.getOrPut(signatureOf(after, line));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, line);
    }

    var out: std.ArrayList(Closed) = .empty;
    errdefer out.deinit(alloc);
    var used = std.AutoHashMap(u32, void).init(alloc);
    defer used.deinit();
    for (folds.items) |old| {
        const cands = candidates.get(old.signature) orelse continue;
        var best: ?u32 = null;
        var best_dist: u32 = std.math.maxInt(u32);
        for (cands.items) |cand| {
            if (used.contains(cand)) continue;
            const dist = if (cand >= old.range.start) cand - old.range.start else old.range.start - cand;
            if (dist < best_dist) {
                best_dist = dist;
                best = cand;
            }
        }
        const picked = best orelse continue;
        try used.put(picked, {});
        const r = rangeAt(after, picked) orelse continue;
        try out.append(alloc, Closed.init(after, r));
    }
    // Rendering/motions assume start-sorted ranges.
    std.mem.sort(Closed, out.items, {}, struct {
        fn lt(_: void, a: Closed, b: Closed) bool {
            return a.range.start < b.range.start;
        }
    }.lt);

    folds.deinit(alloc);
    folds.* = out;
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

// ---- closed-fold transform tests ----

fn appendClosed(folds: *std.ArrayList(Closed), pt: *const PieceTable, line: u32) !void {
    try folds.append(testing.allocator, Closed.init(pt, rangeAt(pt, line).?));
}

test "closed fold: edit after the fold keeps it closed and unchanged" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("top\nfn a() {\n    body\n}\ntail!\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    // replace "tail" (after the closed body) with "tail!" — no newlines
    transformFolds(&folds, .{ .pos = 24, .removed = 4, .inserted = 5, .removed_newlines = 0, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 1, .end = 2 }, folds.items[0].range);
    try testing.expectEqual(@as(u32, 4), folds.items[0].anchor);
}

test "closed fold: a line deleted above shifts it and keeps it closed" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("fn a() {\n    body\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    transformFolds(&folds, .{ .pos = 0, .removed = 4, .inserted = 0, .removed_newlines = 1, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 1 }, folds.items[0].range);
    try testing.expectEqual(@as(u32, 0), folds.items[0].anchor);
    try testing.expectEqual(@as(u32, 8), folds.items[0].header_end); // "fn a() {"
    try testing.expectEqual(@as(u32, 17), folds.items[0].fold_end); // "    body"
    try testing.expectEqual(signatureOf(&after, 0), folds.items[0].signature);
}

test "closed fold: a line inserted above shifts it and keeps it closed" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("new\ntop\nfn a() {\n    body\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    transformFolds(&folds, .{ .pos = 0, .removed = 0, .inserted = 4, .removed_newlines = 0, .inserted_newlines = 1 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 2, .end = 3 }, folds.items[0].range);
}

test "closed fold: an insertion exactly at the header start re-identifies it" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("top\nnew\nfn a() {\n    body\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    // linewise paste of "new\n" at the header's first byte
    transformFolds(&folds, .{ .pos = 4, .removed = 0, .inserted = 4, .removed_newlines = 0, .inserted_newlines = 1 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 2, .end = 3 }, folds.items[0].range);
}

test "closed fold: editing the body keeps it closed and revalidates the range" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("top\nfn a() {\n    BODY\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    transformFolds(&folds, .{ .pos = 17, .removed = 4, .inserted = 4, .removed_newlines = 0, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 1, .end = 2 }, folds.items[0].range);
}

test "closed fold: deleting the body drops the fold" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("top\nfn a() {\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    // delete the only deeper-indented body line
    transformFolds(&folds, .{ .pos = 13, .removed = 9, .inserted = 0, .removed_newlines = 1, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 0), folds.items.len);
}

test "closed fold: deleting the header drops the fold" {
    var before = try table("top\nfn a() {\n    body\n}\ntail\n");
    defer before.deinit();
    var after = try table("top\n    body\n}\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    transformFolds(&folds, .{ .pos = 4, .removed = 9, .inserted = 0, .removed_newlines = 1, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 0), folds.items.len);
}

test "closed fold: CRLF offsets stay correct after an edit above" {
    var before = try table("top\r\nfn a() {\r\n    body\r\n}\r\ntail\r\n");
    defer before.deinit();
    var after = try table("fn a() {\r\n    body\r\n}\r\ntail\r\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1);

    transformFolds(&folds, .{ .pos = 0, .removed = 5, .inserted = 0, .removed_newlines = 1, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 1 }, folds.items[0].range);
    // Header text excludes the \r; the fold end excludes it too.
    try testing.expectEqual(@as(u32, 8), folds.items[0].header_end);
    try testing.expectEqual(@as(u32, 18), folds.items[0].fold_end);
}

test "closed fold: whole-document replacement re-anchors by header text" {
    var before = try table("top\ndef alpha():\n    a\n\ndef beta():\n    b\n");
    defer before.deinit();
    var after = try table("new1\nnew2\ntop\ndef alpha():\n    a\n\ndef BETA():\n    b\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 1); // alpha
    try appendClosed(&folds, &before, 4); // beta

    try reanchor(testing.allocator, &folds, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len); // beta's header changed
    try testing.expectEqual(Range{ .start = 3, .end = 4 }, folds.items[0].range);
    try testing.expectEqual(@as(u32, 14), folds.items[0].anchor);
}

test "closed fold: whole-document re-anchor keeps duplicate headers distinct" {
    var before = try table("def f():\n    a\ndef f():\n    b\n");
    defer before.deinit();
    var after = try table("x\ndef f():\n    a\ndef f():\n    b\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 0);
    try appendClosed(&folds, &before, 2);

    try reanchor(testing.allocator, &folds, &after);
    try testing.expectEqual(@as(usize, 2), folds.items.len);
    try testing.expectEqual(@as(u32, 1), folds.items[0].range.start);
    try testing.expectEqual(@as(u32, 3), folds.items[1].range.start);
}

test "closed fold: edit-span helpers" {
    try testing.expectEqual(@as(u32, 2), countNewlines("a\nb\nc"));
    try testing.expectEqual(@as(u32, 0), countNewlines("abc"));
    var pt = try table("a\nb\nc\n");
    defer pt.deinit();
    try testing.expectEqual(@as(u32, 1), newlinesIn(&pt, 0, 3)); // "a\nb"
    try testing.expectEqual(@as(u32, 0), newlinesIn(&pt, 2, 1)); // "b"
    try testing.expect(isWholeDocument(.{ .pos = 0, .removed = 6, .inserted = 1, .removed_newlines = 2, .inserted_newlines = 0 }, 6));
    try testing.expect(!isWholeDocument(.{ .pos = 0, .removed = 3, .inserted = 1, .removed_newlines = 1, .inserted_newlines = 0 }, 6));
}

test "closed fold: editing the closing boundary extends a surviving fold" {
    var before = try table("head\n    body\nboundary\n    next\ntail\n");
    defer before.deinit();
    var after = try table("head\n    body\n    boundary\n    next\ntail\n");
    defer after.deinit();
    var folds: std.ArrayList(Closed) = .empty;
    defer folds.deinit(testing.allocator);
    try appendClosed(&folds, &before, 0);
    // Indenting the first dedented line changes the extent of the closed
    // indent fold, even though its byte position is after the old fold_end.
    transformFolds(&folds, .{ .pos = 14, .removed = 0, .inserted = 4, .removed_newlines = 0, .inserted_newlines = 0 }, &after);
    try testing.expectEqual(@as(usize, 1), folds.items.len);
    try testing.expectEqual(rangeAt(&after, 0).?, folds.items[0].range);
}
