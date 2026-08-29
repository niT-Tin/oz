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
    bg_alt: Rgb, // gutter / inactive line numbers (distinct from bg_curline
    // so the cursor line pops and row-bg tests can tell them apart)
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
    // window split separators (vim-style boundary lines between panes)
    win_sep: Rgb, // inactive separator (dim)
    win_sep_active: Rgb, // separator adjacent to the focused window
    // syntax
    comment: Rgb,
    keyword: Rgb,
    string: Rgb,
    number: Rgb,
    function: Rgb,
    type: Rgb,
    operator: Rgb,
    punctuation: Rgb,
    // syntax — extended token slots (consumed by Phase 2 highlighting)
    variable: Rgb, // local variables / plain identifiers (kanagawa: inherits fg)
    parameter: Rgb, // function parameters
    property: Rgb, // field access, struct members (kanagawa: Identifier)
    constant: Rgb, // constants and literal-ish tokens
    boolean: Rgb, // true/false (kanagawa: links to Constant)
    character: Rgb, // char literals (kanagawa: links to String)
    namespace: Rgb, // modules / namespaces
    constructor: Rgb, // type constructors (kanagawa: special1)
    builtin: Rgb, // builtin functions / special tokens (kanagawa: special2)
    attribute: Rgb, // attributes / decorators
    label: Rgb, // labels / goto targets
    tag: Rgb, // markup tags / enum variants
    // rainbow brackets + indent guides (visual enhancements)
    rainbow: [7]Rgb, // rainbow bracket colors, 7 levels
    indent: [8]Rgb, // indent guide ramp: [0..6] reuse rainbow, [7] is the dim
    // loop-back color for level 8+ so deep nesting stays subtle
    // diagnostics
    diag_error: Rgb,
    diag_warn: Rgb,
    diag_info: Rgb,
    // git signs (M3a): added / modified / deleted markers in the gutter
    git_add: Rgb,
    git_mod: Rgb,
    git_del: Rgb,
};

pub fn rgb(r: u8, g: u8, b: u8) Rgb {
    return .{ r, g, b };
}

/// onedark-style rainbow palette, shared by every theme (matches the user's
/// nvim rainbow brackets defined in themes.lua).
const onedark_rainbow = [7]Rgb{
    rgb(0xE0, 0x6C, 0x75), // red
    rgb(0xE5, 0xC0, 0x7B), // yellow
    rgb(0x61, 0xAF, 0xEF), // blue
    rgb(0xD1, 0x9A, 0x66), // orange
    rgb(0x98, 0xC3, 0x79), // green
    rgb(0xC6, 0x78, 0xDD), // purple
    rgb(0x56, 0xB6, 0xC2), // cyan
};

