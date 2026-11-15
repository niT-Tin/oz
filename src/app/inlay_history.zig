//! Coordinate transforms for inlay hints across undo/redo edit sequences.
//!
//! The displayed hints are anchored at byte offsets in the current document.
//! An undo applies the group's inverses in reverse recording order; a redo
//! replays them forward. Each step replaces `removed` bytes at `pos` with
//! `inserted` bytes. This module maps an anchor through one such step:
//!
//! - an anchor inside the removed span is dead (null: drop the hint),
//! - an anchor at a pure deletion point stays put (its following text moved
//!   left, so the boundary itself is still the same logical spot),
//! - an anchor at/after an insertion point shifts with the inserted text.
//!
//! Pure (no App/vaxis) so the ordering/boundary rules are unit-tested.
const std = @import("std");

pub const Span = struct {
    /// Byte offset in the document BEFORE this step.
    pos: u32,
    /// Bytes the step removes at `pos`.
    removed: u32,
    /// Bytes the step inserts at `pos`.
    inserted: u32,
};

/// Map one anchor through one editor step. Returns null when the anchor was
/// inside the replaced text (the hint no longer describes any surviving text).
pub fn transformOffset(offset: u32, span: Span) ?u32 {
    if (offset < span.pos) return offset;
    const end = span.pos + span.removed;
    if (span.removed > 0 and offset > span.pos and offset < end) return null;
    if (span.inserted > 0) {
        // Insertion (pure insert, restore, or replacement): anything at or
        // after the insertion point shifts to the end of the inserted text.
        return offset - span.removed + span.inserted;
    }
    // Pure deletion: the anchor at the deletion point keeps its logical
    // position; later anchors move left with the surviving text.
    if (offset == span.pos) return span.pos;
    return offset - span.removed;
}

/// Apply a sequence of spans in application order to every anchor. `offset`
/// becomes null once any step kills it; later steps skip it.
pub fn transformOffsets(offsets: []?u32, spans: []const Span) void {
    for (spans) |span| {
        for (offsets) |*off| {
            const cur = off.* orelse continue;
            off.* = transformOffset(cur, span);
        }
    }
}

/// Build the spans for undoing a recorded edit group. The caller passes the
/// edits in RECORDING order; this reverses them because undo applies them in
/// reverse order.
pub const EditLen = struct { pos: u32, before_len: u32, after_len: u32 };

pub fn undoSpans(out: []Span, edits: []const EditLen) void {
    std.debug.assert(out.len == edits.len);
    var i: usize = 0;
    while (i < edits.len) : (i += 1) {
        const e = edits[edits.len - 1 - i];
        out[i] = .{ .pos = e.pos, .removed = e.after_len, .inserted = e.before_len };
    }
}

/// Build the spans for redoing a recorded edit group (forward order).
pub fn redoSpans(out: []Span, edits: []const EditLen) void {
    std.debug.assert(out.len == edits.len);
    for (edits, out) |e, *s| {
        s.* = .{ .pos = e.pos, .removed = e.before_len, .inserted = e.after_len };
    }
}

// ---- tests ----

test "inlay transform: undo insertion keeps the start anchor and shifts tails" {
    // Undo of inserting "XYZ" at 10: remove 3 bytes, insert none.
    const span = Span{ .pos = 10, .removed = 3, .inserted = 0 };
    try std.testing.expectEqual(@as(?u32, 7), transformOffset(7, span));
    try std.testing.expectEqual(@as(?u32, 10), transformOffset(10, span)); // boundary stays
    try std.testing.expectEqual(@as(?u32, null), transformOffset(11, span)); // inside dies
    try std.testing.expectEqual(@as(?u32, null), transformOffset(12, span));
    try std.testing.expectEqual(@as(?u32, 10), transformOffset(13, span)); // end -> start
    try std.testing.expectEqual(@as(?u32, 17), transformOffset(20, span));
}

test "inlay transform: undo deletion shifts following anchors right" {
    // Undo of deleting "XYZ" at 10: insert 3 bytes, remove none.
    const span = Span{ .pos = 10, .removed = 0, .inserted = 3 };
    try std.testing.expectEqual(@as(?u32, 9), transformOffset(9, span));
    try std.testing.expectEqual(@as(?u32, 13), transformOffset(10, span));
    try std.testing.expectEqual(@as(?u32, 23), transformOffset(20, span));
}

