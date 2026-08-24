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
    params.deinit(alloc);
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
    const uri = loc.object.get("uri") orelse return;
    if (uri != .string) return;
    const range = loc.object.get("range") orelse return;
    if (range != .object) return;
    const start = range.object.get("start") orelse return;
    const line = intField(start, "line") orelse return;
    const character = intField(start, "character") orelse return;
    const uri_copy = try alloc.dupe(u8, uri.string);
    errdefer alloc.free(uri_copy);
    try out.append(alloc, .{ .uri = uri_copy, .line = line, .character = character });
}

fn intField(v: std.json.Value, name: []const u8) ?u32 {
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
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
