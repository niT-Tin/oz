//! Theme-aware chrome styles shared by every TUI surface.
//!
//! Active tabs, panel borders, section rules and the status band must all
//! derive from the active palette. Keeping the mapping here (instead of
//! repeating raw `theme.*` field picks in `render.zig` and `ai.zig`) means
//! the navigator, buffer tab bar and workbox cannot drift apart, and makes
//! the treatment unit-testable without a terminal.
//!
//! The design mirrors the approved web demo: layered editor/band/card
//! surfaces, bold active text and a real SGR underline in `accent_alt`.
//! Active buffer tabs join the editor surface; navigator/workbox selections
//! use `bg_sel`. The `>` marker and file icons share the same accent.
//!
//! `bg` is passed in by the caller because the same logical style lands on
//! different panel surfaces; only semantic foreground/background roles live
//! here.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("../theme.zig");

/// Visual weight of a separator/rule. Both weights use the ordinary window
/// separator color; only focus, active tabs and pending work get a bright
/// accent. `minor` additionally dims the line for dense chrome.
pub const Emphasis = enum { minor, major };

/// Editor content: the default reading surface, not a floating card.
pub fn surfaceStyle(t: theme.Theme) vaxis.Style {
    return .{ .fg = .{ .rgb = t.fg }, .bg = .{ .rgb = t.bg } };
}

/// Persistent chrome such as the buffer strip and global status line.
pub fn bandStyle(t: theme.Theme) vaxis.Style {
    return .{ .fg = .{ .rgb = t.fg_dim }, .bg = .{ .rgb = t.bg_status } };
}

/// A quiet raised region. Cards use `bg_alt`; `bg_float` remains reserved
/// for actual overlays, so ordinary workspace content does not become a
/// full-screen floating panel.
pub fn cardStyle(t: theme.Theme) vaxis.Style {
    return .{ .fg = .{ .rgb = t.fg }, .bg = .{ .rgb = t.bg_alt } };
}

pub const DiffKind = enum { context, added, removed };

/// Diff foreground semantics on a caller-selected surface. The sign and
/// foreground carry the meaning; no accent flood or hardcoded green/red.
pub fn diffStyle(t: theme.Theme, kind: DiffKind, bg: vaxis.Color) vaxis.Style {
    const fg = switch (kind) {
        .context => t.fg_dim,
        .added => t.git_add,
        .removed => t.git_del,
    };
    return .{ .fg = .{ .rgb = fg }, .bg = bg };
}

/// Text style of the selected navigator / workbox tab.
pub fn activeTabStyle(t: theme.Theme) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.fg },
        .bg = .{ .rgb = t.bg_sel },
        .bold = true,
        .ul = .{ .rgb = t.accent_alt },
        .ul_style = .single,
    };
}

/// Softer selection surface for dense lists and workbox tabs: a full
/// `bg_sel` wash reads as a banner; this blend keeps `bg_sel`'s hue while
/// letting the marker/bold/underline carry the selection.
pub fn mutedSelectionColor(t: theme.Theme) vaxis.Color {
    const a = t.bg_float;
    const b = t.bg_sel;
    var out: [3]u8 = undefined;
    inline for (0..3) |i| {
        const av: u16 = a[i];
        const bv: u16 = b[i];
        out[i] = @intCast((av * 45 + bv * 55) / 100);
    }
    return .{ .rgb = out };
}

/// Active buffer tab: continuous with the editor surface, as in the approved
/// demo. Bold + underline preserve the state without relying on color.
pub fn activeSurfaceTabStyle(t: theme.Theme) vaxis.Style {
    var style = activeTabStyle(t);
    style.bg = .{ .rgb = t.bg };
    return style;
}

/// `>` marker / active file icon inside a navigator or workbox tab.
pub fn activeTabMarkerStyle(t: theme.Theme) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.accent_alt },
        .bg = .{ .rgb = t.bg_sel },
        .bold = true,
        .ul = .{ .rgb = t.accent_alt },
        .ul_style = .single,
    };
}

