//! Partition an axis into two panes and an independently owned separator.
const std = @import("std");

pub const Extents = struct {
    first: u32,
    separator: u32,
    second: u32,
};

pub fn divide(total: u32) Extents {
    const gap: u32 = if (total >= 3) 1 else 0;
    const first = total / 2;
    return .{ .first = first, .separator = gap, .second = total - first - gap };
}

/// A header never consumes the final usable source row. Invisible panes
/// have no header, and a one-row pane keeps its source/cursor accessible.
pub fn headerRows(height: u32, width: u32) u32 {
    return if (height >= 2 and width > 0) 1 else 0;
}

test "split geometry: local headers leave source cells in every visible pane" {
    for (0..81) |h| for (0..121) |w| {
        const n = headerRows(@intCast(h), @intCast(w));
        try std.testing.expect(n <= 1 and n <= h);
        if (h > 0 and w > 0) try std.testing.expect(h - n > 0);
        if (h >= 2 and w > 0) try std.testing.expectEqual(@as(u32, 1), n);
    };
}

test "split geometry: panes and separator partition even tiny and maximum extents" {
    for (0..201) |n| try expectPartition(@intCast(n));
    try expectPartition(std.math.maxInt(u32));
    try expectPartition(std.math.maxInt(u32) - 1);
}

fn expectPartition(total: u32) !void {
    const p = divide(total);
    try std.testing.expectEqual(@as(u64, total), @as(u64, p.first) + p.separator + p.second);
    try std.testing.expect(p.separator <= 1);
    if (total >= 3) {
        try std.testing.expect(p.first > 0 and p.second > 0 and p.separator == 1);
    } else try std.testing.expectEqual(@as(u32, 0), p.separator);
    if (total > 0) try std.testing.expect(p.second > 0);
    try std.testing.expect(p.first <= p.second + 1 and p.second <= p.first + 1);
}
