//! tree-sitter syntax highlighting (DESIGN.md M1).
//!
//! Performance contract (终端编辑器性能调查报告.md §5 — do not violate):
//! the cost of a highlight pass must scale with the VISIBLE region, not the
//! file size. nvim's O(file tokens × decoration systems) model is what made
//! cabac.zig (124 KB, 1475 token-dense lines) crawl. Here we:
//!   1. reparse the whole buffer on edit (incremental via old_tree) — the
//!      parser cost is unavoidable, but it is one pass, no objects;
//!   2. run the highlight QUERY only over the visible byte range
//!      (Query.Cursor.setByteRange) so screen-off tokens never materialize;
//!   3. emit one flat `[]Span` per frame, arena-allocated, no per-token
//!      objects (the "统一装饰管线" model).
//! Big-file degradation: files over `SIZE_LIMIT` (100 KB — same threshold as
//! the nvim mitigation report) get NO highlight pass at all; the caller
//! checks `languageFor`/`overLimit` and skips the Highlighter entirely.
//!
//! Query files: src/syntax/queries/<lang>.scm (copied verbatim from the
//! tree-sitter-grammars repos shipped inside the tree_sitter package).

const std = @import("std");
const treez = @import("treez");

/// Highlight style groups, indexed by `Span.style` (0 = default). The caller
/// (main.zig) owns the actual vaxis style palette, keyed by this enum's
/// ordinal — syntax.zig only assigns groups.
pub const Style = enum(u8) {
    default = 0,
    comment,
    keyword,
    string,
    number,
    function,
    type,
    constant,
    operator,
    property,
    tag,
    attribute,
    label,
    boolean,
    character,
    namespace,
    constructor,
    variable,
    parameter,
    punctuation,
    /// Rainbow brackets: style = bracketN where N = bracket depth % 7. The
    /// caller maps ordinals to a 7-color rainbow palette.
    bracket0,
    bracket1,
    bracket2,
    bracket3,
    bracket4,
    bracket5,
    bracket6,
    builtin,
};

/// One highlighted byte range. Sorted by `start`, non-overlapping.
pub const Span = struct {
    start: u32,
    end: u32, // exclusive
    style: Style,
};

/// A byte range identifying a "code block" scope for cursor-aware features
/// (e.g. scope highlighting). `end_byte` is exclusive (tree-sitter
/// convention) — the closing token occupies [end_byte - 1, end_byte); the
/// caller converts both ends to line numbers as needed. `indent_col` is the
/// expanded indent column of the scope's STARTING line (tabs count as
/// tab_width = 4) — the single column where the scope's highlight line is
/// drawn (snacks.indent: `col = indent - leftcol`).
pub const Scope = struct {
    start_byte: u32,
    end_byte: u32, // exclusive
    indent_col: u32,
};

/// A raw byte interval (ERROR-node coverage).
const ByteRange = struct {
    start: u32,
    end: u32, // exclusive
};

/// Cheap per-line lexer fallback for tree-sitter ERROR regions: keywords,
/// strings, characters, numbers and comments get their normal style even
/// while the text is syntactically broken. Identifiers render as variables,
/// everything else stays default. `start_byte` anchors the slice back into
/// the document so emitted spans use absolute byte offsets.
fn fallbackLex(text: []const u8, start_byte: u32, arena: std.mem.Allocator, out: *std.ArrayList(Span)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // line comment // … or # … (zig/python/bash)
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            var j = i;
            while (j < text.len and text[j] != '\n') j += 1;
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = .comment });
            i = j;
            continue;
        }
        if (c == '#') {
            var j = i;
            while (j < text.len and text[j] != '\n') j += 1;
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = .comment });
            i = j;
            continue;
        }
        // string literal "…" (backslash escapes)
        if (c == '"') {
            var j = i + 1;
            while (j < text.len and text[j] != '"') {
                if (text[j] == '\\') j += 1;
                j += 1;
            }
            if (j < text.len) j += 1; // closing quote
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = .string });
            i = j;
            continue;
        }
        // character literal 'x' (keep it off the string rule)
        if (c == '\'') {
            var j = i + 1;
            while (j < text.len and text[j] != '\'') {
                if (text[j] == '\\') j += 1;
                j += 1;
            }
            if (j < text.len) j += 1;
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = .character });
            i = j;
            continue;
        }
        // number: 0x/0b/0o, digits, separators, floats
        if (c >= '0' and c <= '9') {
            var j = i;
            while (j < text.len and (isIdentCont(text[j]) or text[j] == '.' or text[j] == 'x' or text[j] == 'b' or text[j] == 'o')) j += 1;
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = .number });
            i = j;
            continue;
        }
        // identifier / keyword
        if (isIdentStart(c)) {
            var j = i;
            while (j < text.len and isIdentCont(text[j])) j += 1;
            const style: Style = if (isFallbackKeyword(text[i..j])) .keyword else .variable;
            try out.append(arena, .{ .start = start_byte + @as(u32, @intCast(i)), .end = start_byte + @as(u32, @intCast(j)), .style = style });
            i = j;
            continue;
        }
        i += 1;
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Cross-language keyword set for the ERROR-region fallback lexer. Being
/// generous here is fine: the fallback only runs inside syntactically broken
/// regions, where a wrong keyword guess beats an uncolored token.
fn isFallbackKeyword(word: []const u8) bool {
    const kw = [_][]const u8{
        "const",      "pub",            "fn",          "var",      "if",        "else",      "return",   "while",       "for",
        "break",      "continue",       "struct",      "enum",     "union",     "switch",    "case",     "try",         "catch",
        "defer",      "errdefer",       "unreachable", "comptime", "export",    "extern",    "inline",   "noalias",     "opaque",
        "suspend",    "usingnamespace", "test",        "volatile", "allowzero", "align",     "callconv", "linksection", "addrspace",
        "and",        "or",             "not",         "true",     "false",     "null",      "import",   "from",        "as",
        "def",        "class",          "function",    "let",      "new",       "this",      "in",       "is",          "of",
        "do",         "then",           "end",         "local",    "global",    "static",    "void",     "int",         "float",
        "double",     "bool",           "string",      "type",     "use",       "mod",       "impl",     "trait",       "match",
        "loop",       "mut",            "async",       "await",    "yield",     "self",      "super",    "interface",   "extends",
        "implements", "package",        "namespace",   "public",   "private",   "protected", "abstract", "final",       "override",
        "sizeof",     "typeof",         "instanceof",  "elif",     "except",    "with",      "assert",   "lambda",
    };
    for (kw) |k| {
        if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

/// Files larger than this get no syntax pass (see file header).
pub const SIZE_LIMIT: usize = 100 * 1024;

/// Resolve a filetype (from `filetypeOf`) to a tree-sitter language name.
/// Returns null when no grammar is bundled for this filetype.
pub fn languageFor(ft: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ft, "zig")) return "zig";
    if (std.mem.eql(u8, ft, "rs") or std.mem.eql(u8, ft, "rust")) return "rust";
    if (std.mem.eql(u8, ft, "go")) return "go";
    if (std.mem.eql(u8, ft, "py") or std.mem.eql(u8, ft, "python")) return "python";
    if (std.mem.eql(u8, ft, "ts") or std.mem.eql(u8, ft, "typescript")) return "typescript";
    if (std.mem.eql(u8, ft, "tsx")) return "tsx";
    if (std.mem.eql(u8, ft, "js") or std.mem.eql(u8, ft, "javascript") or
        std.mem.eql(u8, ft, "mjs") or std.mem.eql(u8, ft, "cjs")) return "javascript";
    if (std.mem.eql(u8, ft, "json")) return "json";
    if (std.mem.eql(u8, ft, "c") or std.mem.eql(u8, ft, "h")) return "c";
    if (std.mem.eql(u8, ft, "cpp") or std.mem.eql(u8, ft, "cc") or
        std.mem.eql(u8, ft, "hpp") or std.mem.eql(u8, ft, "cxx")) return "cpp";
    if (std.mem.eql(u8, ft, "sh") or std.mem.eql(u8, ft, "bash")) return "bash";
    if (std.mem.eql(u8, ft, "lua")) return "lua";
    if (std.mem.eql(u8, ft, "toml")) return "toml";
    if (std.mem.eql(u8, ft, "yaml") or std.mem.eql(u8, ft, "yml")) return "yaml";
    return null;
}

