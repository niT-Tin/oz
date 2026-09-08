//! Color themes for oz. Semantic palette — the renderer references these
//! names, and a theme maps each to concrete RGB. Defaults to kanagawa-wave
//! (matching the user's nvim colorscheme); other themes are selectable via
//! `:theme <name>` (Tab cycles) or the theme picker. The selection persists
//! automatically to ~/.cache/oz/theme — no env var, no config file.

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

/// kanagawa-dragon — kanagawa's warmer, desaturated dark variant.
/// Source: kanagawa.nvim themes.lua (dragon) + colors.lua.
const kanagawa_dragon = Theme{
    .name = "kanagawa-dragon",
    .bg = rgb(0x18, 0x16, 0x16), // dragonBlack3
    .bg_alt = rgb(0x20, 0x1E, 0x1E), // between dragonBlack3 and dragonBlack4
    .bg_float = rgb(0x22, 0x32, 0x49), // waveBlue1 (pmenu bg)
    .bg_status = rgb(0x28, 0x27, 0x27), // dragonBlack4
    .bg_sel = rgb(0x2D, 0x4F, 0x67), // waveBlue2 (bg_search; visual = waveBlue1)
    .bg_curline = rgb(0x28, 0x27, 0x27), // dragonBlack4
    .fg = rgb(0xC5, 0xC9, 0xC5), // dragonWhite
    .fg_dim = rgb(0x73, 0x7C, 0x73), // dragonAsh (comment)
    .fg_faint = rgb(0x62, 0x5E, 0x5A), // dragonBlack6 (nontext)
    .accent = rgb(0xC4, 0xB2, 0x8A), // dragonYellow
    .accent_alt = rgb(0x8B, 0xA4, 0xB0), // dragonBlue2
    .win_sep = rgb(0x62, 0x5E, 0x5A), // dragonBlack6 (same as fg_faint)
    .win_sep_active = rgb(0xC4, 0xB2, 0x8A), // dragonYellow (accent)
    .comment = rgb(0x73, 0x7C, 0x73), // dragonAsh
    .keyword = rgb(0x89, 0x92, 0xA7), // dragonViolet
    .string = rgb(0x8A, 0x9A, 0x7B), // dragonGreen2
    .number = rgb(0xA2, 0x92, 0xA3), // dragonPink
    .function = rgb(0x8B, 0xA4, 0xB0), // dragonBlue2
    .type = rgb(0x8E, 0xA4, 0xA2), // dragonAqua
    .operator = rgb(0xC4, 0x74, 0x6E), // dragonRed
    .punctuation = rgb(0x9E, 0x9B, 0x93), // dragonGray2
    .variable = rgb(0xC5, 0xC9, 0xC5), // dragonWhite (Variable = none → fg)
    .parameter = rgb(0xA6, 0xA6, 0x9C), // dragonGray
    .property = rgb(0xC4, 0xB2, 0x8A), // dragonYellow (Identifier)
    .constant = rgb(0xB6, 0x92, 0x7B), // dragonOrange
    .boolean = rgb(0xB6, 0x92, 0x7B), // dragonOrange (links to Constant)
    .character = rgb(0x8A, 0x9A, 0x7B), // dragonGreen2 (links to String)
    .namespace = rgb(0x94, 0x9F, 0xB5), // dragonTeal
    .constructor = rgb(0x94, 0x9F, 0xB5), // dragonTeal (special1)
    .builtin = rgb(0xC4, 0x74, 0x6E), // dragonRed (special2)
    .attribute = rgb(0xB6, 0x92, 0x7B), // dragonOrange (links to Constant)
    .label = rgb(0x94, 0x9F, 0xB5), // dragonTeal (special1)
    .tag = rgb(0x94, 0x9F, 0xB5), // dragonTeal
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = dragonAsh loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x73, 0x7C, 0x73),
    },
    .diag_error = rgb(0xE8, 0x24, 0x24), // samuraiRed
    .diag_warn = rgb(0xFF, 0x9E, 0x3B), // roninYellow
    .diag_info = rgb(0x65, 0x85, 0x94), // dragonBlue
    .git_add = rgb(0x8A, 0x9A, 0x7B), // dragonGreen2 (same as string)
    .git_mod = rgb(0xDC, 0xA5, 0x61), // autumnYellow (vcs.changed)
    .git_del = rgb(0xC4, 0x74, 0x6E), // dragonRed (same as builtin)
};

/// everforest (dark, medium contrast).
/// Source: everforest/autoload/everforest.vim (dark medium palette1 + palette2).
const everforest = Theme{
    .name = "everforest",
    .bg = rgb(0x2D, 0x35, 0x3B), // bg0
    .bg_alt = rgb(0x30, 0x3A, 0x3F), // between bg0 and bg1
    .bg_float = rgb(0x3D, 0x48, 0x4D), // bg2 (NormalFloat, float_style=bright)
    .bg_status = rgb(0x3D, 0x48, 0x4D), // bg2 (StatusLine)
    .bg_sel = rgb(0x54, 0x3A, 0x48), // bg_visual
    .bg_curline = rgb(0x34, 0x3F, 0x44), // bg1 (CursorLine)
    .fg = rgb(0xD3, 0xC6, 0xAA), // fg
    .fg_dim = rgb(0x85, 0x92, 0x89), // grey1 (comment)
    .fg_faint = rgb(0x7A, 0x84, 0x78), // grey0
    .accent = rgb(0xDB, 0xBC, 0x7F), // yellow
    .accent_alt = rgb(0x7F, 0xBB, 0xB3), // blue
    .win_sep = rgb(0x7A, 0x84, 0x78), // grey0 (same as fg_faint)
    .win_sep_active = rgb(0xDB, 0xBC, 0x7F), // yellow (accent)
    .comment = rgb(0x85, 0x92, 0x89), // grey1
    .keyword = rgb(0xE6, 0x7E, 0x80), // red
    .string = rgb(0xA7, 0xC0, 0x80), // green
    .number = rgb(0xD6, 0x99, 0xB6), // purple
    .function = rgb(0xA7, 0xC0, 0x80), // green
    .type = rgb(0xDB, 0xBC, 0x7F), // yellow
    .operator = rgb(0xE6, 0x98, 0x75), // orange
    .punctuation = rgb(0xD3, 0xC6, 0xAA), // fg (Delimiter)
    .variable = rgb(0xD3, 0xC6, 0xAA), // fg (TSVariable)
    .parameter = rgb(0xD3, 0xC6, 0xAA), // fg (TSParameter)
    .property = rgb(0x7F, 0xBB, 0xB3), // blue (TSProperty)
    .constant = rgb(0x83, 0xC0, 0x92), // aqua
    .boolean = rgb(0xD6, 0x99, 0xB6), // purple
    .character = rgb(0xA7, 0xC0, 0x80), // green
    .namespace = rgb(0xDB, 0xBC, 0x7F), // yellow (TSNamespace YellowItalic)
    .constructor = rgb(0xA7, 0xC0, 0x80), // green (TSConstructor)
    .builtin = rgb(0xD6, 0x99, 0xB6), // purple (TSVariableBuiltin)
    .attribute = rgb(0xD6, 0x99, 0xB6), // purple (TSAttribute)
    .label = rgb(0xE6, 0x98, 0x75), // orange
    .tag = rgb(0xE6, 0x98, 0x75), // orange
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = grey1 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x85, 0x92, 0x89),
    },
    .diag_error = rgb(0xE6, 0x7E, 0x80), // red
    .diag_warn = rgb(0xDB, 0xBC, 0x7F), // yellow
    .diag_info = rgb(0x7F, 0xBB, 0xB3), // blue
    .git_add = rgb(0xA7, 0xC0, 0x80), // green (same as string)
    .git_mod = rgb(0xDB, 0xBC, 0x7F), // yellow (same as diag_warn)
    .git_del = rgb(0xE6, 0x7E, 0x80), // red (same as keyword)
};

