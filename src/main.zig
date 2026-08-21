const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const ascii = std.ascii;

const oz = @import("oz");

fn enableRawMode(fd: posix.fd_t) !posix.termios {
    const original = try posix.tcgetattr(fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.oflag.OPOST = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);
    return original;
}

fn disableRawMode(fd: posix.fd_t, original: posix.termios) void {
    posix.tcsetattr(fd, .FLUSH, original) catch {};
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const fd = posix.STDIN_FILENO;
    const original = try enableRawMode(fd);
    defer disableRawMode(fd, original);

    var buf: [1]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        if (buf[0] == 'q') break;
        if (ascii.isControl(buf[0])) {
            std.debug.print("{d}\r\n", .{buf[0]});
        } else {
            std.debug.print("{d} ('{c}')\r\n", .{buf[0], buf[0]});
        }
    }
}