/// Map a query capture name (e.g. "@keyword.function") to a Style. The
/// mapping ignores the dotted suffix ("keyword.function" → keyword).
pub fn captureStyle(name: []const u8) Style {
    // capture names may or may not carry the leading '@' (the C API returns
    // them as written in the query)
    var n = name;
    if (n.len > 0 and n[0] == '@') n = n[1..];
    // dotted captures are MORE SPECIFIC than their base: @variable.parameter
    // is a parameter, not a plain variable. Check them before folding the
    // suffix away, or every identifier would render as a variable.
    if (std.mem.eql(u8, n, "variable.parameter")) return .parameter;
    if (std.mem.eql(u8, n, "variable.member")) return .property;
    if (std.mem.eql(u8, n, "variable.builtin")) return .builtin;
    if (std.mem.eql(u8, n, "function.builtin")) return .builtin;
    if (std.mem.eql(u8, n, "type.builtin")) return .type;
    if (std.mem.eql(u8, n, "constant.builtin")) return .constant;
    if (std.mem.eql(u8, n, "module.builtin")) return .namespace;
    if (std.mem.eql(u8, n, "string.escape")) return .string;
    if (std.mem.eql(u8, n, "number.float")) return .number;
    const base = if (std.mem.indexOfScalar(u8, n, '.')) |dot| n[0..dot] else n;
    if (std.mem.eql(u8, base, "comment")) return .comment;
    if (std.mem.eql(u8, base, "keyword")) return .keyword;
    if (std.mem.eql(u8, base, "string")) return .string;
    if (std.mem.eql(u8, base, "number")) return .number;
    if (std.mem.eql(u8, base, "function")) return .function;
    if (std.mem.eql(u8, base, "type")) return .type;
    if (std.mem.eql(u8, base, "constant")) return .constant;
    if (std.mem.eql(u8, base, "operator")) return .operator;
    if (std.mem.eql(u8, base, "property")) return .property;
    if (std.mem.eql(u8, base, "tag")) return .tag;
    if (std.mem.eql(u8, base, "attribute")) return .attribute;
    if (std.mem.eql(u8, base, "label")) return .label;
    if (std.mem.eql(u8, base, "boolean")) return .boolean;
    if (std.mem.eql(u8, base, "character")) return .character;
    if (std.mem.eql(u8, base, "namespace")) return .namespace;
    // zig.scm captures `@module` for identifiers bound by @import
    // ("const std = @import(...)" — the most common line in Zig code)
    if (std.mem.eql(u8, base, "module")) return .namespace;
    if (std.mem.eql(u8, base, "constructor")) return .constructor;
    if (std.mem.eql(u8, base, "variable")) return .variable;
    if (std.mem.eql(u8, base, "parameter")) return .parameter;
    if (std.mem.eql(u8, base, "punctuation")) return .punctuation;
    if (std.mem.eql(u8, base, "builtin")) return .builtin;
    return .default;
}

/// True when a capture name is a bracket punctuation capture — base
/// "punctuation" with a ".bracket" suffix ("@punctuation.bracket"). These get
/// the rainbow `bracketN` styles instead of plain `.punctuation`; the check
/// must happen BEFORE `captureStyle`, which folds the dotted suffix away.
fn isBracketCapture(name: []const u8) bool {
    var n = name;
    if (n.len > 0 and n[0] == '@') n = n[1..];
    const dot = std.mem.indexOfScalar(u8, n, '.') orelse return false;
    if (!std.mem.eql(u8, n[0..dot], "punctuation")) return false;
    return std.mem.endsWith(u8, n, ".bracket");
}

// ---------------------------------------------------------------------------
// Query predicate evaluation (#eq? / #any-of? / #lua-match?)
// ---------------------------------------------------------------------------
// treez's CursorWithValidation only supports #eq? (and panics on #lua-match?),
// so the highlighter evaluates the query predicates itself. Without this the
// predicate-carrying patterns in the .scm files (e.g. `((identifier) @type
// (#lua-match? @type "^[A-Z_]..."))`) match EVERY identifier, and the
// catch-all `(identifier) @variable` from the same node drowns the specific
// capture during span merging — every token ends up the variable color.

