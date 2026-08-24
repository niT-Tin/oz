const std = @import("std");
const mock = @import("lsp/mock_lsp.zig");
const testing = std.testing;

test "pipe probe: exact test body, capture error" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    var write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer if (write_end.handle != -1) std.Io.File.close(write_end, io);

    const c1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const c2 = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    try mock.writeFrameToFile(write_end, io, c1);
    try mock.writeFrameToFile(write_end, io, c2);
    std.Io.File.close(write_end, io);
    write_end.handle = -1;

    const r1 = mock.readFrameFromFile(alloc, read_end, io) catch |e| {
        std.debug.print("read1 error: {s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    if (r1) |got| alloc.free(got) else {
        std.debug.print("read1 null\n", .{});
        return error.TestUnexpectedResult;
    }

    const r2 = mock.readFrameFromFile(alloc, read_end, io) catch |e| {
        std.debug.print("read2 error: {s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    if (r2) |got| alloc.free(got) else {
        std.debug.print("read2 null\n", .{});
        return error.TestUnexpectedResult;
    }

    const r3 = mock.readFrameFromFile(alloc, read_end, io) catch |e| {
        std.debug.print("read3 error: {s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    if (r3) |got| alloc.free(got) else std.debug.print("read3 null (expected)\n", .{});
}
