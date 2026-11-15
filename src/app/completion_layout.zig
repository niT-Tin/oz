//! Pure joint layout for the completion menu and its documentation pane.
//!
//! Inputs are measured in terminal cells by the renderer; this module only
//! decides rectangles inside the focused pane. Rules:
//!   * the menu stays next to the cursor and flips above near the bottom;
//!   * documentation prefers the right of the menu, then the left, then below
//!     or above (never on top of the menu);
//!   * every rectangle is clamped to the pane (Agent rail / splits are not
//!     available space);
//!   * the visible row count and maximum scroll are derived from the chosen
//!     rectangle, so scrolling cannot page past the pane.

const std = @import("std");

pub const Rect = struct {
    row: u32,
    col: u32,
    width: u32,
    height: u32,

    pub fn right(self: Rect) u32 {
        return self.col + self.width;
    }

    pub fn bottom(self: Rect) u32 {
        return self.row + self.height;
    }

    pub fn overlaps(a: Rect, b: Rect) bool {
        return a.col < b.right() and b.col < a.right() and
            a.row < b.bottom() and b.row < a.bottom();
    }
};

pub const Side = enum { right, left, below, above, none };

pub const Options = struct {
    /// Focused editor pane (screen cells; border-exclusive is fine).
    pane: Rect,
    /// Cursor screen position (absolute cell coordinates).
    cursor_row: u32,
    cursor_col: u32,
    /// Horizontal cells between the pane edge and content (gutter).
    gutter: u32 = 0,
    menu_width: u32,
    menu_rows: u32,
    /// Natural/unconstrained documentation width and wrapped line count.
    doc_width: u32 = 64,
    doc_total_rows: u32 = 0,
    /// Minimum documentation width to bother placing it.
    min_doc_width: u32 = 24,
    /// Maximum visible documentation rows (excluding its border).
    max_doc_rows: u32 = 14,
};

pub const Plan = struct {
    /// Both rectangles include their border cells.
    menu: Rect,
    doc: Rect = .{ .row = 0, .col = 0, .width = 0, .height = 0 },
    side: Side = .none,
    doc_visible_rows: u32 = 0,
    scroll_max: u32 = 0,
};

const MenuSlot = struct { row: u32, height: u32 };

fn menuSlot(pane_rect: Rect, cursor: u32, rows: u32) MenuSlot {
    if (pane_rect.height == 0) return .{ .row = pane_rect.row, .height = 0 };
    const caret = std.math.clamp(cursor, pane_rect.row, pane_rect.bottom() - 1);
    const below = pane_rect.bottom() - caret - 1;
    const above = caret - pane_rect.row;
    const desired = rows + 2;
    const use_below = below >= desired or (above < desired and below >= above);
    const height = @min(desired, if (use_below) below else above);
    return .{ .row = if (use_below) caret + 1 else caret - height, .height = height };
}

/// Effective number of rows that fit on one side of the caret. The renderer
/// must use this for the visible slice, selection scroll and bottom border.
pub fn visibleMenuRows(pane_rect: Rect, cursor: u32, requested: u32) u32 {
    if (pane_rect.width < 3 or requested == 0) return 0;
    const slot = menuSlot(pane_rect, cursor, requested);
    return if (slot.height >= 3) slot.height - 2 else 0;
}