/// tokyonight-night — the classic deep-dark tokyonight variant.
/// Source: tokyonight.nvim colors/night.lua (storm palette + darker bg).
const tokyonight_night = Theme{
    .name = "tokyonight-night",
    .bg = rgb(0x1A, 0x1B, 0x26), // bg
    .bg_alt = rgb(0x18, 0x18, 0x22), // between bg and bg_dark
    .bg_float = rgb(0x16, 0x16, 0x1E), // bg_dark (NormalFloat)
    .bg_status = rgb(0x16, 0x16, 0x1E), // bg_dark (StatusLine)
    .bg_sel = rgb(0x28, 0x34, 0x57), // bg_visual (blue0 blended 40% over bg)
    .bg_curline = rgb(0x29, 0x2E, 0x42), // bg_highlight (CursorLine)
    .fg = rgb(0xC0, 0xCA, 0xF5), // fg
    .fg_dim = rgb(0x56, 0x5F, 0x89), // comment
    .fg_faint = rgb(0x3B, 0x42, 0x61), // fg_gutter
    .accent = rgb(0x7A, 0xA2, 0xF7), // blue
    .accent_alt = rgb(0x7D, 0xCF, 0xFF), // cyan
    .win_sep = rgb(0x3B, 0x42, 0x61), // fg_gutter (same as fg_faint)
    .win_sep_active = rgb(0x7A, 0xA2, 0xF7), // blue (accent)
    .comment = rgb(0x56, 0x5F, 0x89), // comment
    .keyword = rgb(0x9D, 0x7C, 0xD8), // purple (@keyword)
    .string = rgb(0x9E, 0xCE, 0x6A), // green
    .number = rgb(0xFF, 0x9E, 0x64), // orange
    .function = rgb(0x7A, 0xA2, 0xF7), // blue
    .type = rgb(0x2A, 0xC3, 0xDE), // blue1 (Type)
    .operator = rgb(0x89, 0xDD, 0xFF), // blue5
    .punctuation = rgb(0xA9, 0xB1, 0xD6), // fg_dark (@punctuation.bracket)
    .variable = rgb(0xC0, 0xCA, 0xF5), // fg (@variable)
    .parameter = rgb(0xE0, 0xAF, 0x68), // yellow (@variable.parameter)
    .property = rgb(0x73, 0xDA, 0xCA), // green1 (@property/@variable.member)
    .constant = rgb(0xFF, 0x9E, 0x64), // orange (Constant)
    .boolean = rgb(0xFF, 0x9E, 0x64), // orange (Boolean → Constant)
    .character = rgb(0x9E, 0xCE, 0x6A), // green (Character)
    .namespace = rgb(0x7D, 0xCF, 0xFF), // cyan (@module → Include → PreProc)
    .constructor = rgb(0xBB, 0x9A, 0xF7), // magenta (@constructor)
    .builtin = rgb(0xF7, 0x76, 0x8E), // red (@variable.builtin)
    .attribute = rgb(0x7D, 0xCF, 0xFF), // cyan (@attribute → PreProc)
    .label = rgb(0x7A, 0xA2, 0xF7), // blue (@label)
    .tag = rgb(0x7A, 0xA2, 0xF7), // blue (@tag → Label)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = comment loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x56, 0x5F, 0x89),
    },
    .diag_error = rgb(0xDB, 0x4B, 0x4B), // red1 (DiagnosticError)
    .diag_warn = rgb(0xE0, 0xAF, 0x68), // yellow
    .diag_info = rgb(0x0D, 0xB9, 0xD7), // blue2 (DiagnosticInfo)
    .git_add = rgb(0x9E, 0xCE, 0x6A), // green (same as string)
    .git_mod = rgb(0xE0, 0xAF, 0x68), // yellow (same as diag_warn)
    .git_del = rgb(0xF7, 0x76, 0x8E), // red (same as builtin)
};

