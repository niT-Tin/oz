//! Color themes for oz. Semantic palette — the renderer references these
//! names, and a theme maps each to concrete RGB. Defaults to kanagawa-wave
//! (matching the user's nvim colorscheme); other themes are selectable via
//! `:theme <name>` (Tab cycles) or OZ_THEME env var.

const std = @import("std");

/// vaxis Color.Rgb is `[3]u8` (r,g,b); the palette uses that directly so
/// themes drop into `.rgb =` fields without conversion.
pub const Rgb = [3]u8;

/// Semantic color slots used across the UI.
pub const Theme = struct {
    name: []const u8,
    // background shades
    bg: Rgb, // editor background (main text area)
    bg_alt: Rgb, // gutter / inactive / cursorline
    bg_float: Rgb, // hover / completion / picker popups
    bg_status: Rgb, // status bar
    bg_sel: Rgb, // selection / highlighted list row
    bg_curline: Rgb, // cursor line highlight
    // foreground
    fg: Rgb, // main text
    fg_dim: Rgb, // inlay hints, ghost text, muted
    fg_faint: Rgb, // inactive tab, secondary text
    accent: Rgb, // active tab, logo, brand (kanagawa carpYellow)
    accent_alt: Rgb, // secondary accent (springBlue / crystalBlue)
    // syntax
    comment: Rgb,
    keyword: Rgb,
    string: Rgb,
    number: Rgb,
    function: Rgb,
    type: Rgb,
    operator: Rgb,
    punctuation: Rgb,
    // diagnostics
    diag_error: Rgb,
    diag_warn: Rgb,
    diag_info: Rgb,
};

pub fn rgb(r: u8, g: u8, b: u8) Rgb {
    return .{ r, g, b };
}

/// kanagawa-wave — the user's nvim colorscheme.
const kanagawa_wave = Theme{
    .name = "kanagawa-wave",
    .bg = rgb(0x1F, 0x1F, 0x28), // sumiInk3
    .bg_alt = rgb(0x2A, 0x2A, 0x37), // sumiInk4
    .bg_float = rgb(0x22, 0x32, 0x49), // waveBlue1
    .bg_status = rgb(0x2A, 0x2A, 0x37), // sumiInk4
    .bg_sel = rgb(0x2D, 0x4F, 0x67), // waveBlue2
    .bg_curline = rgb(0x2A, 0x2A, 0x37), // sumiInk4
    .fg = rgb(0xDC, 0xD7, 0xBA), // fujiWhite
    .fg_dim = rgb(0x72, 0x71, 0x69), // fujiGray
    .fg_faint = rgb(0x54, 0x54, 0x6D), // sumiInk6
    .accent = rgb(0xE6, 0xC3, 0x84), // carpYellow
    .accent_alt = rgb(0x7E, 0x9C, 0xD8), // crystalBlue
    .comment = rgb(0x72, 0x71, 0x69), // fujiGray
    .keyword = rgb(0x95, 0x7F, 0xB8), // oniViolet
    .string = rgb(0x98, 0xBB, 0x6C), // springGreen
    .number = rgb(0xD2, 0x7E, 0x99), // sakuraPink
    .function = rgb(0x7E, 0x9C, 0xD8), // crystalBlue
    .type = rgb(0x7F, 0xB4, 0xCA), // springBlue
    .operator = rgb(0xC8, 0xC0, 0x93), // oldWhite
    .punctuation = rgb(0x93, 0x8A, 0xA9), // springViolet1
    .diag_error = rgb(0xE8, 0x24, 0x24), // samuraiRed
    .diag_warn = rgb(0xFF, 0x9E, 0x3B), // roninYellow
    .diag_info = rgb(0x65, 0x85, 0x94), // dragonBlue
};

