//! File-type icons for oz — an nvim-web-devicons equivalent.
//!
//! Maps a file's basename / extension to a Nerd Font glyph plus a semantic
//! color slot (the renderer resolves the slot through theme.Theme, so icons
//! adapt to the active colorscheme). Only depends on theme.zig.
//!
//! Glyph provenance: every codepoint below was taken from the nvim-web-devicons
//! `icons-default.lua` tables (the reference implementation this mirrors) and
//! cross-checked against the Nerd Fonts v3.5 glyph map (bin/scripts/lib/i_*.sh),
//! so each one is confirmed to exist in the current Nerd Font release. All are
//! single-cell private-use-area glyphs, the same range the completion menu and
//! diagnostic gutter already render. Codepoints are written as \u{...} escapes
//! with a comment naming the Nerd Font set/glyph for auditability.

const std = @import("std");
const theme = @import("theme.zig");

/// Semantic color slots an icon can use; resolved to concrete RGB via
/// `rgbOf` with the active theme.
pub const Color = enum {
    keyword,
    string,
    number,
    function,
    type,
    operator,
    punctuation,
    variable,
    parameter,
    property,
    constant,
    boolean,
    character,
    namespace,
    constructor,
    builtin,
    attribute,
    label,
    tag,
    comment,
    accent,
    accent_alt,
    fg,
    fg_dim,
    fg_faint,
    diag_error,
    diag_warn,
    diag_info,
};

/// Map a semantic slot to the matching field of a concrete theme.
pub fn rgbOf(t: theme.Theme, c: Color) theme.Rgb {
    return switch (c) {
        .keyword => t.keyword,
        .string => t.string,
        .number => t.number,
        .function => t.function,
        .type => t.type,
        .operator => t.operator,
        .punctuation => t.punctuation,
        .variable => t.variable,
        .parameter => t.parameter,
        .property => t.property,
        .constant => t.constant,
        .boolean => t.boolean,
        .character => t.character,
        .namespace => t.namespace,
        .constructor => t.constructor,
        .builtin => t.builtin,
        .attribute => t.attribute,
        .label => t.label,
        .tag => t.tag,
        .comment => t.comment,
        .accent => t.accent,
        .accent_alt => t.accent_alt,
        .fg => t.fg,
        .fg_dim => t.fg_dim,
        .fg_faint => t.fg_faint,
        .diag_error => t.diag_error,
        .diag_warn => t.diag_warn,
        .diag_info => t.diag_info,
    };
}

/// A Nerd Font glyph (UTF-8, one terminal cell) plus its semantic color.
pub const Icon = struct {
    glyph: []const u8,
    color: Color,
};

/// Default file icon: nf-fa-file_o (U+F016).
const default_icon = Icon{ .glyph = "\u{f016}", .color = .fg_dim };

/// Folder icons: nf-fa-folder (U+F07B, closed) / nf-fa-folder_open (U+F07C).
/// Closed folders use the blue namespace slot, open folders the brighter
/// accent_alt so expansion state reads at a glance.
pub fn folder(open: bool) Icon {
    return if (open)
        .{ .glyph = "\u{f07c}", .color = .accent_alt }
    else
        .{ .glyph = "\u{f07b}", .color = .namespace };
}

const ExtEntry = struct { ext: []const u8, icon: Icon };
const FileEntry = struct { name: []const u8, icon: Icon };

