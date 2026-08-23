//! Surround operations (DESIGN.md §1.3): ys{motion}{c} add, ds{c} delete,
//! cs{old}{new} change. Pure functions computing edit ranges + replacement
//! text; the caller applies them through the History.
//!
//! Supported delimiters: () [] {} <> and quotes ' " `.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// A single replacement: replace [start, end) with `text`.
pub const Result = struct {
    start: u32,
    end: u32,
    text: []const u8, // borrowed; caller copies (History does)
};

/// ys: wrap `inner` (the range produced by a motion/text object) with
/// delimiter `ch`. Returns the wrapped text (content unchanged).
pub fn add(allocator: std.mem.Allocator, pt: *const PieceTable, inner: struct { start: u32, end: u32 }, ch: u8) !Result {
    _ = allocator;
    _ = pt;
    _ = inner;
    _ = ch;
    @panic("TODO: implement");
}

/// ds: find the delimiter pair surrounding the range containing `pos` and
/// delete it (leaving the inner content). Returns null if none found.
pub fn delete(allocator: std.mem.Allocator, pt: *const PieceTable, pos: u32) !?Result {
    _ = allocator;
    _ = pt;
    _ = pos;
    @panic("TODO: implement");
}

/// cs: find the delimiter pair around `pos`, replace both delimiters with
/// `new_ch`. Returns null if none found.
pub fn change(allocator: std.mem.Allocator, pt: *const PieceTable, pos: u32, new_ch: u8) !?Result {
    _ = allocator;
    _ = pt;
    _ = pos;
    _ = new_ch;
    @panic("TODO: implement");
}

test "surround basic" {
    // implemented by module owner
}
