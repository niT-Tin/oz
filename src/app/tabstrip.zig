//! Pure two-row buffer-strip geometry (DESIGN.md §18.11).
//!
//! The buffer tab strip is bigger and demo-shaped: every tab has two cells of
//! inner padding on the outside, a devicon, a filename, a reserved dirty
//! marker cell, a close `×`, and a one-cell `│` separator between adjacent
//! tabs. Tabs are at least `min_body` cells wide so a filename is readable
//! without hover, and at most `max_body` so one long path cannot crowd out
//! every other buffer.
//!
//! This module owns the arithmetic only (no vaxis, no App): callers measure
//! each filename in screen cells and pass `Spec`s in buffer order. `plan`
//! returns the visible window, per-tab positions and the close-target cell.
//! When the strip does not fit, the window is scrolled so the ACTIVE tab is
//! always fully visible: neighbours fill to its right first, then to its
//! left. The renderer draws the label row from this plan and the shared rule
//! row below it.
//!
//! ## Geometry (strip-relative cells)
//!
//! ```text
//! │  <icon> <name…> · ×  │ <icon> <name>   × │
//! ^^                    ^^
//! pad=2               pad=2
//! ```
//!
//! Body = `fixed_cells` (2 pad + icon + gap + dirty + gap + close + 2 pad)
//! plus the allocated name region. The dirty marker column is reserved even
//! while clean, so typing never shifts a neighbour; `×` sits at a fixed
//! offset from the body's right edge.
//!
//! Complexity: O(number of tabs) time, O(visible tabs) storage (fixed
//! `max_slots`), no allocation. `plan` is deterministic and total — a
//! foreground render must never fail on unusual buffer counts.

const std = @import("std");

/// Smallest body width: 9 cells of fixed chrome + 11 name cells (fits
/// "noname.txt" and a 9-cell truncated name with room to breathe).
pub const min_body: u32 = 20;
/// Largest body width: 9 cells of fixed chrome + 17 name cells.
pub const max_body: u32 = 26;
pub const pad_left: u32 = 2;
pub const pad_right: u32 = 2;
pub const icon_cells: u32 = 1;
pub const gap_cells: u32 = 1;
pub const dirty_cells: u32 = 1;
pub const close_cells: u32 = 1;
/// Cells of a tab body that do not belong to the filename.
pub const fixed_cells: u32 =
    pad_left + icon_cells + gap_cells + dirty_cells + gap_cells + close_cells + pad_right;
/// Name region of a minimum-width tab (the narrowest filename presentation).
pub const min_name_cells: u32 = min_body - fixed_cells;
/// Largest name region before the width cap truncates.
pub const max_name_cells: u32 = max_body - fixed_cells;
/// One-cell ellipsis inserted into a truncated filename.
pub const ellipsis = "…";

/// Split of a truncated filename's name region: keep a readable prefix and a
/// recognizable extension/suffix, separated by one ellipsis cell. Middle
/// truncation is deliberate — a file named `very_long_feature.zig` should
/// still read as a `.zig` buffer at the width cap (the demo trims the tail,
/// but the TUI's narrow cells need the extension to stay meaningful).
pub const NameSplit = struct { prefix: u32, suffix: u32 };

pub fn nameSplit(name_alloc: u32) NameSplit {
    if (name_alloc <= 1) return .{ .prefix = 0, .suffix = 0 };
    // A suffix of 8 keeps a distinguishing stem + extension ("wna.txt",
    // ".zig", "a.txt") recognizable; very narrow cells shrink it before the
    // prefix.
    const want_suffix = std.math.clamp(name_alloc / 2, 4, 8);
    const suffix = @min(want_suffix, name_alloc - 1);
    return .{ .prefix = name_alloc - 1 - suffix, .suffix = suffix };
}

/// Upper bound on simultaneously visible tabs. 64 tabs need at least
/// `64 * (min_body + 1) - 1` columns, far beyond a real terminal; a wider
/// strip reports the excess as hidden instead of overflowing the array.
pub const max_slots: usize = 64;

/// One buffer tab's measured content. `name_cells` is the filename's display
/// width in cells (the caller measures it once with the terminal's width
/// rules). Paths are not stored here.
pub const Spec = struct {
    name_cells: u32,
    dirty: bool = false,
    active: bool = false,
    /// False for the last remaining buffer (closing it is a no-op), so the
    /// renderer can spell the close affordance as a blank and not register a
    /// dead hint target.
    closeable: bool = true,
};