/// tokyonight-storm — the lighter storm variant.
/// Source: tokyonight.nvim colors/storm.lua.
const tokyonight_storm = Theme{
    .name = "tokyonight-storm",
    .bg = rgb(0x24, 0x28, 0x3B), // bg
    .bg_alt = rgb(0x21, 0x25, 0x38), // between bg and bg_dark
    .bg_float = rgb(0x1F, 0x23, 0x35), // bg_dark (NormalFloat)
    .bg_status = rgb(0x1F, 0x23, 0x35), // bg_dark (StatusLine)
    .bg_sel = rgb(0x2E, 0x3C, 0x64), // bg_visual (blue0 blended 40% over bg)
    .bg_curline = rgb(0x29, 0x2E, 0x42), // bg_highlight (CursorLine)
    .fg = rgb(0xC0, 0xCA, 0xF5), // fg
    .fg_dim = rgb(0x56, 0x5F, 0x89), // comment
    .fg_faint = rgb(0x3B, 0x42, 0x61), // fg_gutter
    .accent = rgb(0x7A, 0xA2, 0xF7), // blue
    .accent_alt = rgb(0x7D, 0xCF, 0xFF), // cyan
    .win_sep = rgb(0x3B, 0x42, 0x61), // fg_gutter (same as fg_faint)
    .win_sep_active = rgb(0x7A, 0xA2, 0xF7), // blue (accent)
    .comment = rgb(0x56, 0x5F, 0x89), // comment
    .keyword = rgb(0x9D, 0x7C, 0xD8), // purple (@keyword)
    .string = rgb(0x9E, 0xCE, 0x6A), // green
    .number = rgb(0xFF, 0x9E, 0x64), // orange
    .function = rgb(0x7A, 0xA2, 0xF7), // blue
    .type = rgb(0x2A, 0xC3, 0xDE), // blue1 (Type)
    .operator = rgb(0x89, 0xDD, 0xFF), // blue5
    .punctuation = rgb(0xA9, 0xB1, 0xD6), // fg_dark (@punctuation.bracket)
    .variable = rgb(0xC0, 0xCA, 0xF5), // fg (@variable)
    .parameter = rgb(0xE0, 0xAF, 0x68), // yellow (@variable.parameter)
    .property = rgb(0x73, 0xDA, 0xCA), // green1 (@property/@variable.member)
    .constant = rgb(0xFF, 0x9E, 0x64), // orange (Constant)
    .boolean = rgb(0xFF, 0x9E, 0x64), // orange (Boolean → Constant)
    .character = rgb(0x9E, 0xCE, 0x6A), // green (Character)
    .namespace = rgb(0x7D, 0xCF, 0xFF), // cyan (@module → Include → PreProc)
    .constructor = rgb(0xBB, 0x9A, 0xF7), // magenta (@constructor)
    .builtin = rgb(0xF7, 0x76, 0x8E), // red (@variable.builtin)
    .attribute = rgb(0x7D, 0xCF, 0xFF), // cyan (@attribute → PreProc)
    .label = rgb(0x7A, 0xA2, 0xF7), // blue (@label)
    .tag = rgb(0x7A, 0xA2, 0xF7), // blue (@tag → Label)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = comment loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x56, 0x5F, 0x89),
    },
    .diag_error = rgb(0xDB, 0x4B, 0x4B), // red1 (DiagnosticError)
    .diag_warn = rgb(0xE0, 0xAF, 0x68), // yellow
    .diag_info = rgb(0x0D, 0xB9, 0xD7), // blue2 (DiagnosticInfo)
    .git_add = rgb(0x9E, 0xCE, 0x6A), // green (same as string)
    .git_mod = rgb(0xE0, 0xAF, 0x68), // yellow (same as diag_warn)
    .git_del = rgb(0xF7, 0x76, 0x8E), // red (same as builtin)
};

/// catppuccin-frappe — same slot mapping as catppuccin-macchiato.
/// Source: catppuccin/lua/catppuccin/palettes/frappe.lua.
const catppuccin_frappe = Theme{
    .name = "catppuccin-frappe",
    .bg = rgb(0x30, 0x34, 0x46), // base
    .bg_alt = rgb(0x2C, 0x30, 0x41), // between base and mantle
    .bg_float = rgb(0x23, 0x26, 0x34), // crust
    .bg_status = rgb(0x29, 0x2C, 0x3C), // mantle
    .bg_sel = rgb(0x62, 0x68, 0x80), // surface2
    .bg_curline = rgb(0x29, 0x2C, 0x3C), // mantle
    .fg = rgb(0xC6, 0xD0, 0xF5), // text
    .fg_dim = rgb(0x83, 0x8B, 0xA7), // overlay1
    .fg_faint = rgb(0x62, 0x68, 0x80), // surface2
    .accent = rgb(0xF2, 0xD5, 0xCF), // rosewater
    .accent_alt = rgb(0x8C, 0xAA, 0xEE), // blue
    .win_sep = rgb(0x62, 0x68, 0x80), // surface2 (same as fg_faint)
    .win_sep_active = rgb(0xF2, 0xD5, 0xCF), // rosewater (accent)
    .comment = rgb(0x83, 0x8B, 0xA7), // overlay1
    .keyword = rgb(0xCA, 0x9E, 0xE6), // mauve
    .string = rgb(0xA6, 0xD1, 0x89), // green
    .number = rgb(0xEF, 0x9F, 0x76), // peach
    .function = rgb(0x8C, 0xAA, 0xEE), // blue
    .type = rgb(0x81, 0xC8, 0xBE), // teal
    .operator = rgb(0xC6, 0xD0, 0xF5), // text
    .punctuation = rgb(0xB5, 0xBF, 0xE2), // subtext1
    .variable = rgb(0xC6, 0xD0, 0xF5), // text
    .parameter = rgb(0xBA, 0xBB, 0xF1), // lavender
    .property = rgb(0x8C, 0xAA, 0xEE), // blue
    .constant = rgb(0xEF, 0x9F, 0x76), // peach
    .boolean = rgb(0xEF, 0x9F, 0x76), // peach
    .character = rgb(0xA6, 0xD1, 0x89), // green
    .namespace = rgb(0x8C, 0xAA, 0xEE), // blue
    .constructor = rgb(0x8C, 0xAA, 0xEE), // blue
    .builtin = rgb(0xE7, 0x82, 0x84), // red
    .attribute = rgb(0xEF, 0x9F, 0x76), // peach
    .label = rgb(0x81, 0xC8, 0xBE), // teal
    .tag = rgb(0x8C, 0xAA, 0xEE), // blue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = overlay0 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x73, 0x79, 0x94),
    },
    .diag_error = rgb(0xE7, 0x82, 0x84), // red
    .diag_warn = rgb(0xE5, 0xC8, 0x90), // yellow
    .diag_info = rgb(0x8C, 0xAA, 0xEE), // blue
    .git_add = rgb(0xA6, 0xD1, 0x89), // green (same as string)
    .git_mod = rgb(0xE5, 0xC8, 0x90), // yellow (same as diag_warn)
    .git_del = rgb(0xE7, 0x82, 0x84), // red (same as builtin)
};

