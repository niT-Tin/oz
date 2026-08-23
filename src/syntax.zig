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
    builtin,
};

/// One highlighted byte range. Sorted by `start`, non-overlapping.
pub const Span = struct {
    start: u32,
    end: u32, // exclusive
    style: Style,
};

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
    if (std.mem.eql(u8, base, "constructor")) return .constructor;
    if (std.mem.eql(u8, base, "variable")) return .variable;
    if (std.mem.eql(u8, base, "parameter")) return .parameter;
    if (std.mem.eql(u8, base, "punctuation")) return .punctuation;
    if (std.mem.eql(u8, base, "builtin")) return .builtin;
    return .default;
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
    /// new_end) on the current tree, then parse the new text. Only byte
    /// offsets matter to our consumers — the point fields are approximated
    /// (zero); tree-sitter needs them only for position metadata we never
    /// read.
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
        try self.reparse(text);
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
        var cursor = try treez.Query.Cursor.create();
        defer cursor.destroy();
        cursor.setByteRange(start_byte, end_byte);
        cursor.execute(self.query, tree.getRootNode());
        while (cursor.nextCapture()) |nc| {
            const match = nc[0];
            const cap = match.captures()[nc[1]];
            const style = captureStyle(self.query.getCaptureNameForId(cap.id));
            if (style == .default) continue;
            const s = cap.node.getStartByte();
            const e = cap.node.getEndByte();
            if (s == e) continue;
            try out.append(arena, .{ .start = s, .end = e, .style = style });
        }
        std.mem.sort(Span, out.items, {}, lessThan);
    }

    fn lessThan(_: void, a: Span, b: Span) bool {
        return a.start < b.start;
    }
};

// ---------------------------------------------------------------------------
// L1 tests (implemented alongside the real logic)
// ---------------------------------------------------------------------------

test "captureStyle: dotted names collapse to the base capture" {
    try std.testing.expect(captureStyle("@keyword") == .keyword);
    try std.testing.expect(captureStyle("@keyword.function") == .keyword);
    try std.testing.expect(captureStyle("@string.special") == .string);
    try std.testing.expect(captureStyle("@variable.builtin") == .variable);
    try std.testing.expect(captureStyle("@punctuation.bracket") == .punctuation);
    try std.testing.expect(captureStyle("@nonexistent") == .default);
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
