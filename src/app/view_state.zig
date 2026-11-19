//! Per-(window, buffer) cursor/viewport snapshots.
//!
//! Cursor and viewport live in `App.Window`, but a window that switches
//! buffers must remember where it left the previous one: without that, the
//! shared window slot carries the old cursor (clamped to the new document)
//! and returning to the buffer lands at a bogus position. The store is owned
//! by the BUFFER and keyed by a stable window id, so:
//!
//! - each split keeps an independent position for the same buffer (two
//!   windows showing one file have separate entries),
//! - buffer/window list reindexing does not invalidate the keys (no list
//!   indices are stored),
//! - a closed buffer frees its snapshots with its other per-document state,
//! - a closed window's entries are removed from every buffer.
//!
//! `clamp` re-validates a snapshot against the CURRENT document: the file may
//! have been truncated externally, replaced by a whole-file edit, or the
//! buffer simply shrank while the window showed another document. The result
//! must be a real cursor position (UTF-8 boundary, inside the line's text so
//! it never lands between `\r` and `\n` of a CRLF terminator) and a viewport
//! that can be rendered (a real line, at/below the cursor line).
//!
//! Pure (no App/vaxis) so the clamping rules are unit-tested.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Snapshot = struct {
    /// Byte offset of the cursor in the buffer.
    cursor: u32 = 0,
    /// First visible document line.
    view_top: u32 = 0,
    /// Wrapped rows skipped within `view_top` when the cursor's wrapped
    /// chunk is scrolled past the viewport.
    view_wrap: u32 = 0,
    /// Set by zz/zt/zb (see App.Window.view_pinned).
    view_pinned: bool = false,
};

pub const Entry = struct {
    /// Stable window identity (App.Window.id), never a list index.
    win_id: u64,
    snap: Snapshot,
};

/// One buffer's saved positions, one entry per window that has shown it.
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    pub fn get(self: *const Store, win_id: u64) ?Snapshot {
        for (self.entries.items) |e| {
            if (e.win_id == win_id) return e.snap;
        }
        return null;
    }

    /// Insert or replace this window's snapshot.
    pub fn save(self: *Store, alloc: std.mem.Allocator, win_id: u64, snap: Snapshot) !void {
        for (self.entries.items) |*e| {
            if (e.win_id == win_id) {
                e.snap = snap;
                return;
            }
        }
        try self.entries.append(alloc, .{ .win_id = win_id, .snap = snap });
    }

    /// Forget every snapshot for a window that no longer exists.
    pub fn removeWindow(self: *Store, win_id: u64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].win_id == win_id) {
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *Store) void {
        self.entries.clearRetainingCapacity();
    }
};

/// Clamp a byte offset to a real cursor position in `pt`: inside the
/// document, on a UTF-8 scalar boundary, and not inside a CRLF terminator.
pub fn clampCursor(pt: *const PieceTable, pos: u32) u32 {
    var p: u32 = @min(pos, pt.len());
    // Never start a cursor on a UTF-8 continuation byte: an external edit or
    // reload may have shifted the saved byte offset into the middle of a
    // multi-byte scalar.
    if (p > 0 and p < pt.len()) {
        while (p > 0 and (pt.byteAt(p) & 0xC0) == 0x80) p -= 1;
    }
    const line = pt.lineOf(p);
    const line_start = pt.lineStart(line);
    const text_end = line_start + pt.lineTextLen(line);
    if (p > text_end) p = text_end;
    return p;
}

/// Clamp a saved viewport against the current document: a real line index,
/// never below the cursor line (the renderer would scroll it down anyway).
pub fn clampViewTop(pt: *const PieceTable, top: u32, cursor: u32) u32 {
    const at_line = pt.lineOf(cursor);
    return @min(top, at_line);
}

/// Re-validate a saved snapshot against the current document. Content is
/// usually unchanged between save and restore, so the common case returns
/// the exact snapshot; this only rewrites values that are no longer legal.
pub fn clamp(pt: *const PieceTable, snap: Snapshot) Snapshot {
    const cursor = clampCursor(pt, snap.cursor);
    const view_top = clampViewTop(pt, snap.view_top, cursor);
    const cursor_line = pt.lineOf(cursor);
    const view_wrap = if (view_top == cursor_line)
        @min(snap.view_wrap, pt.lineLen(cursor_line))
    else
        0;
    return .{
        .cursor = cursor,
        .view_top = view_top,
        .view_wrap = view_wrap,
        .view_pinned = snap.view_pinned,
    };
}

// ---- tests ----

const testing = std.testing;

fn table(text: []const u8) !PieceTable {
    return PieceTable.init(testing.allocator, text);
}

