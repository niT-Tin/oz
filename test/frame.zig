//! Semantic frame assertions for the pty end-to-end harness.
//!
//! `test/e2e.zig` reconstructs a cell grid (text + packed RGB fg/bg) from the
//! terminal byte stream. The helpers here assert *meaning* on that grid —
//! complete regions, drawn boxes, overlap, overflow — so layout tests can
//! avoid magic pixel/row arithmetic and copied constants.
//!
//! The functions are generic over the grid type (`anytype`) and only read the
//! public fields `rows`, `cols`, `buf`, `fg_buf`, `bg_buf`. Cell text slots
//! hold one UTF-8 glyph (possibly multi-byte) and are NUL-terminated.
//!
//! Cursor position is deliberately NOT exposed: the grid parser consumes
//! CSI H/f/G sequences as drawing writes and does not separate vaxis's final
//! cursor placement from them. Focus is asserted through visible state
//! instead (accent rail border, status text, cursorline background). Tests
//! that need a cursor should assert the rendered cell, not a cursor API.
const std = @import("std");

/// Inclusive cell rectangle (top/left/right/bottom are screen cells).
pub const Rect = struct {
    top: usize,
    left: usize,
    right: usize,
    bottom: usize,

    pub fn width(self: Rect) usize {
        return self.right - self.left + 1;
    }

    pub fn height(self: Rect) usize {
        return self.bottom - self.top + 1;
    }

    pub fn contains(self: Rect, row: usize, col: usize) bool {
        return row >= self.top and row <= self.bottom and col >= self.left and col <= self.right;
    }

    /// True when the two rectangles share at least one cell. Sharing only a
    /// border row/column also counts: panes must not overlap, not merely
    /// avoid covering each other's interior.
    pub fn intersects(self: Rect, other: Rect) bool {
        return self.left <= other.right and other.left <= self.right and
            self.top <= other.bottom and other.top <= self.bottom;
    }
};

/// Text of one screen cell ("" for an unpainted cell).
pub fn cellText(grid: anytype, row: usize, col: usize) []const u8 {
    if (row >= grid.rows or col >= grid.cols) return "";
    const slot = grid.buf[(row * grid.cols + col) * 4 ..][0..4];
    var n: usize = 0;
    while (n < 4 and slot[n] != 0) : (n += 1) {}
    return slot[0..n];
}

pub fn cellBg(grid: anytype, row: usize, col: usize) u32 {
    if (row >= grid.rows or col >= grid.cols) return 0;
    return grid.bg_buf[row * grid.cols + col];
}

pub fn cellFg(grid: anytype, row: usize, col: usize) u32 {
    if (row >= grid.rows or col >= grid.cols) return 0;
    return grid.fg_buf[row * grid.cols + col];
}

/// SGR 58 underline color of one cell (0 = terminal default).
pub fn cellUl(grid: anytype, row: usize, col: usize) u32 {
    if (row >= grid.rows or col >= grid.cols) return 0;
    return grid.ul_buf[row * grid.cols + col];
}

/// True when the cell has an SGR 4 single underline.
pub fn cellUnderlined(grid: anytype, row: usize, col: usize) bool {
    if (row >= grid.rows or col >= grid.cols) return false;
    return grid.ul_on_buf[row * grid.cols + col];
}

fn widthOfGlyph(text: []const u8) usize {
    if (text.len == 0) return 1;
    const cp = std.unicode.utf8Decode(text) catch return 1;
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33FF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE10 and cp <= 0xFE19) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE6B) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F000 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x3FFFD) return 2;
    return 1;
}

fn rectInside(grid: anytype, rect: Rect) bool {
    return rect.top <= rect.bottom and rect.left <= rect.right and
        rect.bottom < grid.rows and rect.right < grid.cols;
}

fn dumpRegion(grid: anytype, rect: Rect) void {
    std.debug.print("region: top={d} left={d} right={d} bottom={d}\n", .{
        rect.top, rect.left, rect.right, rect.bottom,
    });
    var r = rect.top;
    while (r <= rect.bottom and r < grid.rows) : (r += 1) {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(std.heap.page_allocator);
        var c = rect.left;
        while (c <= rect.right and c < grid.cols) : (c += 1) {
            const t = cellText(grid, r, c);
            line.appendSlice(std.heap.page_allocator, if (t.len == 0) " " else t) catch {};
        }
        std.debug.print("|{s}|\n", .{line.items});
    }
}