/// catppuccin-macchiato (user's alternative).
const catppuccin_macchiato = Theme{
    .name = "catppuccin-macchiato",
    .bg = rgb(0x24, 0x27, 0x3A), // base
    .bg_alt = rgb(0x30, 0x34, 0x46), // mantle
    .bg_float = rgb(0x1E, 0x20, 0x30), // crust
    .bg_status = rgb(0x30, 0x34, 0x46), // mantle
    .bg_sel = rgb(0x49, 0x4D, 0x64), // surface2
    .bg_curline = rgb(0x30, 0x34, 0x46), // mantle
    .fg = rgb(0xCA, 0xD3, 0xF5), // text
    .fg_dim = rgb(0x6E, 0x73, 0x8F), // overlay1
    .fg_faint = rgb(0x49, 0x4D, 0x64), // surface2
    .accent = rgb(0xF5, 0xE0, 0xDC), // rosewater
    .accent_alt = rgb(0x8A, 0xAD, 0xF4), // blue
    .comment = rgb(0x6E, 0x73, 0x8F), // overlay1
    .keyword = rgb(0xC6, 0xA0, 0xF6), // mauve
    .string = rgb(0xA6, 0xDA, 0x95), // green
    .number = rgb(0xF5, 0xA9, 0x7F), // peach
    .function = rgb(0x8A, 0xAD, 0xF4), // blue
    .type = rgb(0x8B, 0xD5, 0xCA), // teal
    .operator = rgb(0xCA, 0xD3, 0xF5), // text
    .punctuation = rgb(0xB7, 0xBD, 0xDF), // subtext1
    .diag_error = rgb(0xED, 0x87, 0x96), // red
    .diag_warn = rgb(0xEE, 0xDA, 0x9F), // yellow
    .diag_info = rgb(0x8A, 0xAD, 0xF4), // blue
};

/// tokyonight-moon (user's alternative).
const tokyonight_moon = Theme{
    .name = "tokyonight-moon",
    .bg = rgb(0x1E, 0x20, 0x32), // bg
    .bg_alt = rgb(0x2A, 0x2E, 0x48), // bg_dark
    .bg_float = rgb(0x16, 0x18, 0x28), // bg_float
    .bg_status = rgb(0x2A, 0x2E, 0x48), // bg_dark
    .bg_sel = rgb(0x33, 0x41, 0x5E), // bg_highlight
    .bg_curline = rgb(0x2A, 0x2E, 0x48), // bg_dark
    .fg = rgb(0xC8, 0xD3, 0xF5), // fg
    .fg_dim = rgb(0x82, 0x8B, 0xB8), // comment
    .fg_faint = rgb(0x56, 0x5F, 0x89), // comment_dark
    .accent = rgb(0xE0, 0xAF, 0x68), // orange
    .accent_alt = rgb(0x82, 0xAA, 0xFF), // blue
    .comment = rgb(0x82, 0x8B, 0xB8), // comment
    .keyword = rgb(0xC0, 0xCA, 0xF5), // violet
    .string = rgb(0x9D, 0xCD, 0x5F), // green
    .number = rgb(0xFF, 0x9E, 0x64), // orange
    .function = rgb(0x82, 0xAA, 0xFF), // blue
    .type = rgb(0x2A, 0xC3, 0xDE), // cyan
    .operator = rgb(0xC8, 0xD3, 0xF5), // fg
    .punctuation = rgb(0x89, 0x9A, 0xCC), // fg_dark
    .diag_error = rgb(0xDB, 0x4B, 0x4B), // red
    .diag_warn = rgb(0xE0, 0xAF, 0x68), // orange
    .diag_info = rgb(0x82, 0xAA, 0xFF), // blue
};

pub const themes = [_]Theme{ kanagawa_wave, catppuccin_macchiato, tokyonight_moon };

/// Default theme (kanagawa-wave).
pub const default = themes[0];

/// Look up a theme by name (case-insensitive), accepting a unique prefix
/// (e.g. "tokyo" for "tokyonight-moon"). null when unknown.
pub fn byName(name: []const u8) ?Theme {
    var match: ?Theme = null;
    for (themes) |t| {
        if (std.ascii.eqlIgnoreCase(name, t.name)) return t;
        if (name.len > 0 and name.len <= t.name.len and
            std.ascii.eqlIgnoreCase(name, t.name[0..name.len]))
        {
            if (match != null) return null; // ambiguous prefix
            match = t;
        }
    }
    return match;
}

/// Theme picked from OZ_THEME env var, falling back to the default.
pub fn fromEnv(env_map: *std.process.Environ.Map) Theme {
    if (env_map.get("OZ_THEME")) |name| {
        if (byName(name)) |t| return t;
    }
    return default;
}
