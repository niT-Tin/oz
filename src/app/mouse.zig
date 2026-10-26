//! Mouse support (feat/mouse): pure hit-testing, scroll clamping and
//! screen-cell → buffer-byte mapping.
//!
//! Deliberately App/vaxis-loop independent: `src/app/mouse_ui.zig` owns the
//! App-facing half (target collection from the render pass, click/scroll
//! dispatch onto the SAME methods the keyboard/hints use). Everything here
//! is unit-testable without constructing an editor or a terminal.
//!
//! ## Target registry
//!
//! The keyboard-hint renderer already registers the clickable geometry of
//! every action target while it draws (`addHintTarget`). Mouse frames run the
//! same registrations — `State.collecting` is true whenever mouse reporting
//! is enabled — and the same action union, so there is exactly one source of
//! truth for geometry and no duplicated business logic. Editor panes and
//! scroll regions are mouse-only targets (hint mode never labels them).
//!
//! ## Hit priority
//!
//! A click picks the SMALLEST containing clickable target (a 1×1 close `×`
//! inside a tab beats the tab; a 3-cell approve button beats the row/card it
//! sits on). Equal-area overlaps pick the later registration (draw order =
//! topmost). Wheel events pick the smallest containing scroll target.
//!
//! No allocation happens in the registry: one fixed array, reset per frame.

const std = @import("std");
const vaxis = @import("vaxis");
const hints = @import("hints.zig");

/// Fixed capacity: visible hint targets (≤128) plus split panes, separators
/// and scroll regions. Mouse frames never allocate.
pub const max_targets: usize = 256;

/// One on-screen cell rectangle (screen coordinates).
pub const Rect = struct {
    row: u32,
    col: u32,
    width: u32,
    height: u32,
};

/// What a left click does. `hint` reuses the existing hint action union and
/// its dispatcher (`execHintAction`); the other variants are mouse-only.
pub const ClickAction = union(enum) {
    /// A hint target: buffer tab / close × / filetree row / navigator tab /
    /// note row / agent thread / workbox tab / prompt / approve button /
    /// tool card … — executed through the existing action mapping.
    hint: hints.Action,
    /// Focus the split leaf (and place the cursor from the click position).
    focus_pane: usize,
    /// Split separator: explicitly a no-op in v1 (no resize).
    separator,
};

/// Region under the wheel. Editor carries the split leaf it belongs to so
/// scrolling an unfocused pane moves THAT pane's cursor.
pub const Scroll = union(enum) {
    editor: usize,
    navigator_files,
    navigator_notes,
    navigator_agents,
    ai_threads,
    ai_workbox,
};

pub const Action = union(enum) {
    click: ClickAction,
    scroll: Scroll,
};

pub const Target = struct {
    rect: Rect,
    action: Action,
};

pub const Hit = struct {
    index: usize,
    target: Target,
};

pub const State = struct {
    /// True only after `setMouseMode(true)` succeeded; target collection and
    /// event handling are disabled otherwise (the app still starts).
    enabled: bool = false,
    /// True during a render pass that should collect hit targets.
    collecting: bool = false,
    count: usize = 0,
    targets: [max_targets]Target = undefined,
    rows: u32 = 0,
    cols: u32 = 0,

    /// Start a frame's target collection. Cheap (one branch) while mouse
    /// reporting is disabled; resets the previous frame's targets.
    pub fn beginFrame(self: *State, rows: u32, cols: u32) void {
        self.count = 0;
        self.rows = rows;
        self.cols = cols;
        self.collecting = self.enabled and rows > 0 and cols > 0;
    }

    /// Register one target. Off-screen/empty rects are dropped (clamped to
    /// the visible part) and targets past capacity are ignored — a stale or
    /// pathological layout must never panic the frame.
    pub fn add(self: *State, rect: Rect, action: Action) void {
        if (!self.collecting or self.count >= max_targets) return;
        const clamped = clampRect(rect, self.rows, self.cols) orelse return;
        self.targets[self.count] = .{ .rect = clamped, .action = action };
        self.count += 1;
    }

    /// Stop collecting (does not clear the last frame's targets; a click is
    /// always handled before the next render).
    pub fn endFrame(self: *State) void {
        self.collecting = false;
    }

    /// Smallest clickable target containing (col,row). Later registrations
    /// win equal-area ties (they were drawn on top).
    pub fn hitClick(self: *const State, col: i64, row: i64) ?Hit {
        return self.hitMatching(col, row, false);
    }

    /// Smallest scroll target containing (col,row).
    pub fn hitScroll(self: *const State, col: i64, row: i64) ?Hit {
        return self.hitMatching(col, row, true);
    }

    fn hitMatching(self: *const State, col: i64, row: i64, scroll: bool) ?Hit {
        if (!self.enabled) return null;
        if (col < 0 or row < 0) return null;
        if (col >= self.cols or row >= self.rows) return null;
        const px: u32 = @intCast(col);
        const py: u32 = @intCast(row);
        var best: ?usize = null;
        var best_area: u64 = std.math.maxInt(u64);
        for (self.targets[0..self.count], 0..) |t, i| {
            if (!targetMatches(t, scroll)) continue;
            if (!contains(t.rect, px, py)) continue;
            const area = @as(u64, t.rect.width) * @as(u64, t.rect.height);
            if (best == null or area <= best_area) {
                best = i;
                best_area = area;
            }
        }
        const idx = best orelse return null;
        return .{ .index = idx, .target = self.targets[idx] };
    }
};

