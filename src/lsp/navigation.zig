//! LSP semantic navigation (M2): request-param builders and response
//! parsers for hover / definition / references / signatureHelp. The client
//! is async (request → slot filled by drain); these helpers turn the JSON
//! responses into editor-consumable values.

const std = @import("std");
const types = @import("types.zig");

/// A location the editor can jump to.
pub const NavLocation = struct {
    uri: []u8, // owned (dupe of the response string)
    line: u32,
    character: u32,
};

/// Build `{textDocument:{uri}, position:{line,character}}` (all strings are
/// dupe'd heap copies — freeValue semantics; call json_rpc.freeValue after
/// encode). Returns an owned std.json.Value tree.
pub fn buildTextDocPositionParams(alloc: std.mem.Allocator, uri: []const u8, line: u32, character: u32) !std.json.Value {
    var td = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    errdefer td.deinit(alloc);
    const uri_copy = try alloc.dupe(u8, uri);
    errdefer alloc.free(uri_copy);
    try td.put(alloc, "uri", .{ .string = uri_copy });
    var pos = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    errdefer pos.deinit(alloc);
    try pos.put(alloc, "line", .{ .integer = line });
    try pos.put(alloc, "character", .{ .integer = character });
    var params = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    errdefer params.deinit(alloc);
    try params.put(alloc, "textDocument", .{ .object = td });
    try params.put(alloc, "position", .{ .object = pos });
    return .{ .object = params };
}

/// Free a params tree built by `buildTextDocPositionParams` (strings were
/// duped; keys are literals — deinit structure + free the uri dupe).
pub fn freeTextDocPositionParams(alloc: std.mem.Allocator, v: *std.json.Value) void {
    const params = &v.object;
    var td = params.get("textDocument").?;
    const uri = td.object.get("uri").?;
    alloc.free(uri.string);
    td.object.deinit(alloc);
    var pos = params.get("position").?;
    pos.object.deinit(alloc);
    // optional ReferenceParams context (buildReferencesParams)
    if (params.getPtr("context")) |ctx| ctx.object.deinit(alloc);
    params.deinit(alloc);
}

/// ReferenceParams: TextDocumentPositionParams + the REQUIRED `context`
/// (`includeDeclaration`). zls 0.16 treats a request missing `context` as
/// unparseable and EXITS — taking the whole LSP session (inlay hints,
/// diagnostics, nav) down with it.
pub fn buildReferencesParams(alloc: std.mem.Allocator, uri: []const u8, line: u32, character: u32) !std.json.Value {
    var v = try buildTextDocPositionParams(alloc, uri, line, character);
    errdefer freeTextDocPositionParams(alloc, &v);
    var ctx = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    errdefer ctx.deinit(alloc);
    try ctx.put(alloc, "includeDeclaration", .{ .bool = true });
    try v.object.put(alloc, "context", .{ .object = ctx });
    return v;
}

/// Markup kind of a hover payload. It is preserved from the server so the
/// renderer never interprets plaintext as Markdown (literal backticks, `*` or
/// `#` in plaintext must stay literal), and so Markdown fenced code can take
/// the tree-sitter highlighting path.
pub const HoverKind = enum { markdown, plaintext };