/// catppuccin-mocha — the darkest catppuccin flavor.
/// Source: catppuccin/lua/catppuccin/palettes/mocha.lua.
const catppuccin_mocha = Theme{
    .name = "catppuccin-mocha",
    .bg = rgb(0x1E, 0x1E, 0x2E), // base
    .bg_alt = rgb(0x1B, 0x1B, 0x29), // between base and mantle
    .bg_float = rgb(0x11, 0x11, 0x1B), // crust
    .bg_status = rgb(0x18, 0x18, 0x25), // mantle
    .bg_sel = rgb(0x58, 0x5B, 0x70), // surface2
    .bg_curline = rgb(0x18, 0x18, 0x25), // mantle
    .fg = rgb(0xCD, 0xD6, 0xF4), // text
    .fg_dim = rgb(0x7F, 0x84, 0x9C), // overlay1
    .fg_faint = rgb(0x58, 0x5B, 0x70), // surface2
    .accent = rgb(0xF5, 0xE0, 0xDC), // rosewater
    .accent_alt = rgb(0x89, 0xB4, 0xFA), // blue
    .win_sep = rgb(0x58, 0x5B, 0x70), // surface2 (same as fg_faint)
    .win_sep_active = rgb(0xF5, 0xE0, 0xDC), // rosewater (accent)
    .comment = rgb(0x7F, 0x84, 0x9C), // overlay1
    .keyword = rgb(0xCB, 0xA6, 0xF7), // mauve
    .string = rgb(0xA6, 0xE3, 0xA1), // green
    .number = rgb(0xFA, 0xB3, 0x87), // peach
    .function = rgb(0x89, 0xB4, 0xFA), // blue
    .type = rgb(0x94, 0xE2, 0xD5), // teal
    .operator = rgb(0xCD, 0xD6, 0xF4), // text
    .punctuation = rgb(0xBA, 0xC2, 0xDE), // subtext1
    .variable = rgb(0xCD, 0xD6, 0xF4), // text
    .parameter = rgb(0xB4, 0xBE, 0xFE), // lavender
    .property = rgb(0x89, 0xB4, 0xFA), // blue
    .constant = rgb(0xFA, 0xB3, 0x87), // peach
    .boolean = rgb(0xFA, 0xB3, 0x87), // peach
    .character = rgb(0xA6, 0xE3, 0xA1), // green
    .namespace = rgb(0x89, 0xB4, 0xFA), // blue
    .constructor = rgb(0x89, 0xB4, 0xFA), // blue
    .builtin = rgb(0xF3, 0x8B, 0xA8), // red
    .attribute = rgb(0xFA, 0xB3, 0x87), // peach
    .label = rgb(0x94, 0xE2, 0xD5), // teal
    .tag = rgb(0x89, 0xB4, 0xFA), // blue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = overlay0 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x6C, 0x70, 0x86),
    },
    .diag_error = rgb(0xF3, 0x8B, 0xA8), // red
    .diag_warn = rgb(0xF9, 0xE2, 0xAF), // yellow
    .diag_info = rgb(0x89, 0xB4, 0xFA), // blue
    .git_add = rgb(0xA6, 0xE3, 0xA1), // green (same as string)
    .git_mod = rgb(0xF9, 0xE2, 0xAF), // yellow (same as diag_warn)
    .git_del = rgb(0xF3, 0x8B, 0xA8), // red (same as builtin)
};

/// catppuccin-latte — the light catppuccin flavor.
/// Source: catppuccin/lua/catppuccin/palettes/latte.lua.
const catppuccin_latte = Theme{
    .name = "catppuccin-latte",
    .bg = rgb(0xEF, 0xF1, 0xF5), // base
    .bg_alt = rgb(0xEA, 0xED, 0xF2), // between base and mantle
    .bg_float = rgb(0xDC, 0xE0, 0xE8), // crust
    .bg_status = rgb(0xE6, 0xE9, 0xEF), // mantle
    .bg_sel = rgb(0xAC, 0xB0, 0xBE), // surface2
    .bg_curline = rgb(0xE6, 0xE9, 0xEF), // mantle
    .fg = rgb(0x4C, 0x4F, 0x69), // text
    .fg_dim = rgb(0x8C, 0x8F, 0xA1), // overlay1
    .fg_faint = rgb(0xAC, 0xB0, 0xBE), // surface2
    .accent = rgb(0xDC, 0x8A, 0x78), // rosewater
    .accent_alt = rgb(0x1E, 0x66, 0xF5), // blue
    .win_sep = rgb(0xAC, 0xB0, 0xBE), // surface2 (same as fg_faint)
    .win_sep_active = rgb(0xDC, 0x8A, 0x78), // rosewater (accent)
    .comment = rgb(0x8C, 0x8F, 0xA1), // overlay1
    .keyword = rgb(0x88, 0x39, 0xEF), // mauve
    .string = rgb(0x40, 0xA0, 0x2B), // green
    .number = rgb(0xFE, 0x64, 0x0B), // peach
    .function = rgb(0x1E, 0x66, 0xF5), // blue
    .type = rgb(0x17, 0x92, 0x99), // teal
    .operator = rgb(0x4C, 0x4F, 0x69), // text
    .punctuation = rgb(0x5C, 0x5F, 0x77), // subtext1
    .variable = rgb(0x4C, 0x4F, 0x69), // text
    .parameter = rgb(0x72, 0x87, 0xFD), // lavender
    .property = rgb(0x1E, 0x66, 0xF5), // blue
    .constant = rgb(0xFE, 0x64, 0x0B), // peach
    .boolean = rgb(0xFE, 0x64, 0x0B), // peach
    .character = rgb(0x40, 0xA0, 0x2B), // green
    .namespace = rgb(0x1E, 0x66, 0xF5), // blue
    .constructor = rgb(0x1E, 0x66, 0xF5), // blue
    .builtin = rgb(0xD2, 0x0F, 0x39), // red
    .attribute = rgb(0xFE, 0x64, 0x0B), // peach
    .label = rgb(0x17, 0x92, 0x99), // teal
    .tag = rgb(0x1E, 0x66, 0xF5), // blue
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = overlay0 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x9C, 0xA0, 0xB0),
    },
    .diag_error = rgb(0xD2, 0x0F, 0x39), // red
    .diag_warn = rgb(0xDF, 0x8E, 0x1D), // yellow
    .diag_info = rgb(0x1E, 0x66, 0xF5), // blue
    .git_add = rgb(0x40, 0xA0, 0x2B), // green (same as string)
    .git_mod = rgb(0xDF, 0x8E, 0x1D), // yellow (same as diag_warn)
    .git_del = rgb(0xD2, 0x0F, 0x39), // red (same as builtin)
};

