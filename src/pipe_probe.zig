const std = @import("std");
const mock = @import("lsp/mock_lsp.zig");
const testing = std.testing;

test "pipe probe" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    errdefer std.Io.File.close(write_end, io);
    const c1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    try mock.writeFrameToFile(write_end, io, c1);
    std.Io.File.close(write_end, io);
    const r1 = (try mock.readFrameFromFile(alloc, read_end, io)).?;
    defer alloc.free(r1);
    try testing.expectEqualStrings(c1, r1);
    try testing.expectEqual(@as(?[]u8, null), try mock.readFrameFromFile(alloc, read_end, io));
}