/// Parsed hover content: owned text plus how it must be rendered.
pub const HoverContent = struct {
    kind: HoverKind,
    text: []u8,

    pub fn deinit(self: *HoverContent, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

fn hoverKindOf(contents: std.json.Value) HoverKind {
    if (contents == .object) {
        if (contents.object.get("kind")) |k| {
            if (k == .string and std.mem.eql(u8, k.string, "markdown")) return .markdown;
        }
    }
    return .plaintext;
}

fn hoverPlain(alloc: std.mem.Allocator, text: []const u8) !?HoverContent {
    if (text.len == 0) return null;
    return .{ .kind = .plaintext, .text = try alloc.dupe(u8, text) };
}

fn appendHoverFence(out: *std.ArrayList(u8), alloc: std.mem.Allocator, language: []const u8, code: []const u8) !void {
    try out.appendSlice(alloc, "```");
    try out.appendSlice(alloc, language);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, code);
    try out.appendSlice(alloc, "\n```");
}

fn hoverFence(alloc: std.mem.Allocator, language: []const u8, code: []const u8) !?HoverContent {
    if (code.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try appendHoverFence(&out, alloc, language, code);
    return .{ .kind = .markdown, .text = try out.toOwnedSlice(alloc) };
}

/// MarkedString object: `{language, value}` keeps its language as a fenced
/// code block; `{kind, value}` is MarkupContent and keeps its kind.
fn parseHoverObject(alloc: std.mem.Allocator, contents: std.json.Value) !?HoverContent {
    if (contents.object.get("language")) |lang| {
        if (lang == .string) {
            const value = contents.object.get("value") orelse return null;
            if (value != .string) return null;
            return try hoverFence(alloc, lang.string, value.string);
        }
    }
    const value = contents.object.get("value") orelse return null;
    if (value != .string) return null;
    return try hoverPlainWithKind(alloc, contents, value.string);
}

fn hoverPlainWithKind(alloc: std.mem.Allocator, contents: std.json.Value, text: []const u8) !?HoverContent {
    if (text.len == 0) return null;
    return .{ .kind = hoverKindOf(contents), .text = try alloc.dupe(u8, text) };
}

/// MarkedString[]: strings and code-less objects concatenate as Markdown
/// prose; `{language, value}` entries become fenced blocks with that language
/// (an unknown language is preserved readably — the renderer falls back to the
/// buffer's own language for the fence).
fn parseHoverArray(alloc: std.mem.Allocator, items: []const std.json.Value) !?HoverContent {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (items) |item| {
        if (item == .string) {
            if (item.string.len == 0) continue;
            if (out.items.len > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, item.string);
        } else if (item == .object) {
            if (item.object.get("language")) |lang| {
                if (lang == .string) {
                    const value = item.object.get("value") orelse continue;
                    if (value != .string or value.string.len == 0) continue;
                    if (out.items.len > 0) try out.append(alloc, '\n');
                    try appendHoverFence(&out, alloc, lang.string, value.string);
                    continue;
                }
            }
            const value = item.object.get("value") orelse continue;
            if (value != .string or value.string.len == 0) continue;
            if (out.items.len > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, value.string);
        }
    }
    if (out.items.len == 0) return null;
    return .{ .kind = .markdown, .text = try out.toOwnedSlice(alloc) };
}

/// Parse a hover response (`contents` may be a MarkupContent object, a plain
/// string, a legacy MarkedString `{language, value}` or an array of those).
/// The Markdown/plaintext kind and legacy language information are preserved;
/// absent/unknown kinds degrade to plaintext and empty content is "nothing to
/// show" (null). The returned text is owned by the caller.
pub fn parseHover(alloc: std.mem.Allocator, result: std.json.Value) !?HoverContent {
    if (result != .object) return null;
    const contents = result.object.get("contents") orelse return null;
    return switch (contents) {
        .string => |s| try hoverPlain(alloc, s),
        .object => try parseHoverObject(alloc, contents),
        .array => |a| try parseHoverArray(alloc, a.items),
        else => null,
    };
}

/// Parse a definition/references response (Location | Location[] | null)
/// into an owned list. Empty on null/absent.
pub fn parseLocations(alloc: std.mem.Allocator, result: std.json.Value, out: *std.ArrayList(NavLocation)) !void {
    switch (result) {
        .null => return,
        .array => {
            for (result.array.items) |item| {
                try appendLocation(alloc, item, out);
            }
        },
        else => try appendLocation(alloc, result, out),
    }
}

fn appendLocation(alloc: std.mem.Allocator, loc: std.json.Value, out: *std.ArrayList(NavLocation)) !void {
    if (loc != .object) return;
    // Location: {uri, range}. LocationLink (definition/declaration responses):
    // {targetUri, targetSelectionRange, ...} — clangd/gopls often answer with
    // LocationLink[] and we must not silently drop them (gd/gD/gr came back
    // empty).
    const uri: ?[]const u8 = blk: {
        if (loc.object.get("uri")) |u| {
            if (u == .string) break :blk u.string;
        }
        if (loc.object.get("targetUri")) |u| {
            if (u == .string) break :blk u.string;
        }
        break :blk null;
    };
    const u = uri orelse return;
    const range = loc.object.get("range") orelse loc.object.get("targetSelectionRange") orelse return;
    if (range != .object) return;
    const start = range.object.get("start") orelse return;
    const line = intField(start, "line") orelse return;
    const character = intField(start, "character") orelse return;
    const uri_copy = try alloc.dupe(u8, u);
    errdefer alloc.free(uri_copy);
    try out.append(alloc, .{ .uri = uri_copy, .line = line, .character = character });
}

fn intField(v: std.json.Value, name: []const u8) ?u32 {
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        // @intCast panics (Debug) on values above u32 max — saturate by
        // returning null instead: an out-of-range position is treated as
        // invalid by the callers, never a crash.
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        .number_string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

/// A text edit: replace [start, end) with `new_text` (owned).
pub const TextEdit = struct {
    start: u32,
    end: u32,
    new_text: []u8, // owned
};

/// Parse a TextEdit[] response (formatting, rename changes) into `out`.
/// Each edit's range is {start:{line,character}, end:{line,character}} and
/// newText replaces that span. Caller frees each new_text.
pub fn parseTextEdits(alloc: std.mem.Allocator, result: std.json.Value, pt: anytype, out: *std.ArrayList(TextEdit)) !void {
    if (result != .array) return;
    for (result.array.items) |item| {
        if (item != .object) continue;
        const range = item.object.get("range") orelse continue;
        const new_text = item.object.get("newText") orelse continue;
        if (new_text != .string) continue;
        const start = rangeStart(range) orelse continue;
        const end = rangeEnd(range) orelse continue;
        const start_pos = offsetAt(pt, start) orelse continue;
        const end_pos = offsetAt(pt, end) orelse continue;
        const copy = try alloc.dupe(u8, new_text.string);
        errdefer alloc.free(copy);
        try out.append(alloc, .{ .start = start_pos, .end = end_pos, .new_text = copy });
    }
}

const Pos = struct { line: u32, character: u32 };

fn rangeStart(range: std.json.Value) ?Pos {
    const s = range.object.get("start") orelse return null;
    return posFrom(s);
}

fn rangeEnd(range: std.json.Value) ?Pos {
    const e = range.object.get("end") orelse return null;
    return posFrom(e);
}

fn posFrom(v: std.json.Value) ?Pos {
    if (v != .object) return null;
    const line = intField(v, "line") orelse return null;
    const character = intField(v, "character") orelse return null;
    return .{ .line = line, .character = character };
}

/// Convert a {line,character} position to a byte offset. The pt must expose
/// lineStart/lineLen/byteAt (buffer.PieceTable does).
/// LSP characters are UTF-16 code units, not bytes: walk the line's UTF-8
/// and count units (a 4-byte sequence is an astral code point = 2 units).
fn offsetAt(pt: anytype, pos: Pos) ?u32 {
    if (pos.line >= pt.lineCount()) return null;
    const start = pt.lineStart(pos.line);
    const len = pt.lineLen(pos.line);
    var units: u32 = 0;
    var i: u32 = 0;
    while (i < len and units < pos.character) {
        const b = pt.byteAt(start + i);
        const seq_len: u32 = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
        units += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }
    if (units != pos.character or i > len) return null; // past EOL or inside a surrogate pair
    return start + i;
}

/// Extract the line from a {line,character} position value (for outline).
pub fn posLine(v: std.json.Value) ?u32 {
    if (v != .object) return null;
    return intField(v, "line");
}

/// Extract the character from a {line,character} position value.
pub fn posCharacter(v: std.json.Value) ?u32 {
    if (v != .object) return null;
    return intField(v, "character");
}

/// Extract the first signature label from a signatureHelp response.
pub fn parseSignature(alloc: std.mem.Allocator, result: std.json.Value) !?[]u8 {
    if (result != .object) return null;
    const sigs = result.object.get("signatures") orelse return null;
    if (sigs != .array or sigs.array.items.len == 0) return null;
    const first = sigs.array.items[0];
    if (first != .object) return null;
    const label = first.object.get("label") orelse return null;
    if (label == .string) return @as(?[]u8, try alloc.dupe(u8, label.string));
    return null;
}

/// Documentation markup kind. The editor must not treat a plaintext value as
/// Markdown (stars/backticks stay literal); servers that return a string or
/// `{kind:"plaintext"}` get literal rendering.
pub const DocKind = enum { plaintext, markdown };

/// Per-item asynchronous completionItem/resolve state. A late result may only
/// update the item it was requested for.
pub const ResolveState = enum { none, loading, ready, empty, failed };

/// A completion candidate. The display label, the text accepted into the
/// buffer, and the client-side filter key are deliberately separate: servers
/// such as ZLS return `labelDetails` and a `filterText` that must not leak
/// into the inserted bytes or into a label-only match.
pub const CompletionItem = struct {
    /// CompletionItem.label (owned): what the menu shows.
    label: []u8,
    /// Insertion text (owned, optional). null means "same as label".
    insert_text: ?[]u8 = null,
    /// filterText (owned, optional). null means "filter by label".
    filter_text: ?[]u8 = null,
    /// CompletionItem.sortText (owned, optional): the server's PRESENTATION
    /// order for tied candidates. Deliberately excluded from item_id /
    /// selection_key — reordering must not change candidate identity.
    sort_text: ?[]u8 = null,
    /// LSP CompletionItemKind (0 = unknown / buffer-word fallback).
    kind: u8 = 0,
    /// labelDetails.detail (owned, optional): e.g. "(comptime T: type)".
    label_detail: ?[]u8 = null,
    /// labelDetails.description (owned, optional): e.g. "type" (never
    /// synthesized from kind or from the signature).
    label_description: ?[]u8 = null,
    /// CompletionItem.detail (owned, optional): full signature/header.
    detail: ?[]u8 = null,
    /// CompletionItem.documentation value (owned, optional).
    doc: ?[]u8 = null,
    doc_kind: DocKind = .plaintext,
    /// Semantic match key for preserving selection across responses. It is
    /// not a unique handle: resolve ownership also needs generation + index.
    item_id: u64 = 0,
    /// Cross-refresh match excluding the edit range, whose end usually
    /// follows the growing typed prefix. Used only when the match is unique.
    selection_key: u64 = 0,
    /// Raw `data` payload for completionItem/resolve (owned JSON text).
    data_json: ?[]u8 = null,
    deprecated: bool = false,
    /// Resolve bookkeeping (only meaningful for the selected item).
    resolve_requested: bool = false,
    resolve_state: ResolveState = .none,

    pub fn insertText(self: *const CompletionItem) []const u8 {
        return self.insert_text orelse self.label;
    }

    pub fn filterText(self: *const CompletionItem) []const u8 {
        return self.filter_text orelse self.label;
    }

    pub fn deinit(self: *CompletionItem, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        if (self.insert_text) |v| alloc.free(v);
        if (self.filter_text) |v| alloc.free(v);
        if (self.sort_text) |v| alloc.free(v);
        if (self.label_detail) |v| alloc.free(v);
        if (self.label_description) |v| alloc.free(v);
        if (self.detail) |v| alloc.free(v);
        if (self.doc) |v| alloc.free(v);
        if (self.data_json) |v| alloc.free(v);
    }
};

fn intOf(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn stringField(item: std.json.Value, name: []const u8) ?[]const u8 {
    if (item != .object) return null;
    const v = item.object.get(name) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Parse a documentation value: a plain string is literal; a MarkupContent
/// object carries its own kind. Unknown kinds degrade to plaintext instead of
/// being rendered as Markdown.
fn parseDocumentation(alloc: std.mem.Allocator, v: std.json.Value, kind: *DocKind) !?[]u8 {
    switch (v) {
        .string => |s| {
            kind.* = .plaintext;
            return try alloc.dupe(u8, s);
        },
        .object => |o| {
            const val = o.get("value") orelse return null;
            if (val != .string) return null;
            kind.* = .plaintext;
            if (o.get("kind")) |k| {
                if (k == .string and std.mem.eql(u8, k.string, "markdown")) kind.* = .markdown;
            }
            return try alloc.dupe(u8, val.string);
        },
        else => return null,
    }
}

const LabelDetails = struct { detail: ?[]u8 = null, description: ?[]u8 = null };

fn labelDetails(alloc: std.mem.Allocator, item: std.json.Value) !LabelDetails {
    var out = LabelDetails{};
    if (item != .object) return out;
    const ld = item.object.get("labelDetails") orelse return out;
    if (ld != .object) return out;
    errdefer {
        if (out.detail) |v| alloc.free(v);
        if (out.description) |v| alloc.free(v);
    }
    if (ld.object.get("detail")) |d| {
        if (d == .string) out.detail = try alloc.dupe(u8, d.string);
    }
    if (ld.object.get("description")) |d| {
        if (d == .string) out.description = try alloc.dupe(u8, d.string);
    }
    return out;
}

fn stableItemId(label: []const u8, insert_text: []const u8, detail: ?[]const u8, ld_detail: ?[]const u8, ld_desc: ?[]const u8, kind: u8, data: ?[]const u8, edit: ?[]const u8) u64 {
    var h = std.hash.Wyhash.init(0x6f7a2d31);
    h.update(label);
    h.update("\x00");
    h.update(insert_text);
    h.update("\x00");
    if (detail) |d| h.update(d);
    h.update("\x00");
    if (ld_detail) |d| h.update(d);
    h.update("\x00");
    if (ld_desc) |d| h.update(d);
    var kb: [1]u8 = .{kind};
    h.update(&kb);
    h.update("\x00");
    if (data) |d| h.update(d);
    h.update("\x00");
    if (edit) |e| h.update(e);
    return h.final();
}

test "navigation: equal completion labels retain data and edit identities" {
    const a = std.testing.allocator;
    const payload =
        \\[{"label":"duplicate","detail":"fn duplicate() void","data":{"id":"A"}},
        \\ {"label":"duplicate","detail":"fn duplicate() void","data":{"id":"B"}},
        \\ {"label":"duplicate","detail":"fn duplicate() void","data":{"id":"A"},"textEdit":{"newText":"duplicate","range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}}}},
        \\ {"label":"duplicate","detail":"fn duplicate() void","data":{"id":"A"},"textEdit":{"newText":"duplicate","range":{"start":{"line":0,"character":3},"end":{"line":0,"character":4}}}}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, payload, .{});
    defer parsed.deinit();
    var items = std.ArrayList(CompletionItem).empty;
    defer {
        for (items.items) |*item| item.deinit(a);
        items.deinit(a);
    }
    try parseCompletionItems(a, parsed.value, &items);
    try std.testing.expectEqual(@as(usize, 4), items.items.len);
    for (items.items, 0..) |item, i| {
        for (items.items[i + 1 ..]) |other| try std.testing.expect(item.item_id != other.item_id);
    }
}

fn parseOne(alloc: std.mem.Allocator, item: std.json.Value) !?CompletionItem {
    if (item != .object) return null;

    // Snippet candidates (insertTextFormat=2) embed ${n:...} placeholder
    // syntax this editor cannot expand; inserting verbatim corrupts text.
    // Keep the safe existing fallback: insert the plain label.
    const is_snippet: bool = blk: {
        const f = item.object.get("insertTextFormat") orelse break :blk false;
        const fv = intOf(f) orelse break :blk false;
        break :blk fv == 2;
    };

    const label_raw = stringField(item, "label");
    var insert_raw: ?[]const u8 = null;
    if (!is_snippet) {
        if (item.object.get("textEdit")) |te| {
            if (te == .object) {
                if (te.object.get("newText")) |nt| {
                    if (nt == .string) insert_raw = nt.string;
                }
            }
        }
        if (insert_raw == null) insert_raw = stringField(item, "insertText");
    }
    // A raw-array item with only textEdit still needs a display label.
    const label_src = label_raw orelse insert_raw orelse return null;
    if (label_src.len == 0) return null;

    var kind: u8 = 0;
    if (item.object.get("kind")) |k| {
        if (intOf(k)) |n| {
            if (n >= 1 and n <= 255) kind = @intCast(n);
        }
    }

    var detail: ?[]u8 = null;
    if (item.object.get("detail")) |d| {
        if (d == .string) detail = try alloc.dupe(u8, d.string);
    }
    errdefer if (detail) |d| alloc.free(d);

    var doc: ?[]u8 = null;
    var doc_kind: DocKind = .plaintext;
    if (item.object.get("documentation")) |d| {
        doc = try parseDocumentation(alloc, d, &doc_kind);
    }
    errdefer if (doc) |d| alloc.free(d);

    const ld = try labelDetails(alloc, item);
    errdefer {
        if (ld.detail) |d| alloc.free(d);
        if (ld.description) |d| alloc.free(d);
    }

    var insert_copy: ?[]u8 = null;
    // Only allocate when insertion differs from the label; the rest of the
    // editor asks insertText() and gets the label otherwise.
    if (insert_raw) |ins| {
        if (!std.mem.eql(u8, ins, label_src)) insert_copy = try alloc.dupe(u8, ins);
    }
    errdefer if (insert_copy) |v| alloc.free(v);

    var filter_copy: ?[]u8 = null;
    if (stringField(item, "filterText")) |f| {
        if (!std.mem.eql(u8, f, label_src)) filter_copy = try alloc.dupe(u8, f);
    }
    errdefer if (filter_copy) |v| alloc.free(v);

    // Presentation order only: never part of item_id/selection_key.
    var sort_copy: ?[]u8 = null;
    if (stringField(item, "sortText")) |st| sort_copy = try alloc.dupe(u8, st);
    errdefer if (sort_copy) |v| alloc.free(v);

    var data_json: ?[]u8 = null;
    if (item.object.get("data")) |data| {
        data_json = try std.json.Stringify.valueAlloc(alloc, data, .{});
    }
    errdefer if (data_json) |v| alloc.free(v);

    var deprecated = false;
    if (item.object.get("deprecated")) |d| {
        if (d == .bool) deprecated = d.bool;
    }
    if (item.object.get("tags")) |tags| {
        if (tags == .array) {
            for (tags.array.items) |tag| {
                if (intOf(tag)) |n| {
                    if (n == 1) deprecated = true;
                }
            }
        }
    }

    const label_copy = try alloc.dupe(u8, label_src);
    errdefer alloc.free(label_copy);

    // Preserve selection across refreshes without conflating equal-looking
    // items from different symbols/edits. Resolve authorization additionally
    // checks response generation + index; this hash is not a unique handle.
    const edit_json = if (item.object.get("textEdit")) |edit|
        try std.json.Stringify.valueAlloc(alloc, edit, .{})
    else
        null;
    defer if (edit_json) |v| alloc.free(v);
    const id = stableItemId(label_copy, if (insert_copy) |v| v else label_copy, detail, ld.detail, ld.description, kind, data_json, edit_json);
    const selection_key = stableItemId(label_copy, if (insert_copy) |v| v else label_copy, detail, ld.detail, ld.description, kind, data_json, null);
    return CompletionItem{
        .label = label_copy,
        .insert_text = insert_copy,
        .filter_text = filter_copy,
        .sort_text = sort_copy,
        .kind = kind,
        .label_detail = ld.detail,
        .label_description = ld.description,
        .detail = detail,
        .doc = doc,
        .doc_kind = doc_kind,
        .item_id = id,
        .selection_key = selection_key,
        .data_json = data_json,
        .deprecated = deprecated,
    };
}

/// Exact identities take priority; a changing replacement range may fall
/// back to a unique semantic match. Ambiguous duplicates explicitly reset
/// selection instead of silently choosing an equal-looking candidate.
pub fn completionSelection(items: []const CompletionItem, previous_id: u64, previous_key: u64) ?usize {
    return uniqueCompletionMatch(items, previous_id, "item_id") orelse
        uniqueCompletionMatch(items, previous_key, "selection_key");
}

fn uniqueCompletionMatch(items: []const CompletionItem, key: u64, comptime field: []const u8) ?usize {
    var found: ?usize = null;
    for (items, 0..) |item, i| {
        if (@field(item, field) != key) continue;
        if (found != null) return null;
        found = i;
    }
    return found;
}

// ---- stable completion ranking (typed-prefix match quality) ----

/// Match-quality tiers for the typed prefix: higher sorts first, 0 means the
/// candidate does not match. Exact (`filterText` == typed) beats a
/// case-insensitive exact match, which beats a prefix, which beats a
/// word-boundary substring, which beats an interior substring. Case
/// sensitivity breaks ties inside each tier. A prefix match always starts at
/// a word boundary (position 0), so the boundary preference is what orders
/// the substring tiers. Only `filterText` is used for matching (never the
/// label or insertion text).
const score_no_match: u32 = 0;
/// Empty typed prefix: every candidate matches; sortText + stable parse
/// order decide (used by trigger completions such as "b.").
const score_empty_prefix: u32 = 1;
const score_exact: u32 = 1000;
const score_exact_ci: u32 = 900;
const score_prefix: u32 = 800;
const score_prefix_ci: u32 = 700;
const score_boundary_substring: u32 = 600;
const score_boundary_substring_ci: u32 = 500;
const score_substring: u32 = 400;
const score_substring_ci: u32 = 300;

/// True when a match starting at `pos` begins a word: start of the candidate,
/// after an alphanumeric separator such as `_` or punctuation, or at a
/// camelCase hump (lowercase/digit followed by an uppercase ASCII letter).
/// Non-ASCII bytes count as letters (no fabricated boundary inside UTF-8).
fn isCompletionWordBoundary(haystack: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = haystack[pos - 1];
    const cur = haystack[pos];
    const prev_alnum = (prev >= 'a' and prev <= 'z') or
        (prev >= 'A' and prev <= 'Z') or
        (prev >= '0' and prev <= '9') or
        prev >= 0x80;
    if (!prev_alnum) return true; // '_' / punctuation / space start a word
    const prev_lower_or_digit = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9');
    return prev_lower_or_digit and cur >= 'A' and cur <= 'Z';
}

/// Quality of `typed` against the candidate's `filterText` (label when the
/// server omitted filterText). 0 = no match. Pure and allocation-free; the
/// order is the documented ranking contract.
pub fn completionMatchScore(typed: []const u8, item: *const CompletionItem) u32 {
    if (typed.len == 0) return score_empty_prefix;
    const hay = item.filterText();
    if (typed.len > hay.len) return score_no_match;
    if (std.mem.eql(u8, hay, typed)) return score_exact;
    if (std.ascii.eqlIgnoreCase(hay, typed)) return score_exact_ci;
    if (std.mem.startsWith(u8, hay, typed)) return score_prefix;
    if (std.ascii.startsWithIgnoreCase(hay, typed)) return score_prefix_ci;

    // Substring: prefer a match beginning at a word boundary, and prefer a
    // case-sensitive match over a case-insensitive one at the same level.
    var cs_boundary = false;
    var ci_boundary = false;
    var cs_any = false;
    var ci_any = false;
    var i: usize = 0;
    while (i + typed.len <= hay.len) : (i += 1) {
        const boundary = isCompletionWordBoundary(hay, i);
        if (std.mem.eql(u8, hay[i .. i + typed.len], typed)) {
            cs_any = true;
            if (boundary) {
                cs_boundary = true;
                break; // best possible substring tier; no need to scan on
            }
        } else if (std.ascii.eqlIgnoreCase(hay[i .. i + typed.len], typed)) {
            ci_any = true;
            if (boundary) ci_boundary = true;
        }
    }
    if (cs_boundary) return score_boundary_substring;
    if (ci_boundary) return score_boundary_substring_ci;
    if (cs_any) return score_substring;
    if (ci_any) return score_substring_ci;
    return score_no_match;
}

fn sortTextOrder(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    if (a) |av| {
        if (b) |bv| return std.mem.order(u8, av, bv);
        return .lt; // a present sortText sorts before an absent one
    }
    if (b != null) return .gt;
    return .eq;
}

/// One sort entry: the match score is computed ONCE per candidate. The old
/// insertion-sort implementation recomputed it for every comparison, which is
/// O(n²) and froze the UI on servers that return a full unfiltered candidate
/// set (zls). `index` is the original parse index and is part of the total
/// order, so the result does not depend on the sort algorithm's stability.
const CompletionSortEntry = struct {
    score: u32,
    sort_text: ?[]const u8,
    index: usize,
};

/// Total order: match quality desc, server sortText (present before absent,
/// lexicographic ascending), then original parse index ascending.
fn completionSortEntryLessThan(_: void, a: CompletionSortEntry, b: CompletionSortEntry) bool {
    if (a.score != b.score) return a.score > b.score;
    const ord = sortTextOrder(a.sort_text, b.sort_text);
    if (ord != .eq) return ord == .lt;
    return a.index < b.index;
}

/// Stable-order in-place sort of completion candidates by match quality.
/// O(n log n) with O(n) scratch: one score per item, then a total-order sort
/// (score, sortText, original index) — equal candidates keep their original
/// parse/caller order (local buffer-word frequency order, server order for
/// equal sortText) because the original index is the final tiebreaker, not
/// because the algorithm happens to be stable. Must run AFTER filtering and
/// BEFORE display/selection/truncation. On allocation failure the caller's
/// order is left untouched (server order) rather than freezing the editor.
pub fn sortCompletionItems(alloc: std.mem.Allocator, items: []CompletionItem, typed: []const u8) void {
    if (items.len < 2) return;
    const entries = alloc.alloc(CompletionSortEntry, items.len) catch return;
    defer alloc.free(entries);
    for (items, 0..) |*it, i| {
        entries[i] = .{
            .score = completionMatchScore(typed, it),
            .sort_text = it.sort_text,
            .index = i,
        };
    }
    std.mem.sort(CompletionSortEntry, entries, {}, completionSortEntryLessThan);
    // Apply the sorted permutation. A second O(n) array keeps the permutation
    // application trivially correct; sort_text slices are owned by `items` and
    // moving items by value does not invalidate them.
    const sorted = alloc.alloc(CompletionItem, items.len) catch return;
    defer alloc.free(sorted);
    for (entries, 0..) |entry, i| sorted[i] = items[entry.index];
    @memcpy(items, sorted);
}

/// Parse a textDocument/completion response (CompletionList | CompletionItem[])
/// into owned items appended to `out`. Display, insertion and filtering are
/// separate fields; a malformed entry is skipped rather than aborting the
/// whole list.
pub fn parseCompletionItems(alloc: std.mem.Allocator, result: std.json.Value, out: *std.ArrayList(CompletionItem)) !void {
    const items: std.json.Value = if (result == .object)
        (result.object.get("items") orelse return)
    else
        result;
    if (items != .array) return;
    for (items.array.items) |raw| {
        const parsed = try parseOne(alloc, raw);
        if (parsed) |it| {
            errdefer {
                var tmp = it;
                tmp.deinit(alloc);
            }
            try out.append(alloc, it);
        }
    }
}

/// Fields a completionItem/resolve response may refine. Ownership: strings
/// are allocated with `alloc`.
pub const ResolvedCompletion = struct {
    detail: ?[]u8 = null,
    doc: ?[]u8 = null,
    doc_kind: DocKind = .plaintext,
    label_detail: ?[]u8 = null,
    label_description: ?[]u8 = null,

    pub fn deinit(self: *ResolvedCompletion, alloc: std.mem.Allocator) void {
        if (self.detail) |v| alloc.free(v);
        if (self.doc) |v| alloc.free(v);
        if (self.label_detail) |v| alloc.free(v);
        if (self.label_description) |v| alloc.free(v);
    }
};

pub fn parseCompletionResolve(alloc: std.mem.Allocator, result: std.json.Value) !ResolvedCompletion {
    var out = ResolvedCompletion{};
    if (result != .object) return out;
    errdefer out.deinit(alloc);
    if (result.object.get("detail")) |d| {
        if (d == .string) out.detail = try alloc.dupe(u8, d.string);
    }
    if (result.object.get("documentation")) |d| {
        out.doc = try parseDocumentation(alloc, d, &out.doc_kind);
    }
    const ld = try labelDetails(alloc, result);
    out.label_detail = ld.detail;
    out.label_description = ld.description;
    return out;
}

test "navigation: textDocument/position params round-trip" {
    const alloc = std.testing.allocator;
    var v = try buildTextDocPositionParams(alloc, "file:///a.zig", 3, 7);
    defer freeTextDocPositionParams(alloc, &v);
    const td = v.object.get("textDocument").?;
    try std.testing.expectEqualStrings("file:///a.zig", td.object.get("uri").?.string);
    const pos = v.object.get("position").?;
    try std.testing.expectEqual(@as(i64, 3), pos.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 7), pos.object.get("character").?.integer);
}

test "navigation: references params carry the mandatory context" {
    const alloc = std.testing.allocator;
    // ReferenceParams.context is REQUIRED by the spec; zls 0.16 exits on its
    // absence, killing the whole session.
    var v = try buildReferencesParams(alloc, "file:///a.zig", 3, 7);
    defer freeTextDocPositionParams(alloc, &v);
    const ctx = v.object.get("context").?;
    try std.testing.expect(ctx.object.get("includeDeclaration").?.bool);
    const pos = v.object.get("position").?;
    try std.testing.expectEqual(@as(i64, 3), pos.object.get("line").?.integer);
}

fn expectHover(alloc: std.mem.Allocator, payload: []const u8, want_kind: HoverKind, want_text: []const u8) !void {
    var p = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    defer p.deinit();
    var hover = (try parseHover(alloc, p.value)) orelse return error.TestUnexpectedResult;
    defer hover.deinit(alloc);
    try std.testing.expectEqual(want_kind, hover.kind);
    try std.testing.expectEqualStrings(want_text, hover.text);
}

fn expectNoHover(alloc: std.mem.Allocator, payload: []const u8) !void {
    var p = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    defer p.deinit();
    if (try parseHover(alloc, p.value)) |hover_value| {
        var hover = hover_value;
        hover.deinit(alloc);
        return error.TestUnexpectedResult;
    }
}

test "hover content: MarkupContent keeps markdown, plaintext and unknown kinds" {
    const alloc = std.testing.allocator;
    try expectHover(alloc, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"**doc** **bold**\"}}", .markdown, "**doc** **bold**");
    try expectHover(alloc, "{\"contents\":{\"kind\":\"plaintext\",\"value\":\"**not markdown**\"}}", .plaintext, "**not markdown**");
    // Unknown kind must degrade to plaintext instead of being rendered as
    // Markdown; absent kind is plaintext per MarkupContent semantics.
    try expectHover(alloc, "{\"contents\":{\"kind\":\"weird/lang\",\"value\":\"a * b\"}}", .plaintext, "a * b");
    try expectHover(alloc, "{\"contents\":{\"value\":\"no kind given\"}}", .plaintext, "no kind given");
}

test "hover content: plain string is plaintext; empty and null contents show nothing" {
    const alloc = std.testing.allocator;
    try expectHover(alloc, "{\"contents\":\"plain hover\"}", .plaintext, "plain hover");
    try expectHover(alloc, "{\"contents\":{\"kind\":\"plaintext\",\"value\":\"use ``` fences literally\"}}", .plaintext, "use ``` fences literally");
    // Empty content is "nothing to show" for every shape.
    try expectNoHover(alloc, "{\"contents\":{\"kind\":\"plaintext\",\"value\":\"\"}}");
    try expectNoHover(alloc, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"\"}}");
    try expectNoHover(alloc, "{\"contents\":\"\"}");
    try expectNoHover(alloc, "{\"contents\":[]}");
    try expectNoHover(alloc, "{\"contents\":null}");
    try expectNoHover(alloc, "{}");
    try expectNoHover(alloc, "null");
}

test "hover content: legacy MarkedString language object becomes a fenced block" {
    const alloc = std.testing.allocator;
    try expectHover(alloc,
        "{\"contents\":{\"language\":\"zig\",\"value\":\"const x = 1;\"}}",
        .markdown, "```zig\nconst x = 1;\n```");
    // Unknown fence language is preserved readably (the renderer falls back
    // to the buffer's own language for an unknown fence).
    try expectHover(alloc,
        "{\"contents\":{\"language\":\"notalang\",\"value\":\"q\"}}",
        .markdown, "```notalang\nq\n```");
    try expectHover(alloc,
        "{\"contents\":{\"language\":\"\",\"value\":\"q\"}}",
        .markdown, "```\nq\n```");
}

test "hover content: MarkedString array mixes code fences and prose" {
    const alloc = std.testing.allocator;
    try expectHover(alloc,
        "{\"contents\":[{\"language\":\"zig\",\"value\":\"const x = 1;\"},\"plain prose\",{\"language\":\"c\",\"value\":\"int y;\"}]}",
        .markdown, "```zig\nconst x = 1;\n```\nplain prose\n```c\nint y;\n```");
    // A code-only array still keeps each language in its own fence.
    try expectHover(alloc,
        "{\"contents\":[{\"language\":\"zig\",\"value\":\"a\"},{\"language\":\"zig\",\"value\":\"b\"}]}",
        .markdown, "```zig\na\n```\n```zig\nb\n```");
}

test "navigation: locations from single and array responses" {
    const alloc = std.testing.allocator;
    const j1 = "{\"uri\":\"file:///a.zig\",\"range\":{\"start\":{\"line\":5,\"character\":2},\"end\":{\"line\":5,\"character\":8}}}";
    var p1 = try std.json.parseFromSlice(std.json.Value, alloc, j1, .{ .allocate = .alloc_always });
    defer p1.deinit();
    var out1 = std.ArrayList(NavLocation).empty;
    defer {
        for (out1.items) |*l| alloc.free(l.uri);
        out1.deinit(alloc);
    }
    try parseLocations(alloc, p1.value, &out1);
    try std.testing.expectEqual(@as(usize, 1), out1.items.len);
    try std.testing.expectEqualStrings("file:///a.zig", out1.items[0].uri);
    try std.testing.expectEqual(@as(u32, 5), out1.items[0].line);

    const j2 = "{\"contents\":[]}"; // not a location → empty
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, j2, .{ .allocate = .alloc_always });
    defer p2.deinit();
    var out2 = std.ArrayList(NavLocation).empty;
    defer out2.deinit(alloc);
    try parseLocations(alloc, p2.value, &out2);
    try std.testing.expectEqual(@as(usize, 0), out2.items.len);
}

test "navigation: signature label extraction" {
    const alloc = std.testing.allocator;
    const j = "{\"signatures\":[{\"label\":\"foo(x: i32)\"}],\"activeSignature\":0}";
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    const s = (try parseSignature(alloc, p.value)).?;
    defer alloc.free(s);
    try std.testing.expectEqualStrings("foo(x: i32)", s);
}

test "navigation: text edits parse and map to offsets" {
    const alloc = std.testing.allocator;
    const buffer = @import("../buffer/root.zig");
    var pt = try buffer.PieceTable.init(alloc, "aaa\nbbb\nccc");
    defer pt.deinit();
    // replace line 1 (bbb) with "BBB"
    const j = "[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}},\"newText\":\"BBB\"}]";
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    var out = std.ArrayList(TextEdit).empty;
    defer {
        for (out.items) |*e| alloc.free(e.new_text);
        out.deinit(alloc);
    }
    try parseTextEdits(alloc, p.value, &pt, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u32, 4), out.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), out.items[0].end);
    try std.testing.expectEqualStrings("BBB", out.items[0].new_text);
}

test "navigation: text edits map UTF-16 code units to byte offsets" {
    const alloc = std.testing.allocator;
    const buffer = @import("../buffer/root.zig");
    // "aé😀b\nccc": é = 2 UTF-8 bytes / 1 UTF-16 unit, 😀 = 4 bytes / 2 units.
    // LSP character 2..4 (the 😀) is byte range 3..7.
    var pt = try buffer.PieceTable.init(alloc, "aé😀b\nccc");
    defer pt.deinit();
    const j = "[{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":4}},\"newText\":\"X\"}," ++
        "{\"range\":{\"start\":{\"line\":1,\"character\":1},\"end\":{\"line\":1,\"character\":3}},\"newText\":\"YY\"}]";
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    var out = std.ArrayList(TextEdit).empty;
    defer {
        for (out.items) |*e| alloc.free(e.new_text);
        out.deinit(alloc);
    }
    try parseTextEdits(alloc, p.value, &pt, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 3), out.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), out.items[0].end);
    try std.testing.expectEqualStrings("X", out.items[0].new_text);
    try std.testing.expectEqual(@as(u32, 10), out.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), out.items[1].end);
}

