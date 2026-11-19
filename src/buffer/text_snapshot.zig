//! A worker's immutable view of a single piece-table revision. Original bytes
//! are shared. Only piece descriptors and live inserted text are copied.
const std = @import("std");
const table = @import("piece_table.zig");
const Snapshot = @This();

origin: *table.OwnedOrigin,
pieces: []table.Piece,
added: []u8,
len: u32,

pub fn capture(pt: *table.PieceTable) !Snapshot {
    const a = pt.allocator;
    const pieces = try a.dupe(table.Piece, pt.pieces.items);
    errdefer a.free(pieces);
    var size: usize = 0;
    for (pieces) |p| if (p.source == .add) {
        size += p.len;
    };
    const added = try a.alloc(u8, size);
    errdefer a.free(added);
    var off: usize = 0;
    for (pieces) |*p| if (p.source == .add) {
        @memcpy(added[off..][0..p.len], pt.add.items[p.start..][0..p.len]);
        p.start = @intCast(off);
        off += p.len;
    };
    const origin = if (pt.origin_mapping == null) try pt.retainOwnedOrigin() else blk: {
        // A file mapping can change independently of this document.
        const owner = try a.create(table.OwnedOrigin);
        errdefer a.destroy(owner);
        owner.* = .{ .allocator = a, .bytes = try a.dupe(u8, pt.origin) };
        break :blk owner;
    };
    return .{ .origin = origin, .pieces = pieces, .added = added, .len = pt.len() };
}

pub fn deinit(self: Snapshot) void {
    const a = self.origin.allocator;
    a.free(self.added);
    a.free(self.pieces);
    self.origin.release();
}

pub fn bytes(self: Snapshot, p: table.Piece) []const u8 {
    const src = if (p.source == .origin) self.origin.bytes else self.added;
    return src[p.start..][0..p.len];
}

test "git snapshot owns the edited revision across further edits, compaction and close" {
    const a = std.testing.allocator;
    var t = try table.PieceTable.init(a, "one\ntwo\n");
    _ = try t.replace(0, 0, "discard me");
    _ = try t.replace(0, 10, "");
    _ = try t.replace(4, 3, "changed");
    const s = try capture(&t);
    defer s.deinit();
    try std.testing.expect(s.origin.bytes.ptr == t.origin.ptr);
    _ = try t.replace(0, t.len(), "new contents that reallocate the addition store");
    t.compact();
    t.deinit();
    try std.testing.expectEqualStrings("changed", s.added);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (s.pieces) |p| try text.appendSlice(a, s.bytes(p));
    try std.testing.expectEqualStrings("one\nchanged\n", text.items);
}
