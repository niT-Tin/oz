//! LSP diagnostics parsing (M2). Turns a `textDocument/publishDiagnostics`
//! params tree into `[]types.Diagnostic` (owned messages) for the current
//! file only — diagnostics for other documents are dropped by the caller
//! (the editor keeps one buffer's diagnostics at a time).

const std = @import("std");
const types = @import("types.zig");
const utf8 = @import("../buffer/utf8.zig");

pub const ByteRange = struct { start: u32, end: u32, severity: types.Severity };

fn byteAtUtf16(text: []const u8, column: u32) u32 {
    var byte: usize = 0;
    var units: u32 = 0;
    while (byte < text.len and units < column) {
        const cp = utf8.decodeAt(text, byte);
        units += if (cp.cp > 0xFFFF) 2 else 1;
        byte += cp.len;
    }
    return @intCast(byte);
}

/// Source-byte interval for this line, clipped to the supplied visible text.
/// LSP columns are UTF-16 and ranges exclude their end. A point marks the
/// next codepoint if one exists; an EOL/empty-line point has no source glyph.
pub fn byteRangeOnLine(d: types.Diagnostic, line: u32, text: []const u8) ?ByteRange {
    const s = d.range.start;
    const e = d.range.end;
    if (e.line < s.line or (e.line == s.line and e.character < s.character)) return null;
    if (!coversLine(d, line)) return null;
    const start = if (line == s.line) byteAtUtf16(text, s.character) else 0;
    var end = if (line == e.line) byteAtUtf16(text, e.character) else @as(u32, @intCast(text.len));
    if (s.line == e.line and s.character == e.character and start < text.len)
        end = start + utf8.decodeAt(text, start).len;
    if (end <= start) return null;
    return .{ .start = start, .end = end, .severity = d.severity };
}

/// Resolve overlaps by severity and stop at the next source-byte boundary.
pub fn rangeRun(ranges: []const ByteRange, byte: u32, limit: u32) struct { end: u32, severity: ?types.Severity } {
    var end = limit;
    var severity: ?types.Severity = null;
    for (ranges) |r| {
        if (r.start > byte) end = @min(end, r.start);
        if (r.end > byte) end = @min(end, r.end);
        if (r.start <= byte and byte < r.end) {
            if (severity == null or @backingInt(r.severity) < @backingInt(severity.?)) severity = r.severity;
        }
    }
    return .{ .end = end, .severity = severity };
}

test "diagnostic ranges: UTF-16 columns, multiline exclusive ends and point diagnostics" {
    const t = std.testing;
    var d = types.Diagnostic{ .range = .{ .start = .{ .line = 2, .character = 4 }, .end = .{ .line = 2, .character = 5 } }, .message = @constCast("test") };
    const text = "中😀_x";
    const r = byteRangeOnLine(d, 2, text).?;
    try t.expectEqualStrings("x", text[r.start..r.end]);
    d.range.start.character = 1;
    d.range.end.character = 3;
    const emoji = byteRangeOnLine(d, 2, text).?;
    try t.expectEqualStrings("😀", text[emoji.start..emoji.end]);
    d.range.end = .{ .line = 4, .character = 0 };
    try t.expectEqual(@as(u32, 0), byteRangeOnLine(d, 3, text).?.start);
    try t.expect(byteRangeOnLine(d, 4, text) == null);
    d.range.end = d.range.start;
    try t.expectEqual(@as(u32, 7), byteRangeOnLine(d, 2, text).?.end);
    d.range.start.character = 99;
    d.range.end = d.range.start;
    try t.expect(byteRangeOnLine(d, 2, text) == null);
    try t.expect(byteRangeOnLine(d, 2, "") == null);
    d.range.end.character = 0;
    try t.expect(byteRangeOnLine(d, 2, text) == null);
}

test "diagnostic ranges: higher severity wins only on the overlapping interval" {
    const rs = [_]ByteRange{
        .{ .start = 2, .end = 10, .severity = .info },
        .{ .start = 4, .end = 7, .severity = .err },
        .{ .start = 6, .end = 12, .severity = .warning },
    };
    try std.testing.expectEqual(@as(?types.Severity, null), rangeRun(&rs, 1, 20).severity);
    try std.testing.expectEqual(@as(u32, 2), rangeRun(&rs, 1, 20).end);
    try std.testing.expectEqual(types.Severity.info, rangeRun(&rs, 2, 20).severity.?);
    try std.testing.expectEqual(types.Severity.err, rangeRun(&rs, 6, 20).severity.?);
    try std.testing.expectEqual(@as(u32, 7), rangeRun(&rs, 6, 20).end);
    try std.testing.expectEqual(types.Severity.warning, rangeRun(&rs, 7, 20).severity.?);
    try std.testing.expect(rangeRun(&rs, 12, 20).severity == null);
}