/// kanagawa-wave — the user's nvim colorscheme.
const kanagawa_wave = Theme{
    .name = "kanagawa-wave",
    .bg = rgb(0x1F, 0x1F, 0x28), // sumiInk3
    .bg_alt = rgb(0x24, 0x24, 0x30), // between sumiInk3 and sumiInk4
    .bg_float = rgb(0x22, 0x32, 0x49), // waveBlue1
    .bg_status = rgb(0x2A, 0x2A, 0x37), // sumiInk4
    .bg_sel = rgb(0x2D, 0x4F, 0x67), // waveBlue2
    .bg_curline = rgb(0x2A, 0x2A, 0x37), // sumiInk4
    .fg = rgb(0xDC, 0xD7, 0xBA), // fujiWhite
    .fg_dim = rgb(0x72, 0x71, 0x69), // fujiGray
    .fg_faint = rgb(0x54, 0x54, 0x6D), // sumiInk6
    .accent = rgb(0xE6, 0xC3, 0x84), // carpYellow
    .accent_alt = rgb(0x7E, 0x9C, 0xD8), // crystalBlue
    .win_sep = rgb(0x54, 0x54, 0x6D), // sumiInk6 (same as fg_faint)
    .win_sep_active = rgb(0xE6, 0xC3, 0x84), // carpYellow (accent)
    .comment = rgb(0x72, 0x71, 0x69), // fujiGray
    .keyword = rgb(0x95, 0x7F, 0xB8), // oniViolet
    .string = rgb(0x98, 0xBB, 0x6C), // springGreen
    .number = rgb(0xD2, 0x7E, 0x99), // sakuraPink
    .function = rgb(0x7E, 0x9C, 0xD8), // crystalBlue
    .type = rgb(0x7A, 0xA8, 0x9F), // waveAqua2
    .operator = rgb(0xC0, 0xA3, 0x6E), // boatYellow2
    .punctuation = rgb(0x9C, 0xAB, 0xCA), // springViolet2
    .variable = rgb(0xDC, 0xD7, 0xBA), // fujiWhite (Variable = none → fg)
    .parameter = rgb(0xB8, 0xB4, 0xD0), // oniViolet2
    .property = rgb(0xE6, 0xC3, 0x84), // carpYellow (Identifier)
    .constant = rgb(0xFF, 0xA0, 0x66), // surimiOrange
    .boolean = rgb(0xFF, 0xA0, 0x66), // surimiOrange (links to Constant)
    .character = rgb(0x98, 0xBB, 0x6C), // springGreen (links to String)
    .namespace = rgb(0x7F, 0xB4, 0xCA), // springBlue
    .constructor = rgb(0x7F, 0xB4, 0xCA), // springBlue (special1)
    .builtin = rgb(0xE4, 0x68, 0x76), // waveRed (special2)
    .attribute = rgb(0xFF, 0xA0, 0x66), // surimiOrange (links to Constant)
    .label = rgb(0x7F, 0xB4, 0xCA), // springBlue (special1)
    .tag = rgb(0x7F, 0xB4, 0xCA), // springBlue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = fg_dim (fujiGray) loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x72, 0x71, 0x69),
    },
    .diag_error = rgb(0xE8, 0x24, 0x24), // samuraiRed
    .diag_warn = rgb(0xFF, 0x9E, 0x3B), // roninYellow
    .diag_info = rgb(0x65, 0x85, 0x94), // dragonBlue
    .git_add = rgb(0x98, 0xBB, 0x6C), // springGreen (same as string)
    .git_mod = rgb(0xC0, 0xA3, 0x6E), // boatYellow2 (same as operator)
    .git_del = rgb(0xE4, 0x68, 0x76), // waveRed (same as builtin)
};

/// catppuccin-macchiato (user's alternative).
const catppuccin_macchiato = Theme{
    .name = "catppuccin-macchiato",
    .bg = rgb(0x24, 0x27, 0x3A), // base
    .bg_alt = rgb(0x2B, 0x2E, 0x40), // between base and mantle
    .bg_float = rgb(0x1E, 0x20, 0x30), // crust
    .bg_status = rgb(0x30, 0x34, 0x46), // mantle
    .bg_sel = rgb(0x49, 0x4D, 0x64), // surface2
    .bg_curline = rgb(0x30, 0x34, 0x46), // mantle
    .fg = rgb(0xCA, 0xD3, 0xF5), // text
    .fg_dim = rgb(0x6E, 0x73, 0x8F), // overlay1
    .fg_faint = rgb(0x49, 0x4D, 0x64), // surface2
    .accent = rgb(0xF5, 0xE0, 0xDC), // rosewater
    .accent_alt = rgb(0x8A, 0xAD, 0xF4), // blue
    .win_sep = rgb(0x49, 0x4D, 0x64), // surface2 (same as fg_faint)
    .win_sep_active = rgb(0xF5, 0xE0, 0xDC), // rosewater (accent)
    .comment = rgb(0x6E, 0x73, 0x8F), // overlay1
    .keyword = rgb(0xC6, 0xA0, 0xF6), // mauve
    .string = rgb(0xA6, 0xDA, 0x95), // green
    .number = rgb(0xF5, 0xA9, 0x7F), // peach
    .function = rgb(0x8A, 0xAD, 0xF4), // blue
    .type = rgb(0x8B, 0xD5, 0xCA), // teal
    .operator = rgb(0xCA, 0xD3, 0xF5), // text
    .punctuation = rgb(0xB7, 0xBD, 0xDF), // subtext1
    .variable = rgb(0xCA, 0xD3, 0xF5), // text
    .parameter = rgb(0xBA, 0xBB, 0xF1), // lavender
    .property = rgb(0x8A, 0xAD, 0xF4), // blue
    .constant = rgb(0xF5, 0xA9, 0x7F), // peach
    .boolean = rgb(0xF5, 0xA9, 0x7F), // peach
    .character = rgb(0xA6, 0xDA, 0x95), // green
    .namespace = rgb(0x8A, 0xAD, 0xF4), // blue
    .constructor = rgb(0x8A, 0xAD, 0xF4), // blue
    .builtin = rgb(0xED, 0x87, 0x96), // red
    .attribute = rgb(0xF5, 0xA9, 0x7F), // peach
    .label = rgb(0x8B, 0xD5, 0xCA), // teal
    .tag = rgb(0x8A, 0xAD, 0xF4), // blue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = overlay0 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x6C, 0x70, 0x86),
    },
    .diag_error = rgb(0xED, 0x87, 0x96), // red
    .diag_warn = rgb(0xEE, 0xDA, 0x9F), // yellow
    .diag_info = rgb(0x8A, 0xAD, 0xF4), // blue
    .git_add = rgb(0xA6, 0xDA, 0x95), // green (same as string)
    .git_mod = rgb(0xEE, 0xDA, 0x9F), // yellow (same as diag_warn)
    .git_del = rgb(0xED, 0x87, 0x96), // red (same as builtin)
};

