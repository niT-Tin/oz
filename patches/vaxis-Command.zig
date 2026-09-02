const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");

const linux = std.os.linux;
const posix = std.posix;

/// TIOCSCTTY per-OS (std.posix.T lacks it for Darwin). macOS uses the BSD
/// convention (0x20007461), Linux uses 0x540E.
const TIOCSCTTY: c_uint = switch (builtin.os.tag) {
    .linux => 0x540E,
    .macos => 0x20007461,
    else => @compileError("unsupported os"),
};

argv: []const []const u8,

working_directory: ?[]const u8,

// Set after spawn()
pid: ?std.posix.pid_t = null,

env_map: *const std.process.Environ.Map,

pty: Pty,

pub fn spawn(self: *Command, io: std.Io, allocator: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
    const argv_block = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_block[i] = (try arena.dupeZ(u8, arg)).ptr;
    const env_block = try self.env_map.createPosixBlock(arena, .{});
    const path = self.env_map.get("PATH") orelse std.Io.Threaded.default_PATH;

    const pid = try rawFork();
    if (pid == 0) {
        // we are the child
        rawSetsid();

        // set the controlling terminal
        var u: c_uint = std.posix.STDIN_FILENO;
        if (posix.system.ioctl(self.pty.tty.handle, TIOCSCTTY, @intFromPtr(&u)) != 0) return error.IoctlError;

        // set up io
        try rawDup2(self.pty.tty.handle, std.posix.STDIN_FILENO);
        try rawDup2(self.pty.tty.handle, std.posix.STDOUT_FILENO);
        try rawDup2(self.pty.tty.handle, std.posix.STDERR_FILENO);
        self.pty.tty.close(io);
        if (self.pty.pty.handle > 2) self.pty.pty.close(io);

        if (self.working_directory) |wd| {
            const wd_z = try posix.toPosixPath(wd);
            try rawChdir(&wd_z);
        }

        // exec
        execvpeLinux(argv_block.ptr, env_block, self.argv[0], path) catch {};
        rawExit(127);
    }

    // we are the parent
    self.pid = @intCast(pid);

    if (!Terminal.global_sigchild_installed) {
        Terminal.global_sigchild_installed = true;
        var act = posix.Sigaction{
            .handler = .{ .handler = handleSigChild },
            .mask = switch (builtin.os.tag) {
                .macos => 0,
                .linux => posix.sigemptyset(),
                else => @compileError("os not supported"),
            },
            .flags = 0,
        };
        posix.sigaction(posix.SIG.CHLD, &act, null);
    }

    return;
}

fn handleSigChild(_: posix.SIG) callconv(.c) void {
    // Only reap the terminal's own children. A waitpid(-1) here would also
    // reap the app's other children (git/grep jobs), making their own
    // wait() fail with ECHILD. Reap each registered terminal pid
    // non-blocking instead.
    Terminal.global_vt_mutex.lock(Terminal.global_io) catch return;
    defer Terminal.global_vt_mutex.unlock(Terminal.global_io);
    if (!Terminal.global_vts_alive) return; // map was freed by deinit
    var it = Terminal.global_vts.iterator();
    while (it.next()) |entry| {
        if (rawWaitpidExited(entry.key_ptr.*)) {
            entry.value_ptr.*.event_queue.push(.exited) catch {};
        }
    }
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid| {
        posix.kill(pid, posix.SIG.TERM) catch {};
        self.pid = null;
    }
}

// ---- platform wrappers: raw syscalls on Linux (no libc dependency), libc
// on macOS (the numbers differ; the app links libc everywhere) ----

fn rawFork() !posix.pid_t {
    if (builtin.os.tag == .linux) {
        const rc = linux.fork();
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => error.ForkError,
        };
    }
    const rc = std.c.fork();
    if (rc < 0) return error.ForkError;
    return rc;
}

fn rawSetsid() void {
    if (builtin.os.tag == .linux) {
        _ = linux.setsid();
    } else {
        _ = std.c.setsid();
    }
}

fn rawDup2(old: posix.fd_t, new: posix.fd_t) !void {
    if (builtin.os.tag == .linux) {
        switch (linux.errno(linux.dup2(old, new))) {
            .SUCCESS => return,
            else => return error.Dup2Failed,
        }
    }
    if (std.c.dup2(old, new) < 0) return error.Dup2Failed;
}

fn rawChdir(path: [*:0]const u8) !void {
    if (builtin.os.tag == .linux) {
        if (linux.errno(linux.chdir(path)) != .SUCCESS) return error.ChdirFailed;
        return;
    }
    if (std.c.chdir(path) != 0) return error.ChdirFailed;
}

fn rawExit(code: u8) noreturn {
    if (builtin.os.tag == .linux) {
        linux.exit(code);
    } else {
        std.c._exit(code);
    }
}

/// Non-blocking waitpid: true when the child exited.
fn rawWaitpidExited(pid: posix.pid_t) bool {
    if (builtin.os.tag == .linux) {
        var status: u32 = undefined;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        return linux.errno(rc) == .SUCCESS and rc != 0;
    }
    var status: c_int = undefined;
    // WNOHANG is 1 on both Linux and Darwin
    const rc = std.c.waitpid(pid, &status, 1);
    return rc > 0;
}

// Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
fn execvpeLinux(
    argv: [*:null]const ?[*:0]const u8,
    env_block: std.process.Environ.PosixBlock,
    arg0: []const u8,
    path: []const u8,
) !noreturn {
    // This implementation is largely copied from std/Io/Threaded.zig
    // (`spawnPosix` + `posixExecv`/`posixExecvPath`) and adapted for this PTY fork path.
    if (std.mem.indexOfScalar(u8, arg0, '/') != null) {
        const path_z = try posix.toPosixPath(arg0);
        return std.Io.Threaded.posixExecvPath(&path_z, argv, env_block);
    }

    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var err: std.process.ReplaceError = error.FileNotFound;
    var seen_eacces = false;

    while (it.next()) |dir| {
        const path_len = dir.len + arg0.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + 1 ..][0..arg0.len], arg0);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        err = std.Io.Threaded.posixExecvPath(full_path, argv, env_block);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }

    if (seen_eacces) return error.AccessDenied;
    return err;
}
