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