/// tokyonight-moon (user's alternative).
const tokyonight_moon = Theme{
    .name = "tokyonight-moon",
    .bg = rgb(0x1E, 0x20, 0x32), // bg
    .bg_alt = rgb(0x25, 0x29, 0x41), // between bg and bg_dark
    .bg_float = rgb(0x16, 0x18, 0x28), // bg_float
    .bg_status = rgb(0x2A, 0x2E, 0x48), // bg_dark
    .bg_sel = rgb(0x33, 0x41, 0x5E), // bg_highlight
    .bg_curline = rgb(0x2A, 0x2E, 0x48), // bg_dark
    .fg = rgb(0xC8, 0xD3, 0xF5), // fg
    .fg_dim = rgb(0x82, 0x8B, 0xB8), // comment
    .fg_faint = rgb(0x56, 0x5F, 0x89), // comment_dark
    .accent = rgb(0xE0, 0xAF, 0x68), // orange
    .accent_alt = rgb(0x82, 0xAA, 0xFF), // blue
    .win_sep = rgb(0x56, 0x5F, 0x89), // comment_dark (same as fg_faint)
    .win_sep_active = rgb(0xE0, 0xAF, 0x68), // orange (accent)
    .comment = rgb(0x82, 0x8B, 0xB8), // comment
    .keyword = rgb(0xC0, 0xCA, 0xF5), // violet
    .string = rgb(0x9D, 0xCD, 0x5F), // green
    .number = rgb(0xFF, 0x9E, 0x64), // orange
    .function = rgb(0x82, 0xAA, 0xFF), // blue
    .type = rgb(0x2A, 0xC3, 0xDE), // cyan
    .operator = rgb(0xC8, 0xD3, 0xF5), // fg
    .punctuation = rgb(0x89, 0x9A, 0xCC), // fg_dark
    .variable = rgb(0xC8, 0xD3, 0xF5), // fg
    .parameter = rgb(0xB4, 0xC2, 0xF0), // slightly brighter than fg
    .property = rgb(0x82, 0xAA, 0xFF), // blue
    .constant = rgb(0xE0, 0xAF, 0x68), // orange
    .boolean = rgb(0xE0, 0xAF, 0x68), // orange
    .character = rgb(0x9D, 0xCD, 0x5F), // green
    .namespace = rgb(0x82, 0xAA, 0xFF), // blue
    .constructor = rgb(0x82, 0xAA, 0xFF), // blue
    .builtin = rgb(0xDB, 0x4B, 0x4B), // red
    .attribute = rgb(0xE0, 0xAF, 0x68), // orange
    .label = rgb(0x2A, 0xC3, 0xDE), // cyan
    .tag = rgb(0x82, 0xAA, 0xFF), // blue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = comment loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x82, 0x8B, 0xB8),
    },
    .diag_error = rgb(0xDB, 0x4B, 0x4B), // red
    .diag_warn = rgb(0xE0, 0xAF, 0x68), // orange
    .diag_info = rgb(0x82, 0xAA, 0xFF), // blue
    .git_add = rgb(0x9D, 0xCD, 0x5F), // green (same as string)
    .git_mod = rgb(0xE0, 0xAF, 0x68), // orange (same as diag_warn)
    .git_del = rgb(0xDB, 0x4B, 0x4B), // red (same as builtin)
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