pub fn activeSurfaceTabMarkerStyle(t: theme.Theme) vaxis.Style {
    var style = activeTabMarkerStyle(t);
    style.bg = .{ .rgb = t.bg };
    return style;
}

/// Inactive tab: readable dim body text on the surrounding panel surface.
pub fn inactiveTabStyle(t: theme.Theme, bg: vaxis.Color) vaxis.Style {
    return .{ .fg = .{ .rgb = t.fg_dim }, .bg = bg };
}

/// `>` marker of the attached agent thread on its existing row surface.
pub fn activeThreadMarkerStyle(t: theme.Theme, bg: vaxis.Color) vaxis.Style {
    return .{ .fg = .{ .rgb = t.accent_alt }, .bg = bg, .bold = true };
}

/// Ordinary structural rule. Focused panel borders and active tab underlines
/// are stronger; major rules no longer turn into full-width accent stripes.
pub fn separatorStyle(t: theme.Theme, emphasis: Emphasis, bg: vaxis.Color) vaxis.Style {
    return .{
        .fg = .{ .rgb = t.win_sep },
        .bg = bg,
        .dim = emphasis == .minor,
    };
}

/// Outer panel border: `win_sep` when inactive, the theme's active window
/// separator only when the panel owns the keyboard.
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
        try expectRgb(major.fg, t.win_sep);
        try std.testing.expect(!major.dim);

        const minor = separatorStyle(t, .minor, .{ .rgb = t.bg });
        try expectRgb(minor.fg, t.win_sep);
        try std.testing.expect(minor.dim);

        const active_border = panelBorderStyle(t, true, .{ .rgb = t.bg });
        const idle_border = panelBorderStyle(t, false, .{ .rgb = t.bg });
        try expectRgb(active_border.fg, t.win_sep_active);
        try expectRgb(idle_border.fg, t.win_sep);
        try std.testing.expect(!std.meta.eql(active_border.fg, idle_border.fg));
        try std.testing.expect(!std.meta.eql(active_border.fg, vaxis.Color{ .rgb = t.fg_faint }));
    }

    try std.testing.expect(!std.meta.eql(activeTabStyle(a), activeTabStyle(b)));
    try std.testing.expect(!std.meta.eql(activeTabStyle(a), activeTabStyle(light)));
    try std.testing.expect(!std.meta.eql(separatorStyle(a, .major, .default), separatorStyle(b, .major, .default)));
    try std.testing.expect(!std.meta.eql(panelBorderStyle(a, true, .default), panelBorderStyle(light, true, .default)));

    const light_tab = activeTabStyle(light);
    try expectRgb(light_tab.ul, light.accent_alt);
    try std.testing.expect(contrastRatio(light.fg, light.bg_sel) > 7.0);
}

test "chrome: surface band card and diff roles stay semantic in every theme" {
    for (theme.themes) |t| {
        const surface = surfaceStyle(t);
        try expectRgb(surface.fg, t.fg);
        try expectRgb(surface.bg, t.bg);

        const band = bandStyle(t);
        try expectRgb(band.fg, t.fg_dim);
        try expectRgb(band.bg, t.bg_status);

        const card = cardStyle(t);
        try expectRgb(card.fg, t.fg);
        try expectRgb(card.bg, t.bg_alt);

        const active_buffer = activeSurfaceTabStyle(t);
        try expectRgb(active_buffer.bg, t.bg);
        try expectRgb(active_buffer.ul, t.accent_alt);
        try std.testing.expect(active_buffer.bold);
        try expectRgb(activeSurfaceTabMarkerStyle(t).bg, t.bg);

        const card_bg = vaxis.Color{ .rgb = t.bg_alt };
        try expectRgb(diffStyle(t, .context, card_bg).fg, t.fg_dim);
        try expectRgb(diffStyle(t, .added, card_bg).fg, t.git_add);
        try expectRgb(diffStyle(t, .removed, card_bg).fg, t.git_del);
        try expectRgb(diffStyle(t, .added, card_bg).bg, t.bg_alt);
    }
}