test "view state: unchanged document restores the exact snapshot" {
    var pt = try table("first\nsecond\nthird\nfourth\nfifth\n");
    defer pt.deinit();
    const cursor = pt.lineStart(2) + 3; // inside "third"
    const snap = Snapshot{ .cursor = cursor, .view_top = 1, .view_wrap = 0, .view_pinned = true };
    try testing.expectEqual(snap, clamp(&pt, snap));
}

test "view state: truncated document clamps cursor and viewport" {
    var pt = try table("abc\n");
    defer pt.deinit();
    const snap = clamp(&pt, .{ .cursor = 999, .view_top = 42 });
    try testing.expectEqual(@as(u32, 4), snap.cursor); // EOF insertion point
    // "abc\n" has two lines: content line 0 and the empty line after the
    // final newline. The saved top 42 clamps to that last line.
    try testing.expectEqual(@as(u32, 1), snap.view_top);
}

test "view state: UTF-8 continuation byte is pulled back to the boundary" {
    // "é" is two bytes (0xC3 0xA9); offset 1 is inside the scalar.
    var pt = try table("aé\n");
    defer pt.deinit();
    try testing.expectEqual(@as(u32, 1), clampCursor(&pt, 1));
    // 4-byte emoji: offsets 1..3 are continuation bytes.
    var emoji = try table("😀x\n");
    defer emoji.deinit();
    try testing.expectEqual(@as(u32, 0), clampCursor(&emoji, 2));
    try testing.expectEqual(@as(u32, 4), clampCursor(&emoji, 4));
}

test "view state: CRLF terminator is never a cursor position" {
    var pt = try table("ab\r\ncd\r\n");
    defer pt.deinit();
    // Offset 3 is the '\n' of the first CRLF; line 0's text ends at 2.
    try testing.expectEqual(@as(u32, 2), clampCursor(&pt, 3));
    // Offset 7 (EOF) is a legal insertion point on the last line.
    try testing.expectEqual(@as(u32, 8), clampCursor(&pt, 8));
}

test "view state: view_top follows the cursor and the document end" {
    var pt = try table("0\n1\n2\n3\n4\n");
    defer pt.deinit();
    const cursor = pt.lineStart(4);
    try testing.expectEqual(@as(u32, 4), clampViewTop(&pt, 99, cursor));
    try testing.expectEqual(@as(u32, 1), clampViewTop(&pt, 1, cursor));
    // A top ABOVE the cursor line is fine; only the reverse (a top below the
    // cursor line, which the renderer would immediately scroll down) is
    // pulled up to the cursor line.
    try testing.expectEqual(@as(u32, 0), clampViewTop(&pt, 0, pt.lineStart(2)));
    try testing.expectEqual(@as(u32, 2), clampViewTop(&pt, 3, pt.lineStart(2)));
}

test "view state: view_wrap only applies when the cursor line is the top" {
    var pt = try table("short\na very long line that wraps\n");
    defer pt.deinit();
    const at_second = clamp(&pt, .{
        .cursor = pt.lineStart(1) + 5,
        .view_top = 1,
        .view_wrap = 99,
    });
    try testing.expectEqual(@as(u32, 27), at_second.view_wrap); // bounded by line bytes
    const below = clamp(&pt, .{
        .cursor = pt.lineStart(1) + 5,
        .view_top = 0,
        .view_wrap = 9,
    });
    try testing.expectEqual(@as(u32, 0), below.view_wrap);
}

test "view state: two windows on one buffer keep independent positions" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    // Split windows share the document but not the cursor; the store is
    // keyed by window id, so neither position overwrites the other.
    try store.save(alloc, 1, .{ .cursor = 10, .view_top = 2 });
    try store.save(alloc, 2, .{ .cursor = 20, .view_top = 4 });
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 10, .view_top = 2 }), store.get(1));
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 20, .view_top = 4 }), store.get(2));
}

test "view state: store saves, updates and removes per-window entries" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try store.save(alloc, 7, .{ .cursor = 3, .view_top = 1 });
    try store.save(alloc, 9, .{ .cursor = 5, .view_top = 2 });
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 3, .view_top = 1 }), store.get(7));
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 5, .view_top = 2 }), store.get(9));
    try testing.expectEqual(@as(?Snapshot, null), store.get(8));

    // Re-saving the same window replaces rather than duplicating.
    try store.save(alloc, 7, .{ .cursor = 4, .view_top = 6 });
    try testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 4, .view_top = 6 }), store.get(7));

    store.removeWindow(7);
    try testing.expectEqual(@as(?Snapshot, null), store.get(7));
    try testing.expectEqual(@as(?Snapshot, .{ .cursor = 5, .view_top = 2 }), store.get(9));
}
