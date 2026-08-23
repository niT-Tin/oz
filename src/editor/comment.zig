//! Comment toggling (DESIGN.md §1.3): gcc toggles the current line,
//! visual-mode gc toggles a range of lines. Markers per filetype.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Style = struct {
    line: []const u8, // e.g. "//" or "#"
};

/// Marker table (M0): zig/rust/go/ts/js/c/cpp → "//", python/bash → "#",
/// lua → "--", others → null (no comment support yet).
pub fn styleForFiletype(ft: []const u8) ?Style {
    _ = ft;
    @panic("TODO: implement");
}

/// Result of toggling: the new text for the whole line range, and whether the
/// range WAS fully commented (so gcc un-comments when everything is
/// commented and comments otherwise).
pub const Toggle = struct {
    text: []u8, // owned by caller (History copies)
    was_commented: bool,
};

/// Compute the toggled content for lines [start_line, end_line] inclusive.
/// Lines are examined ignoring leading whitespace; a line is "commented" when
/// its first non-blank bytes are exactly the marker.
pub fn toggleLines(
    allocator: std.mem.Allocator,
    pt: *const PieceTable,
    start_line: u32,
    end_line: u32,
    style: Style,
) !Toggle {
    _ = allocator;
    _ = pt;
    _ = start_line;
    _ = end_line;
    _ = style;
    @panic("TODO: implement");
}

test "comment toggle basic" {
    // implemented by module owner
}
