//! Navigator tab model (DESIGN.md §18.3/§18.8, M2b1).
//!
//! Deliberately App/vaxis-independent so the tab transitions are unit-tested
//! without building an editor or a terminal. `src/app/notes.zig` owns the
//! App-facing focus/key handling; `src/app/render.zig` draws the strip.
//!
//! The three tabs are the approved left navigator: `files` (the existing
//! lazy file tree), `notes` (the markdown note list) and `agents` (a
//! navigator view of the session's real AI threads, never a second source
//! of truth).

const std = @import("std");

/// Tab order is the drawn order in the title strip.
pub const Tab = enum { files, notes, agents };

pub const count: usize = @typeInfo(Tab).@"enum".field_names.len;

pub const all = [_]Tab{ .files, .notes, .agents };

/// The full 30-cell navigator needs room for the brand header, three
/// icon+label tabs and the editor beside a docked Agent Rail. Below this
/// width the navigator collapses to an icon rail + peek overlay (the
/// approved demo's narrow layout).
pub const full_min_cols: u32 = 90;

/// Closed navigator box width in full mode (the panel plus its two borders).
/// The editor starts at `panel_width + gutter`.
pub const panel_width: u32 = 30;

/// Compact icon rail width including its right border. Content cells are
/// `compact_width - 1`; the editor starts at `compact_width + gutter`.
pub const compact_width: u32 = 7;

/// Blank column between the navigator and editor content in both modes.
pub const gutter: u32 = 1;

/// Rows above the first content row in full/peek mode: branded top border,
/// workspace/branch line, tab strip and the closing rule.
pub const full_header_rows: u32 = 4;

/// Compact rail rows: OZ (row 0), hairline (row 1), then one two-row button
/// per tab starting at `compact_first_tab_row`.
pub const compact_first_tab_row: u32 = 2;
pub const compact_tab_rows: u32 = 2;

pub const Mode = enum { full, compact };

/// Full navigator at >= 90 columns, icon rail below (matches the demo's
/// narrow breakpoint and keeps the editor usable beside the AI drawer).
pub fn modeForCols(cols: u32) Mode {
    return if (cols >= full_min_cols) .full else .compact;
}

/// Panel width (including borders) for a mode.
pub fn panelWidth(mode: Mode) u32 {
    return switch (mode) {
        .full => panel_width,
        .compact => compact_width,
    };
}

/// Absolute column where editor content starts for a navigator state.
pub fn editorCol(active: bool, cols: u32) u32 {
    if (!active) return 0;
    return panelWidth(modeForCols(cols)) + gutter;
}

/// Position of `tab` in the strip (0-based).
pub fn index(tab: Tab) usize {
    return @backingInt(tab);
}

/// Tab at strip position `i` (wrapping, so callers cannot index out of
/// bounds when cycling).
pub fn fromIndex(i: i32) Tab {
    return all[@intCast(@mod(i, @as(i32, @intCast(count))))];
}

/// Next/previous tab with wrap-around. `delta` is +1 for Tab and -1 for
/// Shift+Tab.
pub fn next(tab: Tab, delta: i32) Tab {
    return fromIndex(@as(i32, @intCast(index(tab))) + delta);
}

/// The direct-selection digit (`1`/`2`/`3`) for a tab, or null. Plain
/// digits are free while the navigator owns the keyboard: the file tree
/// never consumed them, so this cannot shadow a vim count there.
pub fn fromDigit(cp: u21) ?Tab {
    return switch (cp) {
        '1' => .files,
        '2' => .notes,
        '3' => .agents,
        else => null,
    };
}

/// Static label drawn in the strip. Capitalized to match the approved demo
/// (`Files / Notes / Agents`); the Workbox keeps its lowercase chrome.
pub fn label(tab: Tab) []const u8 {
    return switch (tab) {
        .files => "Files",
        .notes => "Notes",
        .agents => "Agents",
    };
}

// ---------------------------------------------------------------------------
// Full-mode tab geometry
// ---------------------------------------------------------------------------

/// Real counts per tab, in `all` order. `null` means "not known yet" for a
/// lazily loaded view (Notes before the first list load): no badge is drawn
/// rather than a fabricated zero.
pub const Counts = [count]?usize;

