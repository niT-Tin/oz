//! LSP diagnostics parsing (M2). Turns a `textDocument/publishDiagnostics`
//! params tree into `[]types.Diagnostic` (owned messages) for the current
//! file only — diagnostics for other documents are dropped by the caller
//! (the editor keeps one buffer's diagnostics at a time).

const std = @import("std");
const types = @import("types.zig");

/// Parse `params` into `out`. Only diagnostics whose `uri` equals `uri` are
/// kept; malformed entries are skipped. `message` is dupe'd (allocator-owned).
pub fn parseDiagnostics(alloc: std.mem.Allocator, params: std.json.Value, uri: []const u8, out: *std.ArrayList(types.Diagnostic)) !void {
    if (params != .object) return;
    const p_uri = params.object.get("uri") orelse return;
    if (p_uri != .string) return;
    if (!std.mem.eql(u8, p_uri.string, uri)) return; // other document: ignore
    const diags = params.object.get("diagnostics") orelse return;
    if (diags != .array) return;
    for (diags.array.items) |d| {
        if (d != .object) continue;
        const range_v = d.object.get("range") orelse continue;
        const rng = parseRange(range_v) orelse continue;
        const msg_v = d.object.get("message") orelse continue;
        if (msg_v != .string) continue;
        const sev = parseSeverity(d.object.get("severity"));
        const message = try alloc.dupe(u8, msg_v.string);
        errdefer alloc.free(message);
        try out.append(alloc, .{ .range = rng, .severity = sev, .message = message });
    }
}

fn parseRange(v: std.json.Value) ?types.Range {
    if (v != .object) return null;
    const start = parsePosition(v.object.get("start") orelse return null) orelse return null;
    const end = parsePosition(v.object.get("end") orelse return null) orelse return null;
    return .{ .start = start, .end = end };
}

fn parsePosition(v: std.json.Value) ?types.Position {
    if (v != .object) return null;
    const line = intField(v, "line") orelse return null;
    const character = intField(v, "character") orelse return null;
    return .{ .line = line, .character = character };
}

fn intField(v: std.json.Value, name: []const u8) ?u32 {
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

fn parseSeverity(v: ?std.json.Value) types.Severity {
    const sv = v orelse return .err;
    return switch (sv) {
        .integer => |n| switch (n) {
            1 => .err,
            2 => .warning,
            3 => .info,
            else => .hint,
        },
        else => .err,
    };
}

/// The diagnostics sorted by line (stable for same-line entries). The editor
/// walks this for ]d/[d and the gutter marks.
pub fn sortByLine(diags: []types.Diagnostic) void {
    std.mem.sort(types.Diagnostic, diags, {}, struct {
        fn lt(_: void, a: types.Diagnostic, b: types.Diagnostic) bool {
            return a.range.start.line < b.range.start.line;
        }
    }.lt);
}

/// First diagnostic on or after `line`, or null.
pub fn nextAtOrAfter(diags: []const types.Diagnostic, line: u32) ?usize {
    for (diags, 0..) |d, i| {
        if (d.range.start.line >= line) return i;
    }
    return null;
}

/// Last diagnostic at or before `line`, or null.
pub fn prevAtOrBefore(diags: []const types.Diagnostic, line: u32) ?usize {
    var best: ?usize = null;
    for (diags, 0..) |d, i| {
        if (d.range.start.line <= line) best = i;
    }
    return best;
}

test "parseDiagnostics: mock hello payload is parsed for the matching uri" {
    const alloc = std.testing.allocator;
    const json =
        \\{"uri":"file:///tmp/a.zig","diagnostics":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"mock error"}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var out = std.ArrayList(types.Diagnostic).empty;
    defer {
        for (out.items) |*d| alloc.free(d.message);
        out.deinit(alloc);
    }
    try parseDiagnostics(alloc, parsed.value, "file:///tmp/a.zig", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u32, 0), out.items[0].range.start.line);
    try std.testing.expectEqual(types.Severity.err, out.items[0].severity);
    try std.testing.expectEqualStrings("mock error", out.items[0].message);
}

test "parseDiagnostics: other-file diagnostics are dropped, malformed skipped" {
    const alloc = std.testing.allocator;
    const json =
        \\{"uri":"file:///tmp/other.zig","diagnostics":[
        \\  {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}},"message":"other file"}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var out = std.ArrayList(types.Diagnostic).empty;
    defer out.deinit(alloc);
    try parseDiagnostics(alloc, parsed.value, "file:///tmp/a.zig", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "diagnostics: sortByLine and next/prev helpers" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayList(types.Diagnostic).empty;
    defer {
        for (diags.items) |*d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try diags.append(alloc, .{ .range = .{ .start = .{ .line = 4, .character = 0 }, .end = .{ .line = 4, .character = 1 } }, .severity = .warning, .message = try alloc.dupe(u8, "b") });
    try diags.append(alloc, .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 1 } }, .severity = .err, .message = try alloc.dupe(u8, "a") });
    sortByLine(diags.items);
    try std.testing.expectEqual(@as(u32, 1), diags.items[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 4), diags.items[1].range.start.line);
    try std.testing.expectEqual(@as(?usize, 0), nextAtOrAfter(diags.items, 0));
    try std.testing.expectEqual(@as(?usize, 1), nextAtOrAfter(diags.items, 2));
    try std.testing.expectEqual(@as(?usize, null), nextAtOrAfter(diags.items, 5));
    try std.testing.expectEqual(@as(?usize, 1), prevAtOrBefore(diags.items, 4));
    try std.testing.expectEqual(@as(?usize, 0), prevAtOrBefore(diags.items, 2));
}
