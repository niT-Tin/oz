//! Multi-cursor (DESIGN.md §1.3): a sorted set of cursors with synchronized
//! editing. Pure logic; the UI (Ctrl+n selection, visual-block fan-out) is
//! wired in the app.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const MultiCursor = struct {
    allocator: std.mem.Allocator,
    cursors: std.ArrayList(u32), // sorted, deduplicated byte offsets
    main: usize = 0, // index of the main cursor into `cursors`

    pub fn init(allocator: std.mem.Allocator) MultiCursor {
        _ = allocator;
        @panic("TODO: implement");
    }

    pub fn deinit(self: *MultiCursor) void {
        _ = self;
        @panic("TODO: implement");
    }

    pub fn len(self: *const MultiCursor) usize {
        _ = self;
        @panic("TODO: implement");
    }

    /// Insert a cursor position (sorted, deduped). Returns true if added.
    pub fn add(self: *MultiCursor, pos: u32) !bool {
        _ = self;
        _ = pos;
        @panic("TODO: implement");
    }

    /// Remove a cursor position. Returns true if it was present.
    pub fn remove(self: *MultiCursor, pos: u32) bool {
        _ = self;
        _ = pos;
        @panic("TODO: implement");
    }

    pub fn clear(self: *MultiCursor) void {
        _ = self;
        @panic("TODO: implement");
    }

    /// The word under the main cursor (cword classification, see motion.zig).
    pub fn wordAt(self: *const MultiCursor, pt: *const PieceTable, pos: u32) []const u8 {
        _ = self;
        _ = pt;
        _ = pos;
        @panic("TODO: implement");
    }

    /// Ctrl+n: add the next occurrence of the main cursor's word after the
    /// last cursor; returns false when no further occurrence exists.
    /// If the cursors are not all on the word, returns false.
    pub fn addNextMatch(self: *MultiCursor, pt: *const PieceTable) !bool {
        _ = self;
        _ = pt;
        @panic("TODO: implement");
    }

    /// Insert `text` at every cursor (applied right-to-left so earlier
    /// positions stay valid); returns the number of edits applied.
    pub fn applyInsert(self: *MultiCursor, pt: *PieceTable, text: []const u8) !usize {
        _ = self;
        _ = pt;
        _ = text;
        @panic("TODO: implement");
    }

    /// Delete `del_len` bytes before every cursor (right-to-left).
    pub fn applyDelete(self: *MultiCursor, pt: *PieceTable, del_len: u32) !usize {
        _ = self;
        _ = pt;
        _ = del_len;
        @panic("TODO: implement");
    }
};

test "multicursor basic" {
    // implemented by module owner
}