/// Extension → icon table (keys lowercase; lookup is case-insensitive).
/// Glyph comments name the Nerd Font set entry, e.g. `seti_zig` = i_seti_zig.
const ext_table = [_]ExtEntry{
    // ---- languages ----
    .{ .ext = "zig", .icon = .{ .glyph = "\u{e6a9}", .color = .constant } }, // seti_zig
    .{ .ext = "rs", .icon = .{ .glyph = "\u{e68b}", .color = .operator } }, // seti_rust
    .{ .ext = "go", .icon = .{ .glyph = "\u{e627}", .color = .namespace } }, // seti_go
    .{ .ext = "py", .icon = .{ .glyph = "\u{e606}", .color = .namespace } }, // seti_python
    .{ .ext = "js", .icon = .{ .glyph = "\u{e60c}", .color = .operator } }, // seti_javascript
    .{ .ext = "mjs", .icon = .{ .glyph = "\u{e60c}", .color = .operator } },
    .{ .ext = "cjs", .icon = .{ .glyph = "\u{e60c}", .color = .operator } },
    .{ .ext = "jsx", .icon = .{ .glyph = "\u{e625}", .color = .namespace } }, // seti_react
    .{ .ext = "ts", .icon = .{ .glyph = "\u{e628}", .color = .function } }, // seti_typescript
    .{ .ext = "tsx", .icon = .{ .glyph = "\u{e7ba}", .color = .function } }, // dev_react
    .{ .ext = "json", .icon = .{ .glyph = "\u{e60b}", .color = .constant } }, // seti_json
    .{ .ext = "jsonc", .icon = .{ .glyph = "\u{e60b}", .color = .constant } },
    .{ .ext = "lua", .icon = .{ .glyph = "\u{e620}", .color = .namespace } }, // seti_lua
    .{ .ext = "c", .icon = .{ .glyph = "\u{e61e}", .color = .function } }, // custom_c
    .{ .ext = "h", .icon = .{ .glyph = "\u{f0fd}", .color = .function } }, // fa_square_h
    .{ .ext = "cpp", .icon = .{ .glyph = "\u{e61d}", .color = .builtin } }, // custom_cpp
    .{ .ext = "hpp", .icon = .{ .glyph = "\u{f0fd}", .color = .builtin } },
    .{ .ext = "cc", .icon = .{ .glyph = "\u{e61d}", .color = .builtin } },
    .{ .ext = "hh", .icon = .{ .glyph = "\u{f0fd}", .color = .builtin } },
    .{ .ext = "sh", .icon = .{ .glyph = "\u{e795}", .color = .string } }, // dev_terminal
    .{ .ext = "bash", .icon = .{ .glyph = "\u{e760}", .color = .string } }, // dev_bash
    .{ .ext = "zsh", .icon = .{ .glyph = "\u{e795}", .color = .string } },
    .{ .ext = "fish", .icon = .{ .glyph = "\u{e795}", .color = .string } },
    .{ .ext = "md", .icon = .{ .glyph = "\u{e609}", .color = .type } }, // seti_markdown
    .{ .ext = "markdown", .icon = .{ .glyph = "\u{e609}", .color = .type } },
    .{ .ext = "html", .icon = .{ .glyph = "\u{e736}", .color = .builtin } }, // dev_html5
    .{ .ext = "htm", .icon = .{ .glyph = "\u{e736}", .color = .builtin } },
    .{ .ext = "css", .icon = .{ .glyph = "\u{e6b8}", .color = .function } }, // custom_css
    .{ .ext = "scss", .icon = .{ .glyph = "\u{e603}", .color = .builtin } }, // seti_sass
    .{ .ext = "sass", .icon = .{ .glyph = "\u{e603}", .color = .builtin } },
    .{ .ext = "less", .icon = .{ .glyph = "\u{e614}", .color = .function } }, // seti_css
    .{ .ext = "yaml", .icon = .{ .glyph = "\u{e8eb}", .color = .punctuation } }, // dev_yaml
    .{ .ext = "yml", .icon = .{ .glyph = "\u{e8eb}", .color = .punctuation } },
    .{ .ext = "toml", .icon = .{ .glyph = "\u{e6b2}", .color = .operator } }, // custom_toml
    .{ .ext = "java", .icon = .{ .glyph = "\u{e738}", .color = .builtin } }, // dev_java
    .{ .ext = "kt", .icon = .{ .glyph = "\u{e634}", .color = .operator } }, // custom_kotlin
    .{ .ext = "kts", .icon = .{ .glyph = "\u{e634}", .color = .operator } },
    .{ .ext = "swift", .icon = .{ .glyph = "\u{e755}", .color = .operator } }, // dev_swift
    .{ .ext = "php", .icon = .{ .glyph = "\u{e608}", .color = .keyword } }, // seti_php
    .{ .ext = "rb", .icon = .{ .glyph = "\u{e791}", .color = .diag_error } }, // dev_ruby_rough
    .{ .ext = "sql", .icon = .{ .glyph = "\u{e706}", .color = .keyword } }, // dev_database
    .{ .ext = "vue", .icon = .{ .glyph = "\u{e6a0}", .color = .string } }, // seti_vue
    .{ .ext = "svelte", .icon = .{ .glyph = "\u{e697}", .color = .diag_error } }, // seti_svelte
    .{ .ext = "xml", .icon = .{ .glyph = "\u{f05c0}", .color = .type } }, // md_xml
    .{ .ext = "svg", .icon = .{ .glyph = "\u{f0721}", .color = .type } }, // md_svg
    .{ .ext = "nix", .icon = .{ .glyph = "\u{f313}", .color = .type } }, // linux_nixos
    // ---- config / tooling ----
    .{ .ext = "ini", .icon = .{ .glyph = "\u{e615}", .color = .fg_dim } }, // seti_config (gear)
    .{ .ext = "conf", .icon = .{ .glyph = "\u{e615}", .color = .fg_dim } },
    .{ .ext = "cfg", .icon = .{ .glyph = "\u{e615}", .color = .fg_dim } },
    .{ .ext = "gitignore", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } }, // dev_git
    .{ .ext = "gitattributes", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } },
    .{ .ext = "editorconfig", .icon = .{ .glyph = "\u{e652}", .color = .fg_dim } }, // seti_editorconfig
    .{ .ext = "env", .icon = .{ .glyph = "\u{f462}", .color = .diag_warn } }, // oct_sliders
    .{ .ext = "lock", .icon = .{ .glyph = "\u{e672}", .color = .fg_dim } }, // seti_lock
    .{ .ext = "dockerfile", .icon = .{ .glyph = "\u{f0868}", .color = .operator } }, // md_docker
    // ---- data / binary ----
    .{ .ext = "png", .icon = .{ .glyph = "\u{e60d}", .color = .number } }, // seti_image
    .{ .ext = "jpg", .icon = .{ .glyph = "\u{e60d}", .color = .number } },
    .{ .ext = "jpeg", .icon = .{ .glyph = "\u{e60d}", .color = .number } },
    .{ .ext = "gif", .icon = .{ .glyph = "\u{e60d}", .color = .number } },
    .{ .ext = "webp", .icon = .{ .glyph = "\u{e60d}", .color = .number } },
    .{ .ext = "ico", .icon = .{ .glyph = "\u{e60d}", .color = .number } },
    .{ .ext = "pdf", .icon = .{ .glyph = "\u{eaeb}", .color = .diag_error } }, // cod_file_pdf
    .{ .ext = "txt", .icon = .{ .glyph = "\u{f0219}", .color = .fg_dim } }, // md_file_document
    .{ .ext = "log", .icon = .{ .glyph = "\u{f0331}", .color = .fg_dim } }, // md_library
    // ---- extras (common languages) ----
    .{ .ext = "ex", .icon = .{ .glyph = "\u{e62d}", .color = .keyword } }, // custom_elixir
    .{ .ext = "exs", .icon = .{ .glyph = "\u{e62d}", .color = .keyword } },
    .{ .ext = "erl", .icon = .{ .glyph = "\u{e7b1}", .color = .diag_error } }, // dev_erlang
    .{ .ext = "hs", .icon = .{ .glyph = "\u{e61f}", .color = .keyword } }, // seti_haskell
    .{ .ext = "clj", .icon = .{ .glyph = "\u{e768}", .color = .keyword } }, // dev_clojure
    .{ .ext = "cljs", .icon = .{ .glyph = "\u{e76a}", .color = .keyword } }, // dev_clojure_alt
    .{ .ext = "cs", .icon = .{ .glyph = "\u{f031b}", .color = .builtin } }, // md_language_csharp
    .{ .ext = "dart", .icon = .{ .glyph = "\u{e798}", .color = .function } }, // dev_dart
    .{ .ext = "elm", .icon = .{ .glyph = "\u{e62c}", .color = .function } }, // custom_elm
    .{ .ext = "hx", .icon = .{ .glyph = "\u{e666}", .color = .constant } }, // seti_haxe
    .{ .ext = "ipynb", .icon = .{ .glyph = "\u{e80f}", .color = .number } }, // dev_jupyter
    .{ .ext = "nim", .icon = .{ .glyph = "\u{e677}", .color = .constant } }, // seti_nim
    .{ .ext = "r", .icon = .{ .glyph = "\u{f07d4}", .color = .function } }, // md_language_r
    .{ .ext = "scala", .icon = .{ .glyph = "\u{e737}", .color = .diag_error } }, // dev_scala
    .{ .ext = "sol", .icon = .{ .glyph = "\u{e656}", .color = .function } }, // seti_ethereum
    .{ .ext = "tf", .icon = .{ .glyph = "\u{e69a}", .color = .keyword } }, // seti_terraform
    .{ .ext = "vim", .icon = .{ .glyph = "\u{e62b}", .color = .string } }, // custom_vim
    .{ .ext = "astro", .icon = .{ .glyph = "\u{e6b3}", .color = .builtin } }, // custom_astro
    .{ .ext = "bat", .icon = .{ .glyph = "\u{e615}", .color = .fg_dim } }, // seti_config
    .{ .ext = "gradle", .icon = .{ .glyph = "\u{e660}", .color = .function } }, // seti_gradle
};

