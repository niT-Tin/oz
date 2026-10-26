//! Line-opening math shared by normal-mode `o`/`O` and insert-mode Enter.
//!
//! A line-ending-aware plan keeps CRLF buffers consistent: opening a line
//! must not splice a bare `\n` between the old line's content and its
//! `\r\n` (which produced a mixed-ending file and left the cursor inside
//! the terminator), and the cursor offset must count every inserted byte.
//!
//! The module is pure so the empty/indented/EOF/CRLF cases are unit-tested
//! without an App or pty.

const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Ending = enum { lf, crlf };

pub fn bytes(ending: Ending) []const u8 {
    return switch (ending) {
        .lf => "\n",
        .crlf => "\r\n",
    };
}

/// The line ending to use when inserting a newline at `line`.
///
/// Prefer the edited line's own terminator (`\n` vs `\r\n`). The last line
/// has no terminator (EOF without a trailing newline, or the phantom empty
/// line after one); use the nearest earlier line's terminator there, so
/// appending with `o` on a CRLF file keeps CRLF. An empty buffer defaults
/// to LF.
pub fn preferredEnding(pt: *const PieceTable, line: u32) Ending {
    const count = pt.lineCount();
    if (line + 1 < count) {
        const len = pt.lineLen(line);
        if (len > 0 and pt.byteAt(pt.lineStart(line) + len - 1) == '\r') return .crlf;
        return .lf;
    }
    // Last line: no terminator of its own. Walk back over at most a few
    // empty/terminator-less lines so a trailing blank line still inherits
    // the buffer's style; the first line with a terminator decides.
    var l = line;
    while (l > 0) {
        l -= 1;
        if (l + 1 >= count) continue;
        const len = pt.lineLen(l);
        if (len > 0 and pt.byteAt(pt.lineStart(l) + len - 1) == '\r') return .crlf;
        return .lf;
    }
    return .lf;
}

/// Bytes to insert for `o` (above == false) or `O` (above == true), plus
/// the cursor's byte offset from the insertion position.
///
/// `o`: `ending ++ indent`, cursor after both (the new line's indentation).
/// `O`: `indent ++ ending`, cursor after the indentation (before the
/// terminator). One record makes the whole open-line edit atomic in the
/// insert session's undo group.
pub const Plan = struct {
    text: []u8,
    cursor_off: u32,

    pub fn deinit(self: *const Plan, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

pub fn plan(alloc: std.mem.Allocator, ending: Ending, indent: []const u8, above: bool) !Plan {
    const e = bytes(ending);
    const text = try alloc.alloc(u8, e.len + indent.len);
    if (above) {
        @memcpy(text[0..indent.len], indent);
        @memcpy(text[indent.len..], e);
    } else {
        @memcpy(text[0..e.len], e);
        @memcpy(text[e.len..], indent);
    }
    return .{
        .text = text,
        .cursor_off = if (above) @intCast(indent.len) else @intCast(e.len + indent.len),
    };
}

// ============================== tests ======================================

fn expectPlan(alloc: std.mem.Allocator, ending: Ending, indent: []const u8, above: bool, expected: []const u8, expected_off: u32) !void {
    const p = try plan(alloc, ending, indent, above);
    defer p.deinit(alloc);
    try std.testing.expectEqualSlices(u8, expected, p.text);
    try std.testing.expectEqual(expected_off, p.cursor_off);
}

test "line_open: LF below/above with and without indent" {
    const a = std.testing.allocator;
    try expectPlan(a, .lf, "", false, "\n", 1);
    try expectPlan(a, .lf, "    ", false, "\n    ", 5);
    try expectPlan(a, .lf, "", true, "\n", 0);
    try expectPlan(a, .lf, "\t  ", true, "\t  \n", 3);
}

test "line_open: CRLF below/above keeps every byte counted" {
    const a = std.testing.allocator;
    try expectPlan(a, .crlf, "", false, "\r\n", 2);
    try expectPlan(a, .crlf, "        ", false, "\r\n        ", 10);
    try expectPlan(a, .crlf, "", true, "\r\n", 0);
    try expectPlan(a, .crlf, "    ", true, "    \r\n", 4);
}

test "line_open: preferredEnding follows the edited line, then earlier lines" {
    var lf = try PieceTable.init(std.testing.allocator, "a\nb\n");
    defer lf.deinit();
    try std.testing.expectEqual(Ending.lf, preferredEnding(&lf, 0));
    try std.testing.expectEqual(Ending.lf, preferredEnding(&lf, 1)); // phantom EOF line

    var crlf = try PieceTable.init(std.testing.allocator, "a\r\nb\r\n");
    defer crlf.deinit();
    try std.testing.expectEqual(Ending.crlf, preferredEnding(&crlf, 0));
    try std.testing.expectEqual(Ending.crlf, preferredEnding(&crlf, 1));
    try std.testing.expectEqual(Ending.crlf, preferredEnding(&crlf, 2)); // trailing phantom line

    // Last line without a terminator inherits from the line above (the
    // common no-trailing-newline EOF case).
    var no_nl = try PieceTable.init(std.testing.allocator, "a\r\nb");
    defer no_nl.deinit();
    try std.testing.expectEqual(Ending.crlf, preferredEnding(&no_nl, 1));

    // Mixed buffer: each line uses its own terminator.
    var mixed = try PieceTable.init(std.testing.allocator, "a\nb\r\nc\n");
    defer mixed.deinit();
    try std.testing.expectEqual(Ending.lf, preferredEnding(&mixed, 0));
    try std.testing.expectEqual(Ending.crlf, preferredEnding(&mixed, 1));
    try std.testing.expectEqual(Ending.lf, preferredEnding(&mixed, 2));

    // Empty buffer defaults to LF.
    var empty = try PieceTable.init(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(Ending.lf, preferredEnding(&empty, 0));
}