pub fn plan(o: Options) Plan {
    var out = Plan{ .menu = undefined };
    if (o.pane.width == 0 or o.pane.height == 0 or o.menu_width == 0 or o.menu_rows == 0) {
        out.menu = .{ .row = o.pane.row, .col = o.pane.col, .width = 0, .height = 0 };
        return out;
    }
    const menu_w = @min(o.menu_width, o.pane.width);
    const slot = menuSlot(o.pane, o.cursor_row, o.menu_rows);
    if (menu_w < 3 or slot.height < 3) {
        out.menu = .{ .row = o.pane.row, .col = o.pane.col, .width = 0, .height = 0 };
        return out;
    }
    const menu_h = slot.height;
    const menu_row = slot.row;
    var menu_col = o.cursor_col;
    if (menu_col + menu_w > o.pane.right()) menu_col = o.pane.right() -| menu_w;
    menu_col = std.math.clamp(menu_col, o.pane.col, o.pane.right() -| menu_w);
    out.menu = .{ .row = menu_row, .col = menu_col, .width = menu_w, .height = menu_h };

    if (o.doc_total_rows == 0) return out;

    const doc_rows: u32 = @min(o.doc_total_rows, o.max_doc_rows);
    const max_w = o.pane.width -| 2;
    const want_w = @min(o.doc_width, max_w);

    // Right of the menu, aligned with its top.
    const right_space = o.pane.right() -| (out.menu.right() + 2);
    if (right_space >= o.min_doc_width + 2) {
        const w = @min(want_w, right_space - 2);
        const avail_rows = o.pane.bottom() -| (menu_row + 1);
        if (avail_rows >= 4) {
            const rows = @min(doc_rows, avail_rows - 2);
            out.doc = .{ .row = menu_row, .col = out.menu.right() + 2, .width = w + 2, .height = rows + 2 };
            out.side = .right;
            out.doc_visible_rows = rows;
            out.scroll_max = o.doc_total_rows - rows;
            return out;
        }
    }

    // Left of the menu.
    const left_space = out.menu.col -| (o.pane.col + 2);
    if (left_space >= o.min_doc_width + 2) {
        const w = @min(want_w, left_space - 2);
        const avail_rows = o.pane.bottom() -| (menu_row + 1);
        if (avail_rows >= 4) {
            const rows = @min(doc_rows, avail_rows - 2);
            out.doc = .{ .row = menu_row, .col = out.menu.col - (w + 4), .width = w + 2, .height = rows + 2 };
            out.side = .left;
            out.doc_visible_rows = rows;
            out.scroll_max = o.doc_total_rows - rows;
            return out;
        }
    }

    // Below / above the menu, full pane width.
    const full_w = @min(want_w, max_w);
    const full_col = o.pane.col + (o.pane.width - (full_w + 2)) / 2;
    const below_rows = o.pane.bottom() -| (out.menu.bottom() + 1);
    if (below_rows >= 4) {
        const rows = @min(doc_rows, below_rows - 2);
        out.doc = .{ .row = out.menu.bottom() + 1, .col = full_col, .width = full_w + 2, .height = rows + 2 };
        out.side = .below;
        out.doc_visible_rows = rows;
        out.scroll_max = o.doc_total_rows - rows;
        return out;
    }
    const above_rows = out.menu.row -| (o.pane.row + 1);
    if (above_rows >= 4) {
        const rows = @min(doc_rows, above_rows - 2);
        out.doc = .{ .row = out.menu.row - (rows + 3), .col = full_col, .width = full_w + 2, .height = rows + 2 };
        out.side = .above;
        out.doc_visible_rows = rows;
        out.scroll_max = o.doc_total_rows - rows;
        return out;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn pane() Rect {
    return .{ .row = 2, .col = 30, .width = 90, .height = 26 };
}

test "completion layout: doc prefers the right and stays inside the pane" {
    const t = std.testing;
    const p = plan(.{
        .pane = pane(),
        .cursor_row = 8,
        .cursor_col = 30,
        .menu_width = 38,
        .menu_rows = 8,
        .doc_total_rows = 10,
    });
    try t.expectEqual(Side.right, p.side);
    try t.expect(p.doc.col >= p.menu.right());
    try t.expect(p.doc.right() <= pane().right());
    try t.expect(p.doc.bottom() <= pane().bottom());
    try t.expect(!Rect.overlaps(p.menu, p.doc));
    try t.expectEqual(@as(u32, 10), p.doc_visible_rows);
    try t.expectEqual(@as(u32, 0), p.scroll_max);
}

test "completion layout: long docs scroll within the visible rectangle" {
    const t = std.testing;
    const p = plan(.{
        .pane = pane(),
        .cursor_row = 8,
        .cursor_col = 40,
        .menu_width = 38,
        .menu_rows = 8,
        .doc_total_rows = 40,
    });
    try t.expectEqual(@as(u32, 14), p.doc_visible_rows);
    try t.expectEqual(@as(u32, 26), p.scroll_max);
    try t.expect(p.doc.bottom() <= pane().bottom());
}

test "completion layout: narrow right side falls back to left or below, never overlap" {
    const t = std.testing;
    // Menu is wide and near the right edge: no room on either side, so the
    // docs go below.
    const p = plan(.{
        .pane = .{ .row = 0, .col = 0, .width = 80, .height = 24 },
        .cursor_row = 4,
        .cursor_col = 40,
        .menu_width = 74,
        .menu_rows = 6,
        .doc_width = 60,
        .doc_total_rows = 12,
    });
    try t.expectEqual(Side.below, p.side);
    try t.expect(!Rect.overlaps(p.menu, p.doc));
    try t.expect(p.doc.right() <= 80);
    try t.expect(p.doc.bottom() <= 24);
    try t.expect(p.doc_visible_rows >= 2);
}

test "completion layout: bottom-edge menu flips above the cursor" {
    const t = std.testing;
    const p = plan(.{
        .pane = .{ .row = 0, .col = 0, .width = 100, .height = 20 },
        .cursor_row = 18,
        .cursor_col = 10,
        .menu_width = 30,
        .menu_rows = 8,
        .doc_total_rows = 0,
    });
    try t.expect(p.menu.bottom() <= 20);
    try t.expect(p.menu.row <= 18);
    try t.expect(p.side == .none);
}

test "completion layout: no documentation space degrades to menu only" {
    const t = std.testing;
    const p = plan(.{
        .pane = .{ .row = 0, .col = 0, .width = 40, .height = 12 },
        .cursor_row = 10,
        .cursor_col = 0,
        .menu_width = 38,
        .menu_rows = 8,
        .doc_total_rows = 20,
    });
    try t.expect(p.side == .none);
    try t.expectEqual(@as(u32, 0), p.doc_visible_rows);
    try t.expect(p.menu.bottom() <= 12);
}

test "completion layout: stacked docs include both borders in a 50-cell pane" {
    const r = Rect{ .row = 2, .col = 30, .width = 50, .height = 26 };
    const p = plan(.{ .pane = r, .cursor_row = 2, .cursor_col = 30, .menu_width = 46, .menu_rows = 8, .doc_total_rows = 20 });
    try std.testing.expectEqual(Side.below, p.side);
    try std.testing.expectEqual(r.col, p.doc.col);
    try std.testing.expectEqual(r.width, p.doc.width);
    try std.testing.expectEqual(r.right(), p.doc.right());
}

test "completion layout: tiny and split panes keep every border and the caret in bounds" {
    for ([_]u32{ 1, 2, 3, 6, 24, 50, 60, 80, 120 }) |width| {
        for (1..29) |height| {
            const r = Rect{ .row = 3, .col = 7, .width = width, .height = @intCast(height) };
            for (0..height) |offset| {
                const caret = r.row + @as(u32, @intCast(offset));
                for ([_]u32{ r.col, r.col + width / 2, r.right() - 1 }) |column| {
                    const p = plan(.{ .pane = r, .cursor_row = caret, .cursor_col = column, .menu_width = 46, .menu_rows = 8, .doc_total_rows = 40 });
                    if (p.menu.height == 0) continue;
                    try std.testing.expect(p.menu.col >= r.col and p.menu.right() <= r.right());
                    try std.testing.expect(p.menu.row >= r.row and p.menu.bottom() <= r.bottom());
                    try std.testing.expect(caret < p.menu.row or caret >= p.menu.bottom());
                    try std.testing.expectEqual(p.menu.height - 2, visibleMenuRows(r, caret, 8));
                    if (p.side != .none) {
                        try std.testing.expect(p.doc.col >= r.col and p.doc.right() <= r.right());
                        try std.testing.expect(p.doc.row >= r.row and p.doc.bottom() <= r.bottom());
                        try std.testing.expect(!Rect.overlaps(p.menu, p.doc));
                        try std.testing.expectEqual(p.doc.height - 2, p.doc_visible_rows);
                    }
                }
            }
        }
    }
}