/// One visible tab. `x`/`width` are strip-relative cells; the caller adds
/// the strip's screen origin. The filename region starts at `name_x` and is
/// exactly `name_alloc` cells wide (spaces included after a short name).
pub const Slot = struct {
    /// Index into the caller's spec slice (absolute buffer index for the
    /// single-window strip, filtered-pane index for a split layer).
    index: usize,
    x: u32,
    width: u32,
    name_x: u32,
    name_alloc: u32,
    truncated: bool,
    close_x: u32,
    closeable: bool,
    active: bool,
    dirty: bool,
    first_visible: bool,
};

/// The visible window of a strip. `used` counts body widths plus the
/// `│` separators between visible tabs, and never exceeds the available
/// width. `hidden_left`/`hidden_right` are tab counts scrolled out on each
/// side; the renderer may show a quiet overflow cue without inventing a new
/// interaction.
pub const Plan = struct {
    slots: [max_slots]Slot = undefined,
    count: usize = 0,
    used: u32 = 0,
    first: usize = 0,
    last: usize = 0,
    total: usize = 0,
    active_index: usize = 0,
    active_visible: bool = false,
    hidden_left: usize = 0,
    hidden_right: usize = 0,
};

/// Body width for one spec: fixed chrome + filename, clamped to the readable
/// demo range. A very short name still gets a comfortable hit target.
pub fn bodyWidth(spec: Spec) u32 {
    const want = fixed_cells + spec.name_cells;
    return std.math.clamp(want, min_body, max_body);
}

fn activeIndex(specs: []const Spec) usize {
    for (specs, 0..) |spec, i| {
        if (spec.active) return i;
    }
    return 0;
}