/// Evaluate the predicates of `match.pattern_index` against the captured
/// text. Returns true when the pattern has no predicates or all of them hold;
/// false (rejecting the capture) when any predicate fails or is unsupported.
fn matchPredicates(self: *Highlighter, match: treez.Query.Match, text: []const u8) bool {
    const preds = self.query.getPredicatesForPattern(match.pattern_index);
    if (preds.len == 0) return true;
    var i: usize = 0;
    while (i < preds.len) {
        // each predicate: [string op] [capture|string args...] [done]
        if (preds[i].type != .string) return false;
        const op = self.query.getStringValueForId(preds[i].value_id);
        i += 1;
        var cap_id: ?u32 = null;
        var str_values: [4][]const u8 = undefined;
        var nstr: usize = 0;
        while (i < preds.len and preds[i].type != .done) : (i += 1) {
            switch (preds[i].type) {
                .capture => cap_id = preds[i].value_id,
                .string => {
                    if (nstr < str_values.len) {
                        str_values[nstr] = self.query.getStringValueForId(preds[i].value_id);
                    }
                    nstr += 1;
                },
                .done => {}, // loop condition excludes it; be exhaustive
            }
        }
        i += 1; // skip .done
        const cid = cap_id orelse return false;
        // the captured node's text within the document
        var value: ?[]const u8 = null;
        for (match.captures()) |cap| {
            if (cap.id == cid) {
                const s = cap.node.getStartByte();
                const e = cap.node.getEndByte();
                if (s <= text.len and e <= text.len and s < e) value = text[s..e];
                break;
            }
        }
        const v = value orelse return false;
        if (std.mem.eql(u8, op, "eq?")) {
            if (nstr != 1 or !std.mem.eql(u8, v, str_values[0])) return false;
        } else if (std.mem.eql(u8, op, "any-of?")) {
            var ok = false;
            for (str_values[0..nstr]) |w| {
                if (std.mem.eql(u8, v, w)) ok = true;
            }
            if (!ok) return false;
        } else if (std.mem.eql(u8, op, "lua-match?")) {
            if (nstr != 1 or !luaMatch(v, str_values[0])) return false;
        } else {
            return false; // unsupported predicate: reject the match
        }
    }
    return true;
}

/// Minimal `#lua-match?` evaluator for the pattern subset used in our query
/// files: '^'/'$' anchors, literal chars, "[...]" character classes with
/// ranges (a-z A-Z 0-9 _ and single chars), and '*', '+', '?' quantifiers.
/// Semantics follow lua string.match (substring unless anchored with '^');
/// the greedy quantifiers never need backtracking here because every pattern
/// ends in the quantified class or a '$' anchor.
fn luaMatch(text: []const u8, pattern: []const u8) bool {
    const anchored = pattern.len > 0 and pattern[0] == '^';
    var start: usize = 0;
    while (true) {
        if (matchAt(text, start, pattern, if (anchored) 1 else 0, pattern.len)) return true;
        if (anchored or start >= text.len) return false;
        start += 1;
    }
}

fn matchAt(text: []const u8, ti_in: usize, pattern: []const u8, pi_in: usize, plen: usize) bool {
    var ti = ti_in;
    var pi = pi_in;
    while (pi < plen) {
        const pc = pattern[pi];
        if (pc == '$') return ti == text.len; // end anchor
        // parse the atom: single char or [class]
        const atom_start = pi;
        var pi2 = pi;
        var is_class = false;
        if (pc == '[') {
            is_class = true;
            pi2 += 1;
            while (pi2 < plen and pattern[pi2] != ']') pi2 += 1;
            if (pi2 >= plen) return false; // unterminated class
            pi2 += 1; // past ']'
        } else {
            pi2 += 1;
        }
        // exclusive atom end: past ']' for classes, past the char otherwise
        const atom_end = if (is_class) pi2 - 1 else pi2;
        // quantifier
        var quant: enum { one, opt, star, plus } = .one;
        if (pi2 < plen) {
            switch (pattern[pi2]) {
                '?' => {
                    quant = .opt;
                    pi2 += 1;
                },
                '*' => {
                    quant = .star;
                    pi2 += 1;
                },
                '+' => {
                    quant = .plus;
                    pi2 += 1;
                },
                else => {},
            }
        }
        switch (quant) {
            .one => {
                if (ti >= text.len or !atomMatch(text[ti], pattern[atom_start..atom_end], is_class)) return false;
                ti += 1;
            },
            .opt => {
                if (ti < text.len and atomMatch(text[ti], pattern[atom_start..atom_end], is_class)) ti += 1;
            },
            .star, .plus => {
                var count: usize = 0;
                while (ti < text.len and atomMatch(text[ti], pattern[atom_start..atom_end], is_class)) : (ti += 1) count += 1;
                if (quant == .plus and count == 0) return false;
            },
        }
        pi = pi2;
    }
    return true;
}

/// Does byte `c` match the atom at pattern[start..end]? (start points at '['
/// when is_class, else at a literal char.)
fn atomMatch(c: u8, atom: []const u8, is_class: bool) bool {
    if (!is_class) return atom.len == 1 and c == atom[0];
    var i: usize = 1; // skip '['
    while (i + 2 < atom.len and atom[i + 1] == '-') {
        if (c >= atom[i] and c <= atom[i + 2]) return true; // range a-b
        i += 3;
    }
    while (i < atom.len) : (i += 1) {
        if (c == atom[i]) return true;
    }
    return false;
}

/// Rainbow style for a bracket at `depth`: bracket0 + depth % 7.
fn bracketStyle(depth: u32) Style {
    const base: u8 = @intFromEnum(Style.bracket0);
    return @enumFromInt(base + @as(u8, @intCast(depth % 7)));
}

/// Bracket nesting depth = the number of `getParent()` steps from `node` up
/// to the tree root. The walk stops when the parent is null (root's parent —
/// treez's `getParent` returns a null node there, and touching any field of
/// it segfaults in this tree-sitter build, so only `isNull()` is consulted),
/// with an identity guard against malformed trees. The root node itself has
/// depth 0.
fn bracketDepth(node: treez.Node) u32 {
    var depth: u32 = 0;
    var cur = node;
    while (true) {
        const parent = cur.getParent();
        if (parent.isNull()) break;
        if (parent.id == cur.id) break; // defensive: self-parent would loop forever
        cur = parent;
        depth += 1;
    }
    return depth;
}

