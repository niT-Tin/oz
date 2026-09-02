//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const linux = std.os.linux;
const posix = std.posix;

/// macOS PTY via libSystem (not in std.c): posix_openpt + grantpt + unlockpt
/// + ptsname. The exe links libc, so these resolve everywhere we support.
const darwin = struct {
    const O_RDWR: c_int = 0x0002;
    const O_NOCTTY: c_int = 0x20000;
    /// TIOCSWINSZ on Darwin. The value does not fit c_int, so callers
    /// @bitCast it to the signed c_int the ioctl extern wants.
    const TIOCSWINSZ: u32 = 0x80087467;
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
};

pty: std.Io.File,
tty: std.Io.File,

/// opens a new tty/pty pair
pub fn init(io: std.Io) !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(io),
        .macos => return openPtyDarwin(io),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty, io: std.Io) void {
    self.pty.close(io);
    self.tty.close(io);
}

/// sets the size of the pty
pub fn setSize(self: Pty, ws: Winsize) !void {
    const _ws: posix.winsize = .{
        .row = @truncate(ws.rows),
        .col = @truncate(ws.cols),
        .xpixel = @truncate(ws.x_pixel),
        .ypixel = @truncate(ws.y_pixel),
    };
    switch (builtin.os.tag) {
        .linux => if (linux.ioctl(self.pty.handle, 0x5414, @intFromPtr(&_ws)) != 0) // TIOCSWINSZ
            return error.SetWinsizeError,
        .macos => if (std.c.ioctl(self.pty.handle, @bitCast(darwin.TIOCSWINSZ), @intFromPtr(&_ws)) != 0)
            return error.SetWinsizeError,
        else => @compileError("unsupported os"),
    }
}

fn openPtyLinux(io: std.Io) !Pty {
    const pty = try std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{
        .mode = .read_write,
        .allow_ctty = false,
    });
    errdefer pty.close(io);

    // unlockpt
    var n: c_uint = 0;
    if (linux.ioctl(pty.handle, 0x40045431, @intFromPtr(&n)) != 0) return error.IoctlError; // TIOCSPTLCK

    // ptsname
    if (linux.ioctl(pty.handle, 0x80045430, @intFromPtr(&n)) != 0) return error.IoctlError; // TIOCGPTN
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const tty = try std.Io.Dir.openFileAbsolute(io, sname, .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    return .{
        .pty = pty,
        .tty = tty,
    };
}

/// macOS: /dev/ptmx needs no ioctls — libc's posix_openpt/grantpt/unlockpt/
/// ptsname do the whole dance. The returned fds are wrapped as Io.File.
fn openPtyDarwin(io: std.Io) !Pty {
    const master = darwin.posix_openpt(darwin.O_RDWR | darwin.O_NOCTTY);
    if (master < 0) return error.OpenPtyFailed;
    errdefer _ = std.c.close(master);
    if (darwin.grantpt(master) != 0) return error.GrantPtyFailed;
    if (darwin.unlockpt(master) != 0) return error.UnlockPtyFailed;
    const name = darwin.ptsname(master) orelse return error.PtsNameFailed;

    const pty: std.Io.File = .{ .handle = master, .flags = .{ .nonblocking = false } };
    errdefer pty.close(io);

    const tty = try std.Io.Dir.openFileAbsolute(io, std.mem.span(name), .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    return .{
        .pty = pty,
        .tty = tty,
    };
}
