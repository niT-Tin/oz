//! Text objects (DESIGN.md §1.1): resolve a vim text object at a byte offset
//! into a range. Pure logic over a PieceTable.
//!
//! Word classification follows motion.zig: cword = [a-zA-Z0-9_] and any
//! non-ASCII byte (CJK etc. count as word characters).
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Kind = enum {
    inner_word, // iw
    around_word, // aw
    inner_paren, // i(
    around_paren, // a(
    inner_bracket, // i[
    around_bracket, // a[
    inner_brace, // i{
    around_brace, // a{
    inner_angle, // i<
    around_angle, // a<
    inner_quote, // i'
    around_quote, // a'
    inner_dquote, // i"
    around_dquote, // a"
    inner_tick, // i`
    around_tick, // a`
};

/// Byte range [start, end). For around_* kinds the delimiters are included.
pub const Range = struct {
    start: u32,
    end: u32,
};

/// Resolve the text object at byte offset `pos` (a character boundary).
pub fn range(pt: *const PieceTable, kind: Kind, pos: u32) Range {
    _ = pt;
    _ = kind;
    _ = pos;
    @panic("TODO: implement");
}

test "text objects basic" {
    // implemented by module owner
}