/// A parsed+queried buffer for one language. Owns the tree-sitter parser,
/// the compiled highlight query and the last parse tree.
pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    parser: *treez.Parser,
    query: *treez.Query,
    /// Language name ("zig", "rust", …) — used by tests and deinit.
    lang_name: []const u8,
    /// Last parsed tree (null before the first parse).
    tree: ?*treez.Tree = null,
    /// The text the current tree was parsed from (owned). tree.edit() needs
    /// the OLD text's line/column to place the edit points correctly — zero
    /// points corrupt tree-sitter's internal position metadata and can drift
    /// the highlight spans after a burst of edits.
    prev_text: ?[]u8 = null,

    /// Grammars with a bundled query file (src/syntax/queries/<lang>.scm).
    const LANGUAGES = [_][]const u8{
        "zig",        "rust", "go", "python", "typescript", "tsx",
        "javascript", "json", "c",  "cpp",    "bash",       "lua",
        "toml",       "yaml",
    };

    pub fn init(allocator: std.mem.Allocator, lang_name: []const u8) !Highlighter {
        inline for (LANGUAGES) |l| {
            if (std.mem.eql(u8, lang_name, l)) {
                return initLang(allocator, l);
            }
        }
        return error.UnsupportedLanguage;
    }

    fn initLang(allocator: std.mem.Allocator, comptime lang: []const u8) !Highlighter {
        const language = try treez.Language.get(lang);
        var parser = try treez.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);
        var error_offset: u32 = 0;
        const query = try treez.Query.create(language, @embedFile("syntax/queries/" ++ lang ++ ".scm"), &error_offset);
        return .{
            .allocator = allocator,
            .parser = parser,
            .query = query,
            .lang_name = lang,
        };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.prev_text) |t| self.allocator.free(t);
        if (self.tree) |t| t.destroy();
        self.query.destroy();
        self.parser.destroy();
    }

    /// Full reparse of `text`. Deliberately passes null as the old tree:
    /// tree-sitter's incremental path reuses the old tree's internal state
    /// and corrupts the result when the new text is a *different document*
    /// (buffer switch) with no edit() records — exactly the "highlight garbles
    /// after switching buffers" bug. Buffer switches and multi-edit fallbacks
    /// land here; the single-edit incremental path lives in `reparseEdit`.
    pub fn reparse(self: *Highlighter, text: []const u8) !void {
        const new_tree = try self.parser.parseString(null, text);
        if (self.tree) |old| old.destroy();
        self.tree = new_tree;
        try self.setPrevText(text);
    }

    fn setPrevText(self: *Highlighter, text: []const u8) !void {
        if (self.prev_text) |t| self.allocator.free(t);
        self.prev_text = try self.allocator.dupe(u8, text);
    }

    /// Incremental reparse: record a single edit [pos, old_end) → [pos,
    /// new_end) on the current tree, then parse the new text reusing the
    /// old tree (tree-sitter's incremental path — the whole point of
    /// t.edit()). Only byte offsets matter to our consumers — the point
    /// fields are approximated; tree-sitter needs them only for position
    /// metadata we never read. On parse failure the old tree may be left
    /// in an unknown state, so it is dropped and a full reparse is used.
    pub fn reparseEdit(self: *Highlighter, pos: u32, old_end: u32, new_end: u32, text: []const u8) !void {
        if (self.tree) |t| {
            const old_text = self.prev_text orelse "";
            t.edit(&.{
                .start_byte = pos,
                .old_end_byte = old_end,
                .new_end_byte = new_end,
                .start_point = pointAt(old_text, pos),
                .old_end_point = pointAt(old_text, @min(old_end, @as(u32, @intCast(old_text.len)))),
                .new_end_point = pointAt(text, new_end),
            });
        }
        const new_tree = self.parser.parseString(self.tree, text) catch {
            if (self.tree) |old| old.destroy();
            self.tree = null;
            return self.reparse(text);
        };
        if (self.tree) |old| old.destroy();
        self.tree = new_tree;
        try self.setPrevText(text);
    }

    /// Line/column of a byte offset (tree-sitter Point).
    fn pointAt(text: []const u8, byte: u32) treez.Point {
        var row: u32 = 0;
        var col: u32 = 0;
        const b = @min(byte, @as(u32, @intCast(text.len)));
        for (text[0..b]) |c| {
            if (c == '\n') {
                row += 1;
                col = 0;
            } else {
                col += 1;
            }
        }
        return .{ .row = row, .column = col };
    }

    /// Run the highlight query over [start_byte, end_byte) and append spans
    /// to `out` (allocated from `arena`, e.g. the render frame arena). The
    /// query cursor is byte-range limited — the O(visible) contract.
    pub fn spansInRange(self: *Highlighter, start_byte: u32, end_byte: u32, arena: std.mem.Allocator, out: *std.ArrayList(Span)) !void {
        const tree = self.tree orelse return;
        const text = self.prev_text orelse return;
        var cursor = try treez.Query.Cursor.create();
        defer cursor.destroy();
        cursor.setByteRange(start_byte, end_byte);
        cursor.execute(self.query, tree.getRootNode());
        while (cursor.nextCapture()) |nc| {
            const match = nc[0];
            const cap = match.captures()[nc[1]];
            // query predicates (#lua-match?/#eq?/#any-of?): the pattern only
            // applies when they hold — treez's own validation only supports
            // #eq? and is not wired in here, so evaluate them ourselves
            // (see matchPredicates). Without this, "@type" with a
            // `#lua-match? "^[A-Z_]..."` predicate matches EVERY identifier.
            if (!matchPredicates(self, match, text)) continue;
            const name = self.query.getCaptureNameForId(cap.id);
            // rainbow brackets: "@punctuation.bracket" spans get bracketN
            // instead of the plain .punctuation that captureStyle() would
            // fold them to (it collapses dotted suffixes onto the base).
            const style: Style = if (isBracketCapture(name))
                bracketStyle(bracketDepth(cap.node))
            else
                captureStyle(name);
            if (style == .default) continue;
            const s = cap.node.getStartByte();
            const e = cap.node.getEndByte();
            if (s == e) continue;
            try out.append(arena, .{ .start = s, .end = e, .style = style });
        }
        // Same byte range can be captured by several patterns (the catch-all
        // `(identifier) @variable` plus the specific one). Our query files
        // list the specific captures AFTER the catch-all, so the LAST
        // capture of a range wins — otherwise the merge in main.zig ("later
        // spans win overlaps") picks the catch-all and every token renders
        // as a variable. Dedup keeping the last occurrence of each range.
        {
            const Key = struct { start: u32, end: u32 };
            var seen = std.AutoHashMap(Key, usize).init(arena);
            defer seen.deinit();
            var write: usize = 0;
            var i: usize = 0;
            while (i < out.items.len) : (i += 1) {
                const sp = out.items[i];
                const key = Key{ .start = sp.start, .end = sp.end };
                if (seen.get(key)) |idx| {
                    out.items[idx] = sp; // later capture wins
                } else {
                    seen.put(key, write) catch {};
                    out.items[write] = sp;
                    write += 1;
                }
            }
            out.shrinkRetainingCapacity(write);
        }
        // tree-sitter's error recovery can swallow whole regions (e.g. typing
        // "1;j" — a syntax error — makes the ERROR node cover "const y" on the
        // NEXT line, so the keyword loses its capture). Fall back to a cheap
        // per-line lexer INSIDE ERROR nodes so keywords/strings/comments/numbers
        // keep their colors while the text is syntactically broken. The lexer
        // runs only on ERROR ranges intersecting the visible range, so the
        // O(visible) contract holds.
        var errs = std.ArrayList(ByteRange).empty;
        defer errs.deinit(arena);
        try self.collectErrorRanges(start_byte, end_byte, arena, &errs);
        for (errs.items) |r| {
            if (r.end <= r.start) continue;
            if (r.end > text.len) continue;
            // an ERROR node can span to the end of the file (unclosed
            // string/comment while typing); the fallback lexer must run only
            // on the visible slice, or every frame costs O(file)
            const lo = @max(r.start, start_byte);
            const hi = @min(r.end, end_byte);
            if (hi <= lo) continue;
            try fallbackLex(text[lo..hi], lo, arena, out);
        }
        std.mem.sort(Span, out.items, {}, lessThan);
    }

    /// Walk the tree (pruned to the byte range) collecting ERROR nodes.
    fn collectErrorRanges(self: *Highlighter, start: u32, end: u32, arena: std.mem.Allocator, out: *std.ArrayList(ByteRange)) !void {
        const tree = self.tree orelse return;
        var stack: [256]treez.Node = undefined;
        var sp: usize = 0;
        stack[sp] = tree.getRootNode();
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const n = stack[sp];
            const ns = n.getStartByte();
            const ne = n.getEndByte();
            if (ne <= start or ns >= end) continue; // outside the visible range
            if (std.mem.eql(u8, n.getType(), "ERROR")) {
                try out.append(arena, .{ .start = ns, .end = ne });
                continue; // don't descend into the error's own children
            }
            var i: u32 = 0;
            while (i < n.getChildCount()) : (i += 1) {
                if (sp < stack.len) {
                    stack[sp] = n.getChild(i);
                    sp += 1;
                }
            }
        }
    }

    fn lessThan(_: void, a: Span, b: Span) bool {
        return a.start < b.start;
    }

    /// Deepest multi-line "code block" node containing `byte`, as a byte
    /// range. Starts at the root and drills down: while the child containing
    /// `byte` is a block-like node that spans more than one line, record it
    /// as the current scope and descend into it. Stops when no child
    /// contains `byte`, the containing child is not block-like, or it is a
    /// single-line node (variable_declaration, expression_statement, … —
    /// those are not blocks, and highlighting one line reads as noise).
    /// Returns null when there is no tree, the file is empty, or the cursor
    /// sits in top-level code with no enclosing block. Cost is O(tree depth
    /// × children per level) — never O(file).
    pub fn scopeAt(self: *Highlighter, byte: u32) ?Scope {
        const tree = self.tree orelse return null;
        const text = self.prev_text orelse return null;
        const root = tree.getRootNode();
        if (root.getEndByte() == 0) return null; // empty file
        var scope: ?treez.Node = null;
        var current = root;
        while (true) {
            // find the child containing `byte` (siblings never overlap, so at
            // most one matches)
            var next: ?treez.Node = null;
            var i: u32 = 0;
            while (i < current.getChildCount()) : (i += 1) {
                const child = current.getChild(i);
                if (child.isNull()) continue;
                if (child.getStartByte() <= byte and byte < child.getEndByte()) {
                    next = child;
                    break;
                }
            }
            const child = next orelse break;
            if (!isBlockNode(child)) break;
            const cs = child.getStartByte();
            const ce = child.getEndByte();
            if (ce > cs and ce <= text.len and std.mem.indexOfScalar(u8, text[cs..ce], '\n') == null) break;
            scope = child;
            current = child;
        }
        const s = scope orelse return null;
        return .{
            .start_byte = s.getStartByte(),
            .end_byte = s.getEndByte(),
            .indent_col = lineIndentCol(text, s.getStartByte()),
        };
    }
};