test "navigation: completion items from CompletionList and raw array" {
    const alloc = std.testing.allocator;
    // CompletionList: {items:[{label,kind},{textEdit:{newText}}]}
    const j1 = "{\"items\":[{\"label\":\"alpha\",\"kind\":5},{\"label\":\"beta\",\"insertText\":\"betaFn\"}]}";
    var p1 = try std.json.parseFromSlice(std.json.Value, alloc, j1, .{ .allocate = .alloc_always });
    defer p1.deinit();
    var out1 = std.ArrayList(CompletionItem).empty;
    defer {
        for (out1.items) |*it| it.deinit(alloc);
        out1.deinit(alloc);
    }
    try parseCompletionItems(alloc, p1.value, &out1);
    try std.testing.expectEqual(@as(usize, 2), out1.items.len);
    try std.testing.expectEqualStrings("alpha", out1.items[0].label);
    try std.testing.expectEqualStrings("alpha", out1.items[0].insertText());
    try std.testing.expectEqual(@as(u8, 5), out1.items[0].kind); // Field
    // Display and insertion are separate: insertText must never replace the
    // label in the menu, and label must never be accepted when insertText is
    // the server-provided insertion.
    try std.testing.expectEqualStrings("beta", out1.items[1].label);
    try std.testing.expectEqualStrings("betaFn", out1.items[1].insertText());
    try std.testing.expectEqual(@as(u8, 0), out1.items[1].kind); // no kind → 0

    // raw array form
    const j2 = "[{\"label\":\"x\"},{\"textEdit\":{\"newText\":\"y\"}}]";
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, j2, .{ .allocate = .alloc_always });
    defer p2.deinit();
    var out2 = std.ArrayList(CompletionItem).empty;
    defer {
        for (out2.items) |*it| it.deinit(alloc);
        out2.deinit(alloc);
    }
    try parseCompletionItems(alloc, p2.value, &out2);
    try std.testing.expectEqual(@as(usize, 2), out2.items.len);
    try std.testing.expectEqualStrings("x", out2.items[0].label);
    try std.testing.expectEqualStrings("y", out2.items[1].label);
    try std.testing.expectEqualStrings("y", out2.items[1].insertText());
}

