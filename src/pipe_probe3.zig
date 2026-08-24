const std = @import("std");
const mock = @import("lsp/mock_lsp.zig");
const testing = std.testing;

test "pipe probe: read after closing write end" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    var write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer if (write_end.handle != -1) std.Io.File.close(write_end, io);

    const c1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    try mock.writeFrameToFile(write_end, io, c1);
    std.Io.File.close(write_end, io);
    write_end.handle = -1; // mark closed so the defer no-ops

    const result = mock.readFrameFromFile(alloc, read_end, io) catch |e| {
        std.debug.print("readFrameFromFile error: {s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    const got = result orelse {
        std.debug.print("readFrameFromFile returned null (clean EOF)\n", .{});
        return error.TestUnexpectedResult;
    };
    defer alloc.free(got);
    try testing.expectEqualStrings(c1, got);
}
