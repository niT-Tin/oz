//! Align lines by a delimiter (DESIGN.md §1.3): ga{motion}{delim} — e.g.
//! `gaip=` aligns the first '=' of every line in the paragraph.
//! Pure logic: returns the replacement text for a line range.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// Compute the aligned content of lines [start_line, end_line] inclusive:
/// the first occurrence of `delim` on each line is padded (spaces before the
/// delimiter) so all delimiters sit in the same column (the max column).
/// Lines without the delimiter keep their leading whitespace and are not
/// padded. The returned text replaces the whole range.
pub fn alignLines(
    allocator: std.mem.Allocator,
    pt: *const PieceTable,
    start_line: u32,
    end_line: u32,
    delim: u8,
) ![]u8 {
    _ = allocator;
    _ = pt;
    _ = start_line;
    _ = end_line;
    _ = delim;
    @panic("TODO: implement");
}

test "align basic" {
    // implemented by module owner
}
