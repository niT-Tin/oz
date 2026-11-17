//! Literal, non-overlapping buffer matches shared by navigation, preview,
//! highlighting and counts. KMP streams pieces without copying the document.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Index = struct {
    query: ?[]u8 = null,
    starts: std.ArrayList(u32) = .empty,
    revision: u64 = 0,
    valid: bool = false,

    pub fn deinit(self: *Index, a: std.mem.Allocator) void {
        if (self.query) |q| a.free(q);
        self.starts.deinit(a);
        self.* = .{};
    }

    pub fn ensure(self: *Index, a: std.mem.Allocator, pt: *const PieceTable, revision: u64, query: []const u8) !void {
        if (self.valid and self.revision == revision and self.query != null and std.mem.eql(u8, self.query.?, query)) return;
        var fresh = Index{ .revision = revision, .valid = true };
        errdefer fresh.deinit(a);
        fresh.query = try a.dupe(u8, query);
        if (query.len > 0 and query.len <= pt.len()) {
            const prefix = try a.alloc(usize, query.len);
            defer a.free(prefix);
            prefix[0] = 0;
            var k: usize = 0;
            for (1..query.len) |i| {
                while (k > 0 and query[k] != query[i]) k = prefix[k - 1];
                if (query[k] == query[i]) k += 1;
                prefix[i] = k;
            }
            k = 0;
            var pos: u32 = 0;
            for (pt.pieces.items) |piece| {
                const src = if (piece.source == .origin) pt.origin else pt.add.items;
                for (src[piece.start..][0..piece.len]) |byte| {
                    while (k > 0 and query[k] != byte) k = prefix[k - 1];
                    if (query[k] == byte) k += 1;
                    pos += 1;
                    if (k == query.len) {
                        try fresh.starts.append(a, pos - @as(u32, @intCast(query.len)));
                        k = 0; // same non-overlap policy as highlight and n/N
                    }
                }
            }
        }
        self.deinit(a);
        self.* = fresh;
    }

    pub fn lowerBound(self: *const Index, pos: u32) usize {
        var lo: usize = 0;
        var hi = self.starts.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts.items[mid] < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Strictly before/after the anchor, then wrap, including a singleton.
    pub fn next(self: *const Index, pos: u32, backward: bool) ?u32 {
        const items = self.starts.items;
        if (items.len == 0) return null;
        var i = self.lowerBound(pos);
        if (backward) return items[if (i == 0) items.len - 1 else i - 1];
        if (i < items.len and items[i] == pos) i += 1;
        return items[if (i == items.len) 0 else i];
    }

    /// Zero means the cursor is between matches, not on a current match.
    pub fn ordinal(self: *const Index, pos: u32) usize {
        var i = self.lowerBound(pos);
        if (i < self.starts.items.len and self.starts.items[i] == pos) return i + 1;
        if (i == 0) return 0;
        i -= 1;
        return if (pos - self.starts.items[i] < (self.query orelse return 0).len) i + 1 else 0;
    }
};

test "search index: backward last match, wrap, singleton and current span" {
    const a = std.testing.allocator;
    var pt = try PieceTable.init(a, "alpha alpha\nalpha");
    defer pt.deinit();
    var index = Index{};
    defer index.deinit(a);
    try index.ensure(a, &pt, 0, "alpha");
    try std.testing.expectEqualSlices(u32, &.{ 0, 6, 12 }, index.starts.items);
    try std.testing.expectEqual(@as(?u32, 6), index.next(12, true));
    try std.testing.expectEqual(@as(?u32, 12), index.next(0, true));
    try std.testing.expectEqual(@as(?u32, 0), index.next(12, false));
    try std.testing.expectEqual(@as(usize, 2), index.ordinal(8));
    try std.testing.expectEqual(@as(usize, 0), index.ordinal(11));
    try index.ensure(a, &pt, 0, "alpha alpha");
    try std.testing.expectEqual(@as(?u32, 0), index.next(0, false));
    try std.testing.expectEqual(@as(?u32, 0), index.next(0, true));
    try index.ensure(a, &pt, 0, "missing");
    try std.testing.expect(index.next(0, false) == null);
    try index.ensure(a, &pt, 0, "");
    try std.testing.expectEqual(@as(usize, 0), index.starts.items.len);
}

test "search index: arbitrary piece boundaries and long Unicode queries" {
    const a = std.testing.allocator;
    var pt = try PieceTable.init(a, "中文END中文END");
    defer pt.deinit();
    _ = try pt.replace(6, 0, "X");
    _ = try pt.replace(6, 1, "");
    _ = try pt.replace(2, 0, "X"); // even a piece boundary inside UTF-8
    _ = try pt.replace(2, 1, "");
    var index = Index{};
    defer index.deinit(a);
    try index.ensure(a, &pt, 0, "中文END");
    try std.testing.expectEqualSlices(u32, &.{ 0, 9 }, index.starts.items);
    var query: [300]u8 = @splat('a');
    query[299] = 'z';
    _ = try pt.replace(0, pt.len(), &query);
    _ = try pt.replace(150, 0, "X");
    _ = try pt.replace(150, 1, "");
    try index.ensure(a, &pt, 1, &query);
    try std.testing.expectEqualSlices(u32, &.{0}, index.starts.items);
}

test "search index: non-overlap policy, cache reuse and edit invalidation" {
    const a = std.testing.allocator;
    var pt = try PieceTable.init(a, "aaaaa");
    defer pt.deinit();
    var index = Index{};
    defer index.deinit(a);
    try index.ensure(a, &pt, 0, "aa");
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, index.starts.items);
    const owned = index.query.?.ptr;
    try index.ensure(a, &pt, 0, "aa");
    try std.testing.expectEqual(owned, index.query.?.ptr);
    _ = try pt.replace(0, 1, "b");
    try index.ensure(a, &pt, 1, "aa");
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, index.starts.items);
    index.valid = false; // full reload may reset the history revision
    _ = try pt.replace(0, pt.len(), "aa");
    try index.ensure(a, &pt, 1, "aa");
    try std.testing.expectEqualSlices(u32, &.{0}, index.starts.items);
}

test "search index: fragmented results agree with an independent byte-string oracle" {
    const a = std.testing.allocator;
    const text = "ababa aaa 中文ababa\nfoo ababa 中文";
    var pt = try PieceTable.init(a, text);
    defer pt.deinit();
    for (0..text.len) |i| {
        _ = try pt.replace(@intCast(i), 0, "X");
        _ = try pt.replace(@intCast(i), 1, "");
    }
    var index = Index{};
    defer index.deinit(a);
    for ([_][]const u8{ "a", "aba", "aa", "中文", "\nfoo", "foo ababa", text, "absent" }) |q| {
        try index.ensure(a, &pt, 0, q);
        var expected = std.ArrayList(u32).empty;
        defer expected.deinit(a);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, q)) |hit| {
            try expected.append(a, @intCast(hit));
            from = hit + q.len;
        }
        try std.testing.expectEqualSlices(u32, expected.items, index.starts.items);
        for (0..text.len + 1) |cursor| {
            var fwd: ?u32 = null;
            var bwd: ?u32 = null;
            for (expected.items) |hit| {
                if (hit > cursor and fwd == null) fwd = hit;
                if (hit < cursor) bwd = hit;
            }
            if (expected.items.len > 0) {
                if (fwd == null) fwd = expected.items[0];
                if (bwd == null) bwd = expected.items[expected.items.len - 1];
            }
            try std.testing.expectEqual(fwd, index.next(@intCast(cursor), false));
            try std.testing.expectEqual(bwd, index.next(@intCast(cursor), true));
        }
    }
}