/// Loose "is this a code block?" check by node-type substring (zig names fn
/// bodies `block`, fns `function_declaration`, containers `struct_declaration`
/// etc. — lenient substring matching keeps this language-agnostic).
fn isBlockNode(node: treez.Node) bool {
    const ty = node.getType();
    const needles = [_][]const u8{
        "block", "function", "fn_", "declaration", "struct", "enum",
        "union", "class", "interface", "impl", "module", "body", "statement",
    };
    for (needles) |nd| {
        if (std.mem.indexOf(u8, ty, nd) != null) return true;
    }
    return false;
}

/// Expanded indent column (spaces, tabs = 4 columns) of the line containing
/// `byte` — the column where that line's block's scope line is drawn
/// (snacks.indent renders the scope guide at `scope.indent`).
fn lineIndentCol(text: []const u8, byte: u32) u32 {
    const b = @min(byte, @as(u32, @intCast(text.len)));
    var ls = b;
    while (ls > 0 and text[ls - 1] != '\n') ls -= 1;
    var col: u32 = 0;
    var i = ls;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {
        col += if (text[i] == '\t') 4 else 1;
    }
    return col;
}

// ---------------------------------------------------------------------------
// L1 tests (implemented alongside the real logic)
// ---------------------------------------------------------------------------