/// Convert a points rect to the shared clamp rules: empty/off-screen rects
/// are not registered, partially visible ones are clipped.
pub fn clampRect(rect: Rect, rows: u32, cols: u32) ?Rect {
    if (rows == 0 or cols == 0) return null;
    if (rect.width == 0 or rect.height == 0) return null;
    if (rect.row >= rows or rect.col >= cols) return null;
    return .{
        .row = rect.row,
        .col = rect.col,
        .width = @min(rect.width, cols - rect.col),
        .height = @min(rect.height, rows - rect.row),
    };
}

pub fn contains(rect: Rect, col: u32, row: u32) bool {
    return col >= rect.col and col < rect.col +| rect.width and
        row >= rect.row and row < rect.row +| rect.height;
}

fn targetMatches(t: Target, scroll: bool) bool {
    return switch (t.action) {
        .click => !scroll,
        .scroll => scroll,
    };
}

// ---------------------------------------------------------------------------
// Pure geometry / mapping helpers (unit-tested below)
// ---------------------------------------------------------------------------

/// Clamp a selection index after a signed delta. `len == 0` yields 0; a
/// selection past the end is first clamped to the last item.
pub fn movedIndex(index: usize, len: usize, delta: i64) usize {
    if (len == 0) return 0;
    var i: i64 = @intCast(@min(index, len - 1));
    i += delta;
    if (i < 0) i = 0;
    if (i >= @as(i64, @intCast(len))) i = @intCast(len - 1);
    return @intCast(i);
}

/// Clamp a document line after a signed delta (wheel clamp, no overflow).
pub fn movedLine(line: u32, line_count: u32, delta: i64) u32 {
    if (line_count == 0) return 0;
    var l: i64 = @intCast(@min(line, line_count - 1));
    l += delta;
    if (l < 0) l = 0;
    if (l >= @as(i64, @intCast(line_count))) l = @intCast(line_count - 1);
    return @intCast(l);
}

pub const RowHit = struct {
    /// Index into the supplied row-count slice (visible line order).
    index: usize,
    /// Soft-wrap row within that line (0 for a non-wrapped line).
    chunk: u32,
};

/// Map a display row offset inside a viewport to (visible line, wrap chunk).
/// `rows_per_line` is the display-row height of each visible line starting at
/// the viewport top (folds already collapsed to one entry). Returns null for
/// rows past the last line (the "~" filler area) — callers then focus the
/// pane without moving the cursor.
pub fn lineForDisplayRow(rows_per_line: []const u32, display_row: u32) ?RowHit {
    var rem = display_row;
    for (rows_per_line, 0..) |rows, i| {
        const r = @max(rows, 1);
        if (rem < r) return .{ .index = i, .chunk = rem };
        rem -= r;
    }
    return null;
}