/// Lay out `specs` in `avail` cells. `active` must be set on exactly one spec
/// (the focused pane's current buffer); when none is, the first tab anchors
/// the window — no panic, no invisible selection.
pub fn plan(specs: []const Spec, avail: u32) Plan {
    var out = Plan{};
    out.total = specs.len;
    if (specs.len == 0 or avail == 0) return out;
    out.active_index = activeIndex(specs);

    // Total natural width (u64: a pathological buffer list must not overflow
    // the arithmetic before the window is chosen).
    var total: u64 = 0;
    for (specs, 0..) |spec, i| {
        total += bodyWidth(spec);
        if (i > 0) total += 1;
    }

    var first: usize = 0;
    var last: usize = specs.len - 1;
    if (total > avail) {
        const active = out.active_index;
        const active_w = bodyWidth(specs[active]);
        first = active;
        last = active;
        if (active_w <= avail) {
            var used: u64 = active_w;
            // Fill to the right first: the active tab keeps its natural
            // reading position and later tabs remain discoverable.
            while (last + 1 < specs.len and out.count == 0) {
                const w = 1 + bodyWidth(specs[last + 1]);
                if (used + w > avail) break;
                used += w;
                last += 1;
                if (last - first + 1 >= max_slots) break;
            }
            while (first > 0) {
                const w = 1 + bodyWidth(specs[first - 1]);
                if (used + w > avail or last - first + 1 >= max_slots) break;
                used += w;
                first -= 1;
            }
        }
    } else if (specs.len > max_slots) {
        // A terminal wider than 64 tabs: keep a window around the active tab
        // rather than silently dropping it.
        const active = out.active_index;
        first = active -| (max_slots / 2);
        last = @min(first + max_slots - 1, specs.len - 1);
        first = last + 1 -| max_slots;
    }

    // Build the visible slots. `x` starts at 0; each later slot adds one
    // separator cell before its body.
    var x: u32 = 0;
    var used: u32 = 0;
    var i = first;
    while (i <= last and out.count < max_slots) : (i += 1) {
        if (out.count > 0) {
            x += 1;
            used += 1;
        }
        const w = @min(bodyWidth(specs[i]), avail -| used);
        if (w == 0) break;
        const spec = specs[i];
        const name_alloc = w -| fixed_cells;
        const truncated = spec.name_cells > name_alloc;
        out.slots[out.count] = .{
            .index = i,
            .x = x,
            .width = w,
            .name_x = x + pad_left + icon_cells + gap_cells,
            .name_alloc = name_alloc,
            .truncated = truncated,
            .close_x = x + w - pad_right - close_cells,
            .closeable = spec.closeable,
            .active = spec.active,
            .dirty = spec.dirty,
            .first_visible = out.count == 0,
        };
        out.count += 1;
        out.active_visible = out.active_visible or spec.active;
        x += w;
        used += w;
    }
    out.used = used;
    out.first = first;
    out.last = if (out.count == 0) first else first + out.count - 1;
    out.hidden_left = first;
    out.hidden_right = specs.len -| (out.last + 1);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn mk(name_cells: u32, active: bool) Spec {
    return .{ .name_cells = name_cells, .active = active };
}

test "tabstrip: body width clamps short names up and long names down" {
    try std.testing.expectEqual(min_body, bodyWidth(mk(1, false)));
    try std.testing.expectEqual(min_body, bodyWidth(mk(min_name_cells, false)));
    try std.testing.expectEqual(max_body, bodyWidth(mk(max_name_cells, false)));
    try std.testing.expectEqual(max_body, bodyWidth(mk(200, false)));
    // The fixed chrome is exactly the difference between body and name cap.
    try std.testing.expectEqual(min_body, fixed_cells + min_name_cells);
    try std.testing.expectEqual(max_body, fixed_cells + max_name_cells);
}

test "tabstrip: a fitting strip lays tabs left to right with separators" {
    const specs = [_]Spec{ mk(5, true), mk(9, false), mk(20, false) };
    const p = plan(&specs, 120);
    try std.testing.expectEqual(@as(usize, 3), p.count);
    try std.testing.expectEqual(@as(usize, 0), p.first);
    try std.testing.expectEqual(@as(usize, 2), p.last);
    try std.testing.expect(p.active_visible);
    try std.testing.expectEqual(@as(usize, 0), p.hidden_left);
    try std.testing.expectEqual(@as(usize, 0), p.hidden_right);
    try std.testing.expectEqual(@as(u32, min_body), p.slots[0].width);
    try std.testing.expectEqual(@as(u32, 0), p.slots[0].x);
    try std.testing.expectEqual(p.slots[0].width + 1, p.slots[1].x);
    try std.testing.expectEqual(p.slots[1].x + p.slots[1].width + 1, p.slots[2].x);
    try std.testing.expectEqual(p.slots[2].x + p.slots[2].width, p.used);
    try std.testing.expect(p.used <= 120);
}

test "tabstrip: geometry pins icon/name/dirty/close columns" {
    const specs = [_]Spec{ .{ .name_cells = 6, .dirty = true, .active = true } };
    const p = plan(&specs, 80);
    const s = p.slots[0];
    try std.testing.expectEqual(@as(u32, 0), s.x);
    try std.testing.expectEqual(pad_left, s.name_x - icon_cells - gap_cells);
    try std.testing.expectEqual(@as(u32, 2), s.name_x - 2);
    try std.testing.expectEqual(min_body, s.width);
    // Name region: body minus fixed chrome; short names are padded.
    try std.testing.expectEqual(@as(u32, min_name_cells), s.name_alloc);
    try std.testing.expect(!s.truncated);
    // `×` is the cell before the two-cell right padding.
    try std.testing.expectEqual(s.width - pad_right - close_cells, s.close_x);
    try std.testing.expect(s.close_x + close_cells + pad_right == s.width);
    // The dirty column sits immediately before the gap + close group.
    try std.testing.expectEqual(s.close_x - 2, s.name_x + s.name_alloc);
}

test "tabstrip: truncation allocates ellipsis inside the name region" {
    const specs = [_]Spec{mk(80, true)};
    const p = plan(&specs, 120);
    const s = p.slots[0];
    try std.testing.expectEqual(max_body, s.width);
    try std.testing.expectEqual(max_name_cells, s.name_alloc);
    try std.testing.expect(s.truncated);
    // A 1-cell ellipsis means the rendered prefix must fit name_alloc - 1.
    try std.testing.expect(@as(u32, 1) <= s.name_alloc);
}

test "tabstrip: active last stays fully visible at 80/100/120" {
    for ([_]u32{ 80, 100, 120 }) |avail| {
        var specs: [7]Spec = undefined;
        for (&specs, 0..) |*s, i| s.* = mk(@intCast(14 + i * 2), i == specs.len - 1);
        const p = plan(&specs, avail);
        try std.testing.expect(p.active_visible);
        try std.testing.expect(p.hidden_left > 0);
        try std.testing.expectEqual(@as(usize, 0), p.hidden_right);
        const active = p.slots[p.count - 1];
        try std.testing.expect(active.active);
        try std.testing.expect(active.x + active.width <= avail);
        try std.testing.expect(p.used <= avail);
        // The window includes the active tab and never overlaps slots.
        var i: usize = 1;
        while (i < p.count) : (i += 1) {
            try std.testing.expect(p.slots[i].x > p.slots[i - 1].x + p.slots[i - 1].width);
        }
    }
}

test "tabstrip: active first keeps followers and respects the width" {
    var specs: [6]Spec = undefined;
    for (&specs, 0..) |*s, i| s.* = mk(12, i == 0);
    const p = plan(&specs, 80);
    try std.testing.expect(p.active_visible);
    try std.testing.expectEqual(@as(usize, 0), p.first);
    try std.testing.expectEqual(@as(usize, 0), p.hidden_left);
    try std.testing.expect(p.hidden_right > 0);
    try std.testing.expect(p.used <= 80);
    try std.testing.expect(p.slots[0].active);
}

test "tabstrip: a single tab never overflows even in a tiny pane" {
    const specs = [_]Spec{mk(40, true)};
    const p = plan(&specs, 10);
    try std.testing.expectEqual(@as(usize, 1), p.count);
    try std.testing.expect(p.active_visible);
    try std.testing.expectEqual(@as(u32, 10), p.used);
    try std.testing.expectEqual(@as(u32, 10), p.slots[0].width);
    try std.testing.expect(p.slots[0].close_x + close_cells + pad_right <= p.slots[0].width + 10);
}

test "tabstrip: empty and zero-width strips are total" {
    const specs = [_]Spec{mk(8, false)};
    const empty = plan(&specs, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expectEqual(@as(usize, 1), empty.total);
    try std.testing.expectEqual(@as(usize, 0), plan(&.{}, 80).count);
    const one = plan(&specs, 80);
    try std.testing.expectEqual(@as(usize, 1), one.count);
    // No active flag: the first tab anchors the window, but no slot claims
    // the active style.
    try std.testing.expect(!one.active_visible);
    try std.testing.expect(one.slots[0].active == false);
}

test "tabstrip: many buffers keep the active tab inside the visible window" {
    var specs: [300]Spec = undefined;
    for (&specs, 0..) |*s, i| s.* = mk(10, i == 250);
    const p = plan(&specs, 120);
    try std.testing.expect(p.active_visible);
    try std.testing.expect(p.count <= max_slots);
    try std.testing.expect(p.hidden_left > 0);
    try std.testing.expect(p.hidden_right > 0);
    var saw_active = false;
    for (p.slots[0..p.count]) |slot| saw_active = saw_active or slot.active;
    try std.testing.expect(saw_active);
    try std.testing.expect(p.used <= 120);
    // Absolute index round-trips, so the renderer can map back to a buffer.
    try std.testing.expect(p.slots[0].index == p.first);
}

test "tabstrip: close target is absent for an uncloseable last buffer" {
    const specs = [_]Spec{.{ .name_cells = 6, .closeable = false }};
    const p = plan(&specs, 80);
    try std.testing.expect(!p.slots[0].closeable);
    // The cell is still reserved so widths and the following tab do not move.
    try std.testing.expectEqual(p.slots[0].width - pad_right - close_cells, p.slots[0].close_x);
}

test "tabstrip: middle truncation keeps an extension-sized suffix" {
    const split = nameSplit(max_name_cells);
    try std.testing.expectEqual(max_name_cells, split.prefix + split.suffix + 1);
    try std.testing.expect(split.prefix >= split.suffix);
    try std.testing.expect(split.suffix >= 5); // ".zig"/"a.txt" stay visible
    const tiny = nameSplit(6);
    try std.testing.expectEqual(@as(u32, 6), tiny.prefix + tiny.suffix + 1);
    try std.testing.expect(tiny.prefix >= 1);
    const none = nameSplit(0);
    try std.testing.expectEqual(@as(u32, 0), none.prefix + none.suffix);
}
