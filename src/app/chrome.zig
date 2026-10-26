//! Theme-aware chrome styles shared by every TUI surface.
//!
//! Active tabs, panel borders, section rules and the status band must all
//! derive from the active palette. Keeping the mapping here (instead of
//! repeating raw `theme.*` field picks in `render.zig` and `ai.zig`) means
//! the navigator, buffer tab bar and workbox cannot drift apart, and makes
//! the treatment unit-testable without a terminal.
//!
//! The design mirrors the approved web demo's active tab: a soft selection
//! background (not a saturated accent flood), `fg` text in bold, and an
//! accent underline. In the TUI the underline is a real SGR underline whose
//! color is the theme's secondary accent (`accent_alt`), the slot that maps
//! to the demo's `--blue` (#7E9CD8 in kanagawa-wave). The `>` marker and
//! active file icon use the same accent so every active affordance agrees.
//!
//! `bg` is passed in by the caller because the same logical style lands on
//! different panel surfaces (editor bg, rail bg_float, header bg_status);
//! only the semantic foreground/background roles live here.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("../theme.zig");

/// Visual weight of a separator/rule. `minor` is an accent-tinted hairline
/// (dim secondary accent); `major` is a structural rule (full secondary
/// accent). Active tab underlines and focused panel borders are stronger
/// than both — they use `accent_alt` / `win_sep_active` respectively.
pub const Emphasis = enum { minor, major };

/// Text style of the selected navigator / buffer / workbox tab.
/// `bg_sel` + `fg` bold + `accent_alt` single underline. The underline is
/// what keeps the tab identifiable in monochrome (bold + underline; the
/// workbox additionally carries the `>` marker).
pub fn activeTabStyle(t: theme.Theme) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.fg },
        .bg = .{ .rgb = t.bg_sel },
        .bold = true,
        .ul = .{ .rgb = t.accent_alt },
        .ul_style = .single,
    };
}

/// `>` marker / active file icon inside an active tab. Same soft selection
/// surface as the label so the marker reads as part of the tab, accent
/// foreground, and the same underline for a continuous accent rule.
pub fn activeTabMarkerStyle(t: theme.Theme) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.accent_alt },
        .bg = .{ .rgb = t.bg_sel },
        .bold = true,
        .ul = .{ .rgb = t.accent_alt },
        .ul_style = .single,
    };
}

/// Inactive tab: readable dim body text on the surrounding panel surface.
/// No gray-only *active* state is allowed, but inactive tabs intentionally
/// stay quiet so the accent underline/marker pops.
pub fn inactiveTabStyle(t: theme.Theme, bg: vaxis.Color) vaxis.Style {
    return .{ .fg = .{ .rgb = t.fg_dim }, .bg = bg };
}

/// `>` marker of the attached agent thread. `bg` is the row background
/// (`bg_sel` while the prompt/rail owns the row, `bg_float` otherwise) so
/// the accent marker never sits on a terminal-default hole.
pub fn activeThreadMarkerStyle(t: theme.Theme, bg: vaxis.Color) vaxis.Style {
    return .{ .fg = .{ .rgb = t.accent_alt }, .bg = bg, .bold = true };
}

/// Accent rule between chrome sections. `minor` stays dim so the strip
/// separators do not compete with the active tab; `major` is used for the
/// workbox section rules and the status top rule.
pub fn separatorStyle(t: theme.Theme, emphasis: Emphasis, bg: vaxis.Color) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.accent_alt },
        .bg = bg,
        .dim = emphasis == .minor,
    };
}