pub fn expectCellBg(grid: anytype, row: usize, col: usize, color: u32) !void {
    if (row >= grid.rows or col >= grid.cols) {
        std.debug.print("cell out of bounds: ({d},{d}) grid {d}x{d}\n", .{ row, col, grid.rows, grid.cols });
        return error.TestUnexpectedResult;
    }
    const got = cellBg(grid, row, col);
    if (got != color) {
        std.debug.print("cell bg mismatch at ({d},{d}): expected #{x:0>6}, got #{x:0>6}\n", .{
            row, col, color, got,
        });
        return error.TestUnexpectedResult;
    }
}

pub fn expectCellUl(grid: anytype, row: usize, col: usize, color: u32) !void {
    if (row >= grid.rows or col >= grid.cols) {
        std.debug.print("cell out of bounds: ({d},{d}) grid {d}x{d}\n", .{ row, col, grid.rows, grid.cols });
        return error.TestUnexpectedResult;
    }
    const got = cellUl(grid, row, col);
    if (got != color) {
        std.debug.print("cell underline mismatch at ({d},{d}): expected #{x:0>6}, got #{x:0>6}\n", .{
            row, col, color, got,
        });
        return error.TestUnexpectedResult;
    }
    if (!cellUnderlined(grid, row, col)) {
        std.debug.print("cell at ({d},{d}) has underline color but SGR 4 is off\n", .{ row, col });
        return error.TestUnexpectedResult;
    }
}

pub fn expectCellFg(grid: anytype, row: usize, col: usize, color: u32) !void {
    if (row >= grid.rows or col >= grid.cols) {
        std.debug.print("cell out of bounds: ({d},{d}) grid {d}x{d}\n", .{ row, col, grid.rows, grid.cols });
        return error.TestUnexpectedResult;
    }
    const got = cellFg(grid, row, col);
    if (got != color) {
        std.debug.print("cell fg mismatch at ({d},{d}): expected #{x:0>6}, got #{x:0>6}\n", .{
            row, col, color, got,
        });
        return error.TestUnexpectedResult;
    }
}

