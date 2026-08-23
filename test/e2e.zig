//! L3 end-to-end tests (DESIGN.md §12.2): spawn the real oz binary in a pty,
//! drive it with scripted keys, capture the terminal byte stream and assert
//! on the rendered screen.
//!
//! Pattern (nvim functional tests in miniature): the pty master end is where
//! we write keys and read the terminal byte stream back; assertions check the
//! stream contains expected rendered content, not what a human would see.
//!
//! The child is forked manually (setsid + TIOCSCTTY + dup2 + execve) because
//! vaxis opens /dev/tty: the child must be a session leader with the pty slave
//! as its controlling terminal — std.process.spawn cannot arrange that.
const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

/// Installed binary, relative to the project root (the run step's cwd).
const oz_exe_path = "zig-out/bin/oz";

// Linux ioctl numbers (no libc needed).
const TIOCGPTN: u32 = 0x80045430; // get pty number
const TIOCSPTLCK: u32 = 0x40045431; // unlock pty
const TIOCSCTTY: u32 = 0x540E; // acquire controlling tty
const TIOCSWINSZ: u32 = 0x5414; // set window size

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const Pty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    fn open() !Pty {
        const master = try std.posix.openat(
            std.posix.AT.FDCWD,
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        );
        errdefer _ = linux.close(master);
        const unlock: c_int = 0;
        _ = linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));
        var n: c_int = undefined;
        _ = linux.ioctl(master, TIOCGPTN, @intFromPtr(&n));
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "/dev/pts/{d}", .{n});
        const slave = try std.posix.openat(
            std.posix.AT.FDCWD,
            name,
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        );
        errdefer _ = linux.close(slave);
        // give the pty a window size so the child's terminal queries succeed
        const ws = Winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        _ = linux.ioctl(master, TIOCSWINSZ, @intFromPtr(&ws));
        return .{ .master = master, .slave = slave };
    }

    fn close(self: *Pty) void {
        _ = linux.close(self.master);
        _ = linux.close(self.slave);
    }
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = linux.write(fd, bytes[i..].ptr, bytes[i..].len);
        switch (linux.errno(rc)) {
            .SUCCESS => i += rc,
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Poll for readability up to timeout_ms, then read whatever is available.
/// Returns 0 on timeout.
fn readAvailable(fd: std.posix.fd_t, buf: []u8, timeout_ms: i32) !usize {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = try std.posix.poll(&fds, timeout_ms);
    if (n == 0) return 0;
    return std.posix.read(fd, buf);
}

/// Fork `argv[0]` (resolved against cwd) into the pty with the slave as its
/// controlling terminal. Returns the child pid.
fn spawnChild(io: Io, pty: *Pty, argv: []const []const u8) !std.posix.pid_t {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_len = try std.Io.Dir.cwd().realPathFile(io, argv[0], &path_buf);
    path_buf[path_len] = 0;
    const exe_path: [:0]const u8 = path_buf[0..path_len :0];

    var arg_bufs: [8][256:0]u8 = undefined;
    var arg_ptrs: [8]?[*:0]const u8 = .{null} ** 8;
    var nargs: usize = 0;
    arg_ptrs[nargs] = exe_path.ptr;
    nargs += 1;
    for (argv[1..]) |a| {
        const az: [:0]u8 = try std.fmt.bufPrintZ(&arg_bufs[nargs - 1], "{s}", .{a});
        arg_ptrs[nargs] = az.ptr;
        nargs += 1;
    }
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&arg_ptrs);

    const env_ptrs = [3]?[*:0]const u8{ "TERM=xterm-256color", "PATH=/usr/bin:/bin:/usr/local/bin", null };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&env_ptrs);

    const rc = linux.fork();
    const pid: std.posix.pid_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return error.ForkFailed,
    };
    if (pid == 0) {
        _ = linux.setsid();
        _ = linux.ioctl(pty.slave, TIOCSCTTY, 0);
        _ = linux.dup2(pty.slave, 0);
        _ = linux.dup2(pty.slave, 1);
        _ = linux.dup2(pty.slave, 2);
        if (pty.master >= 3) _ = linux.close(pty.master);
        if (pty.slave >= 3) _ = linux.close(pty.slave);
        _ = linux.execve(exe_path.ptr, argv_z, envp);
        _ = linux.exit(127); // exec failed
    }
    return pid;
}