/// onedark (navarasu/onedark.nvim, default dark style).
/// Source: onedark.nvim palette.lua (dark) + highlights.lua.
const onedark = Theme{
    .name = "onedark",
    .bg = rgb(0x28, 0x2C, 0x34), // bg0
    .bg_alt = rgb(0x2C, 0x30, 0x39), // between bg0 and bg1
    .bg_float = rgb(0x31, 0x35, 0x3F), // bg1 (NormalFloat/Pmenu)
    .bg_status = rgb(0x39, 0x3F, 0x4A), // bg2 (StatusLine)
    .bg_sel = rgb(0x3B, 0x3F, 0x4C), // bg3 (Visual)
    .bg_curline = rgb(0x31, 0x35, 0x3F), // bg1 (CursorLine)
    .fg = rgb(0xAB, 0xB2, 0xBF), // fg
    .fg_dim = rgb(0x5C, 0x63, 0x70), // grey (comment)
    .fg_faint = rgb(0x4A, 0x51, 0x5D), // between bg2 and grey
    .accent = rgb(0xE5, 0xC0, 0x7B), // yellow
    .accent_alt = rgb(0x61, 0xAF, 0xEF), // blue
    .win_sep = rgb(0x4A, 0x51, 0x5D), // same as fg_faint
    .win_sep_active = rgb(0xE5, 0xC0, 0x7B), // yellow (accent)
    .comment = rgb(0x5C, 0x63, 0x70), // grey
    .keyword = rgb(0xC6, 0x78, 0xDD), // purple
    .string = rgb(0x98, 0xC3, 0x79), // green
    .number = rgb(0xD1, 0x9A, 0x66), // orange
    .function = rgb(0x61, 0xAF, 0xEF), // blue
    .type = rgb(0xE5, 0xC0, 0x7B), // yellow
    .operator = rgb(0xAB, 0xB2, 0xBF), // fg (@operator)
    .punctuation = rgb(0x84, 0x8B, 0x98), // light_grey (Delimiter)
    .variable = rgb(0xAB, 0xB2, 0xBF), // fg (@variable)
    .parameter = rgb(0xE8, 0x66, 0x71), // red (@variable.parameter)
    .property = rgb(0x56, 0xB6, 0xC2), // cyan (@property/@variable.member)
    .constant = rgb(0x56, 0xB6, 0xC2), // cyan (Constant)
    .boolean = rgb(0xD1, 0x9A, 0x66), // orange (Boolean)
    .character = rgb(0xD1, 0x9A, 0x66), // orange (Character)
    .namespace = rgb(0xE5, 0xC0, 0x7B), // yellow (@module)
    .constructor = rgb(0xE5, 0xC0, 0x7B), // yellow (@constructor)
    .builtin = rgb(0x56, 0xB6, 0xC2), // cyan (@function.builtin)
    .attribute = rgb(0x56, 0xB6, 0xC2), // cyan (@attribute)
    .label = rgb(0xE8, 0x66, 0x71), // red (@label)
    .tag = rgb(0xC6, 0x78, 0xDD), // purple (@tag)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = grey loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x5C, 0x63, 0x70),
    },
    .diag_error = rgb(0xE8, 0x66, 0x71), // red
    .diag_warn = rgb(0xE5, 0xC0, 0x7B), // yellow
    .diag_info = rgb(0x61, 0xAF, 0xEF), // blue
    .git_add = rgb(0x98, 0xC3, 0x79), // green (same as string)
    .git_mod = rgb(0xE5, 0xC0, 0x7B), // yellow (same as diag_warn)
    .git_del = rgb(0xE8, 0x66, 0x71), // red (same as diag_error)
};

/// melange (dark) — warm, muted palette.
/// Source: melange-nvim palettes/dark.lua + colors/melange.lua.
const melange = Theme{
    .name = "melange",
    .bg = rgb(0x29, 0x25, 0x22), // a.bg
    .bg_alt = rgb(0x2E, 0x2A, 0x27), // between a.bg and a.float
    .bg_float = rgb(0x34, 0x30, 0x2C), // a.float (NormalFloat)
    .bg_status = rgb(0x34, 0x30, 0x2C), // a.float (StatusLine → NormalFloat)
    .bg_sel = rgb(0x40, 0x3A, 0x36), // a.sel (Visual)
    .bg_curline = rgb(0x34, 0x30, 0x2C), // a.float (CursorLine → ColorColumn)
    .fg = rgb(0xEC, 0xE1, 0xD7), // a.fg
    .fg_dim = rgb(0xC1, 0xA7, 0x8E), // a.com (comment)
    .fg_faint = rgb(0x86, 0x74, 0x62), // a.ui
    .accent = rgb(0xEB, 0xC0, 0x6D), // b.yellow
    .accent_alt = rgb(0xA3, 0xA9, 0xCE), // b.blue
    .win_sep = rgb(0x86, 0x74, 0x62), // a.ui (same as fg_faint; WinSeparator)
    .win_sep_active = rgb(0xEB, 0xC0, 0x6D), // b.yellow (accent)
    .comment = rgb(0xC1, 0xA7, 0x8E), // a.com
    .keyword = rgb(0xE4, 0x9B, 0x5D), // c.yellow (Statement)
    .string = rgb(0xA3, 0xA9, 0xCE), // b.blue
    .number = rgb(0xCF, 0x9B, 0xC2), // b.magenta
    .function = rgb(0xEB, 0xC0, 0x6D), // b.yellow
    .type = rgb(0x7B, 0x96, 0x95), // c.cyan
    .operator = rgb(0xD4, 0x77, 0x66), // b.red
    .punctuation = rgb(0x8B, 0x74, 0x49), // d.yellow (Delimiter)
    .variable = rgb(0xEC, 0xE1, 0xD7), // a.fg (@variable → Identifier)
    .parameter = rgb(0xEC, 0xE1, 0xD7), // a.fg (@variable.parameter unset)
    .property = rgb(0xEC, 0xE1, 0xD7), // a.fg (@property unset → Identifier)
    .constant = rgb(0xB3, 0x80, 0xB0), // c.magenta (Constant)
    .boolean = rgb(0xCF, 0x9B, 0xC2), // b.magenta (Boolean → Number)
    .character = rgb(0x7F, 0x91, 0xB2), // c.blue (Character)
    .namespace = rgb(0xEC, 0xE1, 0xD7), // a.fg (@module → Identifier)
    .constructor = rgb(0xEB, 0xC0, 0x6D), // b.yellow (@constructor → @function)
    .builtin = rgb(0xEB, 0xC0, 0x6D), // b.yellow (@function.builtin → @function)
    .attribute = rgb(0xEC, 0xE1, 0xD7), // a.fg (@attribute unset)
    .label = rgb(0x89, 0xB3, 0xB6), // b.cyan (@label)
    .tag = rgb(0xEC, 0xE1, 0xD7), // a.fg (Tag unset)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = a.ui loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x86, 0x74, 0x62),
    },
    .diag_error = rgb(0xBD, 0x81, 0x83), // c.red
    .diag_warn = rgb(0xEB, 0xC0, 0x6D), // b.yellow
    .diag_info = rgb(0x7F, 0x91, 0xB2), // c.blue
    .git_add = rgb(0x78, 0x99, 0x7A), // c.green (GitSignsAdd)
    .git_mod = rgb(0xB3, 0x80, 0xB0), // c.magenta (GitSignsChange — melange's own)
    .git_del = rgb(0xBD, 0x81, 0x83), // c.red (GitSignsDelete)
};