test "navigation: completion detail and documentation are parsed" {
    const alloc = std.testing.allocator;
    const j = "{\"items\":[{\"label\":\"alpha\",\"kind\":3,\"detail\":\"fn() void\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"**docs**\"}},{\"label\":\"beta\",\"documentation\":\"plain docs\"}]}";
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    var out = std.ArrayList(CompletionItem).empty;
    defer {
        for (out.items) |*it| it.deinit(alloc);
        out.deinit(alloc);
    }
    try parseCompletionItems(alloc, p.value, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("fn() void", out.items[0].detail.?);
    try std.testing.expectEqualStrings("**docs**", out.items[0].doc.?);
    try std.testing.expect(out.items[1].detail == null);
    try std.testing.expectEqualStrings("plain docs", out.items[1].doc.?);
}

test "navigation: snippet completion items degrade to their label" {
    const alloc = std.testing.allocator;
    // insertTextFormat=2 (Snippet): the newText embeds ${n:...} placeholders
    // this editor can't expand — the accept must insert the plain label
    // instead, or the text gets corrupted and the cursor stranded mid-word.
    const j = "{\"items\":[{\"label\":\"standardTargetOptions\",\"insertTextFormat\":2,\"textEdit\":{\"newText\":\"standardTargetOptions(${1:args: StandardTargetOptionsArgs})\"}},{\"label\":\"plain\",\"insertTextFormat\":2,\"insertText\":\"plain(${1:x})\"}]}";
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    var out = std.ArrayList(CompletionItem).empty;
    defer {
        for (out.items) |*it| it.deinit(alloc);
        out.deinit(alloc);
    }
    try parseCompletionItems(alloc, p.value, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // snippet with textEdit: label wins over the placeholder-laden newText
    try std.testing.expectEqualStrings("standardTargetOptions", out.items[0].label);
    // snippet without textEdit: label wins over insertText too
    try std.testing.expectEqualStrings("plain", out.items[1].label);
}

test "navigation: labelDetails, filterText, doc kind and stable identity are separate" {
    const alloc = std.testing.allocator;
    const j =
        \\{"items":[
        \\ {"label":"ArrayList","insertText":"ArrayList","filterText":"AL","kind":22,
        \\  "labelDetails":{"detail":"(comptime T: type)","description":"type"},
        \\  "detail":"fn (comptime T: type) type",
        \\  "documentation":{"kind":"markdown","value":"**body**"},
        \\  "data":{"kind":22}},
        \\ {"label":"ArrayList","insertText":"ArrayList","kind":22,
        \\  "labelDetails":{"detail":"(comptime E)","description":"type"}},
        \\ {"label":"plain","kind":9,"tags":[1],"documentation":"literal *stars*"}
        \\]}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, alloc, j, .{ .allocate = .alloc_always });
    defer p.deinit();
    var out = std.ArrayList(CompletionItem).empty;
    defer {
        for (out.items) |*it| it.deinit(alloc);
        out.deinit(alloc);
    }
    try parseCompletionItems(alloc, p.value, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);

    const a = &out.items[0];
    try std.testing.expectEqualStrings("ArrayList", a.label);
    try std.testing.expectEqualStrings("ArrayList", a.insertText());
    try std.testing.expectEqualStrings("AL", a.filterText());
    try std.testing.expectEqualStrings("(comptime T: type)", a.label_detail.?);
    try std.testing.expectEqualStrings("type", a.label_description.?);
    try std.testing.expectEqual(DocKind.markdown, a.doc_kind);
    try std.testing.expectEqualStrings("**body**", a.doc.?);
    try std.testing.expect(a.data_json != null);
    try std.testing.expect(a.item_id != 0);
    // Same label, different signature → distinct identity.
    try std.testing.expect(a.item_id != out.items[1].item_id);

    const plain = &out.items[2];
    try std.testing.expectEqual(DocKind.plaintext, plain.doc_kind);
    try std.testing.expectEqualStrings("literal *stars*", plain.doc.?);
    try std.testing.expect(plain.deprecated);

    // Resolve refines fields without changing the item's identity.
    const before = a.item_id;
    const rj = "{\"detail\":\"resolved fn\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"RESOLVED\"},\"labelDetails\":{\"detail\":\"(T)\",\"description\":\"struct\"}}";
    var rp = try std.json.parseFromSlice(std.json.Value, alloc, rj, .{ .allocate = .alloc_always });
    defer rp.deinit();
    var resolved = try parseCompletionResolve(alloc, rp.value);
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(before, a.item_id);
    try std.testing.expectEqualStrings("resolved fn", resolved.detail.?);
    try std.testing.expectEqualStrings("RESOLVED", resolved.doc.?);
    try std.testing.expectEqual(DocKind.markdown, resolved.doc_kind);
    try std.testing.expectEqualStrings("(T)", resolved.label_detail.?);
    try std.testing.expectEqualStrings("struct", resolved.label_description.?);
}

test "navigation: selected completion survives a growing replacement range without merging duplicates" {
    const a = std.testing.allocator;
    const payload =
        \\[{"label":"dup","data":{"id":"A"},"textEdit":{"newText":"dup","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}},
        \\ {"label":"dup","data":{"id":"B"},"textEdit":{"newText":"dup","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}}]
    ;
    const longer = try std.mem.replaceOwned(u8, a, payload, "\"character\":2", "\"character\":3");
    defer a.free(longer);
    var before_json = try std.json.parseFromSlice(std.json.Value, a, payload, .{});
    defer before_json.deinit();
    var after_json = try std.json.parseFromSlice(std.json.Value, a, longer, .{});
    defer after_json.deinit();
    var before = std.ArrayList(CompletionItem).empty;
    var after = std.ArrayList(CompletionItem).empty;
    defer {
        for (before.items) |*it| it.deinit(a);
        for (after.items) |*it| it.deinit(a);
        before.deinit(a);
        after.deinit(a);
    }
    try parseCompletionItems(a, before_json.value, &before);
    try parseCompletionItems(a, after_json.value, &after);
    try std.testing.expect(before.items[1].item_id != after.items[1].item_id);
    try std.testing.expectEqual(@as(?usize, 1), completionSelection(after.items, before.items[1].item_id, before.items[1].selection_key));
    // If neither exact nor semantic identity is unique, don't claim a match.
    after.items[0].item_id = after.items[1].item_id;
    after.items[0].selection_key = after.items[1].selection_key;
    try std.testing.expect(completionSelection(after.items, before.items[1].item_id, before.items[1].selection_key) == null);
}

// ==================== completion ranking/ordering tests =====================

const TestItems = struct {
    parsed: std.json.Parsed(std.json.Value),
    items: std.ArrayList(CompletionItem),

    fn deinit(self: *TestItems, alloc: std.mem.Allocator) void {
        for (self.items.items) |*it| it.deinit(alloc);
        self.items.deinit(alloc);
        self.parsed.deinit();
    }
};

fn testItems(alloc: std.mem.Allocator, payload: []const u8) !TestItems {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    var items = std.ArrayList(CompletionItem).empty;
    errdefer {
        for (items.items) |*it| it.deinit(alloc);
        items.deinit(alloc);
    }
    try parseCompletionItems(alloc, parsed.value, &items);
    return .{ .parsed = parsed, .items = items };
}

fn expectLabels(items: []const CompletionItem, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, items[i].label);
    }
}

test "completion ranking: reported order count_lines/read_lines/line/inline puts exact line first" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"count_lines","data":{"id":"count"}},
        \\ {"label":"read_lines","data":{"id":"read"}},
        \\ {"label":"line","data":{"id":"line"}},
        \\ {"label":"inline","data":{"id":"inline"}}]
    );
    defer t.deinit(alloc);

    const exact = completionMatchScore("line", &t.items.items[2]);
    const boundary = completionMatchScore("line", &t.items.items[0]);
    const middle = completionMatchScore("line", &t.items.items[3]);
    try std.testing.expect(exact > boundary);
    try std.testing.expect(boundary > middle);
    try std.testing.expectEqual(@as(u32, 0), completionMatchScore("zzz", &t.items.items[2]));

    sortCompletionItems(alloc, t.items.items, "line");
    try expectLabels(t.items.items, &.{ "line", "count_lines", "read_lines", "inline" });
}