const Session = struct {
    io: Io,
    pty: Pty,
    pid: std.posix.pid_t,
    out: [65536]u8 = undefined,
    used: usize = 0,

    fn spawn(io: Io, argv: []const []const u8) !Session {
        var pty = try Pty.open();
        errdefer pty.close();
        const pid = spawnChild(io, &pty, argv) catch |e| {
            pty.close();
            return e;
        };
        errdefer killPid(pid);
        return .{ .io = io, .pty = pty, .pid = pid };
    }

    fn close(self: *Session) void {
        self.pty.close();
    }

    /// Send raw bytes to the editor's stdin (tty master).
    fn send(self: *Session, bytes: []const u8) !void {
        try writeAll(self.pty.master, bytes);
    }

    /// Read until `needle` appears in the captured stream or timeout.
    fn waitFor(self: *Session, needle: []const u8, timeout_ms: i32) !bool {
        var waited: i32 = 0;
        while (self.used < self.out.len) {
            if (std.mem.indexOf(u8, self.out[0..self.used], needle) != null) return true;
            const n = try readAvailable(self.pty.master, self.out[self.used..], 200);
            if (n == 0) {
                waited += 200;
                if (waited >= timeout_ms) return false;
                continue;
            }
            self.used += n;
        }
        return false;
    }

    fn captured(self: *Session) []const u8 {
        return self.out[0..self.used];
    }

    /// Block until the child exits; returns its exit code (or 0x100+ if
    /// signaled).
    fn waitExit(self: *Session) !u32 {
        var status: u32 = 0;
        while (true) {
            const rc = linux.waitpid(self.pid, &status, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.WaitFailed,
            }
        }
        if (linux.W.IFEXITED(status)) {
            return linux.W.EXITSTATUS(status);
        }
        return 0x100 + (status & 0x7f);
    }

    /// Non-blocking wait; null while the child still runs.
    fn tryWaitExit(self: *Session) !?u32 {
        var status: u32 = 0;
        const rc = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
                return 0x100 + (status & 0x7f);
            },
            .INTR => return try self.tryWaitExit(),
            else => return error.WaitFailed,
        }
    }

    /// Read whatever the child wrote, replying to device-status queries
    /// (ESC[5n → ESC[0n) so vaxis's stop() can unblock its reader thread —
    /// a real terminal would answer these.
    fn drainAndReply(self: *Session) !void {
        while (true) {
            const n = try readAvailable(self.pty.master, self.out[self.used..], 100);
            if (n == 0) break;
            self.used += n;
            const chunk = self.out[self.used - n .. self.used];
            if (std.mem.indexOf(u8, chunk, "\x1b[5n") != null) {
                try self.send("\x1b[0n");
            }
        }
    }

    /// Send keys, then wait for the child to exit cleanly (replying to DSR
    /// queries along the way). Returns the exit code.
    fn commandAndWaitExit(self: *Session, keys: []const u8) !u32 {
        try self.send(keys);
        var exit_code: ?u32 = null;
        var waited: i32 = 0;
        while (exit_code == null and waited < 5000) {
            try self.drainAndReply();
            exit_code = try self.tryWaitExit();
            _ = std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(200 * std.time.ns_per_ms), .real) catch {};
            waited += 200;
        }
        return exit_code orelse 0xffff;
    }
};

fn killPid(pid: std.posix.pid_t) void {
    _ = linux.kill(pid, std.posix.SIG.KILL);
}