/// Map a cell column inside a buffer line to the nearest byte offset.
///
/// ASCII/CJK/tab-aware: walks UTF-8 sequences, adds `tab_width` cells for a
/// tab and `vaxis.gwidth` cells for every other codepoint, and returns the
/// byte that STARTS the clicked cell. A click inside a wide glyph's second
/// cell maps to that glyph's start; a click past the last cell maps to
/// `line.len` (the caller then applies normal-mode end-of-line semantics).
///
/// Inlay hints occupy screen cells without buffer bytes, so the optional
/// sorted `hint_at` (byte offsets) / `hint_width` (cells) arrays are applied
/// before the text at/after their anchor — the same ordering the renderer
/// uses. Combining marks/emoji ZWJ sequences are approximated per codepoint;
/// see DESIGN §21.
pub fn cellToByteWithHints(
    line: []const u8,
    target_cell: i64,
    tab_width: u32,
    method: vaxis.gwidth.Method,
    hint_at: []const u32,
    hint_width: []const u32,
) u32 {
    std.debug.assert(hint_at.len == hint_width.len);
    const target: i64 = @max(target_cell, 0);
    var cell: i64 = 0;
    var p: usize = 0;
    var hi: usize = 0;
    while (true) {
        // Hints anchored at/just before this byte render before the text.
        while (hi < hint_at.len and hint_at[hi] <= p) {
            const w: i64 = @intCast(hint_width[hi]);
            if (target < cell + w) return @intCast(p);
            cell += w;
            hi += 1;
        }
        if (p >= line.len) return @intCast(p);
        const b = line[p];
        var w: i64 = 0;
        var next: usize = p + 1;
        if (b == '\t') {
            w = @intCast(tab_width);
        } else {
            const seq_len: usize = if (b < 0x80)
                1
            else
                (std.unicode.utf8ByteSequenceLength(b) catch 1);
            next = @min(p + seq_len, line.len);
            w = @intCast(vaxis.gwidth.gwidth(line[p..next], method));
        }
        if (target < cell + w) return @intCast(p);
        cell += w;
        p = next;
    }
}

/// Convenience wrapper for lines without inlay hints (unit tests, simple
/// mapping paths).
pub fn cellToByte(line: []const u8, target_cell: i64, tab_width: u32, method: vaxis.gwidth.Method) u32 {
    return cellToByteWithHints(line, target_cell, tab_width, method, &.{}, &.{});
}

