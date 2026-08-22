const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const ascii = std.ascii;

const oz = @import("oz");

const EditorConfig = struct {
  termios: posix.termios,
};

pub fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

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
    posix.tcsetattr(fd, .FLUSH, original) catch |err| {
        std.process.fatal("error disabling raw mode: {s}", .{@errorName(err)});
    };
}

pub fn editorDrawRows(io: std.Io, stdout: std.Io.File) void {
    for (0..24) |_| {
        stdout.writeStreamingAll(io, "~\r\n") catch |err| {
            std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
        };
    }
}

pub fn editorReadKey(io: std.Io, stdin: std.Io.File) !u8 {
    var buf: [1]u8 = undefined;
    const n = stdin.readStreaming(io, &.{&buf}) catch |err| {
        std.process.fatal("read error: {s}", .{@errorName(err)});
    };
    _ = n;
    return buf[0];
}

pub fn editorRefreshScreen(io: std.Io, stdout: std.Io.File) void {
    // vt100转义序列，清空屏幕内容
    stdout.writeStreamingAll(io, "\x1b[2J") catch |err| {
        std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
    };
    // 将光标才重新设置到左上角
    stdout.writeStreamingAll(io, "\x1b[H") catch |err| {
        std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
    };
    // 绘制~, 表示这些行为非文件内容，类似vim
    editorDrawRows(io, stdout);
    // 绘制完成后，继续将光标放置到左上角
    stdout.writeStreamingAll(io, "\x1b[H") catch |err| {
        std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
    };
}

pub fn editorProcessKeypress(io: std.Io, stdin: std.Io.File, stdout: std.Io.File) void {
    const char: u8 = editorReadKey(io, stdin) catch |err| {
        std.process.fatal("cannot read editor key: {s}", .{@errorName(err)});
    };

    switch (char) {
        ctrlKey('q') => {
            stdout.writeStreamingAll(io, "\x1b[2J") catch |err| {
                std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
            };
            stdout.writeStreamingAll(io, "\x1b[H") catch |err| {
                std.process.fatal("error refresh screen: {s}", .{@errorName(err)});
            };
            std.process.exit(0);
        },
        else => {
            std.debug.print("{d} ('{c}')\r\n", .{ char, char });
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const fd = stdin.handle;
    const original = enableRawMode(fd) catch |err| {
        std.process.fatal("error enabling raw mode: {s}", .{@errorName(err)});
    };
    defer disableRawMode(fd, original);

    while (true) {
        editorRefreshScreen(init.io, stdout);
        editorProcessKeypress(init.io, stdin, stdout);
    }
}