test "completion ranking: case variants order exact, case-insensitive exact, prefix, substring" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"Line"},
        \\ {"label":"line_item"},
        \\ {"label":"LINE"},
        \\ {"label":"line"},
        \\ {"label":"inline"}]
    );
    defer t.deinit(alloc);
    const s_line = completionMatchScore("line", &t.items.items[3]); // exact
    const s_cap = completionMatchScore("line", &t.items.items[0]); // case-insensitive exact
    const s_upper = completionMatchScore("line", &t.items.items[2]); // case-insensitive exact
    const s_prefix = completionMatchScore("line", &t.items.items[1]); // prefix
    const s_mid = completionMatchScore("line", &t.items.items[4]); // substring
    try std.testing.expect(s_line > s_cap);
    try std.testing.expectEqual(s_cap, s_upper);
    try std.testing.expect(s_cap > s_prefix);
    try std.testing.expect(s_prefix > s_mid);

    sortCompletionItems(alloc, t.items.items, "line");
    try expectLabels(t.items.items, &.{ "line", "Line", "LINE", "line_item", "inline" });
}

test "completion ranking: word-boundary and camelCase substring beat a plain middle match" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"inline"},
        \\ {"label":"outline"},
        \\ {"label":"count_lines"},
        \\ {"label":"read_lines"},
        \\ {"label":"getLine"}]
    );
    defer t.deinit(alloc);
    try std.testing.expect(completionMatchScore("line", &t.items.items[2]) >
        completionMatchScore("line", &t.items.items[0]));
    try std.testing.expect(completionMatchScore("line", &t.items.items[4]) >
        completionMatchScore("line", &t.items.items[1]));

    sortCompletionItems(alloc, t.items.items, "line");
    // Boundary matches (snake_case '_' and camelCase case change) rank above
    // plain interior matches; equal scores keep the stable parse order.
    try expectLabels(t.items.items, &.{ "count_lines", "read_lines", "getLine", "inline", "outline" });
}