/// Exact-filename → icon table (keys lowercase; lookup is case-insensitive).
/// Checked before the extension table, mirroring nvim-web-devicons.
const file_table = [_]FileEntry{
    .{ .name = "makefile", .icon = .{ .glyph = "\u{e779}", .color = .operator } }, // dev_gnu
    .{ .name = "dockerfile", .icon = .{ .glyph = "\u{f0868}", .color = .operator } }, // md_docker
    .{ .name = ".gitignore", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } }, // dev_git
    .{ .name = ".gitattributes", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } },
    .{ .name = ".gitmodules", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } },
    .{ .name = ".gitconfig", .icon = .{ .glyph = "\u{e702}", .color = .diag_error } },
    .{ .name = ".editorconfig", .icon = .{ .glyph = "\u{e652}", .color = .fg_dim } }, // seti_editorconfig
    .{ .name = "license", .icon = .{ .glyph = "\u{e60a}", .color = .fg_dim } }, // seti_license
    .{ .name = "license.md", .icon = .{ .glyph = "\u{e60a}", .color = .fg_dim } },
    .{ .name = "readme", .icon = .{ .glyph = "\u{f00ba}", .color = .accent } }, // md_book
    .{ .name = "readme.md", .icon = .{ .glyph = "\u{f00ba}", .color = .accent } },
    .{ .name = "package.json", .icon = .{ .glyph = "\u{e71e}", .color = .builtin } }, // dev_npm
    .{ .name = "package-lock.json", .icon = .{ .glyph = "\u{e672}", .color = .fg_dim } }, // seti_lock
    .{ .name = "tsconfig.json", .icon = .{ .glyph = "\u{e69d}", .color = .function } }, // seti_tsconfig
    .{ .name = "cargo.toml", .icon = .{ .glyph = "\u{e6b2}", .color = .operator } }, // custom_toml
    .{ .name = "cargo.lock", .icon = .{ .glyph = "\u{e672}", .color = .fg_dim } }, // seti_lock
    .{ .name = "build.zig", .icon = .{ .glyph = "\u{e6a9}", .color = .constant } }, // seti_zig
    .{ .name = "build.zig.zon", .icon = .{ .glyph = "\u{e6a9}", .color = .constant } },
    .{ .name = "go.mod", .icon = .{ .glyph = "\u{e627}", .color = .namespace } }, // seti_go
    .{ .name = "go.sum", .icon = .{ .glyph = "\u{e627}", .color = .namespace } },
    .{ .name = "pyproject.toml", .icon = .{ .glyph = "\u{e6b2}", .color = .operator } }, // custom_toml
    .{ .name = "requirements.txt", .icon = .{ .glyph = "\u{f0219}", .color = .fg_dim } }, // md_file_document
    .{ .name = ".env", .icon = .{ .glyph = "\u{f462}", .color = .diag_warn } }, // oct_sliders
    .{ .name = ".env.example", .icon = .{ .glyph = "\u{f462}", .color = .diag_warn } },
    .{ .name = "cmakelists.txt", .icon = .{ .glyph = "\u{e794}", .color = .operator } }, // dev_cmake
    .{ .name = "compose.yaml", .icon = .{ .glyph = "\u{f0868}", .color = .operator } }, // md_docker
    .{ .name = "compose.yml", .icon = .{ .glyph = "\u{f0868}", .color = .operator } },
    .{ .name = "docker-compose.yaml", .icon = .{ .glyph = "\u{f0868}", .color = .operator } },
    .{ .name = "docker-compose.yml", .icon = .{ .glyph = "\u{f0868}", .color = .operator } },
    .{ .name = ".bashrc", .icon = .{ .glyph = "\u{e760}", .color = .string } }, // dev_bash
    .{ .name = ".bash_profile", .icon = .{ .glyph = "\u{e760}", .color = .string } },
    .{ .name = ".zshrc", .icon = .{ .glyph = "\u{e795}", .color = .string } }, // dev_terminal
};

