//! The two layouts share a patch cursor (a unified row). Index both orders on
//! the Git worker, so paging, resizing and hunk jumps never rescan patch text.
const std = @import("std");

pub const Kind = enum { header, note, context, add, remove };
pub const Row = struct {
    kind: Kind,
    text: []const u8,
    old: ?u32 = null,
    new: ?u32 = null,
    source_line: u32 = 1,
    pair: usize = 0,
};
pub const Pair = struct {
    left: ?usize = null,
    right: ?usize = null,

    pub fn preferred(self: Pair) usize {
        return self.right orelse self.left.?;
    }
};
pub const View = struct {
    rows: []const Row = &.{},
    pairs: []const Pair = &.{},
    hunks: []const usize = &.{},

    pub fn lineAt(self: View, at: usize, left: bool) ?u32 {
        const pair = self.pairs[self.rows[at].pair];
        const row = self.rows[(if (left) pair.left else pair.right) orelse return null];
        return if (left) row.old else row.new;
    }

    pub fn jump(self: View, at: usize, next: bool) usize {
        var lo: usize = 0;
        var hi = self.hunks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.hunks[mid] < at or (next and self.hunks[mid] == at)) lo = mid + 1 else hi = mid;
        }
        if (next) return if (lo < self.hunks.len) self.hunks[lo] else at;
        return if (lo > 0) self.hunks[lo - 1] else at;
    }
};

fn rangeStart(token: []const u8, prefix: u8) ?u32 {
    if (token.len < 2 or token[0] != prefix) return null;
    const end = std.mem.indexOfScalar(u8, token, ',') orelse token.len;
    return std.fmt.parseInt(u32, token[1..end], 10) catch null;
}

/// All slices and indexes borrow the result arena and its original patch.
pub fn parse(a: std.mem.Allocator, patch: []const u8) !View {
    var rows: std.ArrayList(Row) = .empty;
    var pairs: std.ArrayList(Pair) = .empty;
    var hunks: std.ArrayList(usize) = .empty;
    var old: u32 = 1;
    var new: u32 = 1;
    var first_change = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, patch, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ -")) {
            var fields = std.mem.tokenizeScalar(u8, line[3..], ' ');
            old = rangeStart(fields.next() orelse continue, '-') orelse continue;
            new = rangeStart(fields.next() orelse continue, '+') orelse continue;
            try hunks.append(a, rows.items.len);
            try rows.append(a, .{ .kind = .header, .text = line, .old = @max(old, 1), .new = @max(new, 1), .source_line = @max(new, 1) });
            first_change = true;
            continue;
        }
        if (hunks.items.len == 0 or line.len == 0) continue;
        var row: Row = .{ .kind = .note, .text = line[1..], .source_line = @max(new, 1) };
        switch (line[0]) {
            '-' => {
                row.kind = .remove;
                row.old = old;
                old += 1;
            },
            '+' => {
                row.kind = .add;
                row.new = new;
                new += 1;
            },
            ' ' => {
                row.kind = .context;
                row.old = old;
                row.new = new;
                old += 1;
                new += 1;
            },
            else => row.text = line,
        }
        if (first_change and (row.kind == .remove or row.kind == .add)) {
            rows.items[hunks.items[hunks.items.len - 1]].source_line = row.source_line;
            first_change = false;
        }
        try rows.append(a, row);
    }
    if (hunks.items.len == 0) {
        lines.reset();
        while (lines.next()) |line| {
            if (line.len != 0) try rows.append(a, .{ .kind = .note, .text = line });
        }
    }

    var i: usize = 0;
    while (i < rows.items.len) {
        const kind = rows.items[i].kind;
        if (kind != .remove and kind != .add) {
            rows.items[i].pair = pairs.items.len;
            try pairs.append(a, .{ .left = i, .right = i });
            i += 1;
            continue;
        }
        const start = i;
        while (i < rows.items.len and rows.items[i].kind == .remove) i += 1;
        const split = i;
        while (i < rows.items.len and rows.items[i].kind == .add) i += 1;
        for (0..@max(split - start, i - split)) |j| {
            var pair: Pair = .{};
            if (j < split - start) {
                pair.left = start + j;
                rows.items[start + j].pair = pairs.items.len;
            }
            if (j < i - split) {
                pair.right = split + j;
                rows.items[split + j].pair = pairs.items.len;
            }
            try pairs.append(a, pair);
        }
    }
    return .{ .rows = rows.items, .pairs = pairs.items, .hunks = hunks.items };
}

test "aligned replacements retain both sides, source positions and hunk identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "--- a/x\n+++ b/x\n@@ -8,3 +10,4 @@\n same\n-before\n+after\n+extra\n same2\n@@ -35 +38 @@\n-last\n+final\n");
    try std.testing.expectEqual(@as(usize, 9), p.rows.len);
    try std.testing.expectEqual(@as(usize, 7), p.pairs.len);
    try std.testing.expectEqual(p.rows[2].pair, p.rows[3].pair);
    try std.testing.expectEqual(@as(?u32, 9), p.rows[2].old);
    try std.testing.expectEqual(@as(?u32, 11), p.rows[p.pairs[2].preferred()].new);
    try std.testing.expectEqual(@as(u32, 11), p.rows[0].source_line);
    try std.testing.expectEqual(@as(?usize, null), p.pairs[3].left);
    try std.testing.expectEqual(@as(usize, 6), p.jump(0, true));
    try std.testing.expectEqual(@as(usize, 0), p.jump(6, false));
}