/// Previous codepoint start in `text` at or before `pos`. Used to place a
/// normal-mode cursor on the last character when a click lands past EOL.
pub fn prevCodepointStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = @min(pos - 1, text.len -| 1);
    while (p > 0 and (text[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn inside(rect: Rect, col: u32, row: u32) bool {
    return contains(rect, col, row);
}

test "mouse: rect boundaries are half-open (last cell in, right edge out)" {
    const r = Rect{ .row = 3, .col = 5, .width = 4, .height = 2 };
    try testing.expect(!inside(r, 4, 3));
    try testing.expect(inside(r, 5, 3));
    try testing.expect(inside(r, 8, 3)); // last included column
    try testing.expect(!inside(r, 9, 3));
    try testing.expect(inside(r, 5, 4));
    try testing.expect(!inside(r, 5, 5));
}

test "mouse: clampRect drops empty/offscreen and clips partial rects" {
    try testing.expectEqual(@as(?Rect, null), clampRect(.{ .row = 0, .col = 0, .width = 0, .height = 1 }, 24, 80));
    try testing.expectEqual(@as(?Rect, null), clampRect(.{ .row = 0, .col = 0, .width = 1, .height = 1 }, 0, 80));
    try testing.expectEqual(@as(?Rect, null), clampRect(.{ .row = 24, .col = 0, .width = 1, .height = 1 }, 24, 80));
    try testing.expectEqual(@as(?Rect, null), clampRect(.{ .row = 0, .col = 80, .width = 1, .height = 1 }, 24, 80));
    const clipped = clampRect(.{ .row = 23, .col = 78, .width = 5, .height = 3 }, 24, 80).?;
    try testing.expectEqual(Rect{ .row = 23, .col = 78, .width = 2, .height = 1 }, clipped);
}

test "mouse: click hit prefers the smallest overlapping target (close × over tab)" {
    var st = State{ .enabled = true };
    try testing.expectEqual(@as(usize, 0), st.count);
    try testing.expectEqual(@as(usize, 0), st.cols); // row/cols gate collection
    st.beginFrame(24, 80);
    try testing.expect(st.collecting);
    st.add(.{ .row = 0, .col = 1, .width = 20, .height = 1 }, .{ .click = .{ .hint = .{ .buffer_select = 0 } } });
    st.add(.{ .row = 0, .col = 17, .width = 1, .height = 1 }, .{ .click = .{ .hint = .{ .buffer_close = 0 } } });
    const close = st.hitClick(17, 0).?;
    try testing.expectEqual(@as(usize, 1), close.index);
    try testing.expectEqual(@as(usize, 0), close.target.action.click.hint.buffer_close);
    const tab = st.hitClick(5, 0).?;
    try testing.expectEqual(@as(usize, 0), tab.index);
    try testing.expectEqual(@as(usize, 0), tab.target.action.click.hint.buffer_select);
}

test "mouse: no target / outside / beyond screen are no-ops" {
    var st = State{ .enabled = true };
    st.beginFrame(24, 80);
    st.add(.{ .row = 5, .col = 5, .width = 5, .height = 1 }, .{ .click = .{ .hint = .{ .agent_prompt_focus = {} } } });
    try testing.expectEqual(@as(?Hit, null), st.hitClick(10, 5));
    try testing.expectEqual(@as(?Hit, null), st.hitClick(0, 0));
    try testing.expectEqual(@as(?Hit, null), st.hitClick(80, 5));
    try testing.expectEqual(@as(?Hit, null), st.hitClick(-1, 5));
    try testing.expectEqual(@as(?Hit, null), st.hitClick(5, 24));
}

test "mouse: equal-area overlap picks the later (topmost) target" {
    var st = State{ .enabled = true };
    st.beginFrame(10, 20);
    st.add(.{ .row = 2, .col = 2, .width = 3, .height = 1 }, .{ .click = .{ .hint = .{ .inline_approve = {} } } });
    st.add(.{ .row = 2, .col = 2, .width = 3, .height = 1 }, .{ .click = .{ .hint = .{ .inline_reject = {} } } });
    const hit = st.hitClick(3, 2).?;
    try testing.expectEqual(@as(usize, 1), hit.index);
}

test "mouse: disabled state never collects or hits" {
    var st = State{};
    st.beginFrame(24, 80);
    try testing.expect(!st.collecting);
    st.add(.{ .row = 0, .col = 0, .width = 5, .height = 1 }, .{ .click = .{ .separator = {} } });
    try testing.expectEqual(@as(usize, 0), st.count);
    try testing.expectEqual(@as(?Hit, null), st.hitClick(0, 0));
}

test "mouse: scroll lookup ignores click targets and picks the region" {
    var st = State{ .enabled = true };
    st.beginFrame(24, 80);
    st.add(.{ .row = 2, .col = 0, .width = 80, .height = 20 }, .{ .scroll = .{ .editor = 0 } });
    st.add(.{ .row = 2, .col = 2, .width = 5, .height = 1 }, .{ .click = .{ .hint = .{ .buffer_select = 0 } } });
    try testing.expectEqual(@as(?Hit, null), st.hitClick(3, 5)); // no click target there
    const s = st.hitScroll(3, 5).?;
    try testing.expectEqual(@as(usize, 0), s.target.action.scroll.editor);
    // A nested scroll region wins over the big editor region.
    st.add(.{ .row = 4, .col = 0, .width = 30, .height = 10 }, .{ .scroll = .{ .navigator_files = {} } });
    const s2 = st.hitScroll(3, 5).?;
    try testing.expectEqual(@as(usize, 2), s2.index);
}

test "mouse: selection and line scroll clamp at both ends" {
    try testing.expectEqual(@as(usize, 0), movedIndex(0, 0, 5));
    try testing.expectEqual(@as(usize, 2), movedIndex(1, 3, 1));
    try testing.expectEqual(@as(usize, 0), movedIndex(0, 3, -1));
    try testing.expectEqual(@as(usize, 2), movedIndex(99, 3, 1)); // stale index first clamps
    try testing.expectEqual(@as(usize, 0), movedIndex(1, 3, -1));
    try testing.expectEqual(@as(usize, 1), movedIndex(2, 3, -1));
    try testing.expectEqual(@as(u32, 0), movedLine(0, 0, 1));
    try testing.expectEqual(@as(u32, 0), movedLine(0, 10, -3));
    try testing.expectEqual(@as(u32, 9), movedLine(8, 10, 3));
    try testing.expectEqual(@as(u32, 5), movedLine(2, 10, 3));
}

test "mouse: display row maps to line + wrap chunk, past EOF is null" {
    const rows = [_]u32{ 1, 3, 1, 2 };
    try testing.expectEqual(RowHit{ .index = 0, .chunk = 0 }, lineForDisplayRow(&rows, 0).?);
    try testing.expectEqual(RowHit{ .index = 1, .chunk = 0 }, lineForDisplayRow(&rows, 1).?);
    try testing.expectEqual(RowHit{ .index = 1, .chunk = 2 }, lineForDisplayRow(&rows, 3).?);
    try testing.expectEqual(RowHit{ .index = 2, .chunk = 0 }, lineForDisplayRow(&rows, 4).?);
    try testing.expectEqual(RowHit{ .index = 3, .chunk = 1 }, lineForDisplayRow(&rows, 6).?);
    try testing.expectEqual(@as(?RowHit, null), lineForDisplayRow(&rows, 7));
    // A zero-height count still consumes one row (defensive for bad input).
    const z = [_]u32{0};
    try testing.expectEqual(RowHit{ .index = 0, .chunk = 0 }, lineForDisplayRow(&z, 0).?);
}

test "mouse: cell→byte mapping for ASCII" {
    const m = vaxis.gwidth.Method.unicode;
    try testing.expectEqual(@as(u32, 0), cellToByte("hello", 0, 4, m));
    try testing.expectEqual(@as(u32, 3), cellToByte("hello", 3, 4, m));
    try testing.expectEqual(@as(u32, 5), cellToByte("hello", 5, 4, m)); // past EOL
    try testing.expectEqual(@as(u32, 5), cellToByte("hello", 99, 4, m));
    try testing.expectEqual(@as(u32, 0), cellToByte("hello", -2, 4, m));
    try testing.expectEqual(@as(u32, 0), cellToByte("", 4, 4, m));
}

test "mouse: cell→byte mapping expands tabs and respects CJK cell width" {
    const m = vaxis.gwidth.Method.unicode;
    // "a\tb": a=0, tab covers cells 1..4, b starts at cell 5, line end 6.
    try testing.expectEqual(@as(u32, 1), cellToByte("a\tb", 1, 4, m));
    try testing.expectEqual(@as(u32, 1), cellToByte("a\tb", 3, 4, m));
    try testing.expectEqual(@as(u32, 1), cellToByte("a\tb", 4, 4, m));
    try testing.expectEqual(@as(u32, 2), cellToByte("a\tb", 5, 4, m));
    // "你a": 你 is 2 cells (bytes 0..3), a starts at cell 2 (byte 3).
    try testing.expectEqual(@as(u32, 0), cellToByte("你a", 0, 4, m));
    try testing.expectEqual(@as(u32, 0), cellToByte("你a", 1, 4, m)); // second half of wide glyph
    try testing.expectEqual(@as(u32, 3), cellToByte("你a", 2, 4, m));
    try testing.expectEqual(@as(u32, 4), cellToByte("你a", 3, 4, m));
}

test "mouse: cell→byte mapping accounts for sorted inlay hints" {
    const m = vaxis.gwidth.Method.unicode;
    // Line "abc" with a 2-cell hint before 'b' (byte 1) and a 1-cell hint at EOL.
    const at = [_]u32{ 1, 3 };
    const w = [_]u32{ 2, 1 };
    try testing.expectEqual(@as(u32, 0), cellToByteWithHints("abc", 0, 4, m, &at, &w));
    try testing.expectEqual(@as(u32, 1), cellToByteWithHints("abc", 1, 4, m, &at, &w)); // hint start
    try testing.expectEqual(@as(u32, 1), cellToByteWithHints("abc", 2, 4, m, &at, &w)); // hint 2nd cell
    try testing.expectEqual(@as(u32, 1), cellToByteWithHints("abc", 3, 4, m, &at, &w)); // 'b' start
    try testing.expectEqual(@as(u32, 2), cellToByteWithHints("abc", 4, 4, m, &at, &w));
    try testing.expectEqual(@as(u32, 3), cellToByteWithHints("abc", 5, 4, m, &at, &w)); // EOL hint
    try testing.expectEqual(@as(u32, 3), cellToByteWithHints("abc", 99, 4, m, &at, &w));
}

test "mouse: previous codepoint start walks back over continuation bytes" {
    try testing.expectEqual(@as(usize, 0), prevCodepointStart("abc", 0));
    try testing.expectEqual(@as(usize, 1), prevCodepointStart("abc", 2));
    // "a你": bytes a=1, 你=3; pos 4 → 你 start at 1.
    try testing.expectEqual(@as(usize, 1), prevCodepointStart("a你", 4));
}
