//! Operator-specific multiline inner-block semantics. The mathematical object
//! range stays shared by selection/surround; d/c/y preserve delimiter lines.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;
const object = @import("text_object.zig");

pub const Plan = struct {
    edit: object.Range,
    register: object.Range,
    linewise: bool,
    replacement: []u8,
    cursor: u32,
    pub fn deinit(self: Plan, a: std.mem.Allocator) void {
        a.free(self.replacement);
    }
};

pub fn plan(a: std.mem.Allocator, pt: *const PieceTable, kind: object.Kind, raw: object.Range, change: bool) !?Plan {
    switch (kind) {
        .inner_paren, .inner_bracket, .inner_brace, .inner_angle => {},
        else => return null,
    }
    if (raw.start == 0 or raw.end > pt.len() or raw.end <= raw.start) return null;
    var newline = raw.start;
    while (newline < raw.end and pt.byteAt(newline) != '\n') : (newline += 1) {}
    if (newline == raw.end) return null;
    const ending: []const u8 = if (newline > raw.start and pt.byteAt(newline - 1) == '\r') "\r\n" else "\n";
    var opener_blank = true;
    var i = raw.start;
    while (i < newline) : (i += 1) {
        const c = pt.byteAt(i);
        if (c != ' ' and c != '\t' and c != '\r') opener_blank = false;
    }
    const close_line = pt.lineStart(pt.lineOf(raw.end));
    var closer_blank = true;
    i = close_line;
    while (i < raw.end) : (i += 1) {
        const c = pt.byteAt(i);
        if (c != ' ' and c != '\t') closer_blank = false;
    }
    const reg_start = if (opener_blank) newline + 1 else raw.start;
    var reg_end = if (closer_blank) close_line else raw.end;
    if (closer_blank and !opener_blank and reg_end > 0) {
        reg_end -= 1; // leave the final newline before the closing line
        if (reg_end > 0 and pt.byteAt(reg_end - 1) == '\r') reg_end -= 1;
    }
    reg_end = @max(reg_start, reg_end);
    const has_body = reg_end > reg_start;
    var indent_end = newline + 1;
    if (change and opener_blank and has_body) {
        while (indent_end < reg_end) : (indent_end += 1) {
            const c = pt.byteAt(indent_end);
            if (c != ' ' and c != '\t') break;
        }
    }
    const indent_len = indent_end - (newline + 1);
    const indent = try a.alloc(u8, indent_len);
    defer a.free(indent);
    pt.copyRange(newline + 1, indent);
    // Preserve an unchanged opening terminator in place. This keeps the
    // edit/undo anchor on the body and avoids perturbing its header hints.
    const keep_opening = opener_blank and newline + 1 - raw.start == ending.len;
    const edit_start = if (keep_opening) newline + 1 else raw.start;
    const prefix: []const u8 = if (keep_opening) "" else ending;
    const replacement = try std.mem.concat(a, u8, &.{ prefix, indent, if (change and opener_blank and closer_blank and has_body) ending else "" });
    const cursor = if (change)
        (if (opener_blank) edit_start + @as(u32, @intCast(prefix.len)) + indent_len else raw.start)
    else if (opener_blank)
        edit_start + @as(u32, @intCast(prefix.len)) + (if (closer_blank) raw.end - close_line else 0)
    else
        raw.start - 1;
    return .{
        .edit = .{ .start = edit_start, .end = if (closer_blank) close_line else raw.end },
        .register = .{ .start = reg_start, .end = reg_end },
        .linewise = opener_blank and closer_blank,
        .replacement = replacement,
        .cursor = cursor,
    };
}

test "inner block edit: newline register indentation and CRLF remain independent" {
    const a = std.testing.allocator;
    var pt = try PieceTable.init(a, "foo(\r\n\told\r\n  ) tail\r\n");
    defer pt.deinit();
    const raw = object.range(&pt, .inner_paren, 8, 1);
    const p = (try plan(a, &pt, .inner_paren, raw, true)).?;
    defer p.deinit(a);
    try std.testing.expect(p.linewise);
    try std.testing.expectEqualStrings("\t\r\n", p.replacement);
    try std.testing.expectEqual(@as(u32, 7), p.cursor);
    try std.testing.expectEqual(object.Range{ .start = 6, .end = 12 }, p.register);
    try std.testing.expectEqual(object.Range{ .start = 6, .end = 12 }, p.edit);
    try std.testing.expect(try plan(a, &pt, .around_paren, raw, false) == null);
}
