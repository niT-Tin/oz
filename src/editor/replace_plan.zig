//! Counted Normal r planning: validate one typed grapheme and the complete
//! same-line source span before mutating anything.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Plan = struct {
    before_len: u32,
    text: []u8,
    cursor_off: u32,
    pub fn deinit(self: Plan, a: std.mem.Allocator) void {
        a.free(self.text);
    }
};

pub fn plan(a: std.mem.Allocator, source: []const u8, replacement: []const u8, count: u32) !?Plan {
    if (replacement.len == 0 or !std.unicode.utf8ValidateSlice(replacement)) return null;
    for (replacement) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    var typed = vaxis.unicode.graphemeIterator(replacement);
    const cluster = typed.next() orelse return null;
    if (cluster.len != replacement.len or typed.next() != null) return null;
    const line = source[0 .. std.mem.indexOfAny(u8, source, "\r\n") orelse source.len];
    const n = @max(count, 1);
    if (n > line.len) return null;
    var source_clusters = vaxis.unicode.graphemeIterator(line);
    var end: usize = 0;
    for (0..n) |_| {
        const g = source_clusters.next() orelse return null;
        end = g.start + g.len;
    }
    const total = std.math.mul(usize, replacement.len, n) catch return error.OutOfMemory;
    if (total > std.math.maxInt(u32)) return error.OutOfMemory;
    const text = try a.alloc(u8, total);
    for (0..n) |i| @memcpy(text[i * replacement.len ..][0..replacement.len], replacement);
    return .{ .before_len = @intCast(end), .text = text, .cursor_off = @intCast(total - replacement.len) };
}

test "Normal replace: complete graphemes and atomic line-bound counts" {
    const a = std.testing.allocator;
    const p = (try plan(a, "中e\xcc\x81😀x\r\nNEXT", "语", 3)).?;
    defer p.deinit(a);
    try std.testing.expectEqual(@as(u32, 10), p.before_len);
    try std.testing.expectEqualStrings("语语语", p.text);
    try std.testing.expectEqual(@as(u32, 6), p.cursor_off);
    for ([_][]const u8{ "", "a\nb", "a\r\nb", "\n", "😀" }) |source|
        try std.testing.expect(try plan(a, source, "X", 2) == null);
    for ([_][]const u8{ "", "xy", "\n", "\x1b", "\xff" }) |bad|
        try std.testing.expect(try plan(a, "abc", bad, 1) == null);
    const combining = (try plan(a, "A", "e\xcc\x81", 1)).?;
    defer combining.deinit(a);
    try std.testing.expectEqualStrings("e\xcc\x81", combining.text);
}