test "completion ranking: sortText breaks ties (present before absent, ascending)" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"ab_one","sortText":"02"},
        \\ {"label":"ab_three"},
        \\ {"label":"ab_two","sortText":"01"},
        \\ {"label":"ab_four","sortText":"01"}]
    );
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("02", t.items.items[0].sort_text.?);
    try std.testing.expect(t.items.items[1].sort_text == null);

    sortCompletionItems(alloc, t.items.items, "ab");
    try expectLabels(t.items.items, &.{ "ab_two", "ab_four", "ab_one", "ab_three" });
}

test "completion ranking: filterText drives matching, label displays, insertText inserts" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"display_label","filterText":"line","insertText":"inserted_line"},
        \\ {"label":"line","filterText":"nope"}]
    );
    defer t.deinit(alloc);
    const filtered = &t.items.items[0];
    try std.testing.expectEqualStrings("display_label", filtered.label);
    try std.testing.expectEqualStrings("line", filtered.filterText());
    try std.testing.expectEqualStrings("inserted_line", filtered.insertText());
    // The label alone would not match "line"; filterText is what is scored.
    try std.testing.expectEqual(@as(u32, 0), completionMatchScore("line", &t.items.items[1]));
    try std.testing.expect(completionMatchScore("line", filtered) > 0);

    sortCompletionItems(alloc, t.items.items, "line");
    try std.testing.expectEqualStrings("display_label", t.items.items[0].label);
    try std.testing.expectEqualStrings("inserted_line", t.items.items[0].insertText());
}

