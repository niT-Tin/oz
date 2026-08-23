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

/// Per-test counter so tests don't share the /tmp/oz_e2e_<pid>.txt file.
var tmp_counter: usize = 0;

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

    const env_ptrs = [4]?[*:0]const u8{ "TERM=xterm-256color", "PATH=/usr/bin:/bin:/usr/local/bin", "HOME=/tmp", null };
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

/// Pack an RGB triple for Grid.fg assertions.
fn packRgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// Minimal ANSI parser that reconstructs a character grid from the terminal
/// byte stream (nvim Screen-expectations in miniature). Handles CSI cursor
/// positioning (H/f/G), SGR fg colors (38;2;r;g;b and 38:2:r:g:b), private-
/// mode and OSC sequences; ASCII only — good enough for M0 assertions.
/// Diff-rendered streams only emit changed cells, so raw byte matching is
/// unreliable; the grid is not.
const Grid = struct {
    rows: usize = 24,
    cols: usize = 80,
    buf: []u8, // rows*cols
    fg_buf: []u32, // rows*cols packed RGB (0 = default)
    bg_buf: []u32, // rows*cols packed RGB (0 = default)
    row: usize = 0,
    col: usize = 0,
    fg: u32 = 0, // current fg color (packed RGB, 0 = default)
    bg: u32 = 0, // current bg color (packed RGB, 0 = default)

    fn init(alloc: std.mem.Allocator) !Grid {
        const buf = try alloc.alloc(u8, 24 * 80);
        @memset(buf, ' ');
        const fg_buf = try alloc.alloc(u32, 24 * 80);
        @memset(fg_buf, 0);
        const bg_buf = try alloc.alloc(u32, 24 * 80);
        @memset(bg_buf, 0);
        return .{ .buf = buf, .fg_buf = fg_buf, .bg_buf = bg_buf };
    }

    fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        alloc.free(self.fg_buf);
        alloc.free(self.bg_buf);
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
                        self.fg_buf[self.row * self.cols + self.col] = self.fg;
                        self.bg_buf[self.row * self.cols + self.col] = self.bg;
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
            'm' => {
                // SGR: 0 reset, 39/49 fg/bg default, 38/48;2;r;g;b (or
                // 38/48:2:r:g:b) fg/bg
                var k: usize = 0;
                while (k < np) {
                    const p = params[k];
                    if (p == 0) {
                        self.fg = 0;
                        self.bg = 0;
                    } else if (p == 39) {
                        self.fg = 0;
                    } else if (p == 49) {
                        self.bg = 0;
                    } else if (p == 38 and k + 4 < np and params[k + 1] == 2) {
                        self.fg = packRgb(
                            @intCast(params[k + 2]),
                            @intCast(params[k + 3]),
                            @intCast(params[k + 4]),
                        );
                        k += 5;
                        continue;
                    } else if (p == 48 and k + 4 < np and params[k + 1] == 2) {
                        self.bg = packRgb(
                            @intCast(params[k + 2]),
                            @intCast(params[k + 3]),
                            @intCast(params[k + 4]),
                        );
                        k += 5;
                        continue;
                    }
                    k += 1;
                }
            },
            else => {}, // clear (J/K), modes (h/l), etc. ignored
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

    /// true if `needle` appears on any row with the given packed fg color on
    /// its first character (tree-sitter color assertions).
    fn containsFg(self: *Grid, needle: []const u8, fg: u32) bool {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            const row_text = self.buf[r * self.cols .. (r + 1) * self.cols];
            var c: usize = 0;
            while (c + needle.len <= self.cols) : (c += 1) {
                if (std.mem.eql(u8, row_text[c .. c + needle.len], needle)) {
                    if (self.fg_buf[r * self.cols + c] == fg) return true;
                }
            }
        }
        return false;
    }

    /// Raw text of one row (may contain trailing spaces).
    fn rowText(self: *Grid, r: usize) []const u8 {
        return self.buf[r * self.cols .. (r + 1) * self.cols];
    }

    /// true if any cell on row `r` has the given packed bg color (selection
    /// highlight assertions).
    fn rowHasBg(self: *Grid, r: usize, bg: u32) bool {
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            if (self.bg_buf[r * self.cols + c] == bg) return true;
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

/// true if grid row `r` (absolute) contains `needle` anywhere in its text.
/// Row-scoped asserts avoid false positives from the tab bar (file names
/// embed the test pid) or the status bar.
fn rowContains(grid: *Grid, r: usize, needle: []const u8) bool {
    return std.mem.indexOf(u8, grid.rowText(r), needle) != null;
}

test "smoke: spawn oz, render a file, quit cleanly" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // temp input file (deleted at test end, after the child has read it)
    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
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

test "insert mode: jk leaves no chars, backspace and ctrl-w delete" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "xyz\n");
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

    // --- jk: type i then jk → exits insert, and neither j nor k remains ---
    try sess.send("ijk");
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
    try std.testing.expect(grid.contains("xyz"));
    try std.testing.expect(!grid.contains("xyzj"));
    try std.testing.expect(!grid.contains("xyzk"));

    // --- backspace: $ (last char) a (append) abc BS → "xyzab" ---
    try sess.send("$aabc\x7f");
    waited = 0;
    while (!grid.contains("xyzab")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("xyzab"));
    try std.testing.expect(!grid.contains("xyzabc"));

    // --- ctrl-w (0x17): type " de" → "xyzab de", ctrl-w deletes "de" ---
    try sess.send(" de\x17");
    waited = 0;
    while (grid.contains("xyzab de")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("xyzab de"));

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

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "M1a: text objects, visual ops, yank/paste, easymotion" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one two three\n");
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
    try std.testing.expect(grid.contains("one two three"));

    // diw on "two" (after w) → "one  three"
    try sess.send("wdiw");
    waited = 0;
    while (grid.contains("one two three")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("one  three"));

    // ciw at the space → deletes "three", enters insert; type X, esc
    try sess.send("ciwX\x1b");
    waited = 0;
    while (!grid.contains("one  X")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("one  X"));

    // visual: 0 v e y (yank "one"), then $ p → "one  Xone"
    try sess.send("0vey$p");
    waited = 0;
    while (!grid.contains("one  Xone")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("one  Xone"));

    // visual: 0 v e d → delete "one" → "  Xone"
    try sess.send("0ved");
    waited = 0;
    while (grid.contains("one  Xone")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Xone"));

    // easymotion: s + 'n' (the n in Xone) + label 'a' → jump to the match
    // (the 'n'), then ciw + 'Y' replaces the whole word → "  Y"
    try sess.send("snaciwY\x1b");
    waited = 0;
    while (!grid.contains("Y") or grid.contains("Xone")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Y"));
    try std.testing.expect(!grid.contains("Xone"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "surround: ysw' wraps, ds( deletes, cs(->[ changes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        // the test types the content itself ("ihello world")
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

    // ysw' wraps the word under the cursor
    try sess.send("ihello world\x1b");
    waited = 0;
    while (!grid.contains("hello world")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("0ysw'");
    waited = 0;
    while (!grid.contains("'hello' world")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("'hello' world"));

    // ds( on the parens we add next... use change on the quotes: cs'" -> double quotes
    try sess.send("0cs'\"");
    waited = 0;
    while (!grid.contains("\"hello\" world")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("\"hello\" world"));

    // ds" removes the quotes
    try sess.send("0ds\"");
    waited = 0;
    while (grid.contains("\"hello\" world")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("hello world"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "gcc toggles line comments; Ctrl+n multi-cursor deletes words" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}.zig", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "fn main() void {\n    x = 1;\n}\n");
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

    // gcc on line 2 comments it (filetype zig → "//")
    try sess.send("jgcc");
    waited = 0;
    while (!grid.contains("// x = 1;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("// x = 1;"));

    // gcc again uncomments
    try sess.send("gcc");
    waited = 0;
    while (grid.contains("// x = 1;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("// x = 1;"));

    // multi-cursor: w onto "x", Ctrl+n Ctrl+n, then d deletes the word(s)
    try sess.send("w");
    try sess.send("\x0e\x0e");
    waited = 0;
    while (!grid.contains("x = 1;") or !grid.contains("fn main")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("d");
    waited = 0;
    while (grid.contains("x = 1;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("x = 1;"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual ga= aligns delimiter columns" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "a = 1\nlong = 22\nccc = 333\n");
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

    try sess.send("vjjga=");
    waited = 0;
    while (!grid.contains("a    = 1") or !grid.contains("ccc  = 333")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("a    = 1"));
    try std.testing.expect(grid.contains("long = 22"));
    try std.testing.expect(grid.contains("ccc  = 333"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: <leader>sf fuzzy-finds and opens a file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Spawn with a temp file so the editor starts in normal mode (not the
    // dashboard); the picker still walks the project root cwd.
    var fname_buf: [128:0]u8 = undefined;
    const fname = try std.fmt.bufPrintZ(&fname_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, fname) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, fname, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "placeholder\n");
    }
    var sess = try Session.spawn(io, &.{ oz_exe_path, fname });
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

    // <leader>sf then "main" — src/main.zig should be in the filtered list
    try sess.send(" sfmain");
    waited = 0;
    while (!grid.contains("src/main.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("src/main.zig")) {
        std.debug.print("picker grid:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("src/main.zig"));

    // Enter opens it: the buffer now shows main.zig content
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("const std = @import")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("const std = @import"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":%s substitutes across the file, :s on the current line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "foo foo\nbar foo\n");
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

    // :%s/foo/X/g — replace all across the file
    try sess.send(":%s/foo/X/g\r");
    waited = 0;
    while (!grid.contains("X X") or grid.contains("foo foo")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("X X"));
    try std.testing.expect(!grid.contains("foo"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "dashboard shows recent files; Enter reopens" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "recent file content\n");
    }

    // First run: open the file, then quit
    {
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
        try std.testing.expect(grid.contains("recent file content"));
        const code = try sess.commandAndWaitExit(":q\r");
        try std.testing.expectEqual(@as(u32, 0), code);
    }

    // Second run: no file arg → dashboard with the recent file; Enter reopens it
    {
        var sess = try Session.spawn(io, &.{oz_exe_path});
        defer sess.close();
        defer killPid(sess.pid);
        var grid = try Grid.init(alloc);
        defer grid.deinit(alloc);
        var waited: i32 = 0;
        while (!grid.contains("终端文本编辑器") or !grid.contains(name)) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
            if (n == 0) {
                waited += 200;
                if (waited >= 5000) break;
                continue;
            }
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        try std.testing.expect(grid.contains("终端文本编辑器"));
        try std.testing.expect(grid.contains(name));

        try sess.send("\r");
        waited = 0;
        while (!grid.contains("recent file content")) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
            if (n == 0) {
                waited += 200;
                if (waited >= 5000) break;
                continue;
            }
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        try std.testing.expect(grid.contains("recent file content"));

        const code = try sess.commandAndWaitExit(":q\r");
        try std.testing.expectEqual(@as(u32, 0), code);
    }
}

test "grep picker: <leader>st finds matches and jumps" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "grep target line\n");
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

    // <leader>st + "std.zig" → the grep list shows a match line
    try sess.send(" ststd.zig");
    waited = 0;
    while (!grid.contains("std.zig:")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("std.zig:"));

    // Enter jumps into the first match
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("NORMAL") or grid.contains("std.zig:")) {
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

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "file tree: <leader>e shows files, Enter opens one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "tree test\n");
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

    // <leader>e opens the tree; title + an early entry appear
    try sess.send(" e");
    waited = 0;
    while (!grid.contains(" files ") or !grid.contains("build.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains(" files "));
    try std.testing.expect(grid.contains("build.zig"));

    // Enter opens the selected entry (the first sorted file: DESIGN.md)
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("NORMAL") or grid.contains(" files ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains(" files "));
    try std.testing.expect(grid.contains("# oz")); // DESIGN.md header (ASCII part)

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "multi-buffer: :e opens a tab, gt/:bn switch, :bd closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}a.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}b.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
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
    try std.testing.expect(grid.contains("AAA"));
    try std.testing.expect(grid.contains("a.txt"));

    // :e b.txt — opens a new tab; content switches to BBB
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));

    // gt — back to a.txt
    try sess.send("gt");
    waited = 0;
    while (!grid.contains("AAA") or grid.contains("BBB")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("AAA"));

    // :bd — close the current (a.txt), falling back to b.txt
    try sess.send(":bd\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));
    try std.testing.expect(!grid.contains("AAA"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "buffer picker: <leader>sb lists open buffers, Enter switches" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}pa.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}pb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
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
    try std.testing.expect(grid.contains("AAA"));

    // :e b.txt — now two buffers open (a.txt, b.txt)
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));

    // <leader>sb — both buffer names listed, numbered 1 and 2
    try sess.send(" sb");
    const label_a = try std.fmt.allocPrint(alloc, "1 {s}", .{std.fs.path.basename(na)});
    defer alloc.free(label_a);
    const label_b = try std.fmt.allocPrint(alloc, "2 {s}", .{std.fs.path.basename(nb)});
    defer alloc.free(label_b);
    waited = 0;
    while (!grid.contains(label_a) or !grid.contains(label_b)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains(label_a) or !grid.contains(label_b)) {
        std.debug.print("buffer picker grid:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(label_a));
    try std.testing.expect(grid.contains(label_b));

    // Enter — switch back to a.txt (AAA)
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("AAA") or grid.contains("BBB")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("AAA"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "buffer keys: <leader>bn switches, <leader>bk closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}ka.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}kb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
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
    try std.testing.expect(grid.contains("AAA"));

    // :e b.txt → current is b.txt (BBB)
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));

    // <leader>bn — next buffer wraps to a.txt
    try sess.send(" bn");
    waited = 0;
    while (!grid.contains("AAA") or grid.contains("BBB")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("AAA"));

    // <leader>bk — close the current (a.txt); b.txt remains
    try sess.send(" bk");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));
    try std.testing.expect(!grid.contains("AAA"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":'<,'>s substitutes within the visual range only" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vs.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "foo\nbar\nfoo\n");
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

    // v then j: select lines 1-2. ':' should pre-fill :'<,'>
    try sess.send("vj:");
    waited = 0;
    while (!grid.contains("'<,'>")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("'<,'>")) {
        std.debug.print("cmdline grid:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("'<,'>"));

    // :'<,'>s/foo/BAZ/ — only lines 1-2 (bar) are in range; line 3 keeps foo
    try sess.send("s/foo/BAZ/\r");
    waited = 0;
    while (grid.contains("'<,'>")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BAZ"));
    try std.testing.expect(grid.contains("bar"));
    try std.testing.expect(grid.contains("foo"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("BAZ\nbar\nfoo\n", buf);
}

test "recent picker: <leader>sr lists and reopens a recent file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}ra.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}rb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }
    // seed the recent list so the picker has something to reopen
    std.Io.Dir.cwd().createDirPath(io, "/tmp/.cache/oz") catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, "/tmp/.cache/oz/recent", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, nb);
        try f.writeStreamingAll(io, "\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
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
    try std.testing.expect(grid.contains("AAA"));

    // <leader>sr — the seeded recent path is listed (filtered by basename)
    const base = std.fs.path.basename(nb);
    try sess.send(" sr");
    try sess.send(base);
    waited = 0;
    while (!grid.contains(base)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains(base)) {
        std.debug.print("recent picker grid:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(base));

    // Enter — opens the recent file (BBB)
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "tree-sitter: zig keywords/comments/strings get syntax colors" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}syn.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const x = 1; // note\n");
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

    // kanagawa palette (src/main.zig syntaxStyle): keyword gold,
    // comment faded gray, string green. Assert on the packed fg of the
    // first character of each token.
    try std.testing.expect(grid.containsFg("const", packRgb(224, 175, 104)));
    try std.testing.expect(grid.containsFg("// note", packRgb(116, 127, 148)));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "tree-sitter: files over the size limit get no highlight pass" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}big.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        // >100 KB: syntax.SIZE_LIMIT disables the highlight pass entirely
        var i: usize = 0;
        while (i < 110 * 1024) : (i += 1) {
            try f.writeStreamingAll(io, "const x = 1;\n");
        }
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
    // no gold anywhere: the pass was skipped, text renders in default fg
    try std.testing.expect(!grid.containsFg("const", packRgb(224, 175, 104)));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: <C-v> block + I/A inserts on every line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    // --- I: <C-v> (0x16 = ctrl-v) selects a 1-column block, j j grows it to
    // --- three lines, then I + "XX" types at the block's left edge on every
    // --- line at once. Esc returns to normal with a single cursor.
    try sess.send("\x16jjIXX");
    waited = 0;
    while (!grid.contains("XXaaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("XXaaa")) {
        std.debug.print("after block I:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("XXaaa"));
    try std.testing.expect(grid.contains("XXbbb"));
    try std.testing.expect(grid.contains("XXccc"));
    try std.testing.expect(!grid.contains("aXX"));
    try std.testing.expect(grid.contains("INSERT"));

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

    // --- A: 0 back to the line start, re-select a block across the full
    // --- lines (<C-v> j j $), then A + "YY" appends right after the block's
    // --- right edge — here the end of line — on every line at once.
    try sess.send("0\x16jj$AYY");
    waited = 0;
    while (!grid.contains("XXaaaYY")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("XXaaaYY")) {
        std.debug.print("after block A:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("XXaaaYY"));
    try std.testing.expect(grid.contains("XXbbbYY"));
    try std.testing.expect(grid.contains("XXcccYY"));

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

    // --- undo: each multi-cursor insert session is one undo group, so one
    // --- `u` reverts the whole A session and another reverts the whole I
    // --- session, back to the original file.
    try sess.send("u");
    waited = 0;
    while (grid.contains("XXaaaYY")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("XXaaaYY"));
    try std.testing.expect(grid.contains("XXaaa"));
    try std.testing.expect(grid.contains("XXbbb"));
    try std.testing.expect(grid.contains("XXccc"));

    try sess.send("u");
    waited = 0;
    while (grid.contains("XXaaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("XXaaa"));
    try std.testing.expect(grid.contains("aaa"));
    try std.testing.expect(grid.contains("bbb"));
    try std.testing.expect(grid.contains("ccc"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: multi-cursor backspace, ctrl-w and jk stay in sync" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    // --- jk: I + X, then j k — the 'j' is dropped at every cursor and the
    // --- insert session exits, leaving Xaaa / Xbbb / Xccc.
    try sess.send("\x16jjIXjk");
    waited = 0;
    while (!grid.contains("Xaaa") or grid.contains("INSERT")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("Xaaa") or grid.contains("INSERT")) {
        std.debug.print("after block jk:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("Xaaa"));
    try std.testing.expect(grid.contains("Xbbb"));
    try std.testing.expect(grid.contains("Xccc"));
    try std.testing.expect(!grid.contains("Xjaaa"));
    try std.testing.expect(!grid.contains("INSERT"));

    // --- backspace: I + "ab" then BS (0x7f) deletes the just-typed 'b' at
    // --- every cursor → aaaa / abbb / accc, then Esc.
    try sess.send("\x16jjIab\x7f");
    waited = 0;
    while (!grid.contains("aaaa") or grid.contains("aabaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("aaaa") or grid.contains("aabaa")) {
        std.debug.print("after block backspace:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("aaaa"));
    try std.testing.expect(grid.contains("abbb"));
    try std.testing.expect(grid.contains("accc"));
    try std.testing.expect(!grid.contains("aabaa"));
    try std.testing.expect(!grid.contains("abbbb"));
    try std.testing.expect(!grid.contains("acbcc"));
    try std.testing.expect(grid.contains("INSERT"));

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

    // --- ctrl-w (0x17): I + "foo " then Ctrl-w deletes " aaa" at every
    // --- cursor → foo / foo / foo.
    try sess.send("\x16jjIfoo \x17");
    waited = 0;
    while (!grid.contains("foo") or grid.contains("foo aaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("foo") or grid.contains("foo aaa")) {
        std.debug.print("after block ctrl-w:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("foo"));
    try std.testing.expect(!grid.contains("foo aaa"));

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

    const exit_code = try sess.commandAndWaitExit(":q\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: 非 0 列块 / 空行 clamp / 单行块边界" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        // 行 1 是空行: "aaaa\n\ncccc\n"
        try f.writeStreamingAll(io, "aaaa\n\ncccc\n");
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

    // --- 非 0 列块 + 空行 clamp: l(col 1) <C-v> j j I "XX". 光标在行 0
    // --- col 1, j 到空行时 moveVert clamp 到 col 0, 所以块左边界 = col 0:
    // --- 行 0 → XXaaaa, 空行(行尾=col 0) → XX, 行 2 → XXcccc.
    try sess.send("l\x16jjIXX");
    waited = 0;
    while (!grid.contains("XXaaaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("XXaaaa")) {
        std.debug.print("after boundary block I:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("XXaaaa"));
    try std.testing.expect(grid.contains("XXcccc"));
    try std.testing.expect(!grid.contains("aXX"));

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

    // --- 单行块: 0 回行首, <C-v> I "YY" 只影响行 0 (块只有 1 行).
    try sess.send("0\x16IYY");
    waited = 0;
    while (!grid.contains("YYXXaaaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("YYXXaaaa")) {
        std.debug.print("after single-line block:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("YYXXaaaa"));

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

    // :wq 落盘后读文件做精确断言
    const exit_code = try sess.commandAndWaitExit(":wq\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("YYXXaaaa\nXX\nXXcccc\n", buf);
}

test "file tree: sidebar scrolls as the selection moves past the window" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}f.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello\n");
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

    // <leader>e — the sidebar lists the project (29+ files, more than the
    // ~22 visible sidebar rows)
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // alphabetical order: DESIGN.md is the first entry
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(1), "DESIGN.md") != null);

    // 24 × j — the selection crosses the window bottom; the first visible
    // entry must become the second file (README.md) — the list follows
    try sess.send("jjjjjjjjjjjjjjjjjjjjjjjj");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(1), "README.md") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(1), "README.md") == null) {
        std.debug.print("filetree grid after scroll:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(1), "README.md") != null);

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: list scrolls with the selection; the highlighted row stays visible" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}p.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello\n");
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

    // <leader>sf — the project file picker (55+ entries > 10 visible rows)
    try sess.send(" sf");
    waited = 0;
    while (!grid.contains("> ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const sel_bg = packRgb(54, 74, 130);
    const list_top: usize = 24 - 1 - 10 - 1; // the picker list window
    // the selection starts on the first window row
    try std.testing.expect(grid.rowHasBg(list_top, sel_bg));

    // 15 × Ctrl+n (0x0E) — the selection crosses the window bottom; the
    // highlighted row must stay visible and no longer be the first row
    try sess.send("\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e");
    waited = 0;
    var sel_visible = false;
    var sel_not_top = false;
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        sel_visible = false;
        sel_not_top = true;
        var r: usize = list_top;
        while (r < list_top + 10) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_visible = true;
                if (r == list_top) sel_not_top = false;
            }
        }
        if (sel_visible and sel_not_top) break;
    }
    try std.testing.expect(sel_visible);
    try std.testing.expect(sel_not_top);

    // Esc closes the picker (':q' would be eaten by the filter), then quit
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("> ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: Esc exits and clears the stale selection highlight" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vl.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    const sel_bg = packRgb(54, 74, 130);

    // V (visual line) then j — the selection spans the first two lines
    try sess.send("Vj");
    waited = 0;
    var sel_visible = false;
    while (!sel_visible) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_visible = true;
                break;
            }
        }
    }
    try std.testing.expect(sel_visible);

    // Esc alone (separate write so it isn't Alt+<key>) → back to normal;
    // the selection highlight must be gone (regression: the anchor stayed
    // set and render kept painting the stale selection).
    try sess.send("\x1b");
    waited = 0;
    var sel_cleared = false;
    while (!sel_cleared) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        sel_cleared = true;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_cleared = false;
                break;
            }
        }
    }
    try std.testing.expect(sel_cleared);

    // Second path: ':' from an extended visual selection opens the command
    // line (cmdline gets "'<,'>"), then Esc cancels it — the anchor must go
    // too, or the selection highlight survives the cancel. (V alone leaves
    // anchor == cursor, which renders no highlight; Vj makes it visible.)
    try sess.send("Vj:");
    waited = 0;
    sel_visible = false;
    while (!sel_visible or !grid.contains("'<,'>")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        sel_visible = false;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_visible = true;
                break;
            }
        }
    }
    try std.testing.expect(sel_visible);

    try sess.send("\x1b");
    waited = 0;
    sel_cleared = false;
    while (!sel_cleared) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        sel_cleared = true;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_cleared = false;
                break;
            }
        }
    }
    try std.testing.expect(sel_cleared);

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: keys win over the file tree while both are open" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ft2.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello\n");
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

    const sel_bg = packRgb(54, 74, 130);

    // <leader>e — file tree sidebar
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // the sidebar selection starts on the first entry row (title is row 0)
    try std.testing.expect(grid.rowHasBg(1, sel_bg));

    // <leader>sf — fuzzy file picker over the still-open file tree
    try sess.send(" sf");
    waited = 0;
    while (!grid.contains("> ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const list_top: usize = 24 - 1 - 10 - 1; // the picker list window
    try std.testing.expect(grid.rowHasBg(list_top, sel_bg));

    // 3 × Ctrl+n — the picker selection must move down the list while the
    // file-tree selection stays put (before the fix the sidebar ate the
    // keys and its highlight jumped to row 4).
    try sess.send("\x0e\x0e\x0e");
    waited = 0;
    while (!grid.rowHasBg(list_top + 3, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(list_top + 3, sel_bg));
    // the sidebar highlight stays on row 1 (its own selection never moved)
    try std.testing.expect(grid.rowHasBg(1, sel_bg));

    // One more ↓ (ESC[B) — arrow keys are also routed to the picker now;
    // before the fix the file tree ate them and its highlight moved to row
    // 2 while the picker selection stood still.
    try sess.send("\x1b[B");
    waited = 0;
    while (!grid.rowHasBg(list_top + 4, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(list_top + 4, sel_bg));
    try std.testing.expect(grid.rowHasBg(1, sel_bg));

    // Esc closes the picker (':q' would be eaten by the filter), then quit
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("> ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: gt buffer switch drops the selection highlight" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}gta.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\nAAA\nAAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}gtb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\nBBB\nBBB\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
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

    // Move the cursor in buffer a.txt (each buffer keeps its own cursor).
    // The stale-anchor leak is only visible when the target buffer's cursor
    // differs from the leaked anchor — with both at 0 the range is empty
    // and render paints nothing.
    try sess.send("j");
    waited = 0;
    while (!grid.contains("line 2/")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 2/"));

    // :e b.txt — second buffer
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("BBB") or grid.contains("AAA")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("BBB"));

    const sel_bg = packRgb(54, 74, 130);

    // V then j — a visible selection on buffer b.txt (V alone renders no
    // highlight because anchor == cursor)
    try sess.send("Vj");
    waited = 0;
    var sel_visible = false;
    while (!sel_visible) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_visible = true;
                break;
            }
        }
    }
    try std.testing.expect(sel_visible);

    // gt in visual mode — switchBuffer → switchTo must drop the anchor, or
    // the old buffer's selection leaks onto the new buffer
    try sess.send("gt");
    waited = 0;
    while (!grid.contains("AAA") or grid.contains("BBB")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("AAA"));
    var sel_cleared = true;
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        if (grid.rowHasBg(r, sel_bg)) {
            sel_cleared = false;
            break;
        }
    }
    try std.testing.expect(sel_cleared);

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert Enter: splits the line at the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ent.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "xxabc\n");
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

    // 2l → cursor at col 2 ('a'); i; Enter (\r); Esc. "xxabc\n" (2 lines:
    // "xxabc" + trailing empty) → "xx\nabc\n" (3 lines). The byte before the
    // cursor is 'x' (not blank), so no indent is carried. Content rows start
    // at grid row 1 (row 0 is the tab bar); wait for row 2 to show "abc" so
    // the wait can't be satisfied by a stale pre-edit frame.
    try sess.send("2li\r\x1b");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(2), "abc") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(2), "abc") == null) {
        std.debug.print("after Enter split:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(1), "xx") != null);
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "abc") != null);

    // wait for Esc to land before :wq (else "\x1b" + ":" merge into alt-':')
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

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("xx\nabc\n", buf);
}

test "insert Enter: carries the current line's leading indentation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}enti.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "  abc\n");
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

    // 2l → cursor at col 2 ('a'); i; Enter. The run of blanks before the
    // cursor ("  ") is carried onto the new line: "  abc\n" → "  \n  abc\n".
    try sess.send("2li\r\x1b");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(2), "  abc") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(2), "  abc") == null) {
        std.debug.print("after Enter with indent:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "  abc") != null);

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

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("  \n  abc\n", buf);
}

test "insert Ctrl-k: kills to end of line, then joins the next line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ctl.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello world\nnext\n");
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

    // i; Ctrl+k (\x0b): cursor at col 0 kills "hello world", leaving an
    // empty first line (the newline stays): "hello world\nnext\n" (3 lines)
    // → "\nnext\n" (3 lines: empty, next, trailing empty).
    try sess.send("i\x0b");
    waited = 0;
    while (grid.contains("hello")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.contains("hello")) {
        std.debug.print("after first Ctrl-k:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains("hello"));

    // Second Ctrl-k: cursor is at the (empty) line's end, so it swallows the
    // newline, joining "next" up into line 1: "\nnext\n" → "next\n" (2 lines:
    // next + trailing empty). Esc exits insert.
    try sess.send("\x0b\x1b");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(1), "next") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(1), "next") == null) {
        std.debug.print("after second Ctrl-k:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(1), "next") != null);
    try std.testing.expect(!grid.contains("hello"));
    try std.testing.expect(grid.contains("line 1/2"));

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

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("next\n", buf);
}

test "insert Alt-b/Alt-f: emacs word motion moves the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}alt.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa bbb ccc\n");
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

    try sess.send("i");
    waited = 0;
    while (!grid.contains("INSERT")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("INSERT"));

    // "aaa bbb ccc\n" has 2 lines (trailing empty), so the statusbar reads
    // "line 1/2 col N". Alt+f (\x1bf, one write so vaxis combines ESC+f into
    // alt+f): cursor 0 → end of "aaa" (word_next_end stops on the last char,
    // vim-e semantics: col 2, not 3).
    try sess.send("\x1bf");
    waited = 0;
    while (!grid.contains("line 1/2 col 2")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("line 1/2 col 2")) {
        std.debug.print("after first Alt-f:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 1/2 col 2"));

    // Alt+f again: end of "bbb" (col 6).
    try sess.send("\x1bf");
    waited = 0;
    while (!grid.contains("line 1/2 col 6")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("line 1/2 col 6")) {
        std.debug.print("after second Alt-f:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 1/2 col 6"));

    // Alt+b (\x1bb): back to the start of "bbb" (col 4).
    try sess.send("\x1bb");
    waited = 0;
    while (!grid.contains("line 1/2 col 4")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("line 1/2 col 4")) {
        std.debug.print("after Alt-b:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 1/2 col 4"));

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

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker confirm leaves file-tree mode; j/k control the buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}g.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one\ntwo\nthree\n");
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

    // file tree open, then grep picker "fn" → confirm jumps to a project file
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // sf: the synchronous file picker (no rg subprocess latency). The
    // project lists DESIGN.md first (alphabetical) — confirming opens it
    try sess.send(" sf");
    waited = 0;
    while (!grid.contains("> ") or !grid.contains("DESIGN.md")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("> "));
    // Enter confirms DESIGN.md: the picker closes and the status bar reports
    // a real project file (663 lines, not the 3-line temp file)
    try sess.send("\r");
    waited = 0;
    var jumped = false;
    while (!jumped) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (!grid.contains("> ") and grid.contains("line 1/") and !grid.contains("line 1/3") and !grid.contains("line 1/4")) jumped = true;
    }
    try std.testing.expect(jumped);

    // j must now move the buffer cursor (line number in the status bar rises)
    try sess.send("j");
    waited = 0;
    var line2_seen = false;
    while (!line2_seen) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("line 2/")) line2_seen = true;
    }
    try std.testing.expect(line2_seen);

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line V selects whole lines from mid-line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}v.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abc\nxyz\n");
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

    // 'l' puts the cursor mid-line (col 1), V + j selects both whole lines:
    // the selection must include the first column of row 1 (line 1's start)
    const sel_bg = packRgb(54, 74, 130);
    try sess.send("lVj");
    waited = 0;
    // wait for j to actually land on line 2 (VISUAL + status "line 2/"), so
    // the selection spans both whole lines before we assert the highlight
    while (!(grid.contains(" VISUAL ") and grid.contains("line 2/"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(grid.contains(" VISUAL ") and grid.contains("line 2/"))) {
        std.debug.print("lVj: cursor did not reach line 2; status below\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(" VISUAL "));
    try std.testing.expect(grid.contains("line 2/"));
    // the first column of content rows 1 and 2 must be inside the selection
    // (whole-line selection starts at column 0), and the gutter column (0..4)
    // is not — assert the content column has the bg
    if (!grid.rowHasBg(1, sel_bg) or !grid.rowHasBg(2, sel_bg)) {
        std.debug.print("\nV select rows 1..2 bg: r1={} r2={}\n", .{ grid.rowHasBg(1, sel_bg), grid.rowHasBg(2, sel_bg) });
        var rr: usize = 1;
        while (rr <= 2) : (rr += 1) {
            std.debug.print("row{d} cols:", .{rr});
            var cc: usize = 0;
            while (cc < 12) : (cc += 1) {
                std.debug.print(" [{d}:{x}]", .{ cc, grid.bg_buf[rr * 80 + cc] });
            }
            std.debug.print("\n", .{});
        }
        grid.dump();
    }
    try std.testing.expect(grid.rowHasBg(1, sel_bg));
    try std.testing.expect(grid.rowHasBg(2, sel_bg));

    // Esc clears it
    try sess.send("\x1b");
    waited = 0;
    while (grid.rowHasBg(1, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.rowHasBg(1, sel_bg));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: Ctrl+a / Ctrl+x increment and decrement the number at the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}num.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "5\n");
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

    // cursor starts at column 0, on the '5'; Ctrl+a (0x01) → "6"
    try sess.send("\x01");
    waited = 0;
    while (!(rowContains(&grid, 1, "6") and !rowContains(&grid, 1, "5"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 1, "6") and !rowContains(&grid, 1, "5"))) {
        std.debug.print("after Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "6"));
    try std.testing.expect(!rowContains(&grid, 1, "5"));

    // back to column 0, Ctrl+x (0x18) → "5" again
    try sess.send("0\x18");
    waited = 0;
    while (!(rowContains(&grid, 1, "5") and !rowContains(&grid, 1, "6"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 1, "5") and !rowContains(&grid, 1, "6"))) {
        std.debug.print("after Ctrl+x:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "5"));
    try std.testing.expect(!rowContains(&grid, 1, "6"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("5\n", buf);
}

test "e2e: visual g Ctrl+a increments each line's first number by line offset" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}col.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "10\n10\n10\n");
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

    // V selects line 0, j j extends the selection over all three lines,
    // then g Ctrl+a (g + 0x01) is the column increment: +1, +2, +3. Content
    // rows 1..3 hold the three lines.
    try sess.send("Vjjg\x01");
    waited = 0;
    while (!(rowContains(&grid, 1, "11") and rowContains(&grid, 2, "12") and rowContains(&grid, 3, "13"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 1, "11") and rowContains(&grid, 2, "12") and rowContains(&grid, 3, "13"))) {
        std.debug.print("after g Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "11"));
    try std.testing.expect(rowContains(&grid, 2, "12"));
    try std.testing.expect(rowContains(&grid, 3, "13"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("11\n12\n13\n", buf);
}

test "e2e: multi-cursor n extends the selection; c changes words synchronously" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}mc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "foo foo foo\n");
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

    // Ctrl+n (0x0e) selects the word under the cursor; plain n extends to
    // the next match (twice → all three "foo"s); c deletes the words and
    // enters insert; "bar" applies at every cursor; Esc ends the session.
    try sess.send("\x0enncbar");
    waited = 0;
    while (!rowContains(&grid, 1, "bar bar bar")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 1, "bar bar bar")) {
        std.debug.print("after mc change:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "bar bar bar"));
    try std.testing.expect(grid.contains("INSERT"));

    // Esc alone (a burst starting with ESC would be parsed as Alt+key)
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
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("bar bar bar\n", buf);
}

test "e2e: visual Ctrl+a increments every number in the selection" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vis.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "1 2 3\n");
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

    // v (character-wise visual) then $ selects the whole line; Ctrl+a (0x01)
    // increments every number inside the selection: 1 2 3 → 2 3 4
    try sess.send("v$\x01");
    waited = 0;
    while (!rowContains(&grid, 1, "2 3 4")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 1, "2 3 4")) {
        std.debug.print("after visual Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "2 3 4"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("2 3 4\n", buf);
}

test "gutter: relative line numbers never overlap content on deep files" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // 15000 lines: the relative number at the bottom is 15000 — one digit
    // wider than the old fixed 4-digit gutter (5 digits + space = 6 cells).
    // (piece_table: every '\n' starts a line, so 14999 × "x\n" + "x" = 15000)
    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}gutter.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var i: usize = 0;
        while (i < 14999) : (i += 1) {
            try f.writeStreamingAll(io, "x\n");
        }
        try f.writeStreamingAll(io, "x"); // last line, no trailing newline
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

    // G jumps to the last line (15000); the view scrolls to the bottom and
    // the cursor row (content row 22) shows the 5-digit number "15000 ".
    try sess.send("G");
    waited = 0;
    while (!std.mem.eql(u8, grid.rowText(22)[0..6], "15000 ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!std.mem.eql(u8, grid.rowText(22)[0..6], "15000 ")) {
        std.debug.print("gutter at the bottom:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.eql(u8, grid.rowText(22)[0..6], "15000 "));

    // every visible content row: the first content cell is at the dynamic
    // gutter width (column 6, preceded by the trailing space) — line
    // numbers never run into the text
    var r: usize = 1;
    while (r < 23) : (r += 1) {
        try std.testing.expect(grid.buf[r * 80 + 6] == 'x');
        try std.testing.expect(grid.buf[r * 80 + 5] == ' ');
    }

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "filetree: zig -> md -> zig buffer switch keeps keyword highlighting" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // cwd is the project root: open a real .zig file, hop through the file
    // tree (zig → md → zig, the flow that rebuilds the highlighter via
    // ensureSyntax) and assert the last buffer re-highlights correctly.
    var sess = try Session.spawn(io, &.{ oz_exe_path, "build.zig" });
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
    // build.zig is highlighted (gold keyword) before any switch
    try std.testing.expect(grid.containsFg("const", packRgb(224, 175, 104)));

    // <leader>e: alphabetical tree — DESIGN.md is the first entry (row 1)
    try sess.send(" e");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(1), "DESIGN.md") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(1), "DESIGN.md") != null);

    // j × 1 → README.md, Enter opens it (markdown has no zig grammar)
    try sess.send("j\r");
    waited = 0;
    while (grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(0), "README.md") != null);

    // reopen the tree; the selection keeps its position (README.md, idx 1).
    // Step j one at a time until the highlighted row shows the ops.zig entry
    // (idx 6 — src/buffer/ops.zig, before piece_table.zig etc.), then Enter.
    try sess.send(" e");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(1), "DESIGN.md") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const sel_bg = packRgb(54, 74, 130);
    var ops_selected = false;
    var tries: usize = 0;
    while (!ops_selected and tries < 30) : (tries += 1) {
        var rr: usize = 1;
        while (rr < grid.rows) : (rr += 1) {
            if (grid.rowHasBg(rr, sel_bg) and std.mem.indexOf(u8, grid.rowText(rr), "ops.zig") != null) {
                ops_selected = true;
                break;
            }
        }
        if (ops_selected) break;
        try sess.send("j");
        // drain the render for this keypress so the grid is current before
        // the next check (one j at a time so we never overshoot)
        while (true) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
            if (n == 0) break;
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    if (!ops_selected) {
        std.debug.print("ops.zig not selected in the file tree:\n", .{});
        grid.dump();
    }
    try std.testing.expect(ops_selected);

    try sess.send("\r");
    waited = 0;
    while (!grid.containsFg("pub", packRgb(224, 175, 104))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.containsFg("pub", packRgb(224, 175, 104))) {
        std.debug.print("ops.zig after zig->md->zig switch:\n", .{});
        grid.dump();
    }
    // the last buffer is ops.zig: "pub" is a gold keyword, not comment gray
    try std.testing.expect(grid.containsFg("pub", packRgb(224, 175, 104)));
    try std.testing.expect(!grid.containsFg("pub", packRgb(116, 127, 148)));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: insert undo — delete-first session (backspace then typing) reverts with one u" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ud1.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abc\n");
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

    // $ (end) then a: cursor sits after 'c'; backspace (0x7f) deletes 'c',
    // then typing "XYZ" continues the same insert session. jk exits.
    try sess.send("$a\x7fXYZjk");
    waited = 0;
    while (!grid.contains("abXYZ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("abXYZ"));
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

    // one u must revert the whole insert session (the deletion AND the typing)
    try sess.send("u");
    waited = 0;
    while (!grid.contains("abc") or grid.contains("abXYZ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("abc"));
    try std.testing.expect(!grid.contains("abXYZ"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("abc\n", buf);
}

test "e2e: insert undo — type-then-delete session reverts with one u" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ud2.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abc\n");
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

    // $a then typing "XY" then backspace: the deletion joins the already-open
    // typing group. jk exits; one u reverts everything.
    try sess.send("$aXY\x7fjk");
    waited = 0;
    while (!grid.contains("abcX")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("abcX"));
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

    try sess.send("u");
    waited = 0;
    while (!grid.contains("abc") or grid.contains("abcX")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("abc"));
    try std.testing.expect(!grid.contains("abcX"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("abc\n", buf);
}

test "e2e: dd deletes the whole line under the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}dd.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    // j → line 2; dd must delete the whole line including its trailing '\n'
    // (the linewise sentinel path), so "ccc" moves up to row 2.
    try sess.send("jdd");
    waited = 0;
    while (!rowContains(&grid, 2, "ccc") or grid.contains("bbb")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 2, "ccc"));
    try std.testing.expect(!grid.contains("bbb"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("aaa\nccc\n", buf);
}

test "e2e: 2dd deletes two whole lines" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}2dd.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    // 2dd from line 1 deletes lines 1-2; "ccc" becomes row 1.
    try sess.send("2dd");
    waited = 0;
    while (!rowContains(&grid, 1, "ccc") or grid.contains("bbb")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 1, "ccc"));
    try std.testing.expect(!grid.contains("bbb"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("ccc\n", buf);
}

test "e2e: cc replaces the whole line and enters insert" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\n");
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

    // jj → last line (no trailing '\n'); cc deletes the whole line and enters
    // insert, typing "X" replaces it (row 3 becomes "X"). jk exits.
    try sess.send("jjccXjk");
    waited = 0;
    while (grid.contains("Xccc") or !rowContains(&grid, 3, "X")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("Xccc"));
    try std.testing.expect(rowContains(&grid, 3, "X"));
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
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("aaa\nbbb\nX", buf);
}

test "file tree: Ctrl-w h/l switches focus between sidebar and buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}foc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one\ntwo\nthree\nfour\nfive\n");
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
    const sel_bg = packRgb(54, 74, 130);

    // open file tree; default focus is the sidebar
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // j moves the sidebar selection to row 2 (content rows start at 1)
    try sess.send("j");
    waited = 0;
    while (!grid.rowHasBg(2, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(2, sel_bg));

    // Ctrl-w h → buffer focus; j now moves the buffer cursor (line 2, 3…)
    try sess.send("\x17");
    try sess.send("h");
    try sess.send("j");
    waited = 0;
    while (!grid.contains("line 2/")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 2/"));
    try sess.send("j");
    waited = 0;
    while (!grid.contains("line 3/")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 3/"));

    // Ctrl-w l → sidebar focus again; j moves the sidebar (highlight follows)
    try sess.send("\x17");
    try sess.send("l");
    waited = 0;
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 2000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        break;
    }
    try sess.send("j");
    waited = 0;
    var sel_moved = false;
    while (!sel_moved) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        // the sidebar selection (54,74,130) must have moved to row 3
        if (grid.rowHasBg(3, sel_bg)) sel_moved = true;
    }
    try std.testing.expect(sel_moved);

    // 'h' in the sidebar must NOT close the tree (pane switching is Ctrl-w);
    // Esc closes it and returns focus to the buffer
    try sess.send("h");
    waited = 0;
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 2000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        break;
    }
    try std.testing.expect(grid.contains("files"));
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("files"));

    const exit_code = try sess.commandAndWaitExit(":q\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}