/// Assert every cell in `rect` has the same background color.
pub fn expectRegionBg(grid: anytype, rect: Rect, color: u32) !void {
    if (!rectInside(grid, rect)) {
        std.debug.print("expectRegionBg: invalid rect top={d} left={d} right={d} bottom={d} for grid {d}x{d}\n", .{
            rect.top, rect.left, rect.right, rect.bottom, grid.rows, grid.cols,
        });
        return error.TestUnexpectedResult;
    }
    var r = rect.top;
    while (r <= rect.bottom) : (r += 1) {
        var c = rect.left;
        while (c <= rect.right) : (c += 1) {
            const got = cellBg(grid, r, c);
            if (got != color) {
                std.debug.print("region bg mismatch at ({d},{d}): expected #{x:0>6}, got #{x:0>6}\n", .{
                    r, c, color, got,
                });
                dumpRegion(grid, rect);
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Assert every cell in `rect` has the same foreground color (text color).
pub fn expectRegionFg(grid: anytype, rect: Rect, color: u32) !void {
    if (!rectInside(grid, rect)) return error.TestUnexpectedResult;
    var r = rect.top;
    while (r <= rect.bottom) : (r += 1) {
        var c = rect.left;
        while (c <= rect.right) : (c += 1) {
            const got = cellFg(grid, r, c);
            if (got != color) {
                std.debug.print("region fg mismatch at ({d},{d}): expected #{x:0>6}, got #{x:0>6}\n", .{
                    r, c, color, got,
                });
                dumpRegion(grid, rect);
                return error.TestUnexpectedResult;
            }
        }
    }
}

fn matchAsciiAt(grid: anytype, row: usize, col: usize, needle: []const u8, right: usize) bool {
    var c = col;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (c > right or c >= grid.cols) return false;
        var t = cellText(grid, row, c);
        if (t.len == 0) t = " ";
        if (needle[i] > 0x7f or t.len != 1 or t[0] != needle[i]) return false;
        c += 1;
    }
    return true;
}

/// Assert `needle` appears on a single row inside `rect`. Needles are ASCII;
/// cell boundaries are respected (a 3-byte border glyph is one cell).
pub fn expectTextInRegion(grid: anytype, rect: Rect, needle: []const u8) !void {
    if (!rectInside(grid, rect)) {
        std.debug.print("expectTextInRegion: invalid rect for grid {d}x{d}\n", .{ grid.rows, grid.cols });
        return error.TestUnexpectedResult;
    }
    var r = rect.top;
    while (r <= rect.bottom) : (r += 1) {
        var c = rect.left;
        while (c <= rect.right) : (c += 1) {
            if (matchAsciiAt(grid, r, c, needle, rect.right)) return;
        }
    }
    std.debug.print("missing '{s}' in region top={d} left={d} right={d} bottom={d}\n", .{
        needle, rect.top, rect.left, rect.right, rect.bottom,
    });
    dumpRegion(grid, rect);
    return error.TestUnexpectedResult;
}

/// Assert two rectangles do not share a cell.
pub fn expectNoOverlap(a: Rect, b: Rect) !void {
    if (!a.intersects(b)) return;
    std.debug.print("rectangles overlap:\n  a: top={d} left={d} right={d} bottom={d}\n  b: top={d} left={d} right={d} bottom={d}\n", .{
        a.top, a.left, a.right, a.bottom,
        b.top, b.left, b.right, b.bottom,
    });
    return error.TestUnexpectedResult;
}

fn glyphColInRow(grid: anytype, row: usize, glyph: []const u8, from: usize) ?usize {
    var c = from;
    while (c < grid.cols) : (c += 1) {
        const t = cellText(grid, row, c);
        if (t.len > 0 and std.mem.startsWith(u8, t, glyph)) return c;
    }
    return null;
}

fn lastGlyphColInRow(grid: anytype, row: usize, glyph: []const u8) ?usize {
    var c: usize = grid.cols;
    while (c > 0) {
        c -= 1;
        const t = cellText(grid, row, c);
        if (t.len > 0 and std.mem.startsWith(u8, t, glyph)) return c;
    }
    return null;
}

/// Compute the cell rectangle of the rounded box whose top border is on
/// `top`, from the drawn frame itself (not from layout arithmetic). Returns
/// null when no complete box is visible.
pub fn boxRect(grid: anytype, top: usize) ?Rect {
    if (top >= grid.rows) return null;
    const left = glyphColInRow(grid, top, "╭", 0) orelse return null;
    const right = glyphColInRow(grid, top, "╮", left + 1) orelse return null;
    var r = top + 1;
    while (r < grid.rows) : (r += 1) {
        const l = glyphColInRow(grid, r, "╰", 0) orelse continue;
        const rr = lastGlyphColInRow(grid, r, "╯") orelse continue;
        if (l != left or rr != right) continue;
        return .{ .top = top, .left = left, .right = right, .bottom = r };
    }
    return null;
}

/// Find the top row of a box whose title contains `needle` (e.g. "files"),
/// then compute its rectangle from the drawn corners.
pub fn findBoxByTitle(grid: anytype, needle: []const u8) ?Rect {
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        var c: usize = 0;
        while (c < grid.cols) : (c += 1) {
            if (matchAsciiAt(grid, r, c, needle, grid.cols - 1)) {
                if (boxRect(grid, r)) |rect| return rect;
            }
        }
    }
    return null;
}

/// Validate a rounded border box at `rect`: corners at the exact cells,
/// vertical borders on every interior row, and (optionally) the border
/// foreground color on all side/corner cells. Horizontal segments are not
/// color-checked because titles and focus accents may differ.
pub fn expectBorderBox(grid: anytype, rect: Rect, border_color: ?u32) !void {
    if (!rectInside(grid, rect)) {
        std.debug.print("expectBorderBox: invalid rect for grid {d}x{d}\n", .{ grid.rows, grid.cols });
        return error.TestUnexpectedResult;
    }
    const corners = [_]struct { row: usize, col: usize, glyph: []const u8 }{
        .{ .row = rect.top, .col = rect.left, .glyph = "╭" },
        .{ .row = rect.top, .col = rect.right, .glyph = "╮" },
        .{ .row = rect.bottom, .col = rect.left, .glyph = "╰" },
        .{ .row = rect.bottom, .col = rect.right, .glyph = "╯" },
    };
    for (corners) |corner| {
        const got = cellText(grid, corner.row, corner.col);
        if (!std.mem.startsWith(u8, got, corner.glyph)) {
            std.debug.print("border corner mismatch at ({d},{d}): expected {s}, got \"{s}\"\n", .{
                corner.row, corner.col, corner.glyph, got,
            });
            dumpRegion(grid, rect);
            return error.TestUnexpectedResult;
        }
    }
    var r = rect.top + 1;
    while (r < rect.bottom) : (r += 1) {
        if (!std.mem.startsWith(u8, cellText(grid, r, rect.left), "│")) {
            std.debug.print("missing left border at ({d},{d})\n", .{ r, rect.left });
            dumpRegion(grid, rect);
            return error.TestUnexpectedResult;
        }
        if (!std.mem.startsWith(u8, cellText(grid, r, rect.right), "│")) {
            std.debug.print("missing right border at ({d},{d})\n", .{ r, rect.right });
            dumpRegion(grid, rect);
            return error.TestUnexpectedResult;
        }
    }
    if (border_color) |color| {
        for (corners) |corner| try expectCellFg(grid, corner.row, corner.col, color);
        r = rect.top + 1;
        while (r < rect.bottom) : (r += 1) {
            try expectCellFg(grid, r, rect.left, color);
            try expectCellFg(grid, r, rect.right, color);
        }
    }
}

/// Screen-level overflow guard.
///
/// The ANSI-to-grid parser clamps out-of-range writes, so a cell index can
/// never exceed `grid.cols`; what this checks is the observable consequence:
/// wide glyphs starting in the last usable column (they would need a cell
/// past the screen), and any painted cell past an explicit content limit
/// (e.g. a pane that should stop at the status bar or before the rail).
/// Wrapped-line artifacts are covered by region assertions in the scenario
/// matrix; this helper deliberately does not guess layout.
pub fn expectNoHorizontalOverflow(grid: anytype, width: ?usize) !void {
    const limit = width orelse grid.cols;
    if (grid.cols == 0 or grid.rows == 0 or limit == 0 or limit > grid.cols) {
        std.debug.print("expectNoHorizontalOverflow: invalid grid {d}x{d} limit {d}\n", .{
            grid.rows, grid.cols, limit,
        });
        return error.TestUnexpectedResult;
    }
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        var c = limit;
        while (c < grid.cols) : (c += 1) {
            const t = cellText(grid, r, c);
            if (t.len > 0) {
                std.debug.print("painted cell past width {d} at ({d},{d}): \"{s}\"\n", .{ limit, r, c, t });
                return error.TestUnexpectedResult;
            }
        }
        const edge = limit - 1;
        const t = cellText(grid, r, edge);
        if (t.len > 0 and widthOfGlyph(t) > 1) {
            std.debug.print("wide glyph starts in last usable column ({d},{d}): \"{s}\"\n", .{ r, edge, t });
            return error.TestUnexpectedResult;
        }
    }
}

/// Assert a region is completely filled (its background is never the
/// default/unpainted 0) — catches holes from a pane that stopped early.
pub fn expectRegionPainted(grid: anytype, rect: Rect) !void {
    if (!rectInside(grid, rect)) return error.TestUnexpectedResult;
    var r = rect.top;
    while (r <= rect.bottom) : (r += 1) {
        var c = rect.left;
        while (c <= rect.right) : (c += 1) {
            if (cellBg(grid, r, c) == 0) {
                std.debug.print("unpainted cell at ({d},{d}) in region\n", .{ r, c });
                dumpRegion(grid, rect);
                return error.TestUnexpectedResult;
            }
        }
    }
}
