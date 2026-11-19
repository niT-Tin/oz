//! Cut the comparison at complete, unchanged lines shared with HEAD. Each
//! changed window keeps context on both sides; line offsets are counted in the
//! full documents. Small files use a single ordinary Git diff.
const std = @import("std");
const Snapshot = @import("../buffer/text_snapshot.zig");
const countLines = @import("../buffer/line_pages.zig").countNewlines;

pub const threshold = 4 * 1024 * 1024;
pub const Window = struct { old: []const u8, start: usize, end: usize, old_lines: u32, new_lines: u32 };

pub fn visit(s: Snapshot, base: []const u8, ctx: anytype, comptime emit: anytype) !void {
    // Undo can leave the original partitioned into several adjacent pieces.
    // This proves byte identity without scanning or diffing repeated logs.
    if (s.len == base.len and s.origin.bytes.ptr == base.ptr) {
        var offset: usize = 0;
        for (s.pieces) |p| {
            if (p.source != .origin or p.start != offset) break;
            offset += p.len;
        } else return;
    }
    var state = Split{ .snapshot = s, .base = base };
    if (@max(s.len, base.len) >= threshold) {
        const original = s.origin.bytes;
        const limit = @min(original.len, base.len);
        const prefix = if (base.ptr == original.ptr) limit else commonPrefix(original[0..limit], base[0..limit]);
        const suffix = commonSuffix(original, base, limit - prefix);
        var pos: usize = 0;
        for (s.pieces) |p| {
            if (p.source == .origin) {
                const lo: usize = p.start;
                const hi = lo + p.len;
                if (lo < prefix)
                    try state.anchor(lo, pos, @min(hi, prefix) - lo, ctx, emit);
                if (suffix > 0 and hi > original.len - suffix) {
                    const from = @max(lo, original.len - suffix);
                    try state.anchor(base.len - (original.len - from), pos + (from - lo), hi - from, ctx, emit);
                }
            }
            pos += p.len;
        }
    }
    try state.gap(base.len, s.len, ctx, emit);
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    var off: usize = 0;
    while (a.len - off >= 65536 and std.mem.eql(u8, a[off..][0..65536], b[off..][0..65536])) off += 65536;
    return off + (std.mem.findDiff(u8, a[off..], b[off..]) orelse (a.len - off));
}

fn commonSuffix(a: []const u8, b: []const u8, limit: usize) usize {
    var n: usize = 0;
    while (limit - n >= 65536 and std.mem.eql(u8, a[a.len - n - 65536 ..][0..65536], b[b.len - n - 65536 ..][0..65536])) n += 65536;
    while (n < limit and a[a.len - 1 - n] == b[b.len - 1 - n]) n += 1;
    return n;
}

const Split = struct {
    snapshot: Snapshot,
    base: []const u8,
    old_start: usize = 0,
    new_start: usize = 0,
    counted_base: usize = 0,
    old_lines: u32 = 0,
    new_lines: u32 = 0,

    fn gap(self: *Split, old_end: usize, new_end: usize, ctx: anytype, comptime emit: anytype) !void {
        if (old_end == self.old_start and new_end == self.new_start) return;
        const old = self.base[self.old_start..old_end];
        var pos: usize = 0;
        var added_lines: u32 = 0;
        var identical = old.len == new_end - self.new_start;
        for (self.snapshot.pieces) |p| {
            if (pos >= new_end) break;
            const end = pos + p.len;
            if (end > self.new_start) {
                const start = @max(self.new_start, pos);
                const bytes = self.snapshot.bytes(p)[start - pos .. @min(end, new_end) - pos];
                added_lines += countLines(bytes);
                if (identical) identical = std.mem.eql(u8, bytes, old[start - self.new_start ..][0..bytes.len]);
            }
            pos = end;
        }
        if (identical) return;
        // Between emitted windows both documents contain the same lines.
        // An edit at the top need never count the untouched GiB below it.
        const skipped = countLines(self.base[self.counted_base..self.old_start]);
        self.old_lines += skipped;
        self.new_lines += skipped;
        try emit(ctx, Window{ .old = old, .start = self.new_start, .end = new_end, .old_lines = self.old_lines, .new_lines = self.new_lines });
        self.old_lines += countLines(old);
        self.new_lines += added_lines;
        self.counted_base = old_end;
    }

    fn anchor(self: *Split, old: usize, new: usize, len: usize, ctx: anytype, comptime emit: anytype) !void {
        if (old < self.old_start or new < self.new_start) return;
        const same = self.base[old..][0..len];
        var left: usize = 0;
        var right = same.len;
        // One potentially partial edge line and three complete context lines.
        for (0..4) |_| {
            left += (std.mem.indexOfScalar(u8, same[left..right], '\n') orelse return) + 1;
            right = std.mem.lastIndexOfScalar(u8, same[left..right], '\n') orelse return;
            right += left;
        }
        right += 1;
        // Equal context at both cuts can let xdiff match a repeated line
        // across this anchor, even if neither local hunk touched its edge.
        const left_first = (std.mem.indexOfScalar(u8, same[0..left], '\n') orelse unreachable) + 1;
        const right_last = (std.mem.lastIndexOfScalar(u8, same[right..], '\n') orelse unreachable) + 1;
        const lhs = same[left_first..left];
        const rhs = same[right..][0..right_last];
        if (lhs.len > 0 and std.mem.eql(u8, rhs, lhs))
            return error.AmbiguousWindow;
        try self.gap(old + left, new + left, ctx, emit);
        self.old_start = old + right;
        self.new_start = new + right;
    }
};

test "undo of an insertion skips even a fully repetitive split origin" {
    const PT = @import("../buffer/piece_table.zig").PieceTable;
    const a = std.testing.allocator;
    const data = try a.alloc(u8, threshold);
    @memset(data, '\n');
    var pt = try PT.initOwned(a, data);
    defer pt.deinit();
    _ = try pt.replace(threshold / 2, 0, "edit");
    _ = try pt.replace(threshold / 2, 4, "");
    const s = try Snapshot.capture(&pt);
    defer s.deinit();
    try visit(s, s.origin.bytes, {}, struct {
        fn unexpected(_: void, _: Window) !void {
            return error.UnexpectedDiff;
        }
    }.unexpected);
}