test "captureStyle: dotted names collapse to the base capture" {
    try std.testing.expect(captureStyle("@keyword") == .keyword);
    try std.testing.expect(captureStyle("@keyword.function") == .keyword);
    try std.testing.expect(captureStyle("@string.special") == .string);
    try std.testing.expect(captureStyle("@variable.builtin") == .builtin);
    try std.testing.expect(captureStyle("@variable.parameter") == .parameter);
    try std.testing.expect(captureStyle("@variable.member") == .property);
    try std.testing.expect(captureStyle("@function.builtin") == .builtin);
    try std.testing.expect(captureStyle("@type.builtin") == .type);
    try std.testing.expect(captureStyle("@constant.builtin") == .constant);
    try std.testing.expect(captureStyle("@punctuation.bracket") == .punctuation);
    try std.testing.expect(captureStyle("@nonexistent") == .default);
}

test "isBracketCapture: only punctuation.bracket captures qualify" {
    try std.testing.expect(isBracketCapture("@punctuation.bracket"));
    try std.testing.expect(isBracketCapture("punctuation.bracket"));
    try std.testing.expect(!isBracketCapture("@punctuation.delimiter"));
    try std.testing.expect(!isBracketCapture("@punctuation"));
    try std.testing.expect(!isBracketCapture("@keyword.bracket"));
    try std.testing.expect(!isBracketCapture("@bracket"));
}

test "bracketStyle: depth maps into the 7-color rainbow" {
    try std.testing.expect(bracketStyle(0) == Style.bracket0);
    try std.testing.expect(bracketStyle(6) == Style.bracket6);
    try std.testing.expect(bracketStyle(7) == Style.bracket0);
    try std.testing.expect(bracketStyle(20) == Style.bracket6); // 20 % 7 == 6
}

test "highlight: rainbow brackets — inner brackets have a deeper style than outer" {
    const alloc = std.testing.allocator;
    // nested zig: fn params "()", fn body "{}", if-parens "(true)", if body "{}"
    const src =
        \\pub fn f() void {
        \\    const y = 1;
        \\    if (true) {}
        \\}
        \\
    ;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), std.testing.allocator, &spans);

    const fn_lparen = std.mem.indexOf(u8, src, "(").?; // fn params "("
    const if_lparen = std.mem.indexOfPos(u8, src, fn_lparen + 1, "(").?; // if "("
    const fn_lbrace = std.mem.indexOf(u8, src, "{").?; // fn body "{"
    const if_lbrace = std.mem.indexOfPos(u8, src, fn_lbrace + 1, "{").?; // if body "{"
    const semi = std.mem.indexOf(u8, src, ";").?; // delimiter

    const fn_paren = spanAt(spans.items, @intCast(fn_lparen)).?;
    const fn_brace = spanAt(spans.items, @intCast(fn_lbrace)).?;
    const if_paren = spanAt(spans.items, @intCast(if_lparen)).?;
    const if_brace = spanAt(spans.items, @intCast(if_lbrace)).?;

    // all four brackets get rainbow styles (never plain .punctuation)
    const base: u8 = @intFromEnum(Style.bracket0);
    for ([_]Style{ fn_paren, fn_brace, if_paren, if_brace }) |st| {
        const off = @as(u8, @intFromEnum(st)) -% base;
        if (off > 6) {
            dumpSpans(src, spans.items);
            try std.testing.expect(false);
        }
    }

    // the nesting formula: inner (deeper in the tree) ordinal > outer ordinal
    const ord_if_paren: u8 = @intFromEnum(if_paren);
    const ord_fn_paren: u8 = @intFromEnum(fn_paren);
    const ord_if_brace: u8 = @intFromEnum(if_brace);
    const ord_fn_brace: u8 = @intFromEnum(fn_brace);
    if (!(ord_if_paren > ord_fn_paren) or !(ord_if_brace > ord_fn_brace)) {
        dumpSpans(src, spans.items);
    }
    try std.testing.expect(ord_if_paren > ord_fn_paren);
    try std.testing.expect(ord_if_brace > ord_fn_brace);

    // delimiters stay plain punctuation
    try std.testing.expectEqual(Style.punctuation, spanAt(spans.items, @intCast(semi)).?);
}

test "scopeAt: cursor in fn body returns the fn-body block, not the one-line const" {
    const alloc = std.testing.allocator;
    const src = "pub fn main() void {\n    const x = 1;\n}\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);

    // cursor on "const x = 1;" (line 2): the variable_declaration is a
    // one-line node, so it is NOT a scope — the deepest multi-line block is
    // the fn body "block" whose byte range covers "{\n    const x = 1;\n}".
    const cur = std.mem.indexOf(u8, src, "const x").?;
    const scope = hl.scopeAt(@intCast(cur)).?;
    try std.testing.expect(scope.start_byte <= cur and cur < scope.end_byte);
    const fn_lbrace = std.mem.indexOf(u8, src, "{").?;
    const fn_rbrace = std.mem.indexOf(u8, src, "}").?;
    try std.testing.expectEqual(@as(u32, @intCast(fn_lbrace)), scope.start_byte);
    try std.testing.expect(scope.end_byte > fn_rbrace); // covers the closing brace

    // cursor on the newline right after the statement → same fn-body scope
    const after_statement = std.mem.indexOf(u8, src, ";\n").? + 1; // the "\n" after ";"
    const scope2 = hl.scopeAt(@intCast(after_statement)).?;
    try std.testing.expect(scope2.start_byte <= after_statement and after_statement < scope2.end_byte);
    try std.testing.expect(scope2.end_byte > fn_rbrace); // covers the closing brace
}

test "scopeAt: empty/no-tree and top-level code return null, fn returns its block" {
    const alloc = std.testing.allocator;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();

    // no tree yet → null
    try std.testing.expect(hl.scopeAt(0) == null);

    // empty file → null
    try hl.reparse("");
    try std.testing.expect(hl.scopeAt(0) == null);

    // one-line declarations (even in a multi-line file) are not scopes:
    // top-level code has no enclosing block → null (no highlight, plain
    // gray guides — the desired top-level look)
    const src = "// hello\nconst x = 1;\nconst y = 2;\n";
    try hl.reparse(src);
    try std.testing.expect(hl.scopeAt(0) == null);
    const x_cur = std.mem.indexOf(u8, src, "const x").?;
    try std.testing.expect(hl.scopeAt(@intCast(x_cur)) == null);

    // a multi-line function is a scope from its declaration line: cursor on
    // the "fn" keyword still lands in the function_declaration
    const src2 = "pub fn main() void {\n    const x = 1;\n}\n";
    try hl.reparse(src2);
    const fn_scope = hl.scopeAt(0).?;
    try std.testing.expect(fn_scope.start_byte == 0);
    const src2_rbrace = std.mem.indexOf(u8, src2, "}").?;
    try std.testing.expect(fn_scope.end_byte > src2_rbrace); // covers the closing brace
}