pub const TabLayout = struct {
    /// True when at least one tab draws a count badge.
    shown_counts: bool,
    /// Inner-cell start of each tab (0-based from the panel's inside edge).
    starts: [count]u16,
    /// Inner-cell width of each tab.
    widths: [count]u16,
    /// Inner-cell start of the count badge (only when that tab's count was
    /// drawn; otherwise 0 and `has_count` is false).
    count_starts: [count]u16,
    has_count: [count]bool,
    /// Cells occupied by the tab strip (excluding trailing padding).
    used: u16,
};

fn digits(n: usize) u16 {
    var v = n;
    var d: u16 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn tabWidth(tab: Tab, count_value: ?usize, with_counts: bool) u16 {
    const base: u16 = 1 + 1 + @as(u16, @intCast(label(tab).len)); // icon + space + label
    if (with_counts) {
        if (count_value) |n| return base + digits(n);
    }
    return base;
}

fn measure(counts: Counts, with_counts: bool, gap: u16) u16 {
    var used: u16 = 0;
    for (all, 0..) |tab, i| {
        if (i > 0) used += gap;
        used += tabWidth(tab, counts[i], with_counts);
    }
    return used;
}

/// Fit the three tabs into `inner` cells. Counts are a compact badge directly
/// after the label (`Files15`); when all three do not fit, the badges are
/// dropped rather than truncating a label. The renderer and tests share this
/// geometry, so hint/mouse columns cannot drift from the drawn strip.
pub fn layoutTabs(counts: Counts, inner: u16) TabLayout {
    var with_counts = true;
    var gap: u16 = 1;
    if (measure(counts, true, gap) > inner) {
        gap = 0;
        if (measure(counts, true, gap) > inner) {
            with_counts = false;
            gap = 1;
        }
    }
    var out: TabLayout = .{
        .shown_counts = false,
        .starts = undefined,
        .widths = undefined,
        .count_starts = @splat(0),
        .has_count = @splat(false),
        .used = 0,
    };
    var pos: u16 = 0;
    for (all, 0..) |tab, i| {
        if (i > 0) pos += gap;
        out.starts[i] = pos;
        out.widths[i] = tabWidth(tab, counts[i], with_counts);
        if (with_counts) {
            if (counts[i]) |_| {
                out.has_count[i] = true;
                out.shown_counts = true;
                out.count_starts[i] = pos + 1 + 1 + @as(u16, @intCast(label(tab).len));
            }
        }
        pos += out.widths[i];
    }
    out.used = pos;
    return out;
}

/// `workspace / branch`, or just the workspace when the branch is unknown
/// (startup, non-git tree) or empty. Owned by the caller's buffer; the
/// renderer truncates to the panel budget.
pub fn workspaceLine(ws: []const u8, branch: ?[]const u8, buf: []u8) []const u8 {
    if (branch) |b| {
        if (b.len > 0) {
            return std.fmt.bufPrint(buf, "{s} / {s}", .{ ws, b }) catch ws;
        }
    }
    return std.fmt.bufPrint(buf, "{s}", .{ws}) catch ws;
}

/// Compact-mode icon selection: the same icon toggles an open peek closed;
/// any other tab opens/switches the peek. Returns the tab to show, or null
/// for "close the peek".
pub fn peekAfterSelect(peek_open: bool, active: Tab, requested: Tab) ?Tab {
    if (peek_open and active == requested) return null;
    return requested;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "navigator: tab order, labels and direct digits" {
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(Tab.files, fromIndex(0));
    try std.testing.expectEqual(Tab.notes, fromIndex(1));
    try std.testing.expectEqual(Tab.agents, fromIndex(2));
    try std.testing.expectEqualStrings("Files", label(.files));
    try std.testing.expectEqualStrings("Notes", label(.notes));
    try std.testing.expectEqualStrings("Agents", label(.agents));
    try std.testing.expectEqual(Tab.files, fromDigit('1').?);
    try std.testing.expectEqual(Tab.notes, fromDigit('2').?);
    try std.testing.expectEqual(Tab.agents, fromDigit('3').?);
    try std.testing.expectEqual(@as(?Tab, null), fromDigit('4'));
    try std.testing.expectEqual(@as(?Tab, null), fromDigit('0'));
}

test "navigator: next/prev wrap in both directions" {
    try std.testing.expectEqual(Tab.notes, next(.files, 1));
    try std.testing.expectEqual(Tab.agents, next(.notes, 1));
    try std.testing.expectEqual(Tab.files, next(.agents, 1));
    try std.testing.expectEqual(Tab.agents, next(.files, -1));
    try std.testing.expectEqual(Tab.files, next(.notes, -1));
    try std.testing.expectEqual(Tab.notes, next(.agents, -1));
    // a full cycle returns to the origin
    var t = Tab.files;
    var i: usize = 0;
    while (i < count) : (i += 1) t = next(t, 1);
    try std.testing.expectEqual(Tab.files, t);
}

test "navigator: index and wrapped fromIndex cover every tab" {
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        try std.testing.expectEqual(all[i], fromIndex(@intCast(i)));
        try std.testing.expectEqual(i, index(all[i]));
    }
    try std.testing.expectEqual(Tab.files, fromIndex(-3));
    try std.testing.expectEqual(Tab.agents, fromIndex(5));
}

test "navigator: full/compact breakpoint and editor columns" {
    try std.testing.expectEqual(Mode.compact, modeForCols(59));
    try std.testing.expectEqual(Mode.compact, modeForCols(60));
    try std.testing.expectEqual(Mode.compact, modeForCols(80));
    try std.testing.expectEqual(Mode.compact, modeForCols(89));
    try std.testing.expectEqual(Mode.full, modeForCols(90));
    try std.testing.expectEqual(Mode.full, modeForCols(120));
    try std.testing.expectEqual(Mode.full, modeForCols(200));

    try std.testing.expectEqual(@as(u32, 0), editorCol(false, 80));
    try std.testing.expectEqual(@as(u32, 31), editorCol(true, 90));
    try std.testing.expectEqual(@as(u32, 31), editorCol(true, 120));
    try std.testing.expectEqual(@as(u32, 8), editorCol(true, 80));
    try std.testing.expectEqual(@as(u32, 8), editorCol(true, 60));
}

test "navigator: tab layout fits 28 cells with compact count badges" {
    const inner: u16 = panel_width - 2;
    // Realistic counts: a two-digit Files count and one-digit Notes/Agents.
    const a = layoutTabs(.{ 15, 2, 1 }, inner);
    try std.testing.expect(a.shown_counts);
    try std.testing.expectEqual(@as(u16, 28), a.used);
    try std.testing.expectEqual(@as(u16, 0), a.starts[0]);
    try std.testing.expectEqual(@as(u16, 10), a.starts[1]);
    try std.testing.expectEqual(@as(u16, 19), a.starts[2]);
    try std.testing.expectEqual(@as(u16, 9), a.widths[0]);
    try std.testing.expectEqual(@as(u16, 8), a.widths[1]);
    try std.testing.expectEqual(@as(u16, 9), a.widths[2]);
    try std.testing.expect(a.has_count[0]);

    // One-digit counts keep all three badges plus one spare cell.
    const b = layoutTabs(.{ 4, 2, 1 }, inner);
    try std.testing.expect(b.shown_counts);
    try std.testing.expectEqual(@as(u16, 27), b.used);
    try std.testing.expectEqual(@as(u16, 9), b.starts[1]);

    // Huge counts do not fit: labels stay complete, badges are dropped.
    const c = layoutTabs(.{ 999, 999, 999 }, inner);
    try std.testing.expect(!c.shown_counts);
    try std.testing.expect(c.used <= inner);
    try std.testing.expectEqual(@as(u16, 7), c.widths[0]);
    try std.testing.expectEqual(@as(u16, 8), c.widths[2]);
    try std.testing.expect(!c.has_count[0]);

    // Notes not loaded yet: its badge is omitted; the others still draw.
    const d = layoutTabs(.{ 15, null, 0 }, inner);
    try std.testing.expect(d.shown_counts);
    try std.testing.expect(!d.has_count[1]);
    try std.testing.expect(d.has_count[0] and d.has_count[2]);
    try std.testing.expect(d.used <= inner);

    // All counts unknown: labels only.
    const e = layoutTabs(.{ null, null, null }, inner);
    try std.testing.expect(!e.shown_counts);
    try std.testing.expectEqual(@as(u16, 24), e.used);
}

test "navigator: workspace line and compact peek selection" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("main / feat/navigator-brand", workspaceLine("main", "feat/navigator-brand", &buf));
    try std.testing.expectEqualStrings("main", workspaceLine("main", null, &buf));
    try std.testing.expectEqualStrings("main", workspaceLine("main", "", &buf));

    try std.testing.expectEqual(@as(?Tab, .notes), peekAfterSelect(false, .files, .notes));
    try std.testing.expectEqual(@as(?Tab, null), peekAfterSelect(true, .notes, .notes));
    try std.testing.expectEqual(@as(?Tab, .agents), peekAfterSelect(true, .notes, .agents));
}