/// Minimal ANSI parser that reconstructs a character grid from the terminal
/// byte stream (nvim Screen-expectations in miniature). Handles CSI cursor
/// positioning (H/f/G), SGR (ignored), private-mode and OSC sequences; ASCII
/// only — good enough for M0 assertions. Diff-rendered streams only emit
/// changed cells, so raw byte matching is unreliable; the grid is not.
const Grid = struct {
    rows: usize = 24,
    cols: usize = 80,
    buf: []u8, // rows*cols
    row: usize = 0,
    col: usize = 0,

    fn init(alloc: std.mem.Allocator) !Grid {
        const buf = try alloc.alloc(u8, 24 * 80);
        @memset(buf, ' ');
        return .{ .buf = buf };
    }

    fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    fn cell(self: *Grid, row: usize, col: usize) *u8 {
        return &self.buf[row * self.cols + col];
    }

    fn feed(self: *Grid, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                if (i + 1 >= bytes.len) return;
                if (bytes[i + 1] == '[') {
                    // CSI: params up to final byte 0x40-0x7e
                    var j = i + 2;
                    var params: [16]i64 = .{0} ** 16;
                    var np: usize = 0;
                    var cur: i64 = -1; // -1 = no digit seen yet
                    while (j < bytes.len) {
                        const c = bytes[j];
                        if (c >= '0' and c <= '9') {
                            if (cur < 0) cur = 0;
                            cur = cur * 10 + (c - '0');
                        } else if (c == ';' or c == ':') {
                            if (cur >= 0) {
                                if (np < 16) params[np] = cur;
                                np += 1;
                            }
                            cur = -1;
                        } else if (c >= 0x40 and c <= 0x7e) {
                            // final byte
                            if (cur >= 0) {
                                if (np < 16) params[np] = cur;
                                np += 1;
                            }
                            self.handleCsi(c, &params, np);
                            i = j + 1;
                            break;
                        } else {
                            // other param chars (?, =, etc.) — ignore
                        }
                        j += 1;
                    } else {
                        i = bytes.len; // unterminated CSI
                        continue;
                    }
                    continue;
                }
                if (bytes[i + 1] == ']') {
                    // OSC: skip until BEL or ST
                    var k = i + 2;
                    while (k < bytes.len and bytes[k] != 0x07) k += 1;
                    i = k + 1;
                    continue;
                }
                i += 2; // ESC + single char (e.g. 7/8 save-restore)
                continue;
            }
            switch (b) {
                '\r' => {
                    self.col = 0;
                    i += 1;
                },
                '\n' => {
                    if (self.row + 1 < self.rows) self.row += 1;
                    i += 1;
                },
                0x08 => { // backspace
                    if (self.col > 0) self.col -= 1;
                    i += 1;
                },
                else => {
                    if (b < 0x20) {
                        i += 1;
                        continue;
                    }
                    if (self.row < self.rows and self.col < self.cols) {
                        self.cell(self.row, self.col).* = b;
                    }
                    self.col += 1;
                    i += 1;
                },
            }
        }
    }

    fn handleCsi(self: *Grid, final: u8, params: *const [16]i64, np: usize) void {
        const p0: usize = if (np > 0 and params[0] > 0) @intCast(params[0]) else 1;
        const p1: usize = if (np > 1 and params[1] > 0) @intCast(params[1]) else 1;
        switch (final) {
            'H', 'f' => {
                self.row = @min(p0 - 1, self.rows - 1);
                self.col = @min(p1 - 1, self.cols - 1);
            },
            'G' => self.col = @min(p0 - 1, self.cols - 1),
            'd' => self.row = @min(p0 - 1, self.rows - 1),
            else => {}, // SGR (m), clear (J/K), modes (h/l), etc. ignored
        }
    }

    /// true if any row's text contains `needle`.
    fn contains(self: *Grid, needle: []const u8) bool {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            const row_text = self.buf[r * self.cols .. (r + 1) * self.cols];
            if (std.mem.indexOf(u8, row_text, needle) != null) return true;
        }
        return false;
    }

    fn dump(self: *Grid) void {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            std.debug.print("|{s}|\n", .{self.buf[r * self.cols .. (r + 1) * self.cols]});
        }
    }
};

test "smoke: spawn oz, render a file, quit cleanly" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // temp input file (deleted at test end, after the child has read it)
    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}.txt", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "line one\nline two\nline three\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    // Reconstruct the screen grid from the terminal byte stream and wait
    // until the editor has rendered the file + status bar. Diff rendering
    // only emits changed cells, so we assert on the grid, not the raw bytes.
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL") or !grid.contains("line one")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("NORMAL") or !grid.contains("line one")) {
        std.debug.print("rendered screen:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("NORMAL"));
    try std.testing.expect(grid.contains("line one"));
    try std.testing.expect(grid.contains("line two"));
    try std.testing.expect(grid.contains("line three"));

    // quit via command mode
    const exit_code = try sess.commandAndWaitExit(":q\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert text in insert mode, esc back to normal" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}.txt", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "base\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // i HELLO <esc>: chars must land in the document, then back to NORMAL
    try sess.send("iHELLO");
    waited = 0;
    while (!grid.contains("HELLObase")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("HELLObase")) {
        std.debug.print("after insert:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("HELLObase"));
    try std.testing.expect(grid.contains("INSERT"));

    try sess.send("\x1b"); // esc → normal
    waited = 0;
    while (grid.contains("INSERT")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("INSERT"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":wq writes the buffer to disk and exits" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}.txt", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "base\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // modify the buffer, then :wq
    try sess.send("iHELLO");
    waited = 0;
    while (!grid.contains("HELLObase")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("HELLObase"));

    // esc back to normal (sent alone: ESC immediately followed by ':' would
    // be parsed as Alt+':')
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("INSERT")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("INSERT"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    // the edit must have been written to disk
    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("HELLObase\n", buf);
}
