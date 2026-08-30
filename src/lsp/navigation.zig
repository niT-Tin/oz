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

/// Extract the hover text from a hover response (`contents` may be a string,
/// `{kind,value}` or `{kind:"markdown",value}`). Returns an owned copy or
/// null when there is nothing to show.
pub fn parseHoverText(alloc: std.mem.Allocator, result: std.json.Value) !?[]u8 {
    if (result != .object) return null;
    const contents = result.object.get("contents") orelse return null;
    switch (contents) {
        .string => |s| return @as(?[]u8, try alloc.dupe(u8, s)),
        .array => {
            // MarkupContent[] — join with newlines
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(alloc);
            for (contents.array.items) |item| {
                if (item == .string) {
                    if (out.items.len > 0) try out.append(alloc, '\n');
                    try out.appendSlice(alloc, item.string);
                } else if (item == .object) {
                    if (item.object.get("value")) |val| {
                        if (val == .string) {
                            if (out.items.len > 0) try out.append(alloc, '\n');
                            try out.appendSlice(alloc, val.string);
                        }
                    }
                }
            }
            if (out.items.len == 0) return null;
            return @as(?[]u8, try out.toOwnedSlice(alloc));
        },
        .object => {
            const value = contents.object.get("value") orelse return null;
            if (value == .string) return @as(?[]u8, try alloc.dupe(u8, value.string));
            return null;
        },
        else => return null,
    }
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
    if (units < pos.character) return null; // past the line end
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

/// A completion candidate: the text an accept would insert plus the LSP
/// CompletionItemKind (0 = unknown / buffer-word fallback), used for the
/// kind icon in the menu.
pub const CompletionItem = struct {
    text: []u8, // owned
    kind: u8,
};

/// Parse a textDocument/completion response (CompletionList | CompletionItem[])
/// into owned items appended to `out`. The label (or insertText /
/// textEdit.newText when present) is what an accept would insert.
pub fn parseCompletionItems(alloc: std.mem.Allocator, result: std.json.Value, out: *std.ArrayList(CompletionItem)) !void {
    // result may be {items:[...]} (CompletionList) or [...]
    const items: std.json.Value = if (result == .object)
        (result.object.get("items") orelse return)
    else
        result;
    if (items != .array) return;
    for (items.array.items) |item| {
        if (item != .object) continue;
        // Snippet candidates (insertTextFormat=2) embed ${n:...} placeholder
        // syntax this editor cannot expand; inserting it verbatim would
        // corrupt the text and leave the cursor stranded mid-word (zls's
        // standardTargetOptions is such a snippet). Fall back to the plain
        // label so the accept inserts clean text and the cursor lands after
        // it.
        const is_snippet: bool = blk: {
            const f = item.object.get("insertTextFormat") orelse break :blk false;
            const fv: ?i64 = switch (f) {
                .integer => |n| n,
                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                else => null,
            };
            break :blk fv == 2;
        };
        // prefer insertText / textEdit.newText, fall back to label
        var text: ?[]const u8 = null;
        if (!is_snippet) {
            if (item.object.get("textEdit")) |te| {
                if (te == .object) {
                    if (te.object.get("newText")) |nt| {
                        if (nt == .string) text = nt.string;
                    }
                }
            }
            if (text == null) {
                if (item.object.get("insertText")) |it| {
                    if (it == .string) text = it.string;
                }
            }
        }
        if (text == null) {
            if (item.object.get("label")) |lb| {
                if (lb == .string) text = lb.string;
            }
        }
        const t = text orelse continue;
        if (t.len == 0) continue;
        var kind: u8 = 0;
        if (item.object.get("kind")) |k| {
            // zig's json parser may surface integers as .integer or
            // .number_string depending on magnitude/source
            const kint: ?i64 = switch (k) {
                .integer => |n| n,
                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                else => null,
            };
            if (kint) |n| {
                if (n >= 1 and n <= 255) kind = @intCast(n);
            }
        }
        const copy = try alloc.dupe(u8, t);
        errdefer alloc.free(copy);
        try out.append(alloc, .{ .text = copy, .kind = kind });
    }
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

test "navigation: hover text from markdown/string/array" {
    const alloc = std.testing.allocator;
    const j1 = "{\"contents\":{\"kind\":\"markdown\",\"value\":\"**doc**\"}}";
    var p1 = try std.json.parseFromSlice(std.json.Value, alloc, j1, .{ .allocate = .alloc_always });
    defer p1.deinit();
    const t1 = (try parseHoverText(alloc, p1.value)).?;
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("**doc**", t1);

    const j2 = "{\"contents\":\"plain hover\"}";
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, j2, .{ .allocate = .alloc_always });
    defer p2.deinit();
    const t2 = (try parseHoverText(alloc, p2.value)).?;
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("plain hover", t2);

    const j3 = "{\"contents\":[]}";
    var p3 = try std.json.parseFromSlice(std.json.Value, alloc, j3, .{ .allocate = .alloc_always });
    defer p3.deinit();
    try std.testing.expect((try parseHoverText(alloc, p3.value)) == null);
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
        for (out1.items) |it| alloc.free(it.text);
        out1.deinit(alloc);
    }
    try parseCompletionItems(alloc, p1.value, &out1);
    try std.testing.expectEqual(@as(usize, 2), out1.items.len);
    try std.testing.expectEqualStrings("alpha", out1.items[0].text);
    try std.testing.expectEqual(@as(u8, 5), out1.items[0].kind); // Field
    try std.testing.expectEqualStrings("betaFn", out1.items[1].text);
    try std.testing.expectEqual(@as(u8, 0), out1.items[1].kind); // no kind → 0

    // raw array form
    const j2 = "[{\"label\":\"x\"},{\"textEdit\":{\"newText\":\"y\"}}]";
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, j2, .{ .allocate = .alloc_always });
    defer p2.deinit();
    var out2 = std.ArrayList(CompletionItem).empty;
    defer {
        for (out2.items) |it| alloc.free(it.text);
        out2.deinit(alloc);
    }
    try parseCompletionItems(alloc, p2.value, &out2);
    try std.testing.expectEqual(@as(usize, 2), out2.items.len);
    try std.testing.expectEqualStrings("x", out2.items[0].text);
    try std.testing.expectEqualStrings("y", out2.items[1].text);
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
        for (out.items) |it| alloc.free(it.text);
        out.deinit(alloc);
    }
    try parseCompletionItems(alloc, p.value, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // snippet with textEdit: label wins over the placeholder-laden newText
    try std.testing.expectEqualStrings("standardTargetOptions", out.items[0].text);
    // snippet without textEdit: label wins over insertText too
    try std.testing.expectEqualStrings("plain", out.items[1].text);
}