/// A versioned publication must describe the text we last sent. Missing/null
/// versions remain valid: servers such as ZLS publish unversioned diagnostics.
pub fn matchesVersion(params: std.json.Value, current: ?i32) bool {
    if (params != .object) return false;
    const value = params.object.get("version") orelse return true;
    const version: i32 = switch (value) {
        .null => return true,
        .integer => |n| std.math.cast(i32, n) orelse return false,
        .number_string => |s| std.fmt.parseInt(i32, s, 10) catch return false,
        else => return false,
    };
    return version >= 0 and current != null and version == current.?;
}

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
        // json_rpc.parseMessage keeps numbers as .number_string
        .number_string => |str| std.fmt.parseInt(u32, str, 10) catch null,
        else => null,
    };
}

fn parseSeverity(v: ?std.json.Value) types.Severity {
    const sv = v orelse return .err;
    const n: i64 = switch (sv) {
        .integer => |iv| iv,
        .number_string => |str| std.fmt.parseInt(i64, str, 10) catch return .err,
        else => return .err,
    };
    return switch (n) {
        1 => .err,
        2 => .warning,
        3 => .info,
        else => .hint,
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

test "diagnostics: publication versions must match current text, unversioned servers remain supported" {
    const cases = [_]struct { json: []const u8, current: ?i32 = 3, accepted: bool }{
        .{ .json = "{}", .accepted = true },
        .{ .json = "{\"version\":null}", .accepted = true },
        .{ .json = "{\"version\":3}", .accepted = true },
        .{ .json = "{\"version\":2}", .accepted = false },
        .{ .json = "{\"version\":4}", .accepted = false },
        .{ .json = "{\"version\":-1}", .accepted = false },
        .{ .json = "{\"version\":2147483648}", .accepted = false },
        .{ .json = "{\"version\":\"3\"}", .accepted = false },
        .{ .json = "{\"version\":true}", .accepted = false },
        .{ .json = "{\"version\":3}", .current = null, .accepted = false },
    };
    for (cases) |c| {
        for ([_]bool{ false, true }) |number_strings| {
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, c.json, .{ .parse_numbers = !number_strings });
            defer parsed.deinit();
            try std.testing.expectEqual(c.accepted, matchesVersion(parsed.value, c.current));
        }
    }
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

/// LSP ranges are end-exclusive; a zero-length range still marks its point.
pub fn coversLine(d: types.Diagnostic, line: u32) bool {
    if (line < d.range.start.line or line > d.range.end.line) return false;
    return line == d.range.start.line or line < d.range.end.line or d.range.end.character > 0;
}
pub const LineSummary = struct { index: usize, count: usize };
pub fn lineSummary(diags: []const types.Diagnostic, line: u32) ?LineSummary {
    var result: ?LineSummary = null;
    for (diags, 0..) |d, i| {
        if (!coversLine(d, line)) continue;
        if (result) |*r| {
            r.count += 1;
            if (@backingInt(d.severity) < @backingInt(diags[r.index].severity)) r.index = i;
        } else result = .{ .index = i, .count = 1 };
    }
    return result;
}
pub fn severityLabel(s: types.Severity) []const u8 {
    return switch (s) {
        .err => "Error",
        .warning => "Warning",
        .info => "Info",
        .hint => "Hint",
    };
}
pub fn severityMark(s: types.Severity) []const u8 {
    return switch (s) {
        .err => "E",
        .warning => "W",
        .info => "I",
        .hint => "H",
    };
}
test "diagnostics: current-line summary picks highest severity and respects range ends" {
    const t = std.testing;
    const warning = types.Diagnostic{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 3, .character = 0 } }, .severity = .warning, .message = @constCast("warning") };
    var err = warning;
    err.severity = .err;
    err.range.start.line = 2;
    const ds = [_]types.Diagnostic{ warning, err };
    const summary = lineSummary(&ds, 2).?;
    try t.expectEqual(@as(usize, 1), summary.index);
    try t.expectEqual(@as(usize, 2), summary.count);
    try t.expect(lineSummary(&ds, 3) == null);
    try t.expect(lineSummary(&ds, 0) == null);
    err.range.end.character = 1;
    try t.expect(coversLine(err, 3));
    err.range.end = err.range.start;
    try t.expect(coversLine(err, 2));
}