test "inlay transform: redo insertion shifts anchors right" {
    const span = Span{ .pos = 5, .removed = 0, .inserted = 4 };
    try std.testing.expectEqual(@as(?u32, 4), transformOffset(4, span));
    try std.testing.expectEqual(@as(?u32, 9), transformOffset(5, span));
    try std.testing.expectEqual(@as(?u32, 10), transformOffset(6, span));
}

test "inlay transform: redo deletion keeps boundary and drops interior" {
    const span = Span{ .pos = 5, .removed = 4, .inserted = 0 };
    try std.testing.expectEqual(@as(?u32, 5), transformOffset(5, span));
    try std.testing.expectEqual(@as(?u32, null), transformOffset(6, span));
    try std.testing.expectEqual(@as(?u32, null), transformOffset(8, span));
    try std.testing.expectEqual(@as(?u32, 5), transformOffset(9, span));
    try std.testing.expectEqual(@as(?u32, 6), transformOffset(10, span));
}

test "inlay transform: replacement maps boundary and kills interior" {
    const span = Span{ .pos = 4, .removed = 2, .inserted = 5 };
    try std.testing.expectEqual(@as(?u32, 3), transformOffset(3, span));
    try std.testing.expectEqual(@as(?u32, 7), transformOffset(4, span));
    try std.testing.expectEqual(@as(?u32, null), transformOffset(5, span));
    try std.testing.expectEqual(@as(?u32, 9), transformOffset(6, span)); // end boundary moves to replacement end
    try std.testing.expectEqual(@as(?u32, 12), transformOffset(9, span));
}

test "inlay transform: sequence order matters and dead anchors stay dead" {
    var offsets = [_]?u32{ 0, 1, 3, 4, 8, 12 };
    // Undo (reverse): first remove "Y" at 3 (insertion), then remove "X" at 1.
    const spans = [_]Span{
        .{ .pos = 3, .removed = 1, .inserted = 0 },
        .{ .pos = 1, .removed = 1, .inserted = 0 },
    };
    transformOffsets(&offsets, &spans);
    try std.testing.expectEqual(@as(?u32, 0), offsets[0]);
    try std.testing.expectEqual(@as(?u32, 1), offsets[1]);
    try std.testing.expectEqual(@as(?u32, 2), offsets[2]); // 3 -> 2 after Y, stays 2 after X
    // 4: after span1 (3,1,0) the end boundary maps to 3; after span2
    // (1,1,0) it maps to 2.
    try std.testing.expectEqual(@as(?u32, 2), offsets[3]);
    try std.testing.expectEqual(@as(?u32, 6), offsets[4]);
    try std.testing.expectEqual(@as(?u32, 10), offsets[5]);

    var dead = [_]?u32{ 2, 5 };
    const kill = [_]Span{.{ .pos = 1, .removed = 3, .inserted = 0 }};
    transformOffsets(&dead, &kill);
    try std.testing.expectEqual(@as(?u32, null), dead[0]); // 2 inside [2,4)
    try std.testing.expectEqual(@as(?u32, 2), dead[1]); // 5 -> 2
}

test "inlay transform: span builders reverse undo and keep redo forward" {
    const edits = [_]EditLen{
        .{ .pos = 2, .before_len = 0, .after_len = 1 },
        .{ .pos = 7, .before_len = 3, .after_len = 0 },
    };
    var us: [2]Span = undefined;
    undoSpans(&us, &edits);
    try std.testing.expectEqual(@as(u32, 7), us[0].pos);
    try std.testing.expectEqual(@as(u32, 0), us[0].removed);
    try std.testing.expectEqual(@as(u32, 3), us[0].inserted);
    try std.testing.expectEqual(@as(u32, 2), us[1].pos);
    try std.testing.expectEqual(@as(u32, 1), us[1].removed);

    var rs: [2]Span = undefined;
    redoSpans(&rs, &edits);
    try std.testing.expectEqual(@as(u32, 2), rs[0].pos);
    try std.testing.expectEqual(@as(u32, 0), rs[0].removed);
    try std.testing.expectEqual(@as(u32, 1), rs[0].inserted);
    try std.testing.expectEqual(@as(u32, 7), rs[1].pos);
    try std.testing.expectEqual(@as(u32, 3), rs[1].removed);
}