/// Outer panel border: `win_sep` when the panel is inactive, the theme's
/// active window separator (accent) when it owns the keyboard.
pub fn panelBorderStyle(t: theme.Theme, focused: bool, bg: vaxis.Color) vaxis.Style {
    return .{
        .fg = .{ .rgb = if (focused) t.win_sep_active else t.win_sep },
        .bg = bg,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectRgb(actual: vaxis.Color, expected: theme.Rgb) !void {
    switch (actual) {
        .rgb => |rgb| try std.testing.expectEqual(expected, rgb),
        else => return error.TestUnexpectedResult,
    }
}

fn channel(v: u8) f64 {
    const s = @as(f64, @floatFromInt(v)) / 255.0;
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(rgb: theme.Rgb) f64 {
    return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
}

/// WCAG contrast ratio (1..21). Used only for the readability sanity check:
/// the active tab is bold text, so 3:1 is the relevant large-text floor.
fn contrastRatio(a: theme.Rgb, b: theme.Rgb) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

test "chrome: active tab treatment derives from every theme and stays readable" {
    var min_contrast: f64 = 21;
    for (theme.themes) |t| {
        const tab = activeTabStyle(t);
        try expectRgb(tab.fg, t.fg);
        try expectRgb(tab.bg, t.bg_sel);
        try std.testing.expect(tab.bold);
        try expectRgb(tab.ul, t.accent_alt);
        try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, tab.ul_style);

        const marker = activeTabMarkerStyle(t);
        try expectRgb(marker.fg, t.accent_alt);
        try expectRgb(marker.bg, t.bg_sel);
        try std.testing.expect(marker.bold);
        try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, marker.ul_style);

        const inactive = inactiveTabStyle(t, .{ .rgb = t.bg });
        try expectRgb(inactive.fg, t.fg_dim);
        try expectRgb(inactive.bg, t.bg);

        // Bold active text must stay legible on the soft selection surface
        // for dark AND light palettes (the lowest themes sit near 3.6:1).
        const ratio = contrastRatio(t.fg, t.bg_sel);
        try std.testing.expect(ratio >= 3.0);
        min_contrast = @min(min_contrast, ratio);
    }
    // Guard against a palette edit that makes the active label unreadable.
    try std.testing.expect(min_contrast >= 3.0);
}

test "chrome: separators and panel borders are theme-derived, not fixed gray" {
    const a = theme.byName("kanagawa-wave").?;
    const b = theme.byName("catppuccin-mocha").?;
    const light = theme.byName("flexoki-light").?;

    for (theme.themes) |t| {
        const major = separatorStyle(t, .major, .{ .rgb = t.bg });
        try expectRgb(major.fg, t.accent_alt);
        try std.testing.expect(!major.dim);
        // The active separator must not fall back to the old fixed gray.
        try std.testing.expect(!std.meta.eql(major.fg, vaxis.Color{ .rgb = t.fg_faint }));

        const minor = separatorStyle(t, .minor, .{ .rgb = t.bg });
        try expectRgb(minor.fg, t.accent_alt);
        try std.testing.expect(minor.dim);

        const active_border = panelBorderStyle(t, true, .{ .rgb = t.bg });
        const idle_border = panelBorderStyle(t, false, .{ .rgb = t.bg });
        try expectRgb(active_border.fg, t.win_sep_active);
        try expectRgb(idle_border.fg, t.win_sep);
        try std.testing.expect(!std.meta.eql(active_border.fg, idle_border.fg));
        try std.testing.expect(!std.meta.eql(active_border.fg, vaxis.Color{ .rgb = t.fg_faint }));
    }

    // Two dark themes and one light theme must produce demonstrably
    // different chrome, not merely different names.
    try std.testing.expect(!std.meta.eql(activeTabStyle(a), activeTabStyle(b)));
    try std.testing.expect(!std.meta.eql(activeTabStyle(a), activeTabStyle(light)));
    try std.testing.expect(!std.meta.eql(separatorStyle(a, .major, .default), separatorStyle(b, .major, .default)));
    try std.testing.expect(!std.meta.eql(panelBorderStyle(a, true, .default), panelBorderStyle(light, true, .default)));

    // Light themes are valid styles (no panic, no default/transparent fg)
    // and their marker/underline still come from the palette.
    const light_tab = activeTabStyle(light);
    try expectRgb(light_tab.ul, light.accent_alt);
    try std.testing.expect(contrastRatio(light.fg, light.bg_sel) > 7.0);
}