/// doom-one — the Doom Emacs inspired theme.
/// Source: doom-one.nvim lua/doom-one/colors.lua (dark) + init.lua.
const doom_one = Theme{
    .name = "doom-one",
    .bg = rgb(0x28, 0x2C, 0x34), // bg
    .bg_alt = rgb(0x25, 0x29, 0x31), // between bg and base3
    .bg_float = rgb(0x21, 0x24, 0x2B), // bg_alt (Pmenu)
    .bg_status = rgb(0x23, 0x27, 0x2E), // base3 (StatusLine)
    .bg_sel = rgb(0x22, 0x57, 0xA0), // dark_blue (Visual)
    .bg_curline = rgb(0x21, 0x24, 0x2B), // bg_alt (CursorLine)
    .fg = rgb(0xBB, 0xC2, 0xCF), // fg
    .fg_dim = rgb(0x5B, 0x62, 0x68), // base5 (comment)
    .fg_faint = rgb(0x3F, 0x44, 0x4A), // base4
    .accent = rgb(0x51, 0xAF, 0xEF), // blue
    .accent_alt = rgb(0x46, 0xD9, 0xFF), // cyan
    .win_sep = rgb(0x3F, 0x44, 0x4A), // base4 (same as fg_faint)
    .win_sep_active = rgb(0x51, 0xAF, 0xEF), // blue (accent)
    .comment = rgb(0x5B, 0x62, 0x68), // base5
    .keyword = rgb(0x51, 0xAF, 0xEF), // blue
    .string = rgb(0x98, 0xBE, 0x65), // green
    .number = rgb(0xDA, 0x85, 0x48), // orange
    .function = rgb(0xC6, 0x78, 0xDD), // magenta
    .type = rgb(0xEC, 0xBE, 0x7B), // yellow
    .operator = rgb(0x51, 0xAF, 0xEF), // blue
    .punctuation = rgb(0x51, 0xAF, 0xEF), // blue (Delimiter)
    .variable = rgb(0xBB, 0xC2, 0xCF), // fg (@variable → None)
    .parameter = rgb(0xA9, 0xA1, 0xE1), // violet (LspSignatureActiveParameter)
    .property = rgb(0xC6, 0x78, 0xDD), // magenta (Property)
    .constant = rgb(0xA9, 0xA1, 0xE1), // violet (Constant)
    .boolean = rgb(0xDA, 0x85, 0x48), // orange (Boolean)
    .character = rgb(0xA9, 0xA1, 0xE1), // violet (Character)
    .namespace = rgb(0xA9, 0xA1, 0xE1), // violet (@namespace → Directory)
    .constructor = rgb(0x51, 0xAF, 0xEF), // blue (@constructor → Structure)
    .builtin = rgb(0xDD, 0xAE, 0xEB), // magenta lightened 0.4 (FunctionBuiltin)
    .attribute = rgb(0xA9, 0xA1, 0xE1), // violet (PreProc)
    .label = rgb(0x51, 0xAF, 0xEF), // blue (Label)
    .tag = rgb(0x4C, 0xC4, 0xF7), // mix(blue, cyan, 0.5) (Tag)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = base5 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x5B, 0x62, 0x68),
    },
    .diag_error = rgb(0xFF, 0x6C, 0x6B), // red
    .diag_warn = rgb(0xEC, 0xBE, 0x7B), // yellow
    .diag_info = rgb(0x51, 0xAF, 0xEF), // blue
    .git_add = rgb(0x98, 0xBE, 0x65), // green (same as string)
    .git_mod = rgb(0xEC, 0xBE, 0x7B), // yellow (same as diag_warn)
    .git_del = rgb(0xFF, 0x6C, 0x6B), // red (same as diag_error)
};