test "completion ranking: sortText is presentation order, not identity" {
    const alloc = std.testing.allocator;
    var a = try testItems(alloc, "[{\"label\":\"alpha\",\"kind\":3,\"sortText\":\"05\",\"data\":{\"id\":1}}]");
    defer a.deinit(alloc);
    var b = try testItems(alloc, "[{\"label\":\"alpha\",\"kind\":3,\"sortText\":\"99\",\"data\":{\"id\":1}}]");
    defer b.deinit(alloc);
    try std.testing.expectEqualStrings("05", a.items.items[0].sort_text.?);
    try std.testing.expectEqualStrings("99", b.items.items[0].sort_text.?);
    // item_id/selection_key must not hash the presentation order.
    try std.testing.expectEqual(a.items.items[0].item_id, b.items.items[0].item_id);
    try std.testing.expectEqual(a.items.items[0].selection_key, b.items.items[0].selection_key);
}

test "completion ranking: duplicate labels with different data/textEdit keep their identity" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"dup","data":{"id":"A"},"sortText":"02",
        \\  "textEdit":{"newText":"dup","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}},
        \\ {"label":"dup","data":{"id":"B"},"sortText":"01",
        \\  "textEdit":{"newText":"dup","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}}]
    );
    defer t.deinit(alloc);
    const id_a = t.items.items[0].item_id;
    const key_a = t.items.items[0].selection_key;
    const id_b = t.items.items[1].item_id;
    try std.testing.expect(id_a != id_b);

    sortCompletionItems(alloc, t.items.items, "dup");
    // Both are exact matches; sortText moves B before A without swapping data.
    try std.testing.expectEqual(id_b, t.items.items[0].item_id);
    try std.testing.expectEqual(id_a, t.items.items[1].item_id);
    try std.testing.expectEqual(@as(?usize, 0), completionSelection(t.items.items, id_b, t.items.items[0].selection_key));
    // The selection identity follows A after it moved to index 1.
    try std.testing.expectEqual(@as(?usize, 1), completionSelection(t.items.items, id_a, key_a));
}

test "completion ranking: snippet fallback still inserts the label after sorting" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"snip","insertTextFormat":2,"insertText":"snip(${1:x})"},
        \\ {"label":"snip_other"}]
    );
    defer t.deinit(alloc);
    sortCompletionItems(alloc, t.items.items, "snip");
    try expectLabels(t.items.items, &.{ "snip", "snip_other" });
    try std.testing.expectEqualStrings("snip", t.items.items[0].insertText());
}