/// Icon for a file/dir path or basename. Directories always render the closed
/// folder glyph; files match the filename table first (case-insensitive), then
/// the extension table (case-insensitive), then the default file icon.
pub fn forPath(name: []const u8, is_dir: bool) Icon {
    if (is_dir) return folder(false);
    const base = basename(name);
    for (file_table) |entry| {
        if (lowerMatch(base, entry.name)) return entry.icon;
    }
    if (extOf(base)) |ext| {
        for (ext_table) |entry| {
            if (lowerMatch(ext, entry.ext)) return entry.icon;
        }
    }
    return default_icon;
}

/// Trailing path component; accepts both '/' and '\\' separators.
fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

/// Substring after the last '.' in a basename (empty → null). A leading dot
/// (dotfile) is treated as the separator, so ".gitignore" yields "gitignore".
fn extOf(base: []const u8) ?[]const u8 {
    var i = base.len;
    while (i > 0) {
        i -= 1;
        if (base[i] == '.') {
            const ext = base[i + 1 ..];
            return if (ext.len == 0) null else ext;
        }
    }
    return null;
}

/// ASCII case-insensitive equality; non-ASCII bytes compare byte-for-byte.
fn lowerMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "forPath: zig extension maps to the zig glyph with a real color" {
    const icon = forPath("main.zig", false);
    try std.testing.expectEqualStrings("\u{e6a9}", icon.glyph);
    const rgb = rgbOf(theme.default, icon.color);
    try std.testing.expect(rgb[0] != 0 or rgb[1] != 0 or rgb[2] != 0);
}