/// sonokai-shusia — sonokai's monokai-pro-style variant.
/// Source: sonokai/autoload/sonokai.vim (shusia palette) + colors/sonokai.vim.
const sonokai_shusia = Theme{
    .name = "sonokai-shusia",
    .bg = rgb(0x2D, 0x2A, 0x2E), // bg0
    .bg_alt = rgb(0x32, 0x2F, 0x34), // between bg0 and bg1
    .bg_float = rgb(0x3B, 0x38, 0x3E), // bg2 (Pmenu)
    .bg_status = rgb(0x42, 0x3F, 0x46), // bg3 (StatusLine)
    .bg_sel = rgb(0x49, 0x46, 0x4E), // bg4 (Visual)
    .bg_curline = rgb(0x37, 0x34, 0x3A), // bg1 (CursorLine)
    .fg = rgb(0xE3, 0xE1, 0xE4), // fg
    .fg_dim = rgb(0x84, 0x80, 0x89), // grey (comment)
    .fg_faint = rgb(0x60, 0x5D, 0x68), // grey_dim
    .accent = rgb(0xF8, 0x5E, 0x84), // red
    .accent_alt = rgb(0x7A, 0xCC, 0xD7), // blue
    .win_sep = rgb(0x60, 0x5D, 0x68), // grey_dim (same as fg_faint)
    .win_sep_active = rgb(0xF8, 0x5E, 0x84), // red (accent)
    .comment = rgb(0x84, 0x80, 0x89), // grey
    .keyword = rgb(0xF8, 0x5E, 0x84), // red
    .string = rgb(0xE5, 0xC4, 0x63), // yellow
    .number = rgb(0xAB, 0x9D, 0xF2), // purple
    .function = rgb(0x9E, 0xCD, 0x6F), // green
    .type = rgb(0x7A, 0xCC, 0xD7), // blue
    .operator = rgb(0xF8, 0x5E, 0x84), // red
    .punctuation = rgb(0xE3, 0xE1, 0xE4), // fg (Delimiter)
    .variable = rgb(0xE3, 0xE1, 0xE4), // fg (TSVariable)
    .parameter = rgb(0xE3, 0xE1, 0xE4), // fg (TSParameter)
    .property = rgb(0xEF, 0x90, 0x62), // orange (TSProperty)
    .constant = rgb(0xEF, 0x90, 0x62), // orange (Constant)
    .boolean = rgb(0xAB, 0x9D, 0xF2), // purple (Boolean)
    .character = rgb(0xE5, 0xC4, 0x63), // yellow (Character)
    .namespace = rgb(0x7A, 0xCC, 0xD7), // blue (TSNamespace BlueItalic)
    .constructor = rgb(0x9E, 0xCD, 0x6F), // green (TSConstructor)
    .builtin = rgb(0xAB, 0x9D, 0xF2), // purple (TSVariableBuiltin)
    .attribute = rgb(0x7A, 0xCC, 0xD7), // blue (TSAttribute)
    .label = rgb(0xAB, 0x9D, 0xF2), // purple (Label)
    .tag = rgb(0xEF, 0x90, 0x62), // orange (Tag)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = grey loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x84, 0x80, 0x89),
    },
    .diag_error = rgb(0xF8, 0x5E, 0x84), // red
    .diag_warn = rgb(0xE5, 0xC4, 0x63), // yellow
    .diag_info = rgb(0x7A, 0xCC, 0xD7), // blue
    .git_add = rgb(0x9E, 0xCD, 0x6F), // green (same as function)
    .git_mod = rgb(0xE5, 0xC4, 0x63), // yellow (same as diag_warn)
    .git_del = rgb(0xF8, 0x5E, 0x84), // red (same as keyword)
};

/// flexoki-dark — Steph Ango's inky, paper-adjacent dark palette.
/// Source: flexoki/vim/flexoki_dark.vim (s:base + s:variants.dark).
const flexoki_dark = Theme{
    .name = "flexoki-dark",
    .bg = rgb(0x10, 0x0F, 0x0F), // black (bg)
    .bg_alt = rgb(0x16, 0x15, 0x14), // between black and 950
    .bg_float = rgb(0x1C, 0x1B, 0x1A), // 950 (bg_2)
    .bg_status = rgb(0x28, 0x27, 0x26), // 900 (ui)
    .bg_sel = rgb(0x34, 0x33, 0x31), // 850 (ui_2, Visual)
    .bg_curline = rgb(0x28, 0x27, 0x26), // 900 (ui, CursorLine)
    .fg = rgb(0xCE, 0xCD, 0xC3), // 200 (tx)
    .fg_dim = rgb(0x87, 0x85, 0x80), // 500 (tx_2)
    .fg_faint = rgb(0x57, 0x56, 0x53), // 700 (tx_3)
    .accent = rgb(0xD0, 0xA2, 0x15), // yellow-400 (ye)
    .accent_alt = rgb(0x43, 0x85, 0xBE), // blue-400 (bl)
    .win_sep = rgb(0x57, 0x56, 0x53), // 700 (same as fg_faint)
    .win_sep_active = rgb(0xD0, 0xA2, 0x15), // yellow-400 (accent)
    .comment = rgb(0x57, 0x56, 0x53), // 700 (tx_3)
    .keyword = rgb(0x87, 0x9A, 0x39), // green-400 (gr)
    .string = rgb(0x3A, 0xA9, 0x9F), // cyan-400 (cy)
    .number = rgb(0x8B, 0x7E, 0xC8), // purple-400 (pu)
    .function = rgb(0xDA, 0x70, 0x2C), // orange-400 (or)
    .type = rgb(0x87, 0x9A, 0x39), // green-400 (Type → Keyword)
    .operator = rgb(0x87, 0x85, 0x80), // 500 (tx_2, Operator)
    .punctuation = rgb(0x87, 0x85, 0x80), // 500 (tx_2, Delimiter)
    .variable = rgb(0xCE, 0xCD, 0xC3), // 200 (tx)
    .parameter = rgb(0xCE, 0xCD, 0xC3), // 200 (tx)
    .property = rgb(0x43, 0x85, 0xBE), // blue-400 (Identifier)
    .constant = rgb(0xD0, 0xA2, 0x15), // yellow-400 (Constant)
    .boolean = rgb(0xCE, 0x5D, 0x97), // magenta-400 (Boolean)
    .character = rgb(0x3A, 0xA9, 0x9F), // cyan-400 (Character → String)
    .namespace = rgb(0x43, 0x85, 0xBE), // blue-400 (Identifier)
    .constructor = rgb(0xDA, 0x70, 0x2C), // orange-400 (Function)
    .builtin = rgb(0xCE, 0x5D, 0x97), // magenta-400 (PreProc)
    .attribute = rgb(0xCE, 0x5D, 0x97), // magenta-400 (PreProc)
    .label = rgb(0x87, 0x9A, 0x39), // green-400 (Label → Keyword)
    .tag = rgb(0x3A, 0xA9, 0x9F), // cyan-400 (Tag)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = tx_3 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0x57, 0x56, 0x53),
    },
    .diag_error = rgb(0xD1, 0x4D, 0x41), // red-400 (re)
    .diag_warn = rgb(0xD0, 0xA2, 0x15), // yellow-400 (ye)
    .diag_info = rgb(0x3A, 0xA9, 0x9F), // cyan-400 (DiagnosticInfo)
    .git_add = rgb(0x87, 0x9A, 0x39), // green-400 (gr)
    .git_mod = rgb(0xD0, 0xA2, 0x15), // yellow-400 (ye)
    .git_del = rgb(0xD1, 0x4D, 0x41), // red-400 (re)
};