test "completion ranking: stable order preserves local frequency ordering" {
    // Local buffer-word completion builds this list already sorted by
    // frequency; all entries are case-sensitive prefix matches of "g", so
    // equal scores + equal (absent) sortText must keep the caller's order.
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"gamma"},{"label":"gamma2"},{"label":"gammas"}]
    );
    defer t.deinit(alloc);
    const s = completionMatchScore("g", &t.items.items[0]);
    try std.testing.expect(s > 0);
    try std.testing.expectEqual(s, completionMatchScore("g", &t.items.items[1]));
    try std.testing.expectEqual(s, completionMatchScore("g", &t.items.items[2]));
    sortCompletionItems(alloc, t.items.items, "g");
    try expectLabels(t.items.items, &.{ "gamma", "gamma2", "gammas" });
}

test "completion ranking: first open is the best item and a refresh keeps the selection identity" {
    const alloc = std.testing.allocator;
    var t = try testItems(alloc,
        \\[{"label":"count_lines","data":{"id":"count"}},
        \\ {"label":"read_lines","data":{"id":"read"}},
        \\ {"label":"line","data":{"id":"line"}},
        \\ {"label":"inline","data":{"id":"inline"}}]
    );
    defer t.deinit(alloc);
    // First open: no previous selection -> index 0 after sorting is the best.
    sortCompletionItems(alloc, t.items.items, "line");
    try std.testing.expectEqualStrings("line", t.items.items[0].label);
    // The user had selected count_lines before a refresh; its identity must
    // survive the reorder (the list is sorted first, then matched by id).
    const want_id = t.items.items[1].item_id; // count_lines
    const want_key = t.items.items[1].selection_key;
    try std.testing.expectEqual(@as(?usize, 1), completionSelection(t.items.items, want_id, want_key));

    // A refresh with a different server order must not reset a manual
    // selection to "best": same identities, reordered.
    var r = try testItems(alloc,
        \\[{"label":"inline","data":{"id":"inline"}},
        \\ {"label":"line","data":{"id":"line"}},
        \\ {"label":"count_lines","data":{"id":"count"}},
        \\ {"label":"read_lines","data":{"id":"read"}}]
    );
    defer r.deinit(alloc);
    sortCompletionItems(alloc, r.items.items, "line");
    try std.testing.expectEqualStrings("line", r.items.items[0].label);
    const idx = completionSelection(r.items.items, want_id, want_key) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("count_lines", r.items.items[idx].label);
}

fn freeRankedItems(alloc: std.mem.Allocator, items: *std.ArrayList(CompletionItem)) void {
    for (items.items) |*it| it.deinit(alloc);
    items.deinit(alloc);
}

// Deterministic O(n log n) shape regression: reversed sortText forces a full
// reorder of 5000 candidates while every score is identical. The old
// insertion sort recomputed the score per comparison (O(n²), ~6.8 s in Debug
// on this machine); the precomputed-score sort is milliseconds. The bound is
// deliberately generous (10x+ the measured value) so it is not scheduler
// sensitive, while still failing by orders of magnitude if the quadratic
// behavior returns.
test "completion ranking: 5000 reversed sortText items sort fast and in total order" {
    const alloc = std.testing.allocator;
    var items = std.ArrayList(CompletionItem).empty;
    defer freeRankedItems(alloc, &items);
    var label_buf: [32]u8 = undefined;
    var sort_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const label = try std.fmt.bufPrint(&label_buf, "item{d:0>4}", .{i});
        const sort_text = try std.fmt.bufPrint(&sort_buf, "{d:0>4}", .{4999 - i});
        try items.append(alloc, .{
            .label = try alloc.dupe(u8, label),
            .sort_text = try alloc.dupe(u8, sort_text),
        });
    }
    const start = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    sortCompletionItems(alloc, items.items, "item");
    const elapsed_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start;

    try std.testing.expectEqual(@as(usize, 5000), items.items.len);
    try std.testing.expectEqualStrings("item4999", items.items[0].label);
    try std.testing.expectEqualStrings("item0000", items.items[4999].label);
    var k: usize = 1;
    while (k < items.items.len) : (k += 1) {
        const prev = items.items[k - 1].sort_text.?;
        const cur = items.items[k].sort_text.?;
        try std.testing.expect(std.mem.lessThan(u8, prev, cur));
    }
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

// 5000 equal-score, equal-sortText candidates: the original parse index is
// the final tiebreaker, so the result is the original order on every run and
// sorting an already-sorted list is idempotent (a real total order, not an
// accident of a particular algorithm's stability).
test "completion ranking: 5000 equal-score items keep the original order deterministically" {
    const alloc = std.testing.allocator;
    var items = std.ArrayList(CompletionItem).empty;
    defer freeRankedItems(alloc, &items);
    var label_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const label = try std.fmt.bufPrint(&label_buf, "eq{d:0>4}", .{i});
        try items.append(alloc, .{ .label = try alloc.dupe(u8, label) });
    }
    sortCompletionItems(alloc, items.items, "eq");
    try std.testing.expectEqualStrings("eq0000", items.items[0].label);
    try std.testing.expectEqualStrings("eq4999", items.items[4999].label);
    // Idempotent: a second pass keeps the same total order.
    sortCompletionItems(alloc, items.items, "eq");
    try std.testing.expectEqualStrings("eq0000", items.items[0].label);
    try std.testing.expectEqualStrings("eq4999", items.items[4999].label);
    var k: usize = 0;
    var expected_buf: [32]u8 = undefined;
    while (k < items.items.len) : (k += 1) {
        const expected = try std.fmt.bufPrint(&expected_buf, "eq{d:0>4}", .{k});
        try std.testing.expectEqualStrings(expected, items.items[k].label);
    }
}