test "forPath: extension matching is case-insensitive" {
    try std.testing.expectEqualStrings("\u{e68b}", forPath("main.rs", false).glyph);
    try std.testing.expectEqualStrings("\u{e60b}", forPath("x.JSON", false).glyph);
    try std.testing.expectEqualStrings("\u{e60b}", forPath("X.json", false).glyph);
    try std.testing.expectEqualStrings("\u{e606}", forPath("Upper.PY", false).glyph);
}

test "forPath: exact filenames hit the filename table" {
    try std.testing.expectEqualStrings("\u{e779}", forPath("Makefile", false).glyph);
    try std.testing.expectEqualStrings("\u{e702}", forPath(".gitignore", false).glyph);
    try std.testing.expectEqualStrings("\u{f00ba}", forPath("README", false).glyph);
    try std.testing.expectEqualStrings("\u{e6b2}", forPath("Cargo.toml", false).glyph);
    try std.testing.expectEqualStrings("\u{f462}", forPath(".env", false).glyph);
    try std.testing.expectEqualStrings("\u{e6a9}", forPath("build.zig", false).glyph);
    // case-insensitive filename matching too
    try std.testing.expectEqualStrings("\u{e779}", forPath("MAKEFILE", false).glyph);
    try std.testing.expectEqualStrings("\u{f00ba}", forPath("Readme.md", false).glyph);
}

test "forPath: unknown extensions and dotless names fall back to the default file icon" {
    try std.testing.expectEqualStrings("\u{f016}", forPath("unknown.xyz", false).glyph);
    try std.testing.expectEqualStrings("\u{f016}", forPath("noext", false).glyph);
    try std.testing.expectEqualStrings("\u{f016}", forPath("trailing.", false).glyph);
}

test "forPath: full paths are reduced to the basename" {
    try std.testing.expectEqualStrings("\u{e6a9}", forPath("src/main.zig", false).glyph);
    try std.testing.expectEqualStrings("\u{e606}", forPath("/home/user/proj/scripts/util.py", false).glyph);
    try std.testing.expectEqualStrings("\u{e60c}", forPath("src\\components\\App.js", false).glyph);
}

test "forPath: directories use the closed folder; folder(open) differs" {
    try std.testing.expectEqualStrings("\u{f07b}", forPath("node_modules", true).glyph);
    try std.testing.expectEqualStrings("\u{f07b}", forPath("src", true).glyph);
    try std.testing.expectEqualStrings("\u{f07c}", folder(true).glyph);
    try std.testing.expectEqualStrings("\u{f07b}", folder(false).glyph);
    try std.testing.expect(!std.mem.eql(u8, folder(true).glyph, folder(false).glyph));
}

test "rgbOf: spot checks map Color to the matching theme field" {
    try std.testing.expectEqual(theme.default.keyword, rgbOf(theme.default, .keyword));
    try std.testing.expectEqual(theme.default.accent, rgbOf(theme.default, .accent));
    try std.testing.expectEqual(theme.default.diag_error, rgbOf(theme.default, .diag_error));
    try std.testing.expectEqual(theme.default.fg_dim, rgbOf(theme.default, .fg_dim));
    try std.testing.expectEqual(theme.default.namespace, rgbOf(theme.default, .namespace));
    try std.testing.expectEqual(theme.default.builtin, rgbOf(theme.default, .builtin));
}

test "rgbOf: every Color slot resolves to a non-black RGB" {
    inline for (std.enums.values(Color)) |c| {
        const rgb = rgbOf(theme.default, c);
        try std.testing.expect(rgb[0] != 0 or rgb[1] != 0 or rgb[2] != 0);
    }
}