/// flexoki-light — paper background variant (accent colors use the -600 ramp).
/// Source: flexoki/vim/flexoki_light.vim (s:base + s:variants.light).
const flexoki_light = Theme{
    .name = "flexoki-light",
    .bg = rgb(0xFF, 0xFC, 0xF0), // paper (bg)
    .bg_alt = rgb(0xF8, 0xF6, 0xEA), // between paper and 50
    .bg_float = rgb(0xF2, 0xF0, 0xE5), // 50 (bg_2)
    .bg_status = rgb(0xE6, 0xE4, 0xD9), // 100 (ui)
    .bg_sel = rgb(0xDA, 0xD8, 0xCE), // 150 (ui_2, Visual)
    .bg_curline = rgb(0xE6, 0xE4, 0xD9), // 100 (ui, CursorLine)
    .fg = rgb(0x10, 0x0F, 0x0F), // black (tx)
    .fg_dim = rgb(0x6F, 0x6E, 0x69), // 600 (tx_2)
    .fg_faint = rgb(0xB7, 0xB5, 0xAC), // 300 (tx_3)
    .accent = rgb(0xAD, 0x83, 0x01), // yellow-600 (ye)
    .accent_alt = rgb(0x20, 0x5E, 0xA6), // blue-600 (bl)
    .win_sep = rgb(0xB7, 0xB5, 0xAC), // 300 (same as fg_faint)
    .win_sep_active = rgb(0xAD, 0x83, 0x01), // yellow-600 (accent)
    .comment = rgb(0xB7, 0xB5, 0xAC), // 300 (tx_3)
    .keyword = rgb(0x66, 0x80, 0x0B), // green-600 (gr)
    .string = rgb(0x24, 0x83, 0x7B), // cyan-600 (cy)
    .number = rgb(0x5E, 0x40, 0x9D), // purple-600 (pu)
    .function = rgb(0xBC, 0x52, 0x15), // orange-600 (or)
    .type = rgb(0x66, 0x80, 0x0B), // green-600 (Type → Keyword)
    .operator = rgb(0x6F, 0x6E, 0x69), // 600 (tx_2, Operator)
    .punctuation = rgb(0x6F, 0x6E, 0x69), // 600 (tx_2, Delimiter)
    .variable = rgb(0x10, 0x0F, 0x0F), // black (tx)
    .parameter = rgb(0x10, 0x0F, 0x0F), // black (tx)
    .property = rgb(0x20, 0x5E, 0xA6), // blue-600 (Identifier)
    .constant = rgb(0xAD, 0x83, 0x01), // yellow-600 (Constant)
    .boolean = rgb(0xA0, 0x2F, 0x6F), // magenta-600 (Boolean)
    .character = rgb(0x24, 0x83, 0x7B), // cyan-600 (Character → String)
    .namespace = rgb(0x20, 0x5E, 0xA6), // blue-600 (Identifier)
    .constructor = rgb(0xBC, 0x52, 0x15), // orange-600 (Function)
    .builtin = rgb(0xA0, 0x2F, 0x6F), // magenta-600 (PreProc)
    .attribute = rgb(0xA0, 0x2F, 0x6F), // magenta-600 (PreProc)
    .label = rgb(0x66, 0x80, 0x0B), // green-600 (Label → Keyword)
    .tag = rgb(0x24, 0x83, 0x7B), // cyan-600 (Tag)
    .rainbow = onedark_rainbow,
    // indent[0..6] = rainbow ramp; indent[7] = tx_3 loop-back
    .indent = .{
        onedark_rainbow[0], onedark_rainbow[1], onedark_rainbow[2], onedark_rainbow[3],
        onedark_rainbow[4], onedark_rainbow[5], onedark_rainbow[6], rgb(0xB7, 0xB5, 0xAC),
    },
    .diag_error = rgb(0xAF, 0x30, 0x29), // red-600 (re)
    .diag_warn = rgb(0xAD, 0x83, 0x01), // yellow-600 (ye)
    .diag_info = rgb(0x24, 0x83, 0x7B), // cyan-600 (DiagnosticInfo)
    .git_add = rgb(0x66, 0x80, 0x0B), // green-600 (gr)
    .git_mod = rgb(0xAD, 0x83, 0x01), // yellow-600 (ye)
    .git_del = rgb(0xAF, 0x30, 0x29), // red-600 (re)
};

pub const themes = [_]Theme{
    kanagawa_wave,
    catppuccin_macchiato,
    tokyonight_moon,
    kanagawa_dragon,
    everforest,
    tokyonight_night,
    tokyonight_storm,
    catppuccin_frappe,
    catppuccin_mocha,
    catppuccin_latte,
    onedark,
    melange,
    doom_one,
    sonokai_shusia,
    flexoki_dark,
    flexoki_light,
};

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

/// ANSI 16-color palette for the embedded terminal, derived from the theme slots. Classic ANSI escape
/// colors (index 0-15) map onto theme-derived RGB so the embedded terminal pane follows the active
/// theme instead of leaking the host terminal's palette.
pub fn ansi16(t: Theme) [16]Rgb {
    return .{
        // normal
        t.bg_alt, // 0 black — slightly raised dark surface so black text stays visible on bg
        t.diag_error, // 1 red
        t.git_add, // 2 green
        t.diag_warn, // 3 yellow
        t.accent_alt, // 4 blue
        t.keyword, // 5 magenta
        t.type, // 6 cyan
        t.fg, // 7 white
        // bright
        t.fg_dim, // 8 bright black
        t.builtin, // 9 bright red
        t.string, // 10 bright green
        t.accent, // 11 bright yellow
        t.function, // 12 bright blue
        t.keyword, // 13 bright magenta
        t.constructor, // 14 bright cyan
        t.fg, // 15 bright white
    };
}
