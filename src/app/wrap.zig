//! Shared cell layout for soft-wrapped text. A full row wraps only before
//! the next grapheme; an insertion cursor may occupy the following empty row.
const std = @import("std");
pub const Pos = struct { row: u32 = 0, col: u32 = 0 };
pub const Layout = struct {
    width: u32,
    pos: Pos = .{},
    pub fn place(self: *Layout, cells: u32) Pos {
        if (cells > 0 and self.pos.col > 0 and self.pos.col + cells > @max(self.width, 1)) {
            self.pos.row += 1;
            self.pos.col = 0;
        }
        return self.pos;
    }
    pub fn add(self: *Layout, cells: u32) void {
        _ = self.place(cells);
        self.pos.col += @min(cells, @max(self.width, 1));
    }
    pub fn cursor(self: Layout) Pos {
        return if (self.pos.col >= @max(self.width, 1)) .{ .row = self.pos.row + 1 } else self.pos;
    }
};
test "wrap: styled segments do not consume cells beyond a full row" {
    var l = Layout{ .width = 4 };
    l.add(3);
    l.add(1);
    try std.testing.expectEqual(Pos{ .row = 1 }, l.place(1));
    l.add(1);
    try std.testing.expectEqual(Pos{ .row = 1, .col = 1 }, l.cursor());
}
test "wrap: wide grapheme leaves a gap and an exact-boundary insertion gets its own row" {
    var l = Layout{ .width = 5 };
    l.add(2);
    l.add(2);
    try std.testing.expectEqual(Pos{ .row = 1 }, l.place(2));
    l.add(2);
    l.add(3);
    try std.testing.expectEqual(Pos{ .row = 2 }, l.cursor());
}