test "languageFor: filetype to grammar" {
    try std.testing.expectEqualStrings("zig", languageFor("zig").?);
    try std.testing.expectEqualStrings("rust", languageFor("rs").?);
    try std.testing.expectEqualStrings("go", languageFor("go").?);
    try std.testing.expectEqualStrings("python", languageFor("py").?);
    try std.testing.expectEqualStrings("typescript", languageFor("ts").?);
    try std.testing.expectEqualStrings("tsx", languageFor("tsx").?);
    try std.testing.expectEqualStrings("javascript", languageFor("js").?);
    try std.testing.expectEqualStrings("json", languageFor("json").?);
    try std.testing.expect(languageFor("md") == null);
    try std.testing.expect(languageFor("txt") == null);
}

test "highlight: zig keywords and strings get styled spans" {
    const alloc = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    const msg = "hello";
        \\    std.debug.print("{s}\n", .{msg});
        \\}
        \\
    ;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), std.testing.allocator, &spans);

    // the whole file is visible: we must find at least a keyword ("const",
    // "pub", "fn", "var", "if", …) and a string literal ("hello").
    var saw_keyword = false;
    var saw_string = false;
    for (spans.items) |sp| {
        if (sp.style == .keyword and sp.end > sp.start) saw_keyword = true;
        if (sp.style == .string and sp.end > sp.start) saw_string = true;
    }
    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_string);
}

test "highlight: byte-range limiting only yields spans inside the range" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = 1;
        \\const b = "two";
        \\const c = 3;
        \\
    ;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    // visible range covers only the middle line
    const ls = std.mem.indexOf(u8, src, "const b").?;
    const le = std.mem.indexOf(u8, src, "const c").?;
    try hl.spansInRange(@intCast(ls), @intCast(le), std.testing.allocator, &spans);
    try std.testing.expect(spans.items.len > 0);
    for (spans.items) |sp| {
        try std.testing.expect(sp.start >= ls and sp.end <= le);
    }
}

test "highlight: reparseEdit keeps byte spans correct after an edit" {
    const alloc = std.testing.allocator;
    const src = "const a = 1;\nconst b = 2;\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);

    // single edit: "a" (byte 6) → "aaa" (bytes 6..8)
    const new_src = "const aaa = 1;\nconst b = 2;\n";
    try hl.reparseEdit(6, 7, 9, new_src);

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(new_src.len), alloc, &spans);
    var keyword_at_0 = false;
    var number_at_12 = false;
    for (spans.items) |sp| {
        if (sp.style == .keyword and sp.start == 0 and sp.end == 5) keyword_at_0 = true;
        if (sp.style == .number and sp.start == 12 and sp.end == 13) number_at_12 = true;
    }
    if (!keyword_at_0 or !number_at_12) {
        std.debug.print("spans:", .{});
        for (spans.items) |sp| std.debug.print(" [{d},{d}) {s}", .{ sp.start, sp.end, @tagName(sp.style) });
        std.debug.print("\n", .{});
    }
    try std.testing.expect(keyword_at_0);
    try std.testing.expect(number_at_12);
}
test "highlight: sequential reparseEdit calls keep byte spans stable" {
    const alloc = std.testing.allocator;
    const src = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);

    // simulate typing in a syntax-legal spot: grow "a" into "axxxxx" with
    // one 'x' per edit (positions shift every time — the drift test)
    var text: []u8 = try alloc.dupe(u8, src);
    defer alloc.free(text);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const pos: u32 = @intCast(6 + i); // right after "a" (and the x's)
        const new_text = try std.fmt.allocPrint(alloc, "{s}x{s}", .{ text[0..pos], text[pos..] });
        alloc.free(text);
        text = new_text;
        try hl.reparseEdit(pos, pos, pos + 1, text);
    }

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(text.len), alloc, &spans);
    // final text "const axxxxx = 1;..." — keyword [0,5), number "1" at byte 15
    var keyword_ok = false;
    var number_ok = false;
    for (spans.items) |sp| {
        if (sp.style == .keyword and sp.start == 0 and sp.end == 5) keyword_ok = true;
        if (sp.style == .number and sp.start == 15 and sp.end == 16) number_ok = true;
    }
    if (!keyword_ok or !number_ok) {
        std.debug.print("\ntext=[{s}]\nspans:", .{text});
        for (spans.items) |sp| std.debug.print(" [{d},{d}){s}", .{ sp.start, sp.end, @tagName(sp.style) });
        std.debug.print("\n", .{});
    }
    try std.testing.expect(keyword_ok);
    try std.testing.expect(number_ok);
}
test "highlight: reparse with different text (buffer switch) stays correct" {
    const alloc = std.testing.allocator;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    // parse one document, then fully reparse a different one — the buffer
    // switch case (regression: reusing the stale tree corrupted the spans)
    try hl.reparse("const std = @import(\"std\");\n");
    const src2 = "const Piece = struct {\n    start: u32, // comment\n};\n";
    try hl.reparse(src2);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(src2.len), alloc, &spans);
    var piece_ok = false;
    var struct_ok = false;
    var comment_ok = false;
    for (spans.items) |sp| {
        if (sp.style == .type and sp.start == 6 and sp.end == 11) piece_ok = true;
        if (sp.style == .keyword and sp.start == 14 and sp.end == 20) struct_ok = true;
        if (sp.style == .comment and std.mem.eql(u8, src2[sp.start..sp.end], "// comment")) comment_ok = true;
    }
    try std.testing.expect(piece_ok);
    try std.testing.expect(struct_ok);
    try std.testing.expect(comment_ok);
}

fn dumpSpans(text: []const u8, spans: []const Span) void {
    std.debug.print("\ntext=[{s}]\n", .{text});
    for (spans) |sp| std.debug.print(" [{d},{d}){s}->{s}", .{ sp.start, sp.end, text[sp.start..sp.end], @tagName(sp.style) });
    std.debug.print("\n", .{});
}

fn spanAt(spans: []const Span, byte: u32) ?Style {
    for (spans) |sp| {
        if (sp.start <= byte and byte < sp.end) return sp.style;
    }
    return null;
}

test "repro: insert 'j' at end of an indented fn-body line keeps next-line keyword" {
    const alloc = std.testing.allocator;
    // the e2e shape that reproduces "下一行第一个单词变色": a real zig file,
    // cursor at end of an indented line inside a function body.
    const src = "const std = @import(\"std\");\npub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans0 = std.ArrayList(Span).empty;
    defer spans0.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), alloc, &spans0);
    // line 2 = "    const x = 1;" starts at 50, its 'const' at 54
    try std.testing.expectEqual(Style.keyword, spanAt(spans0.items, 54).?);
    // line 3 = "    const y = 2;" starts at 67, 'const' at 71
    try std.testing.expectEqual(Style.keyword, spanAt(spans0.items, 71).?);

    // insert 'j' at end of line 2 (byte 66, before '\n')
    const new_src = "const std = @import(\"std\");\npub fn main() void {\n    const x = 1;j\n    const y = 2;\n}\n";
    try hl.reparseEdit(66, 66, 67, new_src);

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(new_src.len), alloc, &spans);
    // line 3's 'const' now at byte 72 — must still be keyword (regression:
    // e2e showed it turn into the variable color 0xc0caf5)
    const st = spanAt(spans.items, 72);
    if (st != Style.keyword) dumpSpans(new_src, spans.items);
    try std.testing.expectEqual(Style.keyword, st);
}


test "build.zig style: parameter, type, module, function call get distinct styles" {
    // Regression: the catch-all `(identifier) @variable` used to drown the
    // specific captures (predicates were never evaluated, so `@type` with a
    // `#lua-match?` matched every identifier; and overlapping captures of the
    // same range merged unpredictably). b (parameter), std (module), Build
    // (type) and standardTargetOptions (function call) must each get its own
    // style — like the user's nvim.
    const alloc = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    _ = target;
        \\}
        \\
    ;
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), alloc, &spans);

    const param = std.mem.indexOf(u8, src, "b: *std.Build").?;
    try std.testing.expectEqual(Style.parameter, spanAt(spans.items, @intCast(param)).?);
    const module = std.mem.indexOf(u8, src, "const std").? + 6;
    try std.testing.expectEqual(Style.namespace, spanAt(spans.items, @intCast(module)).?);
    // "std.Build": Build is a field_expression member → @variable.member
    // (carpYellow in the theme — nvim-treesitter's zig query captures it the
    // same way, so it differs from the parameter b and the call below)
    const member_pos = std.mem.indexOf(u8, src, "Build").?;
    try std.testing.expectEqual(Style.property, spanAt(spans.items, @intCast(member_pos)).?);
    const call = std.mem.indexOf(u8, src, "standardTargetOptions").?;
    try std.testing.expectEqual(Style.function, spanAt(spans.items, @intCast(call)).?);
    // the const-declared variable stays a plain variable
    const var_ = std.mem.indexOf(u8, src, "target = ").?;
    try std.testing.expectEqual(Style.variable, spanAt(spans.items, @intCast(var_)).?);
}

test "full reparse of the same syntax-error text" {
    const alloc = std.testing.allocator;
    const new_src = "const std = @import(\"std\");\npub fn main() void {\n    const x = 1;j\n    const y = 2;\n}\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(new_src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(new_src.len), alloc, &spans);
    const st = spanAt(spans.items, 72);
    if (st != Style.keyword) dumpSpans(new_src, spans.items);
    try std.testing.expectEqual(Style.keyword, st);
}

test "indented const is still a keyword" {
    const alloc = std.testing.allocator;
    const src = "    const x = 1;\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), alloc, &spans);
    const st = spanAt(spans.items, 4);
    if (st != Style.keyword) dumpSpans(src, spans.items);
    try std.testing.expectEqual(Style.keyword, st);
}

test "repro: insert 'j' at end of line does not disturb next-line keyword" {
    const alloc = std.testing.allocator;
    const src = "const x = 1;\nconst y = 2;\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(src);

    // sanity: before the edit both "const"s are keywords
    var spans0 = std.ArrayList(Span).empty;
    defer spans0.deinit(alloc);
    try hl.spansInRange(0, @intCast(src.len), alloc, &spans0);
    try std.testing.expectEqual(Style.keyword, spanAt(spans0.items, 0).?);
    try std.testing.expectEqual(Style.keyword, spanAt(spans0.items, 13).?);

    // insert 'j' right after ";" (byte 12, before the "\n")
    const new_src = "const x = 1;j\nconst y = 2;\n";
    try hl.reparseEdit(12, 12, 13, new_src);

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(new_src.len), alloc, &spans);
    const k0 = spanAt(spans.items, 0).?; // first const
    const k1 = spanAt(spans.items, 14).?; // second const (next line)
    if (k0 != Style.keyword or k1 != Style.keyword) dumpSpans(new_src, spans.items);
    try std.testing.expectEqual(Style.keyword, k0);
    try std.testing.expectEqual(Style.keyword, k1);
}

test "repro: o-then-type-j keeps the line below highlighted" {
    const alloc = std.testing.allocator;
    // state after `o` on line 1 of "const x = 1;\nconst y = 2;\n": the new
    // empty line is inserted (full reparse), then typing 'j' is one more edit.
    const after_o = "const x = 1;\n\nconst y = 2;\n";
    var hl = try Highlighter.init(alloc, "zig");
    defer hl.deinit();
    try hl.reparse(after_o);
    var spans0 = std.ArrayList(Span).empty;
    defer spans0.deinit(alloc);
    try hl.spansInRange(0, @intCast(after_o.len), alloc, &spans0);
    try std.testing.expectEqual(Style.keyword, spanAt(spans0.items, 14).?); // "const y" after o

    // type 'j' on the new (empty) line: insert at byte 13 (its start)
    const after_j = "const x = 1;\nj\nconst y = 2;\n";
    try hl.reparseEdit(13, 13, 14, after_j);

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(alloc);
    try hl.spansInRange(0, @intCast(after_j.len), alloc, &spans);
    // "const y" now starts at byte 15; must still be keyword
    const k0 = spanAt(spans.items, 0).?;
    const k1 = spanAt(spans.items, 15).?;
    if (k0 != Style.keyword or k1 != Style.keyword) dumpSpans(after_j, spans.items);
    try std.testing.expectEqual(Style.keyword, k0);
    try std.testing.expectEqual(Style.keyword, k1);
}
