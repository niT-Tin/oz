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
        return openRows(24);
    }

    /// Open a pty with a custom height (rows). Most tests use the default
    /// 24-row terminal; the inlay-viewport tests need a taller one so the
    /// request window's coverage of the visible rows is observable.
    fn openRows(rows: u16) !Pty {
        return openSize(rows, 80);
    }

    /// Open a pty with a custom height AND width (the AI workspace tests
    /// drive a 120-column docked rail and an 80-column drawer).
    fn openSize(rows: u16, cols: u16) !Pty {
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
        const ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
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

/// Run a command in the TEST process (not the pty child) to completion with
/// `cwd`, capturing stdout (owned; empty on spawn/failure). Used by the git
/// tests to set up and inspect a temp repository.
fn runCmdCapture(io: Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) ![]u8 {
    var proc = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return &.{};
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    if (proc.stdout) |f| {
        while (true) {
            const n = f.readStreaming(io, &.{tmp[0..]}) catch break;
            if (n == 0) break;
            out.appendSlice(alloc, tmp[0..n]) catch break;
        }
        // NOT closed here: proc.wait() closes the child's pipes; closing them
        // early makes its cleanup hit EBADF (recoverableOsBugDetected panics)
    }
    _ = proc.wait(io) catch {};
    return out.toOwnedSlice(alloc);
}

/// Write `text` into `dir`/`name` (test-process helper for temp repos).
fn writeTestFile(io: Io, dir: []const u8, name: []const u8, text: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

/// Fork `argv[0]` (resolved against cwd) into the pty with the slave as its
/// controlling terminal. Returns the child pid.
fn spawnChild(io: Io, pty: *Pty, argv: []const []const u8) !std.posix.pid_t {
    return spawnChildEnv(io, pty, argv, null);
}

/// spawnChild with extra environment entries appended to the fixed base env
/// (TERM/PATH/HOME) — used to inject OZ_LSP_CMD for mock-server tests.
fn spawnChildEnv(io: Io, pty: *Pty, argv: []const []const u8, env_extra: ?[]const []const u8) !std.posix.pid_t {
    return spawnChildEnvCwd(io, pty, argv, env_extra, null);
}

/// spawnChildEnv plus a cwd to chdir into before exec — the git tests run oz
/// inside a temp git repo (git commands resolve the repo from the cwd).
fn spawnChildEnvCwd(io: Io, pty: *Pty, argv: []const []const u8, env_extra: ?[]const []const u8, cwd: ?[]const u8) !std.posix.pid_t {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_len = try std.Io.Dir.cwd().realPathFile(io, argv[0], &path_buf);
    path_buf[path_len] = 0;
    const exe_path: [:0]const u8 = path_buf[0..path_len :0];

    var arg_bufs: [8][256:0]u8 = undefined;
    var arg_ptrs: [8]?[*:0]const u8 = @splat(null);
    var nargs: usize = 0;
    arg_ptrs[nargs] = exe_path.ptr;
    nargs += 1;
    for (argv[1..]) |a| {
        const az: [:0]u8 = try bufPrintZ(&arg_bufs[nargs - 1], "{s}", .{a});
        arg_ptrs[nargs] = az.ptr;
        nargs += 1;
    }
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&arg_ptrs);

    var env_bufs: [12][256:0]u8 = undefined;
    var env_ptrs: [13]?[*:0]const u8 = @splat(null);
    var nenv: usize = 0;
    const base_env = [_][]const u8{ "TERM=xterm-256color", "PATH=/usr/bin:/bin:/usr/local/bin", "HOME=/tmp" };
    outer: for (base_env) |e| {
        const key = e[0..(std.mem.indexOfScalar(u8, e, '=') orelse e.len)];
        if (env_extra) |extra| {
            // env_extra entries with the same key override the base entry (theme tests pass their own
            // HOME=... so their persisted state stays out of the shared /tmp)
            for (extra) |x| {
                const xkey = x[0..(std.mem.indexOfScalar(u8, x, '=') orelse x.len)];
                if (std.mem.eql(u8, xkey, key)) continue :outer;
            }
        }
        const ez: [:0]u8 = try bufPrintZ(&env_bufs[nenv], "{s}", .{e});
        env_ptrs[nenv] = ez.ptr;
        nenv += 1;
    }
    if (env_extra) |extra| {
        for (extra) |e| {
            const ez: [:0]u8 = try bufPrintZ(&env_bufs[nenv], "{s}", .{e});
            env_ptrs[nenv] = ez.ptr;
            nenv += 1;
        }
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&env_ptrs);

    const rc = linux.fork();
    const pid: std.posix.pid_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return error.ForkFailed,
    };
    if (pid == 0) {
        if (cwd) |c| {
            var cwd_buf: [256:0]u8 = undefined;
            const cwd_z: [:0]u8 = bufPrintZ(&cwd_buf, "{s}", .{c}) catch linux.exit(126);
            _ = linux.chdir(cwd_z.ptr); // raw syscall in the forked child
        }
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
    // 1 MiB capture buffer: a single full-color frame of a syntax-highlighted
    // file is ~60KB (every cell carries two 38;2/48;2 SGR sequences), and a
    // session with LSP status frames + overlays can exceed 64KB. A full
    // buffer silently starves every later waitFor/readAvailable (0 bytes →
    // timeout), which makes tests that open big colored files flaky.
    out: [1 << 20]u8 = undefined,
    used: usize = 0,

    fn spawn(io: Io, argv: []const []const u8) !Session {
        return spawnEnv(io, argv, null);
    }

    fn spawnEnv(io: Io, argv: []const []const u8, env_extra: ?[]const []const u8) !Session {
        return spawnEnvRows(io, argv, env_extra, 24);
    }

    /// spawnEnv with a custom pty height (rows).
    fn spawnEnvRows(io: Io, argv: []const []const u8, env_extra: ?[]const []const u8, rows: u16) !Session {
        return spawnEnvSize(io, argv, env_extra, rows, 80);
    }

    /// spawnEnv with a custom pty size (AI workspace tests).
    fn spawnEnvSize(io: Io, argv: []const []const u8, env_extra: ?[]const []const u8, rows: u16, cols: u16) !Session {
        return spawnEnvSizeCwd(io, argv, env_extra, rows, cols, null);
    }

    /// spawnEnvSize plus a cwd. Golden frames run in a fixed, non-git temp
    /// directory so status-bar/workspace metadata is deterministic.
    fn spawnEnvSizeCwd(
        io: Io,
        argv: []const []const u8,
        env_extra: ?[]const []const u8,
        rows: u16,
        cols: u16,
        cwd: ?[]const u8,
    ) !Session {
        var pty = try Pty.openSize(rows, cols);
        errdefer pty.close();
        const pid = spawnChildEnvCwd(io, &pty, argv, env_extra, cwd) catch |e| {
            pty.close();
            return e;
        };
        errdefer killPid(pid);
        return .{ .io = io, .pty = pty, .pid = pid };
    }

    /// Spawn with a specific cwd (git tests run inside a temp repo).
    fn spawnCwd(io: Io, argv: []const []const u8, cwd: []const u8) !Session {
        var pty = try Pty.open();
        errdefer pty.close();
        const pid = spawnChildEnvCwd(io, &pty, argv, null, cwd) catch |e| {
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
        var status: i32 = 0;
        while (true) {
            const rc = linux.waitpid(self.pid, &status, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.WaitFailed,
            }
        }
        if (linux.W.IFEXITED(waitStatusBits(status))) {
            return linux.W.EXITSTATUS(waitStatusBits(status));
        }
        return 0x100 + (waitStatusBits(status) & 0x7f);
    }

    /// Non-blocking wait; null while the child still runs.
    fn tryWaitExit(self: *Session) !?u32 {
        var status: i32 = 0;
        const rc = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                if (linux.W.IFEXITED(waitStatusBits(status))) return linux.W.EXITSTATUS(waitStatusBits(status));
                return 0x100 + (waitStatusBits(status) & 0x7f);
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
/// Terminal cell width of a decoded codepoint, for the screen
/// reconstruction. Grid slots are cells, not codepoints: a CJK glyph is one
/// UTF-8 character but occupies TWO columns, so advancing one column per
/// codepoint shifted every border to the right of it three cells left for
/// "第三行". Nerd Font icons live in the Private Use Area and stay width 1.
fn glyphCells(cp: u21) usize {
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33FF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE10 and cp <= 0xFE19) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE6B) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F000 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x3FFFD) return 2;
    return 1;
}

/// Zig 0.16's std.fmt.bufPrintZ became bufPrintSentinel(buf, fmt, args, 0)
/// in 0.17; every e2e path/argv construction wants a NUL-terminated slice.
fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

/// waitpid(2) writes an int, but Zig 0.17's W* helpers still take u32.
fn waitStatusBits(status: i32) u32 {
    return @bitCast(status);
}

const Grid = struct {
    rows: usize = 24,
    cols: usize = 80,
    /// rows*cols*4: one UTF-8-capable slot per cell (a Nerd Font icon is 3
    /// bytes but ONE cell, so columns must count characters, not bytes —
    /// otherwise vaxis's diff updates land in the wrong column).
    buf: []u8,
    fg_buf: []u32, // rows*cols packed RGB (0 = default)
    bg_buf: []u32, // rows*cols packed RGB (0 = default)
    /// SGR 58 underline color (0 = default) and SGR 4 underline state.
    /// Active chrome tabs use a colored single underline; recording it lets
    /// the theme-matrix test prove the underline follows `accent_alt`
    /// instead of inheriting the label fg.
    ul_buf: []u32 = &.{},
    ul_on_buf: []bool = &.{},
    row: usize = 0,
    col: usize = 0,
    fg: u32 = 0, // current fg color (packed RGB, 0 = default)
    bg: u32 = 0, // current bg color (packed RGB, 0 = default)
    ul: u32 = 0, // current underline color (packed RGB, 0 = default)
    ul_on: bool = false, // SGR 4 single underline active
    /// Scratch buffer for rowText (one row of compressed cells; the AI
    /// workspace tests use 120 columns with 4-byte box-drawing glyphs).
    row_text_buf: [160 * 4]u8 = undefined,
    /// Allocator for the pending-tail combine (set by init).
    alloc: std.mem.Allocator,
    /// Truncated escape/UTF-8 sequence tail from the last feed: pty reads
    /// split sequences at arbitrary byte boundaries, and without stashing
    /// the tail the continuation bytes print as TEXT and corrupt the grid
    /// (a split SGR like "ESC[48:2:42:42:5" + "5m" painted ":42:42:55m"
    /// into the status row).
    pending: [128]u8 = undefined,
    pending_len: usize = 0,

    fn init(alloc: std.mem.Allocator) !Grid {
        return initSized(alloc, 24);
    }

    /// init with a custom terminal height (rows); the inlay-viewport tests
    /// run a 40-row terminal so a request window narrower than the viewport
    /// leaves visible rows without hints.
    fn initSized(alloc: std.mem.Allocator, rows: usize) !Grid {
        return initSizedCols(alloc, rows, 80);
    }

    /// init with a custom terminal size. `cols` must match the pty width or
    /// cells past the default 80 columns are dropped.
    fn initSizedCols(alloc: std.mem.Allocator, rows: usize, cols: usize) !Grid {
        const buf = try alloc.alloc(u8, rows * cols * 4);
        @memset(buf, 0);
        const fg_buf = try alloc.alloc(u32, rows * cols);
        @memset(fg_buf, 0);
        const bg_buf = try alloc.alloc(u32, rows * cols);
        @memset(bg_buf, 0);
        const ul_buf = try alloc.alloc(u32, rows * cols);
        @memset(ul_buf, 0);
        const ul_on_buf = try alloc.alloc(bool, rows * cols);
        @memset(ul_on_buf, false);
        return .{
            .rows = rows,
            .cols = cols,
            .buf = buf,
            .fg_buf = fg_buf,
            .bg_buf = bg_buf,
            .ul_buf = ul_buf,
            .ul_on_buf = ul_on_buf,
            .alloc = alloc,
        };
    }

    fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        alloc.free(self.fg_buf);
        alloc.free(self.bg_buf);
        alloc.free(self.ul_buf);
        alloc.free(self.ul_on_buf);
    }

    /// The 4-byte slot for one screen cell.
    fn cell(self: *Grid, row: usize, col: usize) *[4]u8 {
        return self.buf[(row * self.cols + col) * 4 ..][0..4];
    }

    /// Save a truncated tail for the next feed (bounded; an over-long tail
    /// is dropped rather than corrupting the grid).
    fn stashPending(self: *Grid, tail: []const u8) void {
        const n = @min(tail.len, self.pending.len);
        @memcpy(self.pending[0..n], tail[0..n]);
        self.pending_len = n;
    }

    fn feed(self: *Grid, bytes: []const u8) void {
        if (self.pending_len > 0) {
            const combined = self.alloc.alloc(u8, self.pending_len + bytes.len) catch {
                self.pending_len = 0;
                self.feedBytes(bytes);
                return;
            };
            defer self.alloc.free(combined);
            @memcpy(combined[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(combined[self.pending_len..], bytes);
            self.pending_len = 0;
            self.feedBytes(combined);
            return;
        }
        self.feedBytes(bytes);
    }

    fn feedBytes(self: *Grid, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                if (i + 1 >= bytes.len) {
                    self.stashPending(bytes[i..]);
                    return;
                }
                if (bytes[i + 1] == '[') {
                    // CSI: params up to final byte 0x40-0x7e
                    var j = i + 2;
                    var params: [16]i64 = @splat(0);
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
                        // unterminated CSI (split across reads): stash the
                        // tail so the continuation parses as one sequence
                        self.stashPending(bytes[i..]);
                        return;
                    }
                    continue;
                }
                if (bytes[i + 1] == ']') {
                    // OSC: skip until BEL (0x07) or ST (ESC \). vaxis emits
                    // OSC 52 clipboard writes with the ST terminator, not
                    // BEL; only looking for BEL swallowed the rest of the
                    // stream (Screen.feed stashed it as "pending"), freezing
                    // every test after a yank/delete.
                    var k = i + 2;
                    var found = false;
                    while (k < bytes.len) {
                        if (bytes[k] == 0x07) {
                            k += 1;
                            found = true;
                            break;
                        }
                        if (bytes[k] == 0x1b) {
                            if (k + 1 >= bytes.len) break; // split ST
                            if (bytes[k + 1] == '\\') {
                                k += 2;
                                found = true;
                                break;
                            }
                        }
                        k += 1;
                    }
                    if (!found) {
                        self.stashPending(bytes[i..]);
                        return;
                    }
                    i = k;
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
                    // one UTF-8 character = one cell (icons are 3 bytes)
                    var ln: usize = 1;
                    if (b >= 0xC0) {
                        ln = if (b < 0xE0) 2 else (if (b < 0xF0) 3 else 4);
                    }
                    if (i + ln > bytes.len) {
                        // truncated UTF-8 at the chunk end — stash for the
                        // next feed (a partial memcpy renders U+FFFD junk)
                        self.stashPending(bytes[i..]);
                        return;
                    }
                    // Decode the codepoint so wide glyphs advance two
                    // cells (the second cell is left blank, as a terminal
                    // does: the glyph covers both columns).
                    var cp: u21 = b;
                    if (ln == 2) {
                        cp = (@as(u21, b & 0x1F) << 6) | @as(u21, bytes[i + 1] & 0x3F);
                    } else if (ln == 3) {
                        cp = (@as(u21, b & 0x0F) << 12) |
                            (@as(u21, bytes[i + 1] & 0x3F) << 6) |
                            @as(u21, bytes[i + 2] & 0x3F);
                    } else if (ln == 4) {
                        cp = (@as(u21, b & 0x07) << 18) |
                            (@as(u21, bytes[i + 1] & 0x3F) << 12) |
                            (@as(u21, bytes[i + 2] & 0x3F) << 6) |
                            @as(u21, bytes[i + 3] & 0x3F);
                    }
                    const cells = glyphCells(cp);
                    if (self.row < self.rows and self.col < self.cols) {
                        const slot = self.cell(self.row, self.col);
                        @memset(slot, 0);
                        @memcpy(slot[0..ln], bytes[i .. i + ln]);
                        self.fg_buf[self.row * self.cols + self.col] = self.fg;
                        self.bg_buf[self.row * self.cols + self.col] = self.bg;
                        self.ul_buf[self.row * self.cols + self.col] = self.ul;
                        self.ul_on_buf[self.row * self.cols + self.col] = self.ul_on;
                        var extra: usize = 1;
                        while (extra < cells and self.col + extra < self.cols) : (extra += 1) {
                            @memset(self.cell(self.row, self.col + extra), 0);
                            self.fg_buf[self.row * self.cols + self.col + extra] = self.fg;
                            self.bg_buf[self.row * self.cols + self.col + extra] = self.bg;
                            self.ul_buf[self.row * self.cols + self.col + extra] = self.ul;
                            self.ul_on_buf[self.row * self.cols + self.col + extra] = self.ul_on;
                        }
                    }
                    self.col += cells;
                    i += ln;
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
                        self.ul = 0;
                        self.ul_on = false;
                    } else if (p == 39) {
                        self.fg = 0;
                    } else if (p == 49) {
                        self.bg = 0;
                    } else if (p == 59) {
                        self.ul = 0;
                    } else if (p == 4) {
                        self.ul_on = true;
                    } else if (p == 24) {
                        self.ul_on = false;
                    } else if (p == 58 and k + 4 < np and params[k + 1] == 2) {
                        self.ul = packRgb(
                            @intCast(params[k + 2]),
                            @intCast(params[k + 3]),
                            @intCast(params[k + 4]),
                        );
                        k += 5;
                        continue;
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
            // EL (erase in line, ESC[K): clear from the cursor column to the
            // end of the row — without it a SHORTER status bar redraw leaves
            // the previous longer text's tail behind (stale "⎇ master")
            'K' => {
                var c = self.col;
                while (c < self.cols) : (c += 1) {
                    @memset(self.cell(self.row, c), 0);
                    self.fg_buf[self.row * self.cols + c] = 0;
                    self.bg_buf[self.row * self.cols + c] = 0;
                    self.ul_buf[self.row * self.cols + c] = 0;
                    self.ul_on_buf[self.row * self.cols + c] = false;
                }
            },
        }
    }

    /// true if any row's text contains `needle`.
    fn contains(self: *Grid, needle: []const u8) bool {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            const row_text = self.rowText(r);
            if (std.mem.indexOf(u8, row_text, needle) != null) return true;
        }
        return false;
    }

    /// true if `needle` appears on any row with the given packed fg color on
    /// its first character (tree-sitter color assertions). Cell-aware: walks
    /// the row cell by cell and matches the needle at cell boundaries, so
    /// multi-byte glyphs (Nerd Font icons, "│" borders, CJK text) do NOT
    /// shift the byte offset away from the cell column — the old byte-based
    /// scan read the fg of a cell to the right whenever a row contained a
    /// multi-byte char, and could run past the row text on partially-painted
    /// rows.
    fn containsFg(self: *Grid, needle: []const u8, fg: u32) bool {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            const row_text = self.rowText(r);
            var byte: usize = 0;
            var c: usize = 0;
            while (c < self.cols and byte < row_text.len) : (c += 1) {
                const slot = self.buf[(r * self.cols + c) * 4 ..][0..4];
                var k: usize = 0;
                while (k < 4 and slot[k] != 0) : (k += 1) {}
                if (k == 0) continue; // empty cell (never painted)
                if (byte + needle.len <= row_text.len and
                    std.mem.eql(u8, row_text[byte .. byte + needle.len], needle))
                {
                    if (self.fg_buf[r * self.cols + c] == fg) return true;
                }
                byte += k;
            }
        }
        return false;
    }

    /// packed fg of the first "│" (indent guide) on row `row`, or null when
    /// the row has no guide.
    fn guideFg(self: *Grid, row: usize) ?u32 {
        const row_text = self.rowText(row);
        const idx = std.mem.indexOf(u8, row_text, "│") orelse return null;
        return self.fg_buf[row * self.cols + idx];
    }

    /// packed fg of the `n`-th "│" (indent guide, 0-based) on row `row`, or
    /// null when the row has fewer guides — distinguishes the scope's own
    /// guide column from outer levels' guides on the same line. Scans the
    /// per-cell slots directly so the "│" (3 UTF-8 bytes) is matched per
    /// cell and the cell index IS the column.
    fn guideFgAt(self: *Grid, row: usize, n: usize) ?u32 {
        var seen: usize = 0;
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            const slot = self.buf[(row * self.cols + c) * 4 ..][0..4];
            if (std.mem.startsWith(u8, slot, "│")) {
                if (seen == n) return self.fg_buf[row * self.cols + c];
                seen += 1;
            }
        }
        return null;
    }

    /// Text of one row, compressed from the per-cell slots (each UTF-8 char
    /// occupies one slot; the slot's bytes up to the first NUL form the char).
    fn rowText(self: *Grid, r: usize) []const u8 {
        const base = r * self.cols * 4;
        var w: usize = 0;
        var c: usize = 0;
        while (c < self.cols and w < self.row_text_buf.len) : (c += 1) {
            const slot = self.buf[base + c * 4 ..][0..4];
            var k: usize = 0;
            while (k < 4 and slot[k] != 0 and w + k < self.row_text_buf.len) : (k += 1) {
                self.row_text_buf[w + k] = slot[k];
            }
            w += k;
        }
        return self.row_text_buf[0..w];
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

    /// true if EVERY cell on row `r` has the given bg — used to assert a
    /// floating window's panel is a solid theme-colored block (no gaps of
    /// editor background at the row's right edge).
    fn rowAllBg(self: *Grid, r: usize, bg: u32) bool {
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            if (self.bg_buf[r * self.cols + c] != bg) return false;
        }
        return true;
    }

    /// Byte offset into rowText(r) where column `c` starts. Cells hold
    /// variable-width UTF-8 glyphs, so a byte-level slice of rowText can
    /// split a glyph in half; slicing at this offset always lands on a cell
    /// boundary.
    fn rowByteOf(self: *Grid, r: usize, c: usize) usize {
        const base = r * self.cols * 4;
        var off: usize = 0;
        var col: usize = 0;
        while (col < c and col < self.cols) : (col += 1) {
            const slot = self.buf[base + col * 4 ..][0..4];
            var k: usize = 0;
            while (k < 4 and slot[k] != 0) : (k += 1) {}
            off += k;
        }
        return off;
    }

    fn dump(self: *Grid) void {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            std.debug.print("|{s}|\n", .{self.rowText(r)});
        }
    }
};

/// true if grid row `r` (absolute) contains `needle` anywhere in its text.
/// Row-scoped asserts avoid false positives from the tab bar (file names
/// embed the test pid) or the status bar.
fn rowContains(grid: *Grid, r: usize, needle: []const u8) bool {
    return std.mem.indexOf(u8, grid.rowText(r), needle) != null;
}

/// Index of the first grid row containing `needle`, or null.
fn findRow(grid: *Grid, needle: []const u8) ?usize {
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        if (rowContains(grid, r, needle)) return r;
    }
    return null;
}

/// true if `needle` appears on row `r` with the given packed fg color on its
/// first character (row-scoped containsFg). Pins a syntax-color assertion to
/// one row — e.g. the grep preview column, where the left list may show the
/// same token in a different color.
fn rowContainsFg(grid: *Grid, r: usize, needle: []const u8, fg: u32) bool {
    const row_text = grid.rowText(r);
    var byte: usize = 0;
    var c: usize = 0;
    while (c < grid.cols and byte < row_text.len) : (c += 1) {
        const slot = grid.buf[(r * grid.cols + c) * 4 ..][0..4];
        var k: usize = 0;
        while (k < 4 and slot[k] != 0) : (k += 1) {}
        if (k == 0) continue; // empty cell (never painted)
        if (byte + needle.len <= row_text.len and
            std.mem.eql(u8, row_text[byte .. byte + needle.len], needle))
        {
            if (grid.fg_buf[r * grid.cols + c] == fg) return true;
        }
        byte += k;
    }
    return false;
}

/// Column (0-based) of the n-th "│" (0-based) on row `r`, or null when the
/// row has fewer pipes. Used to pin the grep panel's split-separator column
/// across the empty and filled states (the panel must not resize).
fn nthPipeCol(grid: *Grid, r: usize, n: usize) ?usize {
    var seen: usize = 0;
    var c: usize = 0;
    while (c < grid.cols) : (c += 1) {
        const slot = grid.buf[(r * grid.cols + c) * 4 ..][0..4];
        if (std.mem.startsWith(u8, slot, "│")) {
            if (seen == n) return c;
            seen += 1;
        }
    }
    return null;
}

/// Column of the one-cell `glyph` on row `r`, starting at `from`, or null.
/// Compares whole CELLS (a Nerd Font/CJK glyph is up to 4 UTF-8 bytes but
/// occupies exactly one grid slot), which is what border alignment needs.
fn glyphCol(grid: *Grid, r: usize, glyph: []const u8, from: usize) ?usize {
    var c = from;
    while (c < grid.cols) : (c += 1) {
        const slot = grid.buf[(r * grid.cols + c) * 4 ..][0..4];
        var k: usize = 0;
        while (k < 4 and slot[k] != 0) : (k += 1) {}
        if (std.mem.eql(u8, slot[0..k], glyph)) return c;
    }
    return null;
}

fn lastGlyphCol(grid: *Grid, r: usize, glyph: []const u8) ?usize {
    var c: usize = grid.cols;
    while (c > 0) {
        c -= 1;
        const slot = grid.buf[(r * grid.cols + c) * 4 ..][0..4];
        var k: usize = 0;
        while (k < 4 and slot[k] != 0) : (k += 1) {}
        if (std.mem.eql(u8, slot[0..k], glyph)) return c;
    }
    return null;
}

/// Assert that the rounded box whose top border is on `top` is rectangular:
/// every content row's left/right │ sit exactly under ╭/╮, and the bottom
/// ╰/╯ closes at the same columns. Returns the bottom-border row.
/// This is the screenshot regression: a row whose padding is counted in
/// BYTES ("→" = 3 bytes / 1 cell) ends short, so its right │ drifts left of
/// the corner and the panel gets a notch.
fn assertPopupBox(grid: *Grid, top: usize) !usize {
    const left = glyphCol(grid, top, "╭", 0) orelse return error.TestUnexpectedResult;
    const right = glyphCol(grid, top, "╮", 0) orelse return error.TestUnexpectedResult;
    var r = top + 1;
    while (r < grid.rows) : (r += 1) {
        if (glyphCol(grid, r, "╯", 0)) |bottom| {
            try std.testing.expectEqual(right, bottom);
            return r;
        }
        const l = glyphCol(grid, r, "│", 0) orelse return error.TestUnexpectedResult;
        const rr = lastGlyphCol(grid, r, "│") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(left, l);
        try std.testing.expectEqual(right, rr);
    }
    return error.TestUnexpectedResult;
}

/// Feed the pty until `needle` disappears from the screen (or timeout).
fn gridWaitGone(sess: *Session, grid: *Grid, needle: []const u8, timeout_ms: i32) !void {
    var waited: i32 = 0;
    while (grid.contains(needle)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= timeout_ms) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.contains(needle)) {
        std.debug.print("'{s}' still visible:\n", .{needle});
        grid.dump();
    }
    try std.testing.expect(!grid.contains(needle));
}

/// Feed the pty into `grid` until `needle` is on screen (or timeout).
fn gridWaitFor(sess: *Session, grid: *Grid, needle: []const u8, timeout_ms: i32) !void {
    var waited: i32 = 0;
    while (!grid.contains(needle)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= timeout_ms) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains(needle)) {
        std.debug.print("missing '{s}':\n", .{needle});
        grid.dump();
    }
    try std.testing.expect(grid.contains(needle));
}

/// Parse the first visible `<label><n>ms` pair (label includes its trailing
/// space, e.g. `"avg "` / `"p95 "`). Used to prove the Tools-tab latency text
/// is a real number from the recorded samples, not a fabricated constant.
fn gridMetricMs(grid: *Grid, label: []const u8) ?u32 {
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        const text = grid.rowText(r);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, label)) |at| {
            var i = at + label.len;
            const start = i;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i > start and i + 2 <= text.len and std.mem.eql(u8, text[i .. i + 2], "ms")) {
                return std.fmt.parseInt(u32, text[start..i], 10) catch null;
            }
            from = at + label.len;
        }
    }
    return null;
}

// ---- feat/mouse: pty mouse-sequence helpers (SGR 1006, CELL coordinates) ----
//
// vaxis parses SGR mouse reports as 0-based cells; the wire format is
// 1-based. `press` uses 'M', release 'm'; wheel is a press with button
// 64 (up) / 65 (down). A real click is press+release.
fn sendMouseButton(sess: *Session, col: usize, row: usize, button: u32, release: bool) !void {
    var buf: [64]u8 = undefined;
    const coord_col = col + 1;
    const coord_row = row + 1;
    const seq = if (release)
        try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}m", .{ button, coord_col, coord_row })
    else
        try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{ button, coord_col, coord_row });
    try sess.send(seq);
}

fn mouseClickAt(sess: *Session, col: usize, row: usize) !void {
    try sendMouseButton(sess, col, row, 0, false);
    try sendMouseButton(sess, col, row, 0, true);
}

fn mouseWheelAt(sess: *Session, col: usize, row: usize, direction: i8) !void {
    const button: u32 = if (direction < 0) 64 else 65;
    try sendMouseButton(sess, col, row, button, false);
}

/// Mouse-enable / mouse-reset sequences vaxis emits (ctlseqs.zig). Testing
/// the raw bytes proves the terminal is restored after quit.
const mouse_enable_seq = "\x1b[?1002;1003;1004;1006h";
const mouse_reset_seq = "\x1b[?1002;1003;1004;1006;1016l";

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
}

/// Like gridWaitFor but scoped to one screen row (the rail header names a
/// thread that also appears in the thread list, so row identity matters).
fn gridWaitRowContains(sess: *Session, grid: *Grid, row: usize, needle: []const u8, timeout_ms: i32) !void {
    var waited: i32 = 0;
    while (waited < timeout_ms) : (waited += 50) {
        if (row < grid.rows and aiRowContains(grid, row, needle)) return;
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    if (row >= grid.rows or !aiRowContains(grid, row, needle)) {
        std.debug.print("row {d} missing '{s}':\n", .{ row, needle });
        grid.dump();
    }
    try std.testing.expect(row < grid.rows and aiRowContains(grid, row, needle));
}

/// Buffer-tab body width from tabstrip.plan (fixed chrome 9, min 20,
/// max 26) for an ASCII basename.
fn tabBodyWidth(name_cells: usize) usize {
    const want = 9 + name_cells;
    return @min(@max(want, 20), 26);
}

test "mouse: buffer tab click switches, close × closes, at 80/100/120" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    inline for ([_]u16{ 80, 100, 120 }) |cols| {
        var a_buf: [160:0]u8 = undefined;
        const path_a = try bufPrintZ(&a_buf, "/tmp/ozmouse_{d}_{d}_a.txt", .{ linux.getpid(), tmp_counter });
        var b_buf: [160:0]u8 = undefined;
        const path_b = try bufPrintZ(&b_buf, "/tmp/ozmouse_{d}_{d}_b.txt", .{ linux.getpid(), tmp_counter });
        tmp_counter += 1;
        defer std.Io.Dir.cwd().deleteFile(io, path_a) catch {};
        defer std.Io.Dir.cwd().deleteFile(io, path_b) catch {};
        {
            const fa = try std.Io.Dir.cwd().createFile(io, path_a, .{ .truncate = true });
            defer fa.close(io);
            try fa.writeStreamingAll(io, "MOUSE_A_MARK\n");
            const fb = try std.Io.Dir.cwd().createFile(io, path_b, .{ .truncate = true });
            defer fb.close(io);
            try fb.writeStreamingAll(io, "MOUSE_B_MARK\n");
        }

        var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, path_a }, null, 24, cols);
        defer sess.close();
        defer killPid(sess.pid);
        var grid = try Grid.initSizedCols(alloc, 24, cols);
        defer grid.deinit(alloc);
        try gridWaitFor(&sess, &grid, "NORMAL", 8000);
        try gridWaitFor(&sess, &grid, "MOUSE_A_MARK", 5000);

        // Second buffer: two tabs. Geometry comes from tabstrip.plan:
        // body = clamp(9 fixed cells + filename cells, 20, 26), next tab one
        // separator cell later, × at body_end-3.
        var cmd_buf: [256]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, ":e {s}\r", .{path_b});
        try sess.send(cmd);
        try gridWaitFor(&sess, &grid, "MOUSE_B_MARK", 5000);
        try std.testing.expect(!grid.contains("MOUSE_A_MARK"));

        const w_a = tabBodyWidth(std.fs.path.basename(path_a).len);
        const x_b = w_a + 1;
        const w_b = tabBodyWidth(std.fs.path.basename(path_b).len);

        // Click the first tab body → buffer A.
        try mouseClickAt(&sess, 5, 0);
        try gridWaitFor(&sess, &grid, "MOUSE_A_MARK", 5000);
        // Click the second tab body → buffer B.
        try mouseClickAt(&sess, x_b + 5, 0);
        try gridWaitFor(&sess, &grid, "MOUSE_B_MARK", 5000);
        try frame.expectNoHorizontalOverflow(&grid, cols);

        // Dirty B, then close it through the tab's × (the SAME closeBufferAt
        // path as :bd).
        try sess.send("iZ");
        std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
        try sess.send("\x1b");
        std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
        try gridWaitFor(&sess, &grid, "\u{25cf}", 3000);
        try mouseClickAt(&sess, x_b + w_b - 3, 0);
        try gridWaitFor(&sess, &grid, "MOUSE_A_MARK", 5000);
        try std.testing.expect(!grid.contains("MOUSE_B_MARK"));
        try std.testing.expect(!grid.contains("\u{25cf}"));
        try frame.expectNoHorizontalOverflow(&grid, cols);

        const exit_code = try sess.commandAndWaitExit(":q!\r");
        try std.testing.expectEqual(@as(u32, 0), exit_code);
    }
}

test "mouse: navigator tabs, filetree row, notes row, wheel move/clamp" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/ozmouse_nav_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var docs_dir_buf: [200]u8 = undefined;
    const docs_dir = try std.fmt.bufPrint(&docs_dir_buf, "{s}/docs", .{root});
    try std.Io.Dir.cwd().createDirPath(io, docs_dir);
    var src_dir_buf: [200]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_dir_buf, "{s}/src", .{root});
    try std.Io.Dir.cwd().createDirPath(io, src_dir);
    var name_buf: [200:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "{s}/root.txt", .{root});
    try aiWriteFile(io, root, "root.txt", "MOUSE_NAV_MARK\n");
    try aiWriteFile(io, docs_dir, "workspace-plan.md", "# plan\n");
    try aiWriteFile(io, src_dir, "main.zig", "// main\n");

    var notes_buf: [128]u8 = undefined;
    const notes_dir = try notesTestDir(io, &notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    try aiWriteFile(io, notes_dir, "alpha.md", "# Alpha note\n\nsnippet body\n");
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, name }, &.{notes_env}, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "docs", 5000);
    try gridWaitFor(&sess, &grid, "root.txt", 5000);

    // Tab targets move as real counts arrive, so resolve the label column
    // from the DRAWN frame before each click (hint/mouse rectangles use the
    // same layout).
    var notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, notes_col + 1, navTabsRow());
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    const files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, files_col + 1, navTabsRow());
    try gridWaitFor(&sess, &grid, "docs", 5000);

    // First content row is docs/. Click expands exactly like Enter; click
    // again collapses.
    try mouseClickAt(&sess, 5, navBodyRow());
    try gridWaitFor(&sess, &grid, "workspace-plan", 5000);
    try mouseClickAt(&sess, 5, navBodyRow());
    try gridWaitGone(&sess, &grid, "workspace-plan", 5000);

    // Wheel down selects the next row (src); clamp is proven by scrolling far
    // up afterwards and toggling the row that must be selected.
    try mouseWheelAt(&sess, 5, navBodyRow(), 1);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "main.zig", 5000);
    for (0..20) |_| try mouseWheelAt(&sess, 5, navBodyRow(), -1);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "workspace-plan", 5000);

    // Notes row click opens the note in the editor (its buffer tab appears;
    // the editor body owns "# Alpha note", the list only shows the title).
    notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, notes_col + 1, navTabsRow());
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try mouseClickAt(&sess, 5, navBodyRow());
    try gridWaitFor(&sess, &grid, "# Alpha note", 5000);
    try std.testing.expect(aiRowContains(&grid, 0, "alpha.md"));

    // Agents tab click initializes/shows the real thread model.
    const agents_col = navTabStart(&grid, "Agents") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, agents_col + 1, navTabsRow());
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try std.testing.expect(grid.contains("NORMAL"));
    try frame.expectNoHorizontalOverflow(&grid, 120);

    try aiQuit(&sess);
}

test "mouse: split pane focuses and places cursor; separator/status are no-ops; wheel clamps" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/ozmouse_{d}_{d}split.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 30, 100);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 100);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "line1", 5000);

    // :vs — vertical split (left 0..49, separator col 50, right 50..99).
    try sess.send(":vs\r");
    var waited: i32 = 0;
    while (waited < 5000) : (waited += 100) {
        const row = grid.rowText(2);
        const first = std.mem.indexOf(u8, row, "line1");
        const second = if (first) |f| std.mem.indexOfPos(u8, row, f + 1, "line1") else null;
        if (first != null and second != null) break;
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) continue;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "│") != null);

    // Left pane click on line 3, text cell 2 (gutter=2 for 9 lines).
    try mouseClickAt(&sess, 4, 4);
    try gridWaitFor(&sess, &grid, "line 3/9 col 2", 5000);

    // Right pane click on line 5, text cell 1.
    try mouseClickAt(&sess, 53, 6);
    try gridWaitFor(&sess, &grid, "line 5/9 col 1", 5000);

    // Clicking the separator must NOT resize or move the cursor (v1 no-op).
    try mouseClickAt(&sess, 50, 6);
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    try std.testing.expect(grid.contains("line 5/9 col 1"));

    // Wheel over the right pane: 3 lines per notch, clamped at the file end
    // and the file start without overflow.
    try mouseWheelAt(&sess, 53, 6, 1);
    try gridWaitFor(&sess, &grid, "line 8/9 col 1", 5000);
    try mouseWheelAt(&sess, 53, 6, 1);
    try gridWaitFor(&sess, &grid, "line 9/9 col 1", 5000);
    for (0..5) |_| try mouseWheelAt(&sess, 53, 6, -1);
    try gridWaitFor(&sess, &grid, "line 1/9 col 1", 5000);

    // Cursor placement: click line 2 cell 3 in the LEFT pane, insert Q at the
    // mapped byte (line2: l/i/n/e/2 → insert before 'e').
    try mouseClickAt(&sess, 5, 3);
    try gridWaitFor(&sess, &grid, "line 2/9 col 3", 5000);
    try sess.send("iQ");
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try gridWaitFor(&sess, &grid, "linQe2", 5000);

    // Right pane click line 5 cell 1 → insert R after 'l'.
    try mouseClickAt(&sess, 53, 6);
    try gridWaitFor(&sess, &grid, "line 5/9 col 1", 5000);
    try sess.send("iR");
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try gridWaitFor(&sess, &grid, "lRine5", 5000);

    // Clicking the status band (no target) is a no-op.
    try mouseClickAt(&sess, 80, 29);
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    // The status band has no target: no mode/cursor/layout change.
    try std.testing.expect(grid.contains("line 5/9"));
    try std.testing.expect(grid.contains("NORMAL"));
    try frame.expectNoHorizontalOverflow(&grid, 100);

    // Two split windows: :q! closes one, :qa! quits the editor.
    const exit_code = try sess.commandAndWaitExit(":qa!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "mouse: AI thread row attach, workbox tabs, prompt focus, transcript wheel" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/ozmouse_{d}_{d}ai.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "MOUSE_AI_MARK\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var reply = std.ArrayList(u8).empty;
    defer reply.deinit(alloc);
    for (0..30) |i| {
        var line_buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "L{d:0>2} reply", .{i});
        try reply.appendSlice(alloc, line);
        if (i + 1 < 30) try reply.appendSlice(alloc, "\\n");
    }
    const stream = try aiTextSse(alloc, reply.items);
    defer alloc.free(stream);
    try aiWriteFile(io, dir, "stream-1.sse", stream);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    const rail_col = aiRailCol(120);
    try aiEnterRail(&sess, &grid);
    // From the prompt, Tab returns to the thread list; `n` then creates
    // thread 2 (the prompt would otherwise swallow the key as text).
    try sess.send("\t");
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try gridWaitRowContains(&sess, &grid, aiWorkboxHeaderRow(30), "thread 2", 3000);

    // Click thread 1 in the rail's thread list (row 2) → attach it.
    try mouseClickAt(&sess, rail_col + 4, 2);
    try gridWaitRowContains(&sess, &grid, aiWorkboxHeaderRow(30), "thread 1", 5000);

    // Workbox tab clicks: tools then chat.
    const tabs_row = aiTabsRow(30);
    const tools_col = aiCellIndexOf(&grid, tabs_row, "tools").?;
    try mouseClickAt(&sess, tools_col + 1, tabs_row);
    try gridWaitFor(&sess, &grid, "no tool calls yet", 5000);
    const chat_col = aiCellIndexOf(&grid, tabs_row, "chat").?;
    try mouseClickAt(&sess, chat_col + 1, tabs_row);
    try gridWaitFor(&sess, &grid, "❯ ", 5000);

    // Prompt row click focuses the input; typing streams the long reply.
    try mouseClickAt(&sess, rail_col + 6, aiPromptRow(30));
    try sess.send("hello");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "L29 reply", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try frame.expectNoHorizontalOverflow(&grid, 120);

    // Wheel over the transcript (3 rows/notch): scroll up to the first line.
    for (0..6) |_| try mouseWheelAt(&sess, rail_col + 5, aiTabsSepRow(30) + 1, -1);
    try gridWaitFor(&sess, &grid, "L00 reply", 5000);
    try std.testing.expect(grid.contains("NORMAL"));

    // Leave the prompt focus (Esc) before typing the quit command.
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try aiQuit(&sess);
}

test "mouse: approve/reject buttons act on the real pending edit and keep disk untouched" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/ozmouse_appr_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/appr.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "ALPHA old marker\nsecond line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_mouse_a", .name = "edit_file", .args = "{\"path\":\"appr.txt\",\"old_string\":\"old marker\",\"new_string\":\"NEW marker\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "FIRST staged follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const round3 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_mouse_b", .name = "edit_file", .args = "{\"path\":\"appr.txt\",\"old_string\":\"second line\",\"new_string\":\"SECOND NEW\"}" },
    });
    defer alloc.free(round3);
    try aiWriteFile(io, dir, "stream-3.sse", round3);
    const round4 = try aiTextSse(alloc, "SECOND staged follow-up");
    defer alloc.free(round4);
    try aiWriteFile(io, dir, "stream-4.sse", round4);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "ALPHA old marker", 5000);

    const rail_col = aiRailCol(120);
    try aiEnterRail(&sess, &grid);
    try sess.send("edit the marker");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "approve", 5000);

    // Click the Changes tab (real workbox tab target), then the Approve
    // button's visible label ("approve" is inside the expanded target).
    const tabs_row = aiTabsRow(30);
    try mouseClickAt(&sess, aiCellIndexOf(&grid, tabs_row, "changes").? + 1, tabs_row);
    try gridWaitFor(&sess, &grid, "[a] approve", 5000);
    const approve_cell = aiFindCell(&grid, "[a] approve") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, approve_cell.col + 4, approve_cell.row);
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "ALPHA NEW marker", 5000);
    try std.testing.expect(!grid.contains("approval required"));
    const disk_before = try absFileText(io, alloc, editor);
    defer alloc.free(disk_before);
    try std.testing.expectEqualStrings("ALPHA old marker\nsecond line\n", disk_before);

    // Stage a second edit through the prompt (mouse focus). The prompt only
    // exists on the Chat tab, so click Chat first, then the prompt row.
    const tabs_row2 = aiTabsRow(30);
    try mouseClickAt(&sess, aiCellIndexOf(&grid, tabs_row2, "chat").? + 1, tabs_row2);
    try gridWaitFor(&sess, &grid, "❯ ", 5000);
    try mouseClickAt(&sess, rail_col + 6, aiPromptRow(30));
    try sess.send("edit the second line");
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "[a] approve", 5000);
    try mouseClickAt(&sess, aiCellIndexOf(&grid, tabs_row2, "changes").? + 1, tabs_row2);
    try gridWaitFor(&sess, &grid, "[r] reject", 5000);
    const reject_cell = aiFindCell(&grid, "[r] reject") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, reject_cell.col + 4, reject_cell.row);
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try std.testing.expect(grid.contains("ALPHA NEW marker"));
    try std.testing.expect(!grid.contains("SECOND NEW"));
    try frame.expectNoHorizontalOverflow(&grid, 120);

    const disk_after = try absFileText(io, alloc, editor);
    defer alloc.free(disk_after);
    try std.testing.expectEqualStrings("ALPHA old marker\nsecond line\n", disk_after);

    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try aiQuit(&sess);
}

test "mouse: reporting lifecycle restores the terminal; Alt+r stays clean; no hint labels" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/ozmouse_{d}_{d}life.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "MOUSE_LIFE_MARK\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "MOUSE_LIFE_MARK", 5000);

    // Mouse reporting is enabled exactly once at startup; no labels are
    // drawn outside hint mode.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(sess.captured(), mouse_enable_seq));
    try std.testing.expect(!grid.contains("HINTS"));

    // Regression from 1b47588: Alt+r opens the embedded terminal with no
    // vaxis diagnostic spam while mouse reporting is active.
    try sess.send("\x1br");
    try gridWaitFor(&sess, &grid, "$", 8000);
    try std.testing.expect(!grid.contains("warning("));
    try std.testing.expect(!grid.contains("info("));
    try std.testing.expect(!grid.contains("couldn't write uri"));

    // Esc returns keyboard focus to the editor; clicking the visible
    // terminal again focuses it (click target is the overlay rect).
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try mouseClickAt(&sess, 20, 10);
    try sess.send("echo MOUSE_TERM_FOCUS\r");
    try gridWaitFor(&sess, &grid, "MOUSE_TERM_FOCUS", 8000);

    // Wheel over the focused terminal is not stolen by the editor: the
    // cursor/status stay where they were (no scroll behind the overlay).
    try mouseWheelAt(&sess, 20, 10, 1);
    try mouseWheelAt(&sess, 20, 10, -1);
    std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
    try std.testing.expect(grid.contains("line 1/2"));
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    // Cleanup: exactly one reset, after the enable, and the alt screen is
    // left. No subsequent enable means no raw mouse reporting is leaked.
    const captured = sess.captured();
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(captured, mouse_reset_seq));
    const enable_pos = std.mem.lastIndexOf(u8, captured, mouse_enable_seq) orelse return error.TestUnexpectedResult;
    const reset_pos = std.mem.lastIndexOf(u8, captured, mouse_reset_seq) orelse return error.TestUnexpectedResult;
    try std.testing.expect(reset_pos > enable_pos);
    try std.testing.expect(std.mem.indexOfPos(u8, captured, reset_pos, mouse_enable_seq) == null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "\x1b[?1049l") != null);
}

test "smoke: spawn oz, render a file, quit cleanly" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // temp input file (deleted at test end, after the child has read it)
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert text in insert mode, esc back to normal" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    // i HELLO <esc>: chars must land in the document, then back to NORMAL.
    // A single Esc exits: buffer-word auto-suggest excludes the word being
    // typed, so typing HELLO into "base" opens no menu.
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":wq writes the buffer to disk and exits" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    // be parsed as Alt+':'). Single Esc: buffer auto-suggest excludes the
    // word being typed, so typing HELLO into "base" opens no menu.
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

test "relative CLI path: :w saves without BadPathName" {
    // The e2e harness runs with cwd = project root; open the file via a
    // relative path (e.g. `oz relsave/oz_e2e_...txt`), edit, and :w — the
    // saved path must resolve correctly, not produce BadPathName (which
    // happens when the stored path contains a NUL byte).
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const abs = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}rel.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    // relative path from the project root to the same file
    var rel_path_buf: [256:0]u8 = undefined;
    const rel_path = try bufPrintZ(&rel_path_buf, "../../../../tmp/{s}", .{abs["/tmp/".len..]});
    defer std.Io.Dir.cwd().deleteFile(io, abs) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, abs, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "base\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, rel_path });
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
    if (!grid.contains("NORMAL")) {
        std.debug.print("relative-path grid after spawn:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("NORMAL"));

    try sess.send("iHELLO\x1b");
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

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    // the relative path must have saved to the right file
    const f2 = try std.Io.Dir.cwd().openFile(io, abs, .{ .mode = .read_only });
    defer f2.close(io);
    const size2 = (try f2.stat(io)).size;
    const buf2 = try alloc.alloc(u8, @intCast(size2));
    defer alloc.free(buf2);
    _ = try f2.readPositionalAll(io, buf2, 0);
    try std.testing.expectEqualStrings("HELLObase\n", buf2);
}

test "path with spaces: :w saves (no BadPathName)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz e2e sp {d} {d}.txt", .{ linux.getpid(), tmp_counter });
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
    if (!grid.contains("NORMAL")) {
        std.debug.print("space-path grid after spawn:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("NORMAL"));

    try sess.send("iHELLO\x1b");
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

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f3 = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f3.close(io);
    const size3 = (try f3.stat(io)).size;
    const buf3 = try alloc.alloc(u8, @intCast(size3));
    defer alloc.free(buf3);
    _ = try f3.readPositionalAll(io, buf3, 0);
    try std.testing.expectEqualStrings("HELLObase\n", buf3);
}

test ":theme lists themes, switches colors, rejects unknown names" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}th.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\n");
    }

    // isolated HOME: :theme switches are persisted now, keep them out of the shared /tmp
    // unique HOME: :theme persists the choice on exit, so a fixed path
    // poisons the next run's "default is kanagawa" assertion
    var home_buf: [96]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "HOME=/tmp/oz_e2e_th_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{home});
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

    // default theme is kanagawa-wave: bg 0x1F1F28
    const kanagawa_bg = packRgb(0x1F, 0x1F, 0x28);
    try std.testing.expect(grid.rowHasBg(2, kanagawa_bg));

    // :theme with no arg lists the available themes in the status bar
    try sess.send(":theme\r");
    waited = 0;
    while (!grid.contains("themes: ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("themes: kanagawa-wave"));
    // The list is longer than the 80-col status line; assert an early
    // entry that is actually visible (tokyonight starts past column 80).
    try std.testing.expect(grid.contains("catppuccin-macchiato"));

    // switch to tokyonight-moon: bg becomes 0x1E2032
    try sess.send(":theme tokyonight-moon\r");
    waited = 0;
    const moon_bg = packRgb(0x1E, 0x20, 0x32);
    while (!grid.rowHasBg(2, moon_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(2, moon_bg));
    try std.testing.expect(!grid.rowHasBg(2, kanagawa_bg));

    // unknown theme → status message
    try sess.send(":theme bogus\r");
    waited = 0;
    while (!grid.contains("unknown theme")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("unknown theme"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "theme picker: <leader>sp lists themes, previews live, Esc restores" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}thp.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello\n");
    }

    // isolated HOME: Enter persists the theme now, keep it out of the shared /tmp
    var home_buf: [96]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "HOME=/tmp/oz_e2e_thp_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{home});
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

    // <leader>sp opens the theme picker: " Themes " title + all 3 themes.
    // While the picker is open the status bar is not drawn, so the screen's
    // bottom row (below the centered box) is the plain editor bg.
    try sess.send(" sp");
    waited = 0;
    while (!grid.contains(" Themes ") or !grid.contains("kanagawa-wave")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains(" Themes "));
    try std.testing.expect(grid.contains("kanagawa-wave"));
    try std.testing.expect(grid.contains("catppuccin-macchiato"));
    try std.testing.expect(grid.contains("tokyonight-moon"));
    // default theme is kanagawa: the whole screen (row 23 included) is its bg.
    // The picker's first frame may still have the old status-bar cells on
    // row 23; wait for the full repaint before asserting.
    waited = 0;
    while (!grid.rowAllBg(23, packRgb(0x1F, 0x1F, 0x28))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowAllBg(23, packRgb(0x1F, 0x1F, 0x28)));

    // ↓ (ESC[B) previews catppuccin-macchiato LIVE: the entire UI repaints
    // with catppuccin's colors — row 23 is now catppuccin's bg (0x24273A)
    try sess.send("\x1b[B");
    waited = 0;
    while (!grid.rowAllBg(23, packRgb(0x24, 0x27, 0x3A))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowAllBg(23, packRgb(0x24, 0x27, 0x3A)));
    // the picker panel itself re-skins too: its float bg is now catppuccin's
    // crust (0x1E2030), no longer kanagawa's waveBlue1 (0x223249)
    try std.testing.expect(grid.rowHasBg(6, packRgb(0x1E, 0x20, 0x30)));
    try std.testing.expect(!grid.rowHasBg(6, packRgb(0x22, 0x32, 0x49)));

    // Esc cancels: the picker closes AND kanagawa is restored — the status
    // bar comes back with kanagawa's bg_status (0x2A2A37) on the last row
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains(" Themes ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains(" Themes "));
    try std.testing.expect(grid.rowHasBg(23, packRgb(0x2A, 0x2A, 0x37)));
    try std.testing.expect(!grid.rowHasBg(23, packRgb(0x30, 0x34, 0x46)));

    // reopen, preview catppuccin again, Enter CONFIRMS: the theme stays
    // catppuccin after the picker closes (status row bg_status = 0x303446)
    // and the status bar reports it
    try sess.send(" sp");
    waited = 0;
    while (!grid.contains(" Themes ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains(" Themes "));
    try sess.send("\x1b[B\r");
    waited = 0;
    while (!grid.contains("theme: catppuccin-macchiato")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("theme: catppuccin-macchiato"));
    try std.testing.expect(grid.rowHasBg(23, packRgb(0x30, 0x34, 0x46)));
    try std.testing.expect(!grid.rowHasBg(23, packRgb(0x2A, 0x2A, 0x37)));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert mode: jk leaves no chars, backspace and ctrl-w delete" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "auto-pairs: openers close, closers skip, backspace deletes empty pair" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    // '(' pairs to '()' with the cursor between; typing ')' over the
    // auto-inserted closer skips it (no duplicate).
    try sess.send("$a(ab);");
    waited = 0;
    while (!grid.contains("xyz(ab);")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("xyz(ab);"));
    try std.testing.expect(!grid.contains("xyz(ab));"));

    // quotes pair too, and a second '"' skips over the auto-inserted one.
    // (Esc closes any open completion menu and exits insert in one press.)
    try sess.send("\x1b\x1bo\"ab\";");
    waited = 0;
    while (!grid.contains("\"ab\";")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("\"ab\";"));
    try std.testing.expect(!grid.contains("\"ab\"\";"));

    // backspace between the braces of an empty pair deletes BOTH sides
    try sess.send("\x1b\x1bo{\x7fz;");
    waited = 0;
    while (!grid.contains("z;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("z;"));
    try std.testing.expect(!grid.contains("{z"));

    try sess.send("\x1b\x1b"); // Esc exits insert (the extra Esc is a normal-mode no-op)
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "search: / ? n N jump between matches; :<number> jumps to line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}search.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha\nbeta\ngamma\nbeta again\n");
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

    // Regression guard for the original bug: typing into the search cmdline
    // must NEVER leak into the buffer as normal-mode commands ('bg_fl' used
    // to execute b / g / f-l / o and insert "at" into the document).
    // /beta -> line 2
    try sess.send("/beta\r");
    waited = 0;
    while (!grid.contains("line 2/5")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 2/5"));
    try std.testing.expect(grid.contains("alpha")); // buffer untouched
    try std.testing.expect(!grid.contains("betaa")); // no leaked insert

    // n -> next match wraps to line 4 ("beta again")
    try sess.send("n");
    waited = 0;
    while (!grid.contains("line 4/5")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 4/5"));

    // N -> opposite direction: back to line 2
    try sess.send("N");
    waited = 0;
    while (!grid.contains("line 2/5")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 2/5"));

    // ?gamma from line 2: backward wraps to line 3
    try sess.send("?gamma\r");
    waited = 0;
    while (!grid.contains("line 3/5")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 3/5"));

    // :1 jumps to the first line (also covers :<number> parsing)
    try sess.send(":1\r");
    waited = 0;
    while (!grid.contains("line 1/5")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 1/5"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "M1a: text objects, visual ops, yank/paste, easymotion" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "surround: ysw' wraps, ds( deletes, cs(->[ changes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "gcc toggles line comments; Ctrl+n multi-cursor deletes words" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}.zig", .{linux.getpid()});
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual ga= aligns delimiter columns" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: <leader>sf fuzzy-finds and opens a file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Spawn with a temp file so the editor starts in normal mode (not the
    // dashboard); the picker still walks the project root cwd.
    var fname_buf: [128:0]u8 = undefined;
    const fname = try bufPrintZ(&fname_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":%s substitutes across the file, :s on the current line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "foo foo\nbar foo\nhttp://x\n");
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

    // an escaped separator `\/` in the pattern must match a real '/' —
    // http:\/\/x matches "http://x" and becomes DONE
    try sess.send(":%s/http:\\/\\/x/DONE/\r");
    waited = 0;
    // Wait for the command line to close (":s/http" echo gone) BEFORE the
    // buffer assertion — the cmdline echo contains "DONE" (the replacement
    // text), so a DONE-only wait can pass on the echo while the
    // substitution hasn't run yet (a rare full-suite timing flake).
    while (grid.contains(":s/http") or !grid.contains("DONE")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("DONE"));
    try std.testing.expect(!grid.contains("http://x"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "'.' repeats dw and x from the current cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha beta gamma delta\n");
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

    // dw deletes "alpha ", then '.' deletes "beta " from the same cursor
    try sess.send("dw.");
    waited = 0;
    while (grid.contains("alpha") or grid.contains("beta")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("gamma delta"));
    try std.testing.expect(!grid.contains("alpha"));
    try std.testing.expect(!grid.contains("beta"));

    // x deletes one char; '.' repeats it
    try sess.send("0x.");
    waited = 0;
    while (!grid.contains("mma delta")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("mma delta"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "tabs render expanded; cursor column accounts for tab width" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "a\tb\n");
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

    // the tab expands to 4 spaces: the line reads "a    b", not "ab" (the
    // old 0-width behavior dropped the tab entirely)
    try std.testing.expect(grid.contains("a    b"));
    try std.testing.expect(!grid.contains("ab"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "vim editing keys: x X D C S r ~ J >>" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abcdef\n  Indented\nlast\n");
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

    // x deletes the char under the cursor (cursor on 'a')
    try sess.send("x");
    waited = 0;
    while (grid.contains("abcdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("bcdef"));

    // move right one char (cursor on 'c'), X deletes the char before it
    // ('b') → "cdef"
    try sess.send("lX");
    waited = 0;
    while (grid.contains("bcdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("cdef"));

    // rq replaces the char under the cursor (now on 'c') with 'q' ("qdef")
    try sess.send("rq");
    waited = 0;
    while (!grid.contains("qdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("qdef"));

    // ~ toggles case of the char under the cursor ('q' → 'Q')
    try sess.send("~");
    waited = 0;
    while (!grid.contains("Qdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Qdef"));

    // D deletes to end of line ("Qdef" → "Q")
    try sess.send("D");
    waited = 0;
    while (grid.contains("Qdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Q"));
    try std.testing.expect(!grid.contains("Qdef"));

    // j down to line 2 ("  Indented"), S changes the whole line, type "xyz",
    // esc → file becomes "Q\nxyz\nlast\n"
    try sess.send("jSxyz\x1b");
    waited = 0;
    while (!grid.contains("xyz") or grid.contains("Indented")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("xyz"));
    try std.testing.expect(!grid.contains("Indented"));

    // J joins the next line ("xyz" + "last" → "xyz last")
    try sess.send("J");
    waited = 0;
    while (!grid.contains("xyz last")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("xyz last"));
    // >> indents the current line by 4 spaces. The first space of the indent
    // renders as the indent guide "│" (4 columns of indent = one level), so
    // the line reads "│   xyz last" rather than four spaces.
    try sess.send(">>");
    waited = 0;
    while (!grid.contains("│   xyz last")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("│   xyz last"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "dashboard shows recent files; Enter reopens" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
        const code = try sess.commandAndWaitExit(":q!\r");
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

        const code = try sess.commandAndWaitExit(":q!\r");
        try std.testing.expectEqual(@as(u32, 0), code);
    }
}

test "grep picker: <leader>st finds matches and jumps" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    // <leader>st + "std.zig" → the grep list shows a match line (the split
    // panel truncates the left column at ~32 cols — assert on the fully
    // visible "test/e2e.zig:" path prefix; the line number itself is
    // self-referential and shifts as this file is edited). Wait for the FULL
    // query in the input row so the results are the final set: every
    // "std.zig" match lives in test/e2e.zig.
    try sess.send(" ststd.zig");
    waited = 0;
    while (!grid.contains("❯ std.zig") or !grid.contains("test/e2e.zig:")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("test/e2e.zig:")) {
        const st = grid.rowText(grid.rows - 1);
        std.debug.print("grep picker no result; status={s}\n", .{if (st.len > 0) st[0..@min(st.len, 40)] else ""});
        grid.dump();
        const all = sess.out[0..sess.used];
        const tail = if (all.len > 1500) all[all.len - 1500 ..] else all;
        std.debug.print("G-DUMP: {s}\n", .{tail});
    }
    try std.testing.expect(grid.contains("test/e2e.zig:"));
    // the split preview degrades to a hint for files over the 100KB limit
    // (test/e2e.zig is 354KB): "preview unavailable" only ever appears in the
    // preview column, never in the left list
    try std.testing.expect(grid.contains("preview unavailable"));

    // Enter jumps into the first match
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("NORMAL") or grid.contains("❯ ")) {
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "grep picker: fixed-size panel with split syntax preview" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}g.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "grep fixed box\n");
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

    // <leader>st with an EMPTY query: the panel must already be at its full
    // fixed width (no small→big pop once results arrive) and the list area
    // shows the "no matches" hint instead of a 12-col sliver.
    try sess.send(" st");
    waited = 0;
    while (!grid.contains("no matches")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains(" Grep "));
    try std.testing.expect(grid.contains("no matches"));
    var hint_row: ?usize = null;
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        if (rowContains(&grid, r, "no matches")) {
            hint_row = r;
            break;
        }
    }
    try std.testing.expect(hint_row != null);
    // the split separator "│" (2nd pipe on the hint row) sits deep inside the
    // panel — far right of the old small box (12-col sliver)
    const sep_col_empty = nthPipeCol(&grid, hint_row.?, 1) orelse return error.MissingSeparator;
    try std.testing.expect(sep_col_empty >= 40);

    // type a query → results arrive; the panel width must NOT change (the
    // separator stays at the same column) and the split preview appears.
    // "pub fn" hits build.zig first ("pub fn build" — the only "pub fn" in
    // build.zig; small file → preview available). Assert the file, not the
    // line: build.zig's line numbers drift with the vendored-patch block.
    try sess.send("pub fn build");
    waited = 0;
    while (!grid.contains("❯ pub fn") or !grid.contains("build.zig:")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("build.zig:"));
    const sep_col_filled = nthPipeCol(&grid, hint_row.?, 1) orelse return error.MissingSeparator;
    try std.testing.expectEqual(sep_col_empty, sep_col_filled);

    // preview syntax highlighting: the selected result is build.zig:14, so
    // the ±4 window shows line 15 "    const target = ..." — tree-sitter
    // colors "const" with the keyword color (kanagawa oniViolet). The left
    // list never renders "const" keyword-colored (fzy only colors the query
    // chars "pub fn"), so this proves the PREVIEW column is highlighted.
    // the preview file read is async: wait for its content, not just the
    // header, before scanning for the highlighted line
    waited = 0;
    while (!grid.contains("const target")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    var preview_row: ?usize = null;
    r = hint_row.? + 1;
    while (r < grid.rows) : (r += 1) {
        if (rowContains(&grid, r, "const target")) {
            preview_row = r;
            break;
        }
    }
    try std.testing.expect(preview_row != null);
    try std.testing.expect(rowContainsFg(&grid, preview_row.?, "const", packRgb(149, 127, 184)));

    // selection movement (Ctrl+n) refreshes the preview to the next result's
    // file: build.zig's content leaves the panel (build.zig has exactly one
    // "pub fn" match, so the new selection is always a different file)
    try sess.send("\x0e");
    waited = 0;
    while (grid.contains("const target")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("const target"));

    // Enter still jumps into the selected match (whatever file that is)
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("NORMAL") or grid.contains("❯ ")) {
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "file tree: <leader>e shows files, Enter opens one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    // <leader>e opens the tree; title + an early entry appear. The tree is
    // now a real directory tree: first level is dirs-first sorted (docs/,
    // src/, test/), so the first row is a directory, not DESIGN.md.
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files") or !grid.contains("build.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Files"));
    try std.testing.expect(grid.contains("build.zig"));
    // dirs come first: the first content row is a directory with the
    // closed folder glyph; "docs" is the first sorted first-level dir.
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(navBodyRow()), "docs") != null);
    // nvim/snacks geometry: border, one padding cell (the cursor sits here),
    // then the tree branch and the icon — cursor and glyph never share a cell.
    try std.testing.expect(std.mem.startsWith(u8, grid.rowText(navBodyRow()), "│ ├╴"));

    // Enter on the selected directory (docs) expands it — its only child
    // (workspace-plan) appears, and the folder glyph flips open
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("workspace-plan")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("workspace-plan"));
    try std.testing.expect(grid.contains("\u{f07c}")); // open folder glyph

    // Enter again folds docs — its child disappears
    try sess.send("\r");
    waited = 0;
    while (grid.contains("workspace-plan")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("workspace-plan"));

    // j × 5 → DESIGN.md (first-level file); Enter opens it but KEEPS the
    // tree open — only <space>e (toggle) or Esc close it; focus returns to
    // the buffer so typing edits the file.
    // dirs-first first level: docs, patches, src, test, tools, DESIGN.md.
    try sess.send("jjjjj\r");
    waited = 0;
    while (!grid.contains("# oz") or !grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("# oz")); // DESIGN.md header (ASCII part)
    try std.testing.expect(navCompactRailVisible(&grid)); // rail stays after Enter

    // <space>e toggles the tree closed (and is the only toggle)
    try sess.send(" e");
    waited = 0;
    while (navCompactRailVisible(&grid)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!navCompactRailVisible(&grid));
    try std.testing.expect(grid.contains("# oz"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "file tree: sidebar background matches the editor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // one-line file: only row 1 gets editor content (gutter + cursorline),
    // so rows below it are plain editor background — an unselected sidebar
    // row there is uniformly the editor bg, proving the panel no longer
    // paints itself with the float background
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ftb.txt", .{ linux.getpid(), tmp_counter });
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

    // <leader>e opens the tree; dirs-first: row 3 = docs (selected),
    // row 4 = src (unselected), below the strip label+rule rows.
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files") or !grid.contains("build.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Files"));
    try std.testing.expect(grid.contains("build.zig"));

    // the selected row keeps its bg_sel highlight
    try std.testing.expect(grid.rowHasBg(navBodyRow(), packRgb(0x2D, 0x4F, 0x67)));
    // an unselected row is now ALL the editor background (0x1F1F28) — tree
    // panel cells, the fg_faint borders and the editor side alike — where
    // before the panel was bg_float (0x223249)
    const tree_bg = packRgb(0x1F, 0x1F, 0x28);
    try std.testing.expect(grid.rowAllBg(navBodyRow() + 1, tree_bg));
    try std.testing.expect(!grid.rowHasBg(navBodyRow() + 1, packRgb(0x22, 0x32, 0x49)));
    // the brand/tab rows share the editor bg too (fg_faint borders stay)
    try std.testing.expect(grid.rowHasBg(navTabsRow(), tree_bg));
    try std.testing.expect(!grid.rowHasBg(navTabsRow(), packRgb(0x22, 0x32, 0x49)));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "multi-buffer: :e opens a tab, gt/:bn switch, :bd closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}a.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}b.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "buffer picker: <leader>sb lists open buffers, Enter switches" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}pa.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}pb.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "buffer keys: <leader>bn switches, <leader>bk closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}ka.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}kb.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test ":'<,'>s substitutes within the visual range only" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vs.txt", .{ linux.getpid(), tmp_counter });
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
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}ra.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}rb.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "tree-sitter: zig keywords/comments/strings get syntax colors" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}syn.zig", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expect(grid.containsFg("const", packRgb(149, 127, 184)));
    try std.testing.expect(grid.containsFg("// note", packRgb(114, 113, 105)));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "markdown: inline rendering with conceal, injection and decorations" {
    // M4 markdown 内联渲染: block + inline highlight via the two-grammar
    // injection, fence content in the fence's language, and conceal of the
    // markup chrome with anti-conceal on the cursor line.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}md.md", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\# Title
            \\
            \\A **bold** word and `code` here.
            \\
            \\See [ozeditor](https://example.com) now.
            \\
            \\- [ ] todo
            \\- [x] done
            \\
            \\```zig
            \\const zx = 1;
            \\```
            \\
        );
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

    // The cursor sits on line 0 (the heading): it stays unconcealed
    // (anti-conceal) but the heading STYLE still applies.
    // kanagawa accent (carpYellow) for the heading text:
    try std.testing.expect(grid.containsFg("Title", packRgb(0xE6, 0xC3, 0x84)));

    // inline injection: "**" concealed off the cursor line, code span in
    // string green, link destination concealed (only the text remains)
    try std.testing.expect(!grid.contains("**bold**"));
    try std.testing.expect(grid.contains("bold"));
    try std.testing.expect(grid.containsFg("code", packRgb(0x98, 0xBB, 0x6C)));
    try std.testing.expect(!grid.contains("https://example.com"));
    try std.testing.expect(grid.contains("ozeditor"));

    // task list checkboxes become Nerd Font icons
    try std.testing.expect(grid.contains("\u{f096}")); // unchecked
    try std.testing.expect(grid.contains("\u{f046}")); // checked
    try std.testing.expect(!grid.contains("[ ]"));
    try std.testing.expect(!grid.contains("[x]"));

    // fence injection: the zig keyword inside ```zig gets keyword gold
    try std.testing.expect(grid.containsFg("const", packRgb(149, 127, 184)));

    // anti-conceal: move the cursor onto the bold line — its markup chrome
    // reappears, and the heading marker conceals once line 0 is no longer
    // the cursor line
    try sess.send("jj");
    waited = 0;
    while (!grid.contains("**bold**")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("**bold**"));
    try std.testing.expect(!grid.contains("# Title"));
    try std.testing.expect(grid.contains("Title"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("MD EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "tree-sitter: colors stay correct after o + typing + jk exit" {
    // Regression for the "chars turn comment-gray after jk" drift: after an
    // 'o' (structural edit) + typing + jk exit, the incremental reparse must
    // still color a keyword gold. exitInsert no longer forces a full reparse
    // on every insert exit (that made the frame after jk flash on large
    // files); the structural-op sites still force one.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}drift.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const x = 1;\n");
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

    // o opens a line, type a keyword, then jk exits insert (removing the 'j')
    try sess.send("ofn main\n");
    waited = 0;
    while (!grid.contains("fn main")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("fn main"));
    // jk: the 'k' removes the just-typed 'j' and exits to normal
    try sess.send("jk");
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
    // the new line's "fn" keyword must still be gold, not drifted to comment
    // gray (kanagawa keyword fg 149,127,184)
    try std.testing.expect(grid.containsFg("fn", packRgb(149, 127, 184)));

    const exit_code2 = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code2);
}

test "tree-sitter: files over the size limit get no highlight pass" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}big.zig", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expect(!grid.containsFg("const", packRgb(149, 127, 184)));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual: rainbow brackets, indent guides and scope highlight" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vis.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        // fn f (lines 1-6) with a NESTED if-block (lines 2-4) so entering the
        // inner scope must turn the outer scope's guide line gray again; fn h
        // (lines 7-9) provides out-of-scope guides. (A bare "fn f() {" with no
        // return type parses as one container_field, so the fn signature
        // carries an explicit `void`.)
        try f.writeStreamingAll(io, "fn f() void {\n" ++
            "    if (x) {\n" ++
            "        y();\n" ++
            "    }\n" ++
            "    g();\n" ++
            "}\n" ++
            "fn h() void {\n" ++
            "    x();\n" ++
            "}\n");
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

    // kanagawa-wave literals (src/theme.zig): the rainbow ramp is shared by
    // all themes. The fixture's outer "(" of "fn f()" sits at bracket depth 3
    // → rainbow[3] (boatYellow2 0xD19A66). Guides outside the cursor's scope
    // are dim gray (fg_dim 0x727169 — snacks links SnacksIndent to NonText);
    // ONLY the scope's own guide column takes the indent ramp: fn-level
    // scope indent_col=0 → level 0 → indent[0] (0xE06C75); if-level scope
    // indent_col=4 → level 1 → indent[1] (0xE5C07B). Content rows start at
    // grid row 1 (row 0 is the tab bar), so buffer lines 1..9 → rows 1..9.
    const rainbow3 = packRgb(0xD1, 0x9A, 0x66);
    const indent0 = packRgb(0xE0, 0x6C, 0x75);
    const indent1 = packRgb(0xE5, 0xC0, 0x7B);
    const guide_gray = packRgb(0x72, 0x71, 0x69);
    const cursorline_bg = packRgb(42, 42, 55);

    // 1. rainbow brackets: the outer "(" of "fn f()" renders with the
    //    rainbow color of its nesting depth, not the plain punctuation gray.
    try std.testing.expect(grid.containsFg("(", rainbow3));

    // 2. cursor on line 1 (fn f's declaration — f is the scope, lines 1-6,
    //    indent_col=0). Wait for the "out" spread (~500ms) to fill the scope,
    //    then: row 3 ("        y();", two guide columns) has its column-0
    //    guide highlighted (the fn scope's line) while the column-4 guide
    //    stays gray (not the scope's column); h's body (row 8) stays gray.
    waited = 0;
    while (grid.guideFgAt(4, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(4, 0) != indent0) {
        std.debug.print("fn scope guide never reached indent0: row3 col0={?}\n", .{grid.guideFgAt(4, 0)});
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(4, 0));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(4, 1));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(9, 0));

    // 3. enter the nested if-block ("2j" → line 3, "        y();"). The if
    //    body becomes the scope (lines 2-4, indent_col=4): after the spread,
    //    the column-4 guide is highlighted (indent[1]) and the column-0
    //    guide — the OUTER fn scope's line — reverts to gray. Only the
    //    nearest scope stays lit.
    try sess.send("2j");
    waited = 0;
    while (!grid.rowHasBg(4, cursorline_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    waited = 0;
    while (grid.guideFgAt(4, 1) != indent1) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(4, 1) != indent1 or grid.guideFgAt(4, 0) != guide_gray) {
        std.debug.print("nested scope: row3 col0={?} col1={?}\n", .{ grid.guideFgAt(4, 0), grid.guideFgAt(4, 1) });
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent1), grid.guideFgAt(4, 1));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(4, 0));

    // 4. leave the nested block ("2j" → line 5, "    g();" — fn body, no
    //    enclosing if): the fn body block is the scope again; row 3's
    //    column-0 guide relights and column-4 stays gray.
    try sess.send("2j");
    waited = 0;
    while (!grid.rowHasBg(6, cursorline_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    waited = 0;
    while (grid.guideFgAt(4, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(4, 0) != indent0) {
        std.debug.print("after leaving nested: row3 col0={?}\n", .{grid.guideFgAt(4, 0)});
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(4, 0));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(4, 1));

    // (The scope first line's underline — snacks.indent.scope underline — is
    // SGR underline, which the e2e grid does not parse, so it is not
    // asserted here.)

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "indent: scope vertical skips its first line and runs through blank rows" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "fn foo() void {\n    const a = 1;\n\n    const b = 2;\n}\n");
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

    // cursor into the fn body (line 2): scope = fn block, guide column 0.
    try sess.send("j");
    waited = 0;
    const indent0 = packRgb(0xE0, 0x6C, 0x75); // rainbow[0] — scope guide at col 0
    while (grid.guideFgAt(4, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.guideFgAt(4, 0) != indent0) {
        std.debug.print("blank-row scope guide missing: row3 col0={?}\n", .{grid.guideFgAt(4, 0)});
        grid.dump();
    }
    // the blank line (row 3) carries the scope vertical…
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(4, 0));
    // …but the scope's FIRST line (the fn header, row 1) and the closing
    // brace (row 5) do NOT — the vertical starts below the first line.
    try std.testing.expectEqual(@as(?u32, null), grid.guideFgAt(2, 0));
    try std.testing.expectEqual(@as(?u32, null), grid.guideFgAt(6, 0));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "indent: blank rows carry gray context guides plus the scope column" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "fn foo() void {\n        const a = 1;\n\n        const b = 2;\n}\n");
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

    // j → "const a = 1;" (indent 8): scope = fn body (guide column 0). The
    // blank line (row 3) must match its indent-8 neighbors: the scope
    // column highlighted AND the level-1 column GRAY — the gray guides
    // continue through blank rows instead of breaking. (Wait for the scope
    // highlight: the gray guides render immediately, the spread animation
    // takes ~500ms to reach the blank row.)
    try sess.send("j");
    waited = 0;
    const indent0 = packRgb(0xE0, 0x6C, 0x75); // rainbow[0] — scope guide
    const guide_gray = packRgb(0x72, 0x71, 0x69);
    while (grid.guideFgAt(3, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.guideFgAt(3, 0) != indent0) {
        std.debug.print("blank scope guide missing: row3 col0={?} col1={?}\n", .{ grid.guideFgAt(3, 0), grid.guideFgAt(3, 1) });
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(3, 0));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(3, 1));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: <C-v> block + I/A inserts on every line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: rectangle semantics — highlight and d delete per column" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // uneven line lengths: the old byte-range path highlighted [anchor..cursor)
    // bytes, which on these rows is NOT a rectangle (row 0 would light "aa",
    // row 1 the whole line). vim semantics: every covered row shares the
    // same single-column slice.
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}blk.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbbb\ncc\n");
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

    const sel_bg = packRgb(45, 79, 103);
    // cursor → col 1, Ctrl+v (anchor col 1), j j → cursor line 2 col 1.
    // Screen layout: row 0 = tab bar, content col 0 = gutter (2 wide for a
    // 3-line file), so file line n sits on screen row n+1 and its byte col 1
    // is screen col 3.
    try sess.send("l\x16jj");
    waited = 0;
    var block_hl = false;
    while (!block_hl) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.bg_buf[2 * grid.cols + 3] == sel_bg and
            grid.bg_buf[3 * grid.cols + 3] == sel_bg and
            grid.bg_buf[4 * grid.cols + 3] == sel_bg)
        {
            block_hl = true;
        }
    }
    if (!block_hl) {
        std.debug.print("block highlight missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(block_hl);
    // the rectangle must NOT light column 0 or 2 on any row (the byte-range
    // path lit col 2 on row 0 and col 0..3 on row 1)
    try std.testing.expect(grid.bg_buf[2 * grid.cols + 2] != sel_bg);
    try std.testing.expect(grid.bg_buf[2 * grid.cols + 4] != sel_bg);
    try std.testing.expect(grid.bg_buf[3 * grid.cols + 2] != sel_bg);
    try std.testing.expect(grid.bg_buf[4 * grid.cols + 2] != sel_bg);

    // d deletes exactly one column from every covered row: aa / bbb / c
    try sess.send("d");
    waited = 0;
    while (!rowContains(&grid, 2, "aa") or rowContains(&grid, 2, "aaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 2, "aa") or rowContains(&grid, 2, "aaa")) {
        std.debug.print("after block d:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "aa"));
    try std.testing.expect(!rowContains(&grid, 2, "aaa"));
    try std.testing.expect(rowContains(&grid, 3, "bbb"));
    try std.testing.expect(rowContains(&grid, 4, "c"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("aa\nbbb\nc\n", buf);
}

test "visual block: c deletes the rectangle and types at the top-left cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}blkc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbbb\ncc\n");
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

    // block rows 0..2 col 1, then c: deletes the column everywhere and enters
    // insert at the block's top-left (row 0 col 1). Typing 'X' then applies
    // to EVERY line of the block at the same column (vim blockwise change —
    // the typed text lands in each line, not just at the cursor): aXa /
    // bXbb (row "bbbb" minus col 1, 'X' at col 1) / cX.
    try sess.send("l\x16jjcX");
    waited = 0;
    while (!rowContains(&grid, 2, "aXa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 2, "aXa")) {
        std.debug.print("after block c:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "aXa"));
    try std.testing.expect(rowContains(&grid, 3, "bXbb"));
    try std.testing.expect(rowContains(&grid, 4, "cX"));
    try std.testing.expect(grid.contains("INSERT"));

    // Esc exits insert (sent alone — Esc followed by ':' would merge into
    // Alt+':'), then :wq persists.
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

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("aXa\nbXbb\ncX\n", buf);
}

test "visual block: multi-cursor backspace, ctrl-w and jk stay in sync" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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

    // --- ctrl-w (0x17): I + "foo " then Ctrl-w deletes the inserted word at
    // --- every cursor. The poll+drain loop renders once per key batch, so
    // --- the insertion and the deletion are sent (and verified) separately:
    // --- "Xfoo aaa" appears, then Ctrl-w removes "Xfoo " → "aaa".
    try sess.send("\x16jjIfoo ");
    waited = 0;
    while (!grid.contains("Xfoo") and !grid.contains("Xafoo")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("Xfoo") and !grid.contains("Xafoo")) {
        std.debug.print("after block ctrl-w insert:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("Xfoo") or grid.contains("Xafoo"));

    try sess.send("\x17"); // Ctrl+w deletes the inserted word
    waited = 0;
    while (grid.contains("Xfoo") or grid.contains("Xafoo")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.contains("Xfoo") or grid.contains("Xafoo")) {
        std.debug.print("after block ctrl-w delete:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains("Xfoo"));
    try std.testing.expect(!grid.contains("Xafoo"));

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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual block: 非 0 列块 / 空行 clamp / 单行块边界" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}f.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 30, 100);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.initSizedCols(alloc, 30, 100);
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

    // <leader>e — the tree opens. First level is dirs-first (docs/ src/
    // test/), so row 2 (first entry row) is a directory, not a file.
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(navBodyRow()), "docs") != null);

    // Expand enough of the tree to overflow the ~20 visible sidebar rows:
    // l on docs (children), 5j to src + l, j to src/ai (new M1 module),
    // j to app + l (its children) → more than the ~20 visible rows.
    try sess.send("ljjjjjljjl");
    waited = 0;
    while (!grid.contains("block_insert.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("block_insert.zig")); // app children visible

    // 22 × j — the selection reaches the window bottom; the scroll window
    // follows so the selected entry stays visible (it is no longer the first
    // entry: "docs" scrolled off). (The poll+drain loop renders once per
    // key batch, so the final scroll state is what we assert.)
    try sess.send("jjjjjjjjjjjjjjjjjjjjjj");
    waited = 0;
    var scrolled = false;
    while (!scrolled) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        // "docs" was the first entry; once the window scrolls it is gone
        // from the first entry row, and the selected entry (bg_sel) is
        // visible somewhere inside the sidebar window
        var sr: usize = navBodyRow();
        var has_sel = false;
        while (sr < 30 - 2) : (sr += 1) {
            if (grid.rowHasBg(sr, packRgb(45, 79, 103))) has_sel = true;
        }
        if (std.mem.indexOf(u8, grid.rowText(navBodyRow()), "docs") == null and has_sel) scrolled = true;
    }
    if (!scrolled) {
        std.debug.print("filetree grid after scroll:\n", .{});
        grid.dump();
        var dr: usize = 0;
        while (dr < 6) : (dr += 1) std.debug.print("row{d}: [{s}]\n", .{ dr, grid.rowText(dr) });
    }
    try std.testing.expect(scrolled);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: list scrolls with the selection; the highlighted row stays visible" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}p.txt", .{ linux.getpid(), tmp_counter });
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
    while (!grid.contains("❯ ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const sel_bg = packRgb(45, 79, 103);
    // centered picker box: box_h = 10 list rows + title + input + bottom =
    // 13, start_row = (24-13)/3 = 3, first list row = start_row + 2 = 5
    const list_top: usize = 5;
    // the selection starts on the first window row
    try std.testing.expect(grid.rowHasBg(list_top, sel_bg));
    // the picker floats centered (telescope style): the title row and the
    // in-panel "❯" input row sit at 1/3 height — NOT glued to the bottom
    // row of the screen like the old status-bar prompt
    try std.testing.expect(rowContains(&grid, 3, " Files "));
    try std.testing.expect(rowContains(&grid, 4, "❯"));
    try std.testing.expect(!rowContains(&grid, 23, "❯"));

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
    while (grid.contains("❯ ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: Esc exits and clears the stale selection highlight" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vl.txt", .{ linux.getpid(), tmp_counter });
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

    const sel_bg = packRgb(45, 79, 103);

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
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
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
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
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
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
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
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                sel_cleared = false;
                break;
            }
        }
    }
    try std.testing.expect(sel_cleared);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker: keys win over the file tree while both are open" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ft2.txt", .{ linux.getpid(), tmp_counter });
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

    const sel_bg = packRgb(45, 79, 103);

    // <leader>e — file tree sidebar
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // the sidebar selection starts on the first peek content row
    try std.testing.expect(grid.rowHasBg(navBodyRow(), sel_bg));

    // <leader>sf — fuzzy file picker over the still-open file tree
    try sess.send(" sf");
    waited = 0;
    while (!grid.contains("❯ ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // centered picker box: box_h = 13, start_row = (24-13)/3 = 3, first
    // list row = start_row + 2 = 5 (same geometry as the scroll test)
    const list_top: usize = 5;
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
    // the sidebar highlight stays on the first content row
    try std.testing.expect(grid.rowHasBg(navBodyRow(), sel_bg));

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
    try std.testing.expect(grid.rowHasBg(navBodyRow(), sel_bg));

    // Esc closes the picker (':q' would be eaten by the filter), then quit
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("❯ ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: gt buffer switch drops the selection highlight" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}gta.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\nAAA\nAAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}gtb.txt", .{ linux.getpid(), tmp_counter });
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

    const sel_bg = packRgb(45, 79, 103);

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
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
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
    var r: usize = 1; // row 0 is the tab bar (active tab bg_sel)
    while (r < grid.rows) : (r += 1) {
        if (grid.rowHasBg(r, sel_bg)) {
            sel_cleared = false;
            break;
        }
    }
    try std.testing.expect(sel_cleared);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert Enter: splits the line at the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ent.txt", .{ linux.getpid(), tmp_counter });
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
    while (std.mem.indexOf(u8, grid.rowText(3), "abc") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(3), "abc") == null) {
        std.debug.print("after Enter split:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "xx") != null);
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(3), "abc") != null);

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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}enti.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ctl.txt", .{ linux.getpid(), tmp_counter });
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
    while (std.mem.indexOf(u8, grid.rowText(2), "next") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (std.mem.indexOf(u8, grid.rowText(2), "next") == null) {
        std.debug.print("after second Ctrl-k:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "next") != null);
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}alt.txt", .{ linux.getpid(), tmp_counter });
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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker confirm leaves file-tree mode; j/k control the buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}g.txt", .{ linux.getpid(), tmp_counter });
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
    while (!grid.contains("Files")) {
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
    while (!grid.contains("❯ ") or !grid.contains("DESIGN.md")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("❯ "));
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
        if (!grid.contains("❯ ") and grid.contains("line 1/") and !grid.contains("line 1/3") and !grid.contains("line 1/4")) jumped = true;
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
    if (!line2_seen) {
        std.debug.print("PICKER FAIL DUMP:\n", .{});
        grid.dump();
    }
    try std.testing.expect(line2_seen);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line V selects whole lines from mid-line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}v.txt", .{ linux.getpid(), tmp_counter });
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
    const sel_bg = packRgb(45, 79, 103);
    try sess.send("lVj");
    waited = 0;
    // wait for j to actually land on line 2 (VISUAL + status "line 2/"), so
    // the selection spans both whole lines before we assert the highlight
    while (!(grid.contains("[VISUAL]") and grid.contains("line 2/"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(grid.contains("[VISUAL]") and grid.contains("line 2/"))) {
        std.debug.print("lVj: cursor did not reach line 2; status below\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("[VISUAL]"));
    try std.testing.expect(grid.contains("line 2/"));
    // the first column of the first two content rows must be inside the
    // selection
    // (whole-line selection starts at column 0), and the gutter column (0..4)
    // is not — assert the content column has the bg
    if (!grid.rowHasBg(2, sel_bg) or !grid.rowHasBg(3, sel_bg)) {
        std.debug.print("\nV select rows 1..2 bg: r1={} r2={}\n", .{ grid.rowHasBg(2, sel_bg), grid.rowHasBg(3, sel_bg) });
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
    try std.testing.expect(grid.rowHasBg(2, sel_bg));
    try std.testing.expect(grid.rowHasBg(3, sel_bg));

    // Esc clears it
    try sess.send("\x1b");
    waited = 0;
    while (grid.rowHasBg(2, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.rowHasBg(2, sel_bg));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: V + d/c deletes ALL selected lines (incl. the last one)" {
    // Regression: visual_line d/c used anchor..cursor bytes, so a selection
    // ending on the last line left that line's tail (or the whole line)
    // behind. The range must span whole lines: anchor-line start through
    // cursor-line end + its newline.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vld.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\nddd\n");
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

    // -- d: select lines 2..4 (last line) from mid-line 2, delete them all --
    // j to line 2, l to mid-line, V, jj (cursor on line 4 = last), d
    try sess.send("jlVjjd");
    waited = 0;
    while (!(!rowContains(&grid, 3, "bbb") and !rowContains(&grid, 4, "ccc") and !rowContains(&grid, 5, "ddd"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // only "aaa" remains on row 1; rows 2..4 are empty
    try std.testing.expect(rowContains(&grid, 2, "aaa"));
    try std.testing.expect(!rowContains(&grid, 3, "bbb"));
    try std.testing.expect(!rowContains(&grid, 4, "ccc"));
    try std.testing.expect(!rowContains(&grid, 5, "ddd"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "visual line: V + c consumes ALL selected lines (incl. the last one)" {
    // Regression: visual_line change used anchor..cursor bytes, leaving the
    // last selected line's tail behind. c must consume every whole line.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vlc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "aaa\nbbb\nccc\nddd\n");
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

    // select lines 2..4 (last line) from mid-line 2: j, l, V, jj, c
    try sess.send("jlVjjc");
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
    // Esc back to normal: only "aaa" remains, bbb/ccc/ddd all consumed
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
    try std.testing.expect(rowContains(&grid, 2, "aaa"));
    try std.testing.expect(!rowContains(&grid, 3, "bbb"));
    try std.testing.expect(!rowContains(&grid, 4, "ccc"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: Ctrl+a / Ctrl+x increment and decrement the number at the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}num.txt", .{ linux.getpid(), tmp_counter });
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
    while (!(rowContains(&grid, 2, "6") and !rowContains(&grid, 2, "5"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 2, "6") and !rowContains(&grid, 2, "5"))) {
        std.debug.print("after Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "6"));
    try std.testing.expect(!rowContains(&grid, 2, "5"));

    // back to column 0, Ctrl+x (0x18) → "5" again
    try sess.send("0\x18");
    waited = 0;
    while (!(rowContains(&grid, 2, "5") and !rowContains(&grid, 2, "6"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 2, "5") and !rowContains(&grid, 2, "6"))) {
        std.debug.print("after Ctrl+x:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "5"));
    try std.testing.expect(!rowContains(&grid, 2, "6"));

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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}col.txt", .{ linux.getpid(), tmp_counter });
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
    while (!(rowContains(&grid, 2, "11") and rowContains(&grid, 3, "12") and rowContains(&grid, 4, "13"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 2, "11") and rowContains(&grid, 3, "12") and rowContains(&grid, 4, "13"))) {
        std.debug.print("after g Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "11"));
    try std.testing.expect(rowContains(&grid, 3, "12"));
    try std.testing.expect(rowContains(&grid, 4, "13"));

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

test "e2e: visual block g Ctrl+a respects the block columns (vim column increment)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}colb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        // two columns of numbers; the block will select ONLY the second
        // column, so the first column must stay untouched (vim: g<C-A> acts
        // on numbers inside the block only)
        try f.writeStreamingAll(io, "0 9\n1 9\n2 9\n");
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

    // Move to column 2 first ("0 9": 0@0, space@1, 9@2 → ll), THEN Ctrl+v
    // anchors the block there; j extends to all three lines; g Ctrl+a
    // (g + 0x01): each block line's number gets +1, +2, +3 → "0 10\n1 11\n2
    // 12\n". The first column stays untouched — vim's g<C-A> acts on
    // numbers inside the block only.
    try sess.send("ll\x16jjg\x01");
    waited = 0;
    while (!(rowContains(&grid, 2, "0 10") and rowContains(&grid, 3, "1 11") and rowContains(&grid, 4, "2 12"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 2, "0 10") and rowContains(&grid, 3, "1 11") and rowContains(&grid, 4, "2 12"))) {
        std.debug.print("after block g Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "0 10"));
    try std.testing.expect(rowContains(&grid, 3, "1 11"));
    try std.testing.expect(rowContains(&grid, 4, "2 12"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("0 10\n1 11\n2 12\n", buf);
}

test "e2e: visual block g Ctrl+a on 0..4 gives vim's 1,3,5,7,9 (line offset)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}colc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "0\n1\n2\n3\n4\n");
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

    // vim's g<C-A>: line i gets +i (1-based) → 0,1,2,3,4 becomes
    // 1,3,5,7,9. (To build 1,2,3,4,5 from scratch, block-select 0,0,0,0,0.)
    try sess.send("\x16jjjjg\x01");
    waited = 0;
    while (!(rowContains(&grid, 2, "1") and rowContains(&grid, 3, "3") and
        rowContains(&grid, 4, "5") and rowContains(&grid, 5, "7") and rowContains(&grid, 6, "9")))
    {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 2, "1") and rowContains(&grid, 3, "3") and
        rowContains(&grid, 4, "5") and rowContains(&grid, 5, "7") and rowContains(&grid, 6, "9")))
    {
        std.debug.print("after block g Ctrl+a on 0..4:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "1"));
    try std.testing.expect(rowContains(&grid, 3, "3"));
    try std.testing.expect(rowContains(&grid, 4, "5"));
    try std.testing.expect(rowContains(&grid, 5, "7"));
    try std.testing.expect(rowContains(&grid, 6, "9"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: insert mode arrow keys move the cursor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}arr.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abc\ndef\n");
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

    // i → insert at (0,0). Right arrow → after 'a', type X → "aXbc".
    // Left arrow twice → back to (0,0), type Y → "YaXbc". Down arrow to
    // line 2 KEEPING the column (vim behavior: after "Y" the cursor is at
    // col 1, so Z lands after 'd' → "dZef"). Esc exits.
    try sess.send("i");
    try sess.send("\x1b[C"); // right
    try sess.send("X");
    try sess.send("\x1b[D\x1b[D"); // left left
    try sess.send("Y");
    try sess.send("\x1b[B"); // down → line 2, col 1
    try sess.send("Z");
    try sess.send("\x1b");
    waited = 0;
    while (!grid.contains("YaXbc")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(grid.contains("YaXbc") and grid.contains("dZef"))) {
        std.debug.print("after insert arrow keys:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("YaXbc"));
    try std.testing.expect(grid.contains("dZef"));
    try std.testing.expect(!grid.contains("INSERT"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("YaXbc\ndZef\n", buf);
}

test "e2e: counts — 5p pastes five times, 3x deletes three, 2ciw changes two words" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cnt.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one two three\nabcdef\n");
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

    // yiw copies "one"; $ 5p pastes it five times after the line's last char:
    // "one two three" + "one"*5.
    try sess.send("yiw$5p");
    waited = 0;
    while (!grid.contains("threeoneoneoneoneone")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("threeoneoneoneoneone")) {
        std.debug.print("after 5p:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("threeoneoneoneoneone"));

    // move to line 2, 3x deletes "abc" → "def" remains.
    try sess.send("j03x");
    waited = 0;
    while (grid.contains("abcdef")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (grid.contains("abcdef")) {
        std.debug.print("after 3x:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains("abcdef"));
    try std.testing.expect(grid.contains("def"));

    // 2ciw on "one" (line 1): deletes "one two" and enters insert; type "X"
    // → "X three" + the pasted "one"*5 tail. jk exits.
    try sess.send("gg02ciwXjk");
    waited = 0;
    while (!grid.contains("X three")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("X three")) {
        std.debug.print("after 2ciw:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("X three"));
    try std.testing.expect(!grid.contains("one two"));

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("X threeoneoneoneoneone\ndef\n", buf);
}

test "e2e: multi-cursor n extends the selection; c changes words synchronously" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}mc.txt", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 2, "bar bar bar")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 2, "bar bar bar")) {
        std.debug.print("after mc change:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "bar bar bar"));
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

test "e2e: multi-cursor Ctrl+n moves the main cursor and scrolls the viewport" {
    // Regression: Ctrl+n added the next match to the cursor list but never
    // moved the main cursor, so the screen cursor stayed put and a match
    // beyond the visible area was never scrolled into view.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}mcscroll.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            try f.writeStreamingAll(io, "foo\n");
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

    // Walk 12 matches with Ctrl+n (0x0e): the cursor must move far below the
    // initial line (line 1), past the ~10-row viewport, scrolling the text.
    try sess.send("\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e\x0e");
    waited = 0;
    var cursor_past = false;
    while (!cursor_past) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        // status shows "line N/31"; N must be well past 1
        var row: usize = 0;
        while (row < grid.rows) : (row += 1) {
            const txt = grid.rowText(row);
            if (std.mem.indexOf(u8, txt, "line ") != null and std.mem.indexOf(u8, txt, "/31") != null) {
                if (std.mem.indexOf(u8, txt, "line 1/") == null) {
                    cursor_past = true;
                }
                break;
            }
        }
    }
    try std.testing.expect(cursor_past);
    // The viewport must have scrolled: the cursorline row is not the first
    // content row (the cursor line is now ~13, far below the top).
    var r: usize = 2;
    var cursorline_row: ?usize = null;
    const cursorline_bg = packRgb(42, 42, 55);
    while (r < 24) : (r += 1) {
        if (grid.rowHasBg(r, cursorline_bg)) {
            cursorline_row = r;
            break;
        }
    }
    try std.testing.expect(cursorline_row != null);
    try std.testing.expect(cursorline_row.? > 2); // scrolled off the top

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: visual Ctrl+a increments every number in the selection" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vis.txt", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 2, "2 3 4")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 2, "2 3 4")) {
        std.debug.print("after visual Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "2 3 4"));

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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}gutter.txt", .{ linux.getpid(), tmp_counter });
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
    // the cursor row (the last content row, below the strip) shows the
    // 5-digit number "15000 ".
    try sess.send("G");
    waited = 0;
    while (!std.mem.eql(u8, grid.rowText(21)[0..6], "15000 ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!std.mem.eql(u8, grid.rowText(21)[0..6], "15000 ")) {
        std.debug.print("gutter at the bottom:\n", .{});
        grid.dump();
    }
    try std.testing.expect(std.mem.eql(u8, grid.rowText(21)[0..6], "15000 "));

    // every visible content row: the first content cell is at the dynamic
    // gutter width (column 6, preceded by the trailing space) — line
    // numbers never run into the text
    var r: usize = 2;
    while (r < 22) : (r += 1) {
        try std.testing.expect(grid.buf[(r * 80 + 6) * 4] == 'x');
        try std.testing.expect(grid.buf[(r * 80 + 5) * 4] == ' ');
    }

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
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
    try std.testing.expect(grid.containsFg("const", packRgb(149, 127, 184)));

    // <leader>e: the tree's first level is dirs-first (docs/ src/ test/),
    // so row 2 (row 0 = tab bar, row 1 = sidebar title/border) is a
    // directory, not the alphabetical first file.
    try sess.send(" e");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(navBodyRow()), "docs") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(navBodyRow()), "docs") != null);

    // j × 7 → README.md. Current first level (dirs first, then uppercase
    // names before lowercase in byte order): docs, patches, src, test,
    // tools, DESIGN.md, LICENSE, README.md. Enter opens it. The tree STAYS
    // open (only <space>e / Esc close it) — the buffer tab shows README.md
    // (row 0, now NOT covered by the sidebar).
    try sess.send("jjjjjjj\r");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(1), "README.md") == null and
        std.mem.indexOf(u8, grid.rowText(navBodyRow()), "README.md") == null)
    {
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
    try std.testing.expect(navCompactRailVisible(&grid)); // the rail did not close

    // The tree is still open with focus on the buffer (Enter moves focus).
    // Ctrl-w h → sidebar focus (the tree is the leftmost pane; h moves left
    // from the buffer into it); the selection is still on README.md's row.
    // kkkkk → src, l expands it, j → buffer, l expands it, jj → ops.zig,
    // then Enter opens it (zig → md → zig, the chain that rebuilds the
    // highlighter via ensureSyntax).
    try sess.send("\x17h");
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
    try sess.send("kkkkk");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("l");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("j");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // src's first child is now ai; step over it and app to buffer
    try sess.send("j");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("j");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("l");
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) break;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const sel_bg = packRgb(45, 79, 103);
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
    while (!grid.containsFg("pub", packRgb(149, 127, 184))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.containsFg("pub", packRgb(149, 127, 184))) {
        std.debug.print("ops.zig after zig->md->zig switch:\n", .{});
        grid.dump();
    }
    // the last buffer is ops.zig: "pub" is a gold keyword, not comment gray
    try std.testing.expect(grid.containsFg("pub", packRgb(149, 127, 184)));
    try std.testing.expect(!grid.containsFg("pub", packRgb(114, 113, 105)));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "e2e: insert undo — delete-first session (backspace then typing) reverts with one u" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ud1.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ud2.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}dd.txt", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 3, "ccc") or grid.contains("bbb")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 3, "ccc"));
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
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}2dd.txt", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expectEqualStrings("ccc\n", buf);
}

test "e2e: cc replaces the whole line and enters insert" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cc.txt", .{ linux.getpid(), tmp_counter });
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

    // jj → last real line ("ccc"); cc clears its text and enters insert,
    // typing "X" replaces it (row 3 becomes "X"). jk exits.
    try sess.send("jjccXjk");
    waited = 0;
    while (grid.contains("Xccc") or !rowContains(&grid, 4, "X")) {
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
    try std.testing.expect(rowContains(&grid, 4, "X"));
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
    // cc keeps the line's newline (vim: change clears the line's TEXT, the
    // line itself survives) — the saved file ends with '\n' like nvim's
    // 'fixeol' default
    try std.testing.expectEqualStrings("aaa\nbbb\nX\n", buf);
}

test "e2e: yy/dd/p/P linewise register matches nvim (lines below/above, cursor on first non-blank)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}yank.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abc\n  bbb\nccc\nddd\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));

    // yy p: the yanked line goes BELOW the cursor line as a whole line
    // (nvim linewise put), not spliced into the text after the cursor.
    // Buffer: abc / abc / bbb / ccc / ddd; cursor lands on the pasted line.
    try sess.send("yyp");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 2/6"));
    // rowText keeps the bg-padded trailing spaces — trim before comparing
    try std.testing.expectEqualStrings("1 abc", std.mem.trim(u8, grid.rowText(2), " "));
    try std.testing.expectEqualStrings("2 abc", std.mem.trim(u8, grid.rowText(3), " "));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(4), " "));

    // one u undoes the whole paste (single undo group). The cursor stays at
    // the change site, so wait for the restored line count, then gg home
    try sess.send("u");
    try std.testing.expect(try Wait.until(&sess, &grid, "/5 col"));
    try sess.send("gg");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 1/5"));

    // j yy P on the indented line: pasted ABOVE, cursor on the first
    // non-blank of the pasted line (col 2), like nvim
    try sess.send("jyyP");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 2/6 col 2"));
    try std.testing.expectEqualStrings("2   bbb", std.mem.trim(u8, grid.rowText(3), " "));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(4), " "));

    // u, then dd p: dd fills the register LINEWISE (vim unnamed register),
    // p puts the cut line below the next one — abc moves under bbb
    try sess.send("u");
    try std.testing.expect(try Wait.until(&sess, &grid, "/5 col"));
    try sess.send("gg");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 1/5"));
    try sess.send("ddp");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 2/5"));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(2), " "));
    try std.testing.expectEqualStrings("2 abc", std.mem.trim(u8, grid.rowText(3), " "));
    try std.testing.expectEqualStrings("1 ccc", std.mem.trim(u8, grid.rowText(4), " "));

    // save and verify the exact bytes
    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("  bbb\nabc\nccc\nddd\n", buf);
}

test "e2e: xp swaps two characters (x fills the charwise register)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}xp.txt", .{ linux.getpid(), tmp_counter });
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

    // xp on "abc": cut 'a' (into the register, charwise) and put it after
    // 'b' → "bac", cursor on the pasted char (col 1) — vim's char swap
    try sess.send("xp");
    waited = 0;
    while (!grid.contains("bac")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("bac"));
    try std.testing.expect(grid.contains("col 1"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "file tree: Ctrl-w h/l switches focus between sidebar and buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}foc.txt", .{ linux.getpid(), tmp_counter });
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
    const sel_bg = packRgb(45, 79, 103);

    // open file tree; default focus is the sidebar
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    // j moves the sidebar selection one content row down (the peek starts
    // below the two-row strip + four navigator header rows).
    try sess.send("j");
    waited = 0;
    while (!grid.rowHasBg(navBodyRow() + 1, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(navBodyRow() + 1, sel_bg));

    // Ctrl-w l → buffer focus (the tree is the leftmost pane; l moves right
    // out of it); j now moves the buffer cursor (line 2, 3…)
    try sess.send("\x17");
    try sess.send("l");
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

    // Ctrl-w h → sidebar focus again (h moves left from the leftmost buffer
    // window into the tree); j moves the sidebar (highlight follows)
    try sess.send("\x17");
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
        // the sidebar selection must have moved to the third content row
        // (two j's landed on the third entry below the header)
        if (grid.rowHasBg(navBodyRow() + 2, sel_bg)) sel_moved = true;
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
    try std.testing.expect(grid.contains("Files"));
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("Files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("Files"));
    try std.testing.expect(navCompactRailVisible(&grid));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "insert Ctrl+n: keyword completion inserts the top candidate" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}comp.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha beta gamma\nconst alpha = 1;\n");
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
    const sel_bg = packRgb(45, 79, 103);

    // jj → last (empty) line, i → insert, type "al", Ctrl+n (\x0e). The menu
    // shows the whole-buffer words by frequency: alpha (2×) first; the typed
    // prefix "al" is excluded from the candidates. The selected row is the
    // picker highlight (54,74,130) in the bottom list (rows ≥ 15).
    try sess.send("jji" ++ "al" ++ "\x0e");
    waited = 0;
    var menu_shown = false;
    while (!menu_shown) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var r: usize = 1;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg) and rowContains(&grid, r, "alpha")) {
                menu_shown = true;
                break;
            }
        }
    }
    if (!menu_shown) {
        std.debug.print("completion menu did not appear:\n", .{});
        grid.dump();
    }
    try std.testing.expect(menu_shown);

    // Ctrl+n → next candidate, Ctrl+p → back to the top candidate, Enter
    // accepts: "alpha" replaces the typed prefix "al" → line 3 = "alpha".
    try sess.send("\x0e\x10\r");
    waited = 0;
    while (rowContains(&grid, 3, "alpha") == false) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (rowContains(&grid, 3, "alpha") == false) {
        std.debug.print("after accept:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 3, "alpha"));

    // Esc exits insert (menu is already closed), then :wq persists.
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

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("alpha beta gamma\nconst alpha = 1;\nalpha", buf);
}

test "insert Ctrl+n: Ctrl+e hides the menu and stays in insert" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}compc.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha beta gamma\nconst alpha = 1;\n");
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
    const sel_bg = packRgb(45, 79, 103);

    try sess.send("jji" ++ "al" ++ "\x0e");
    waited = 0;
    var menu_shown = false;
    while (!menu_shown) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var r: usize = 1;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg) and rowContains(&grid, r, "alpha")) {
                menu_shown = true;
                break;
            }
        }
    }
    try std.testing.expect(menu_shown);

    // Ctrl+e hides the menu only — insert mode continues, the typed prefix
    // stays untouched; further typing still lands in the buffer. (Esc is the
    // insert-exit key: it closes the menu AND leaves insert, covered by the
    // "one Esc leaves insert" regression below.)
    try sess.send("\x05");
    waited = 0;
    var menu_gone = false;
    while (!menu_gone) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var any_hl = false;
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                any_hl = true;
                break;
            }
        }
        if (!any_hl) menu_gone = true;
    }
    // the menu is dismissed: the typed prefix is still there and typing
    // continues in insert mode (a stale selection-bg cell on an empty menu
    // row can linger in the diff accumulator, so assert on the content
    // instead of the selection bg)
    try std.testing.expect(grid.contains("al"));

    try sess.send("x");
    waited = 0;
    while (rowContains(&grid, 4, "alx") == false) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 4, "alx"));

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
    try std.testing.expectEqualStrings("alpha beta gamma\nconst alpha = 1;\nalx", buf);
}

test "insert Ctrl+n: no candidates when the cursor is not inside a word" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}compn.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha beta gamma\nconst alpha = 1;\n");
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
    const sel_bg = packRgb(45, 79, 103);

    // Cursor on the empty last line (byte before it is '\n', not a word
    // byte): Ctrl+n is swallowed — no menu, insert continues untouched.
    try sess.send("jji\x0e");
    waited = 0;
    var any_hl = false;
    var timeout = false;
    while (!timeout) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 1200) timeout = true;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        // Row 0 is the buffer tab bar: its active tab also uses bg_sel, so
        // selection scans start at the first editor content row.
        var r: usize = 1;
        while (r < grid.rows) : (r += 1) {
            if (grid.rowHasBg(r, sel_bg)) {
                any_hl = true;
                break;
            }
        }
    }
    try std.testing.expect(!any_hl);
    try std.testing.expect(grid.contains("INSERT"));

    // Esc exits insert; the untouched session leaves the file unchanged.
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
    try std.testing.expectEqualStrings("alpha beta gamma\nconst alpha = 1;\n", buf);
}

/// fg of the first char of `needle` on row `r`, or null when absent.
fn fgOfOnRow(grid: *Grid, r: usize, needle: []const u8) ?u32 {
    const row_text = grid.rowText(r);
    var c: usize = 0;
    while (c + needle.len <= grid.cols) : (c += 1) {
        if (std.mem.eql(u8, row_text[c .. c + needle.len], needle)) {
            return grid.fg_buf[r * grid.cols + c];
        }
    }
    return null;
}

test "insert: typing 'j' at end of a line keeps the next line's first word color" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}jcol.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const std = @import(\"std\");\npub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n");
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
    // quick probe: is ANY "const" gold on the initial render of a multi-line
    // zig file (regression check for the j-typing report)
    const any_gold = grid.containsFg("const", packRgb(149, 127, 184));
    if (!any_gold) {
        std.debug.print("no gold 'const' anywhere on initial render:\n", .{});
        grid.dump();
    }
    try std.testing.expect(any_gold);

    const gold = packRgb(149, 127, 184);
    const cursorline_bg = packRgb(42, 42, 55);
    // rows: 0 = label row, 1 = strip rule, 2.. = file lines. Move the cursor
    // down two lines (file line 2 = "    const x = 1;"), waiting on the
    // cursorline highlight so the motions have actually been processed (a
    // content-only wait is satisfied by the initial frame before the keys
    // are handled).
    try sess.send("jj"); // cursor → file line 2
    waited = 0;
    while (!grid.rowHasBg(4, cursorline_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(4, cursorline_bg));
    // the next line ("    const y = 2;") is on screen row 5; its "const"
    // must be gold before typing anything
    const before = fgOfOnRow(&grid, 5, "const");
    if (before != gold) {
        std.debug.print("before typing j: row4 'const' fg = 0x{x:0>6}\n", .{before orelse 0});
        grid.dump();
    }
    try std.testing.expectEqual(gold, before);

    // A → insert at end of line 2, type 'j'; the NEXT line's first word
    // ("const y") must keep its keyword color.
    try sess.send("Aj");
    waited = 0;
    while (!rowContains(&grid, 4, "const x = 1;j")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 4, "const x = 1;j"));
    const after = fgOfOnRow(&grid, 4, "const");
    if (after != gold) {
        std.debug.print("after typing j: row4 'const' fg = 0x{x:0>6}\n", .{after orelse 0});
        grid.dump();
    }
    try std.testing.expectEqual(gold, after);

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

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

/// Poll until row 0's split tab bar shows every needle of `left` in the
/// left zone and every needle of `right` in the right zone, each exactly
/// once and never in the OTHER zone (the split tab bar owns each tab: a
/// buffer's tab appears once, in the pane that last showed it). An empty
/// slice asserts nothing about that zone.
fn waitTabs(sess: *Session, grid: *Grid, left: []const []const u8, right: []const []const u8) !bool {
    var w: i32 = 0;
    while (true) {
        // The pane boundary is the vertical separator on the first content
        // row (row 2); using a hard-coded 40 cut a wider tab label in half
        // once tabs grew. Split the label row at that same CELL boundary
        // (glyphs are multi-byte, so a byte cut would tear a label).
        var split_col: usize = 40;
        var sc: usize = 20;
        while (sc + 20 < grid.cols) : (sc += 1) {
            if (std.mem.eql(u8, aiCellText(grid, 2, sc), "│")) {
                split_col = sc;
                break;
            }
        }
        // Zone membership is decided by where the tab label STARTS, not by
        // slicing the row text: a left-pane tab may legitimately borrow
        // cells up to the pane edge, and a wider label can straddle the
        // cut. Every tab's name still starts on its own side.
        var ok = true;
        for (left) |n| {
            const at = aiCellIndexOf(grid, 0, n) orelse {
                ok = false;
                continue;
            };
            if (at >= split_col) ok = false;
        }
        for (right) |n| {
            const at = aiCellIndexOf(grid, 0, n) orelse {
                ok = false;
                continue;
            };
            if (at < split_col) ok = false;
        }
        if (ok) return true;
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            w += 200;
            if (w >= 5000) return false;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
}

/// Count occurrences of `needle` in grid row `r` ("appears exactly once"
/// assertions for the single-window tab bar).
fn countInRow(g: *Grid, r: usize, needle: []const u8) usize {
    const row = g.rowText(r);
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, row, pos, needle)) |p| {
        n += 1;
        pos = p + needle.len;
    }
    return n;
}

test "windows: :vs splits side-by-side; Ctrl-w l/h switch; :q closes one; :qa quits" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}win.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "line1\nline2\nline3\nline4\nline5\nline6\n");
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

    // :vs — vertical split: both halves show "line1" (appears twice on the
    // first content row, below the label row and the shared strip rule)
    try sess.send(":vs\r");
    waited = 0;
    var both = false;
    while (!both) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        const first = std.mem.indexOf(u8, row, "line1");
        const second = if (first) |f| std.mem.indexOfPos(u8, row, f + 1, "line1") else null;
        both = first != null and second != null;
    }
    if (!both) {
        std.debug.print("after :vs:\n", .{});
        grid.dump();
    }
    try std.testing.expect(both);
    // the vertical split is delimited by a "│" separator column between the
    // two panes (vim statusline style) — the panes no longer sit flush
    try std.testing.expect(rowContains(&grid, 2, "│"));

    // the new (right) window has focus; Ctrl-w h → left window, j moves its
    // cursor independently (state bar shows line 2/7), Ctrl-w l back to the
    // right window which still sits on line 1.
    try sess.send("\x17h");
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
    while (!grid.contains("line 2/7")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("line 2/7")) {
        std.debug.print("after Ctrl-w h + j:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 2/7"));
    try sess.send("\x17l");
    waited = 0;
    while (!grid.contains("line 1/7")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 1/7"));

    // :q closes the focused (right) window → single window again
    try sess.send(":q!\r");
    waited = 0;
    var single = false;
    while (!single) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        const first = std.mem.indexOf(u8, row, "line1");
        const second = if (first) |f| std.mem.indexOfPos(u8, row, f + 1, "line1") else null;
        single = first != null and second == null; // exactly one window left
    }
    if (!single) {
        std.debug.print("after :q (window close):\n", .{});
        grid.dump();
    }
    try std.testing.expect(single);

    // :qa exits the editor entirely
    const exit_code = try sess.commandAndWaitExit(":qa\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "windows: :sp splits stacked; each window scrolls independently" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}winsp.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "topline\nsecond\nthird\nfourth\nfifth\n");
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

    // :sp — horizontal split: the buffer strip gains a second label row for
    // the stacked pane, then the shared strip rule; the top window shows
    // "topline" on row 3; the "─" pane separator consumes row 12 (vim
    // statusline style), and the bottom window's own first line sits
    // underneath it, so its first visible line ("second") starts at row 13
    try sess.send(":sp\r");
    waited = 0;
    while (!(grid.contains("topline") and grid.contains("second") and rowContains(&grid, 12, "─"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try gridSettle(&sess, &grid, 120, 3000);
    const top_here = rowContains(&grid, 3, "topline");
    const bottom_here = rowContains(&grid, 13, "second");
    if (!top_here or !bottom_here) {
        std.debug.print("after :sp:\n", .{});
        grid.dump();
    }
    try std.testing.expect(top_here);
    try std.testing.expect(bottom_here);
    // the pane boundary reads as a real separator row of "─" (row 12)
    try std.testing.expect(rowContains(&grid, 12, "─"));

    // both windows keep independent viewports: bottom window (focused) scrolls
    // down with G, top window stays on line 1
    try sess.send("G");
    waited = 0;
    while (!grid.contains("line 6/6")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("line 6/6"));
    try std.testing.expect(rowContains(&grid, 3, "topline")); // top window unchanged

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "TMP: tab-bar fuzz — every open buffer's tab appears exactly once" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // three short-named files in a unique dir (short basenames keep tabs
    // unclipped even when several stack in one 40-col pane)
    var dir_buf: [128:0]u8 = undefined;
    const dir = try bufPrintZ(&dir_buf, "/tmp/ozfz_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteDir(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    var paths: [3][160:0]u8 = undefined;
    const contents = [_][]const u8{ "AAAA\n", "BBBB\n", "CCCC\n" };
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    for (0..3) |i| {
        const p = try bufPrintZ(&paths[i], "{s}/{s}", .{ dir, names[i] });
        const f = try std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, contents[i]);
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, &paths[0] });
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

    // random window/buffer ops (fixed seed): after every op, every open
    // buffer's tab must appear EXACTLY ONCE on the tab bar — a missing or
    // duplicated name means ownership or rendering went wrong (e.g.
    // horizontal splits stack panes over the same tab-bar columns and the
    // later pane's tabs overwrite the earlier pane's). Every op starts
    // with Esc so a leftover command line can't swallow the keys (a real
    // user would press Esc first); :q! is excluded because it quits when
    // a single window is left.
    const actions = [_][]const u8{
        ":vs\r", ":sp\r", "\x17h", "\x17l", "\x17j", "\x17k", " bh", " bl", "gt", ":bd\r",
    };
    var prng = std.Random.DefaultPrng.init(0xF00DF00D);
    const seeds = [_]u64{ 0xF00DF00D, 0xDEADBEEF, 0x12345678, 0xC0FFEE42 };
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        // rotate the seed every 40 steps so several random sequences are
        // exercised, not just one fixed one
        prng = std.Random.DefaultPrng.init(seeds[i / 40]);
        var act_buf: [192]u8 = undefined;
        var act: []const u8 = undefined;
        if (prng.random().uintLessThan(usize, 6) == 0) {
            const f = 1 + prng.random().uintLessThan(usize, 2);
            act = try std.fmt.bufPrint(&act_buf, ":e {s}\r", .{&paths[f]});
        } else {
            act = actions[prng.random().uintLessThan(usize, actions.len)];
        }
        try sess.send("\x1b"); // back to Normal before every op
        try sess.send(act);
        // drain until quiet
        var d: i32 = 0;
        while (d < 600) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
            if (n == 0) {
                d += 50;
                if (d >= 600) break;
                continue;
            }
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        // invariants on the tab bar (rows 0..status; stacked panes draw
        // their tabs on separate rows):
        //  - each name appears AT MOST once across all rows (never
        //    duplicated or overwritten);
        //  - a buffer whose content is VISIBLE in some pane (its unique
        //    content marker appears in rows 1..status) MUST have its tab
        //    on the bar exactly once — a pane shows it, so the tab cannot
        //    be missing (horizontal splits stack panes over the same
        //    columns; without per-row tab bars the later pane's tabs would
        //    overwrite the earlier pane's).
        for (names, 0..) |nm, fi| {
            var cnt: usize = 0;
            var rr: usize = 0;
            while (rr + 1 < grid.rows) : (rr += 1) {
                const row = grid.rowText(rr);
                var pos: usize = 0;
                while (std.mem.indexOfPos(u8, row, pos, nm)) |p| {
                    cnt += 1;
                    pos = p + nm.len;
                }
            }
            if (cnt > 1) {
                std.debug.print("step {d} act '{s}': tab '{s}' appears {d} times\n", .{ i, act, nm, cnt });
                grid.dump();
                return error.TabBarInvariantBroken;
            }
            const marker = contents[fi][0..4];
            var visible = false;
            rr = 1;
            while (rr + 1 < grid.rows) : (rr += 1) {
                if (std.mem.indexOf(u8, grid.rowText(rr), marker) != null) {
                    visible = true;
                    break;
                }
            }
            if (visible and cnt != 1) {
                std.debug.print("step {d} act '{s}': '{s}' visible in a pane but its tab appears {d} times\n", .{ i, act, nm, cnt });
                grid.dump();
                return error.TabBarInvariantBroken;
            }
        }
    }

    const code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "TMP: split/close cycles + Ctrl-w navigation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

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
    // random window ops fuzz (fixed seed): should never panic the tree
    // invariant nor leak on exit
    const actions = [_][]const u8{
        ":vs\r", ":sp\r", "\x17h", "\x17l", "\x17j", "\x17k", ":q!\r",
    };
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const act = actions[prng.random().uintLessThan(usize, actions.len)];
        try sess.send(act);
        // drain whatever renders (short)
        var d: i32 = 0;
        while (d < 400) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
            if (n == 0) {
                d += 50;
                if (d >= 400) break;
                continue;
            }
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    const code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), code);
    // drain post-exit output: DebugAllocator leak reports land on stderr
    // (dup2'd into the pty) — assert none
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    const all = sess.out[0..sess.used];
    try std.testing.expect(std.mem.indexOf(u8, all, "leaked") == null);
}

test "windows: :vs keeps the old window left; :e lands in the left window when split" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_{d}_{d}a.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_{d}_{d}b.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }
    var nc_buf: [128:0]u8 = undefined;
    const nc = try bufPrintZ(&nc_buf, "/tmp/oz_{d}_{d}c.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nc) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nc, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "CCC\n");
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

    // :vs → both halves show AAA; the old window stays LEFT, new right
    try sess.send(":vs\r");
    waited = 0;
    var both = false;
    while (!both) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        const first = std.mem.indexOf(u8, row, "AAA");
        const second = if (first) |f| std.mem.indexOfPos(u8, row, f + 1, "AAA") else null;
        both = first != null and second != null;
    }
    try std.testing.expect(both);

    // Ctrl-w h → LEFT window; :e b.txt puts BBB in the LEFT half
    try sess.send("\x17h");
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
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    waited = 0;
    var swapped = false;
    while (!swapped) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        const left_b = std.mem.indexOf(u8, row[0..40], "BBB") != null;
        const right_a = std.mem.indexOf(u8, row[40..80], "AAA") != null;
        swapped = left_b and right_a;
    }
    if (!swapped) {
        std.debug.print("after Ctrl-w h + :e b.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(swapped);
    // split tab bar: each buffer's tab appears exactly once — BBB's in the
    // LEFT zone (the pane showing it), AAA's in the RIGHT
    if (!(try waitTabs(&sess, &grid, &.{"b.txt"}, &.{"a.txt"}))) {
        std.debug.print("tab bar after Ctrl-w h + :e b.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(try waitTabs(&sess, &grid, &.{"b.txt"}, &.{"a.txt"}));

    // Ctrl-w l → RIGHT window; :e c.txt STILL lands in the LEFT window (the
    // open-in-left default), focus follows it; the right half keeps AAA
    try sess.send("\x17l");
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
    try sess.send(":e ");
    try sess.send(nc);
    try sess.send("\r");
    waited = 0;
    var left_c = false;
    while (!left_c) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        left_c = std.mem.indexOf(u8, row[0..40], "CCC") != null and std.mem.indexOf(u8, row[40..80], "AAA") != null;
    }
    if (!left_c) {
        std.debug.print("after Ctrl-w l + :e c.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(left_c);
    // split tab bar: CCC (left pane) AND hidden BBB (last shown in the
    // left pane) keep tabs in the LEFT zone; AAA's tab stays in the RIGHT
    // zone — each exactly once
    if (!(try waitTabs(&sess, &grid, &.{ "c.txt", "b.txt" }, &.{"a.txt"}))) {
        std.debug.print("tab bar after Ctrl-w l + :e c.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(try waitTabs(&sess, &grid, &.{ "c.txt", "b.txt" }, &.{"a.txt"}));

    // :q closes the focused (left) window → only AAA (right) remains
    try sess.send(":q!\r");
    waited = 0;
    var only_a = false;
    while (!only_a) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        const has_a = std.mem.indexOf(u8, row, "AAA") != null;
        const has_c = std.mem.indexOf(u8, row, "CCC") != null;
        only_a = has_a and !has_c;
    }
    try std.testing.expect(only_a);
    // back to a single window: the tab bar lists every buffer exactly once
    // (BBB/CCC re-homed to the surviving pane when their window closed)
    try std.testing.expectEqual(@as(usize, 1), countInRow(&grid, 0, "a.txt"));
    try std.testing.expectEqual(@as(usize, 1), countInRow(&grid, 0, "b.txt"));
    try std.testing.expectEqual(@as(usize, 1), countInRow(&grid, 0, "c.txt"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "windows: <leader>bh/bl move the buffer to the left/right window; last buffer closes the window" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}bha.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "WAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}bhb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "WBB\n");
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

    const Wait = struct {
        // poll until the first content row (below the two-row strip) shows
        // `left` in the left pane and `right` in the right pane (empty
        // `right` = no right pane at all: no separator)
        fn panes(s: *Session, g: *Grid, left: []const u8, right: []const u8) !bool {
            var w: i32 = 0;
            while (true) {
                const row = g.rowText(2);
                const l_ok = left.len == 0 or (row.len >= 40 and std.mem.indexOf(u8, row[0..40], left) != null);
                const r_ok = right.len == 0 or (row.len > 40 and std.mem.indexOf(u8, row[40..], right) != null);
                const r_gone = right.len != 0 or std.mem.indexOf(u8, row, "│") == null;
                if (l_ok and r_ok and r_gone) return true;
                const n = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (n == 0) {
                    w += 200;
                    if (w >= 5000) return false;
                    continue;
                }
                s.used += n;
                g.feed(s.out[s.used - n .. s.used]);
            }
        }
    };

    // :vs → both halves show WAA; :e b.txt LANDS IN THE LEFT window (the
    // open-in-left default: panes hold distinct buffers, focus follows)
    try sess.send(":vs\r");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WAA", "WAA"));
    // the new (focused) pane is the last to show the shared buffer: its
    // single tab sits in the RIGHT zone, the left zone shows no tab
    if (!(try waitTabs(&sess, &grid, &.{}, &.{"bha.txt"}))) {
        std.debug.print("tab bar after :vs:\n", .{});
        grid.dump();
    }
    try std.testing.expect(try waitTabs(&sess, &grid, &.{}, &.{"bha.txt"}));
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WBB", "WAA"));
    // tabs follow the panes: WBB's tab in the LEFT zone, WAA's in the RIGHT
    try std.testing.expect(try waitTabs(&sess, &grid, &.{"bhb.txt"}, &.{"bha.txt"}));

    // <leader>bl from the left window: WBB moves RIGHT; the left window
    // falls back to the next buffer (WAA)
    try sess.send(" bl");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WAA", "WBB"));
    // the moved buffer's tab crossed the divider with it
    try std.testing.expect(try waitTabs(&sess, &grid, &.{"bha.txt"}, &.{"bhb.txt"}));

    // <leader>bh from the left window: no left neighbor → no-op
    try sess.send(" bh");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WAA", "WBB"));

    // focus the right window and <leader>bh: WBB moves back LEFT; the right
    // window falls back to WAA
    try sess.send("\x17l");
    try sess.send(" bh");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WBB", "WAA"));
    try std.testing.expect(try waitTabs(&sess, &grid, &.{"bhb.txt"}, &.{"bha.txt"}));

    // drop WAA (:bd in the right window) → both halves show WBB, one buffer
    try sess.send(":bd\r");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WBB", "WBB"));
    // the sole buffer's tab belongs to the focused (right) pane
    try std.testing.expect(try waitTabs(&sess, &grid, &.{}, &.{"bhb.txt"}));

    // <leader>bh with the LAST buffer: the buffer moves left and the current
    // window closes — a single pane remains (no split separator on row 1)
    try sess.send(" bh");
    try std.testing.expect(try Wait.panes(&sess, &grid, "WBB", ""));
    const row = grid.rowText(2);
    const first = std.mem.indexOf(u8, row, "WBB").?;
    try std.testing.expect(std.mem.indexOfPos(u8, row, first + 1, "WBB") == null);
    // single-window tab bar: the buffer's tab appears exactly once
    try std.testing.expectEqual(@as(usize, 1), countInRow(&grid, 0, "bhb.txt"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "windows: editing in one split clamps the other window's stale cursor (no crash)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

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
    // right window: cursor to EOF (doc_len). Left window: delete a char —
    // the doc shrinks under the right window's cursor → must clamp, not crash.
    try sess.send(":vs\r\x17lG");
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
    try sess.send("\x17h");
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
    // delete the char at the end of the LAST line (shrinks the doc)
    try sess.send("G$xi");
    waited = 0;
    var ok = false;
    while (!ok) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("INSERT")) ok = true;
    }
    if (!ok) {
        std.debug.print("oz crashed while editing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(ok);
    // backspace too (shrink again), then Esc
    try sess.send("\x7f\x1b");
    waited = 0;
    var normal = false;
    while (!normal) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("NORMAL") and !grid.contains("INSERT")) normal = true;
    }
    if (!normal) {
        std.debug.print("oz crashed after backspace:\n", .{});
        grid.dump();
    }
    try std.testing.expect(normal);
    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "windows: both splits keep highlighting when showing different buffers" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // the user flow: oz build.zig → :vs → open the tree → open another zig
    // file in the focused window — BOTH windows must stay highlighted.
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
    const gold = packRgb(149, 127, 184);

    // :vs — the focused (right) window shows build.zig, both halves gold
    try sess.send(":vs\r");
    waited = 0;
    var right_gold = false;
    while (!right_gold) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(2);
        if (std.mem.indexOf(u8, row[40..80], "const") != null) {
            const c = 40 + std.mem.indexOf(u8, row[40..80], "const").?;
            right_gold = grid.fg_buf[2 * grid.cols + c] == gold;
        }
    }
    if (!right_gold) {
        std.debug.print("right half not gold after :vs:\n", .{});
        grid.dump();
    }
    try std.testing.expect(right_gold);

    // Ctrl-w h → LEFT window, :e src/buffer/utf8.zig there. Now the left
    // window shows utf8.zig and the right still build.zig — BOTH gold.
    try sess.send("\x17h");
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
    try sess.send(":e src/buffer/utf8.zig\r");
    waited = 0;
    var left_gold = false;
    var right_still_gold = false;
    while (!(left_gold and right_still_gold)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        var r: usize = 1;
        while (r < 8 and !(left_gold and right_still_gold)) : (r += 1) {
            const row = grid.rowText(r);
            // left half (utf8.zig): any gold keyword in rows 2..8
            if (std.mem.indexOf(u8, row[0..40], "const") != null or
                std.mem.indexOf(u8, row[0..40], "pub") != null or
                std.mem.indexOf(u8, row[0..40], "fn") != null)
            {
                var c: usize = 2;
                while (c < 40) : (c += 1) {
                    if (grid.fg_buf[r * grid.cols + c] == gold) {
                        left_gold = true;
                        break;
                    }
                }
            }
            // right half (build.zig): "const std" still gold on row 1
            if (std.mem.indexOf(u8, row[40..80], "const") != null) {
                const cc = 40 + std.mem.indexOf(u8, row[40..80], "const").?;
                if (grid.fg_buf[r * grid.cols + cc] == gold) right_still_gold = true;
            }
        }
    }
    if (!(left_gold and right_still_gold)) {
        std.debug.print("after :e utf8.zig in left window:\n", .{});
        grid.dump();
    }
    try std.testing.expect(left_gold);
    try std.testing.expect(right_still_gold);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "lsp: smoke with real gopls (no crash on start/didChange)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}lsp.go", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "package main\n\nfunc main() {\n\tprintln(\"hi\")\n}\n");
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
            if (waited >= 8000) break; // gopls handshake can take a moment
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // edit → didChange path must not crash. Typing 'X' may auto-open the
    // completion menu (the LSP answers fast), so Ctrl+e (\x05) hides any
    // menu and Esc exits insert. A lone "\x1b\x1b" would be misparsed as an
    // escape sequence, and "\x05" is unambiguous.
    try sess.send("iX\x05\x1b");
    waited = 0;
    var ok = false;
    while (!ok) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("NORMAL")) ok = true;
    }
    try std.testing.expect(ok);
    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "lsp: mock server handshake + didChange round-trip (OZ_LSP_CMD)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}lspm.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\n");
    }

    // spawn oz with OZ_LSP_CMD pointing at the built mock server
    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break; // mock handshake + diagnostics push
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // edit → didChange must reach the mock without crashing. Typing 'X'
    // auto-opens the completion menu (the mock answers any request), so
    // Ctrl+e (\x05) hides it and Esc exits insert. The mock's inlay hint
    // anchors at column 0, so after inserting X the line reads "X: i32
    // const ..." (the hint shifts to sit right after X) — assert the edit
    // landed, not a bare "Xconst" (which the inlay visually interrupts).
    try sess.send("iX\x05\x1b");
    waited = 0;
    var ok = false;
    while (!ok) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("NORMAL") and grid.contains("const a = 1")) ok = true;
    }
    if (!ok) {
        std.debug.print("after edit with mock lsp:\n", .{});
        grid.dump();
    }
    try std.testing.expect(ok);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    // drain post-exit: no DebugAllocator leak reports from the LSP client
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: diagnostics push repaints without a keypress (stale mark cleared)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}diagc.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\n");
    }

    // mock pushes one error at didOpen, then an EMPTY diagnostics list on the
    // first didChange (clear_on_change). Both transitions must repaint on
    // their own: regression — publishDiagnostics didn't mark the frame dirty,
    // so a final "all clean" push left a phantom ✖ until the next keypress.
    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{
        "OZ_LSP_CMD=zig-out/bin/mock_lsp",
        "OZ_MOCK_SCRIPT=clear_on_change",
    });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // The ✖ (nf-fa-times_circle, U+F467 → EF 91 A7) appears on the gutter of
    // screen row 2 (first content row) WITHOUT any keypress — the wake event alone must repaint.
    waited = 0;
    var mark = false;
    while (!mark) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.buf[(2 * grid.cols + 1) * 4] == 0xEF and
            grid.buf[(2 * grid.cols + 1) * 4 + 1] == 0x91 and
            grid.buf[(2 * grid.cols + 1) * 4 + 2] == 0xA7) mark = true;
    }
    if (!mark) {
        std.debug.print("diagnostics mark never appeared without a keypress:\n", .{});
        grid.dump();
    }
    try std.testing.expect(mark);

    // Edit once (didChange → mock pushes the empty list). The mark must
    // vanish with NO further keypress. Ctrl+e hides the completion menu the
    // mock's answer would open; Esc leaves insert.
    try sess.send("iX\x05\x1b");
    waited = 0;
    var cleared = false;
    while (!cleared) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        const gutter = grid.buf[(1 * grid.cols + 1) * 4 ..][0..3];
        if (!(gutter[0] == 0xEF and gutter[1] == 0x91 and gutter[2] == 0xA7)) cleared = true;
    }
    if (!cleared) {
        std.debug.print("stale diagnostics mark survived the clear push:\n", .{});
        grid.dump();
    }
    try std.testing.expect(cleared);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "lsp: jk exit re-syncs the phantom 'j' removal (no stale diagnostic)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}jksync.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\n");
    }

    // jk_sync pushes an error diagnostic whenever its latest document text
    // starts with 'j'. Regression for the reported bug: 'i' then 'j' then
    // 'k' inserts a 'j' (didChange #1 carries the phantom) and removes it on
    // exit — the removal must send didChange #2, or the server keeps
    // analyzing "jconst a = 1;" forever: a phantom ✖ in the gutter (real
    // zls reports "expected ',' after field" at col 0) and inlay hints
    // computed against text that never existed.
    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{
        "OZ_LSP_CMD=zig-out/bin/mock_lsp",
        "OZ_MOCK_SCRIPT=jk_sync",
    });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // i → insert, j → type 'j'. The didChange carries the phantom and the
    // mock answers with the "phantom j" diagnostic — WAIT for the ✖ to
    // appear, proving the phantom round-trip works (this happens with or
    // without the fix; the ✖ glyph is U+F467 = EF 91 A7 in UTF-8).
    try sess.send("ij");
    waited = 0;
    var phantom_seen = false;
    while (!phantom_seen) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 8000) break;
        }
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            const g = grid.buf[(r * grid.cols + 1) * 4 ..][0..3];
            if (g[0] == 0xEF and g[1] == 0x91 and g[2] == 0xA7) {
                phantom_seen = true;
                break;
            }
        }
    }
    if (!phantom_seen) {
        std.debug.print("phantom j mark never appeared:\n", .{});
        grid.dump();
    }
    try std.testing.expect(phantom_seen);

    // k → jk exit (removes the 'j'). The removal must send didChange #2
    // ("const a = 1;") so the mock pushes an EMPTY list and the ✖ clears.
    // Without the fix no second didChange ever arrives and the ✖ stays
    // forever. Also assert the exit happened and the buffer is intact.
    try sess.send("k");
    waited = 0;
    var phantom_gone = false;
    while (!phantom_gone) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 8000) break;
        }
        var r: usize = 0;
        phantom_gone = true;
        while (r < grid.rows) : (r += 1) {
            const g = grid.buf[(r * grid.cols + 1) * 4 ..][0..3];
            if (g[0] == 0xEF and g[1] == 0x91 and g[2] == 0xA7) {
                phantom_gone = false;
                break;
            }
        }
    }
    if (!phantom_gone) {
        std.debug.print("phantom j diagnostic stayed after jk exit:\n", .{});
        grid.dump();
    }
    try std.testing.expect(phantom_gone);
    try std.testing.expect(!grid.contains("INSERT"));
    try std.testing.expect(grid.contains("const a = 1"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "lsp: diagnostics — gutter mark, gl, <leader>sd list" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}diag.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nconst b = 2;\nconst c = 3;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // Wait for the async attach + publishDiagnostics to land (the gutter
    // mark appears) before gl; in 0.17 the LSP handshake can finish after
    // the first NORMAL frame, and gl on an empty list would cache "no
    // diagnostics" before the notification arrives.
    waited = 0;
    while (!grid.contains("\u{f467}")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("gl");
    waited = 0;
    while (!grid.contains("mock error")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("mock error")) {
        std.debug.print("gl did not show:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("mock error"));

    // diagnostics arrived; the gutter's last column of row 2 (first content row, file line 0)
    // must show 'E'
    waited = 0;
    var mark = false;
    while (!mark) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        // gutter col 1 on screen row 2: the Nerd Font ✖ (nf-fa-times_circle,
        // U+F467 → EF 91 A7) — no longer a bare 'E'
        if (grid.buf[(2 * grid.cols + 1) * 4] == 0xEF and
            grid.buf[(2 * grid.cols + 1) * 4 + 1] == 0x91 and
            grid.buf[(2 * grid.cols + 1) * 4 + 2] == 0xA7) mark = true;
    }
    if (!mark) {
        std.debug.print("no gutter mark; col1={x}{x}{x}\n", .{
            grid.buf[(2 * grid.cols + 1) * 4],
            grid.buf[(2 * grid.cols + 1) * 4 + 1],
            grid.buf[(2 * grid.cols + 1) * 4 + 2],
        });
        grid.dump();
    }
    try std.testing.expect(mark);

    // <leader>sd → diagnostics list with "1: mock error"
    try sess.send(" sd");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("1: mock error")) listed = true;
    }
    if (!listed) {
        std.debug.print("leader sd list missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);

    // Esc closes the list
    try sess.send("\x1b");
    waited = 0;
    var closed = false;
    while (!closed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("1: mock error")) closed = true;
    }
    try std.testing.expect(closed);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: navigation — K hover, gd jump, gr list, gs signature" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}nav.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nconst b = 2;\nconst c = 3;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // K → hover request; a following keypress drains the response and the
    // floating window shows "mock hover" (the main loop is event-driven).
    // K → hover request; a following keypress drains the response and the
    // floating window shows "mock hover" (the main loop is event-driven).
    // Cursor motion dismisses the hover (nvim behavior) — asserted below via
    // the 'j' that also advances to line 2 for the gd step.
    try sess.send("K");
    waited = 0;
    while (!grid.contains("mock hover")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mock hover")) break;
    }
    if (!grid.contains("mock hover")) {
        std.debug.print("hover window missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("mock hover"));
    // Multi-line hover: the floating window must show all rows (the mock
    // returns "mock hover\nsecond line\nthird line"), not just the first.
    waited = 0;
    while (!grid.contains("second line")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("second line")) break;
    }
    if (!grid.contains("second line")) {
        std.debug.print("hover second line missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("second line"));
    try std.testing.expect(grid.contains("third line"));
    // The panel must be a solid theme-colored block: the row holding
    // "second line" (short text, 11 chars) has its padding cells past the
    // text filled with bg_float (0x223249), not the editor background —
    // the "edge not covered by the theme" bug. Check the region between the
    // two │ borders of that hover row.
    {
        var r: usize = 0;
        var found_row: ?usize = null;
        while (r < grid.rows) : (r += 1) {
            if (std.mem.indexOf(u8, grid.rowText(r), "second line") != null) {
                found_row = r;
                break;
            }
        }
        if (found_row) |fr| {
            // The hover row is "│" + 60 content cells + "│". Locate the left
            // border: rowText is ASCII up to it (gutter digits), so its byte
            // offset is the box's first cell.
            const row_text = grid.rowText(fr);
            const left = std.mem.indexOf(u8, row_text, "│") orelse {
                std.debug.print("hover row has no left border:\n", .{});
                grid.dump();
                return error.TestUnexpectedResult;
            };
            // Every cell of the box (borders + text + padding after a short
            // line) must be bg_float — no editor-background gap at the edge.
            const hline_fg: u32 = packRgb(0x22, 0x32, 0x49);
            var c: usize = left;
            while (c < left + 62) : (c += 1) {
                if (grid.bg_buf[fr * grid.cols + c] != hline_fg) {
                    std.debug.print("hover row cell {d} not bg_float (bg={x})\n", .{ c, grid.bg_buf[fr * grid.cols + c] });
                    grid.dump();
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    // The fenced ```zig block ("const b = 2;") must get REAL tree-sitter
    // colors: "const" keyword violet, "2" number pink — on the hover row,
    // not the buffer ("b = 2;" exists only inside the hover).
    {
        var r: usize = 0;
        var code_row: ?usize = null;
        while (r < grid.rows) : (r += 1) {
            if (std.mem.indexOf(u8, grid.rowText(r), "const b = 2;") != null) {
                code_row = r;
                break;
            }
        }
        if (code_row) |cr| {
            try std.testing.expect(rowContainsFg(&grid, cr, "const", packRgb(0x95, 0x7F, 0xB8)));
            try std.testing.expect(rowContainsFg(&grid, cr, "2", packRgb(0xD2, 0x7E, 0x99)));
        } else {
            std.debug.print("hover code block row missing:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        }
    }
    // The prose tokens still get markdown colors: the bold run and the URL.
    try std.testing.expect(grid.containsFg("mock hover", packRgb(0xDC, 0xD7, 0xBA)));
    try std.testing.expect(grid.containsFg("second line", packRgb(0x98, 0xBB, 0x6C)));
    try std.testing.expect(grid.containsFg("http://example.com", packRgb(0x7E, 0x9C, 0xD8)));

    // gd → mock returns a location at line 1 col 6 (the identifier in
    // "const a = 1;"). The wake mechanism drains the response without a
    // keypress: the cursor jumps to line 1 col 6 (status "line 2/4 col 6"),
    // landing on the definition token — not the line start. Then two 'j's
    // move to line 3 → "line 4/4".
    try sess.send("gd");
    waited = 0;
    while (!grid.contains("line 2/4 col 6")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("line 2/4 col 6")) break;
    }
    if (!grid.contains("line 2/4 col 6")) {
        std.debug.print("gd jump missing; status={s}\n", .{grid.rowText(grid.rows - 1)[0..40]});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 2/4 col 6"));

    try sess.send("jj");
    waited = 0;
    while (!grid.contains("line 4/4")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("line 4/4")) break;
    }
    if (!grid.contains("line 4/4")) {
        std.debug.print("gd jj move missing; status={s}\n", .{grid.rowText(grid.rows - 1)[0..40]});
        grid.dump();
    }
    try std.testing.expect(grid.contains("line 4/4"));

    // gr → two locations → list overlay appears with "2:" and "3:" entries
    try sess.send("grjj");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("2:") and grid.contains("3:")) listed = true;
    }
    if (!listed) {
        std.debug.print("gr list missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);

    // Esc closes the list
    try sess.send("\x1b");
    waited = 0;
    var closed = false;
    while (!closed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("2:") and !grid.contains("3:")) closed = true;
    }
    try std.testing.expect(closed);

    // gs → signatureHelp floating window
    try sess.send("gsjj");
    waited = 0;
    while (!grid.contains("mockSig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockSig")) break;
    }
    if (!grid.contains("mockSig")) {
        std.debug.print("signature window missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("mockSig"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}
test "lsp: completion — Ctrl+n lists server items, Enter accepts" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}comp.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nconst b = 2;\nmo");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // move to the last line ("mo"), insert, and hit Ctrl+n — the LSP mock
    // answers with mockItem / mockAlpha (server completion, not local words).
    try sess.send("jjA\x0e");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockItem") and grid.contains("mockAlpha")) listed = true;
    }
    if (!listed) {
        std.debug.print("lsp completion menu missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);

    // Enter accepts the selected item (mockItem): the typed "mo" prefix on
    // the last line (grid row 3) is replaced by "mockItem".
    try sess.send("\r");
    waited = 0;
    while (!rowContains(&grid, 4, "mockItem")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 4, "mockItem")) break;
    }
    if (!rowContains(&grid, 4, "mockItem")) {
        std.debug.print("lsp completion accept failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 4, "mockItem"));

    // Esc exits the insert session; then :qa quits.
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: auto-suggest — typing a word char opens the menu (blink style)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}auto.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nconst b = 2;\nmo");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // Just typing a word character ('x' after "mo") must open the menu —
    // no Ctrl+n. The mock answers mockItem / mockAlpha for any prefix.
    try sess.send("jjAx");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockItem") and grid.contains("mockAlpha")) listed = true;
    }
    if (!listed) {
        std.debug.print("auto-suggest menu missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);
    // the menu is a floating window: rounded corner (╭) + kind icons
    // (mockItem kind 6 = Variable , mockAlpha kind 5 = Field )
    try std.testing.expect(grid.contains("\xe2\x95\xad")); // ╭
    try std.testing.expect(grid.contains("\xee\xaa\x88")); // Variable icon
    try std.testing.expect(grid.contains("\xee\xad\x9f")); // Field icon

    // Ctrl+e hides the menu (blink mapping), insert continues.
    try sess.send("\x05");
    waited = 0;
    var hidden = false;
    while (!hidden) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("mockItem")) hidden = true;
    }
    try std.testing.expect(hidden);

    // Esc exits insert; :qa quits. No allocator leaks from the discard paths.
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: auto-suggest fires on '.' (trigger character, e.g. 'b.')" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}trig.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const b = 1;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // 'A' then '.' — no word character is typed in this session, so the only
    // way the menu can open is the trigger-character path (the mock declares
    // triggerCharacters ["."]; the client asks the server after "b.").
    try sess.send("A.");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockItem")) listed = true;
    }
    if (!listed) {
        std.debug.print("trigger-char menu missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);

    // Enter accepts (inserts at the cursor, after the '.'); Esc exits insert
    // (the menu is closed by accept, so one Esc suffices), then :qa.
    try sess.send("\r");
    waited = 0;
    while (!rowContains(&grid, 2, "mockItem")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 2, "mockItem")) break;
    }
    if (!rowContains(&grid, 2, "mockItem")) {
        std.debug.print("trigger accept failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "mockItem"));
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: auto-suggest updates the menu as you type (dynamic)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}dyn.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const b = 1;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // The mock echoes the typed prefix in its labels ("mockItema"), so a
    // changing menu proves each keystroke triggers a fresh completion request
    // whose response is applied (not discarded as stale) AND that the client
    // filters the server's full candidate set by the prefix (zls returns
    // everything unfiltered — the editor must filter, like blink/nvim).
    // "const b = 1;" is 12 chars: 'A' puts the cursor at col 12, typing 'a'
    // → prefix "a" → "mockItema".
    try sess.send("Aa");
    waited = 0;
    var first = false;
    while (!first) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockItema")) first = true;
    }
    if (!first) {
        std.debug.print("first suggestion missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(first);

    // typing 'b' → prefix "ab": the menu must show mockItemab (the
    // suggestions follow the input, not a frozen list)
    try sess.send("b");
    waited = 0;
    var updated = false;
    while (!updated) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockItemab")) updated = true;
    }
    if (!updated) {
        std.debug.print("menu did not update after typing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(updated);

    // exit insert (Ctrl+e hides the still-open menu, Esc exits), then :qa
    try sess.send("\x05\x1b");
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: accepting a snippet candidate inserts its clean label" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}snp.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nmo");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // Ctrl+n at "mo" shows three items; the third (mockSnippet) is a snippet
    // candidate whose textEdit.newText embeds ${1:args} placeholders. The
    // editor must degrade it to its plain label on accept — otherwise the
    // text would be corrupted with placeholder syntax.
    try sess.send("jjA\x0e");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockSnippet")) listed = true;
    }
    if (!listed) {
        std.debug.print("snippet candidate missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);

    // ↓↓ → third item → Enter accepts "mockSnippet" (clean label, no ${1:)
    try sess.send("\x1b[B\x1b[B\r");
    waited = 0;
    while (!rowContains(&grid, 3, "mockSnippet")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 3, "mockSnippet")) break;
    }
    if (!rowContains(&grid, 3, "mockSnippet") or grid.contains("${1:")) {
        std.debug.print("snippet accept corrupted the text:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 3, "mockSnippet"));
    try std.testing.expect(!grid.contains("${1:")); // no placeholder garbage

    // exit insert, then :qa
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "lsp: user flow — b. Ctrl+n stand Enter jk A keeps the cursor at EOL" {
    // The exact reproduction from the user report: open build.zig, 14j, o,
    // tab, type "const target = b.", Ctrl+n, type "stand", Enter (accept),
    // jk (exit insert), A. After all of that the cursor must sit at the end
    // of the line (after the accepted completion), not stranded mid-line or
    // on a stray newline.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}flow.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {
            \\    const t1 = b.standardTargetOptions(.{});
            \\    const t2 = b.standardOptimizeOption(.{});
            \\    _ = t1;
            \\    _ = t2;
            \\    const exe = b.addExecutable(.{ .name = "x", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }) });
            \\    b.installArtifact(exe);
            \\    const rc = b.addRunArtifact(exe);
            \\    const ts = b.step("test", "run");
            \\    ts.dependOn(&rc.step);
            \\    _ = ts;
            \\}
            \\
        );
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // the exact user key sequence, staged so the completion has time to open
    try sess.send("14jo\tconst target = b.");
    waited = 0;
    var menu = false;
    while (!menu) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("mockItem")) menu = true; // b. trigger menu open
    }
    if (!menu) {
        std.debug.print("b. menu did not open:\n", .{});
        grid.dump();
    }
    try std.testing.expect(menu);

    try sess.send("\x0estand"); // Ctrl+n then type stand
    waited = 0;
    var filtered = false;
    while (!filtered) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        if (grid.contains("mockAlphastand")) filtered = true; // filtered list
    }
    try std.testing.expect(filtered);

    try sess.send("\rjkA"); // accept, exit insert, append
    waited = 0;
    var ok = false;
    while (!ok) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 10000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        // accepted completion on the new line (mockItemstand or
        // mockAlphastand — Ctrl+n vs auto-accept timing) + cursor at EOL in
        // the status bar; both candidates are 14 chars so col 35 = line end
        if (grid.contains("mockItemstand") or grid.contains("mockAlphastand")) {
            if (grid.contains("col 35")) ok = true;
        }
    }
    if (!ok) {
        std.debug.print("user flow failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(ok);

    // A left us in insert mode; exit before :qa
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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

test "edit: o keeps an EOL inlay hint on its own line (Zig + mock LSP)" {
    // zls anchors a variable type hint at the end of the declared name,
    // which is the line end for a legal multiline declaration:
    //     const foo
    //         = 1;
    // `o` inserts a newline at that position without inserting any text
    // inside the line. The hint must stay on `const foo`; re-anchoring it
    // to character 0 of the new row made the insert cursor count the stale
    // label and ride in the middle of the empty line. The mock answers only
    // the first inlayHint request (slow zls), so the assertions cannot be
    // repaired by a background refresh.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}eol.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const foo\n    = 1;\nconst bar = 2;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{
        "OZ_LSP_CMD=zig-out/bin/mock_lsp",
        "OZ_MOCK_SCRIPT=inlay_eol",
    });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL") or !grid.contains(": eol")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("NORMAL") or !grid.contains(": eol")) {
        std.debug.print("inlay_eol fixture did not render:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("NORMAL"));
    try std.testing.expect(grid.contains(": eol"));

    // o on line 0, type a full statement. The new line must be hint-free
    // and the cursor column must count only the text (no stale label).
    try sess.send("o");
    try sess.send("const baz = 3;");
    try gridWaitFor(&sess, &grid, "const baz = 3;", 5000);
    {
        const foo_row = findRow(&grid, "const foo") orelse {
            std.debug.print("old line vanished after o:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        const baz_row = findRow(&grid, "const baz = 3;") orelse {
            std.debug.print("typed line missing after o:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(rowContains(&grid, foo_row, ": eol"));
        try std.testing.expect(!rowContains(&grid, baz_row, ": eol"));
    }
    try std.testing.expect(grid.contains("line 2/5 col 14"));

    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);

    // O above `const bar`: its EOL hint moves down with the line; the new
    // row stays clean, and the cursor sits on the new row after the indent.
    try sess.send("jjO");
    try sess.send("const top = 0;");
    try gridWaitFor(&sess, &grid, "const top = 0;", 5000);
    {
        const top_row = findRow(&grid, "const top = 0;") orelse {
            std.debug.print("O line missing:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        const bar_row = findRow(&grid, "const bar = 2;") orelse {
            std.debug.print("const bar line missing after O:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(!rowContains(&grid, top_row, ": eol"));
        try std.testing.expect(rowContains(&grid, bar_row, ": eol"));
    }
    try std.testing.expect(grid.contains("line 4/6 col 14"));

    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings(
        "const foo\nconst baz = 3;\n    = 1;\nconst top = 0;\nconst bar = 2;\n",
        buf,
    );
}

test "edit: o/O preserve CRLF endings and the cursor row (Zig + mock LSP)" {
    // A CRLF Zig buffer edited with o/O must stay pure CRLF: the newline is
    // the line's own terminator (not a bare LF spliced before the old CR),
    // the cursor lands after the autoindent on the new line, and typing at
    // EOL never happens between '\r' and '\n'.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}crlf.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn main() void {\r\n    const foo = 1;\r\n}\r\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{
        "OZ_LSP_CMD=zig-out/bin/mock_lsp",
        "OZ_MOCK_SCRIPT=inlay_eol",
    });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // O on the indented line: autoindent 4 + typed 14 = col 18.
    try sess.send("jO");
    try sess.send("const top = 0;");
    try gridWaitFor(&sess, &grid, "const top = 0;", 5000);
    try std.testing.expect(grid.contains("line 2/5 col 18"));
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);

    // o below the same line: 4 + 17 = col 21.
    try sess.send("jo");
    try sess.send("const bottom = 2;");
    try gridWaitFor(&sess, &grid, "const bottom = 2;", 5000);
    try std.testing.expect(grid.contains("line 4/6 col 21"));
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings(
        "pub fn main() void {\r\n    const top = 0;\r\n    const foo = 1;\r\n    const bottom = 2;\r\n}\r\n",
        buf,
    );
}

test "insert: one Esc leaves insert with an open completion menu" {
    // With a Zig/zls suggestion menu open, Esc is the insert-exit key (the
    // menu closes as part of the same press). The old menu-only Esc left a
    // half-insert state: a following `o` was typed as text, and `:wq` never
    // reached the command line. Ctrl+e is the stay-in-insert hide mapping.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}escmenu.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const foo = 1;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    try sess.send("o");
    // End on a trigger character so the response for the final document
    // arrives after the last edit and the menu actually opens (typing a
    // whole word faster than the mock round-trip leaves every response
    // stale, so no menu ever appears).
    try sess.send("const target = b.");
    try gridWaitFor(&sess, &grid, "mockItem", 5000);

    try sess.send("\x1b"); // ONE Esc: close the menu AND leave insert
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);

    const exit_code = try sess.commandAndWaitExit(":wq\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);

    const f = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const buf = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    try std.testing.expectEqualStrings("const foo = 1;\nconst target = b.\n", buf);
}

test "lsp: signature help — typing ( shows the callee signature" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}sig.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nfoo(");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // cursor to the end of "foo(" and type "(" — signatureHelp fires on the
    // keypress and the floating window shows the mock signature (the wake
    // mechanism drains the response without needing a further key).
    try sess.send("$a(");
    waited = 0;
    while (!grid.contains("mockSig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockSig")) break;
    }
    if (!grid.contains("mockSig")) {
        std.debug.print("signature window missing on (:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("mockSig"));

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

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}
test "lsp: editing — rename, format, inlay hints, outline" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}edit.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const foo = 1;\nconst bar = 2;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{"OZ_LSP_CMD=zig-out/bin/mock_lsp"});
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // <leader>o — outline list shows the mock symbol
    try sess.send(" o");
    waited = 0;
    var listed = false;
    while (!listed) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("mockFn")) listed = true;
    }
    if (!listed) {
        std.debug.print("outline list missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(listed);
    try sess.send("\x1b"); // Esc closes the list
    waited = 0;
    while (grid.contains("mockFn")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("mockFn"));

    // <leader>lf — format (mock returns a no-op whole-doc edit; content stays)
    try sess.send(" lf");
    waited = 0;
    while (!grid.contains("NORMAL") or grid.contains("COMMAND")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("NORMAL") and !grid.contains("COMMAND")) break;
    }
    try std.testing.expect(grid.contains("const foo = 1;"));

    // <leader>ti — inlay hint label rendered dim
    try sess.send(" ti");
    waited = 0;
    while (!grid.contains(": i32")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": i32")) break;
    }
    if (!grid.contains(": i32")) {
        std.debug.print("inlay hint missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(": i32"));

    // The hint STAYS visible while typing in insert mode (vim shows inlay
    // hints during insert) AND across the exit back to normal: the data is
    // shift-maintained per edit, so there is no clear + async re-request —
    // the "hints vanish then reappear" flash after jk.
    try sess.send("A.");
    waited = 0;
    var hint_kept = false;
    while (!hint_kept) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 5000) break;
        }
        if (grid.contains(": i32")) hint_kept = true;
    }
    if (!hint_kept) {
        std.debug.print("inlay hint vanished while typing in insert mode:\n", .{});
        grid.dump();
    }
    try std.testing.expect(hint_kept);
    // back to normal for the rename step below. '.' is a completion trigger
    // (the mock declares triggerCharacters ["."]), so the menu opened — Ctrl+e
    // hides it, then Esc exits insert; the hint stays (no re-request needed).
    try sess.send("\x05\x1b");
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
    // normal mode: the hint must still be there — exitInsert no longer
    // clears + re-requests, so there is no vanish/reappear flash
    waited = 0;
    var hint_after = false;
    while (!hint_after) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 8000) break;
        }
        // check the grid even on empty reads: the hint may already be
        // present from a previous feed (no new bytes arrive)
        if (grid.contains("i32")) hint_after = true;
    }
    if (!hint_after) {
        std.debug.print("inlay hint gone after insert exit:\n", .{});
        grid.dump();
    }
    try std.testing.expect(hint_after);

    // Repeated insert ⇄ normal toggling via jk must NOT drift the hint's
    // column: the 'j' is inserted (adjustInlayHintsInsert +1) and removed on
    // 'k' — the removal must shift hints back, or each jk exit leaves them
    // one column too far right (accumulating, as reported).
    var i_toggle: u32 = 0;
    var prev_col: ?usize = null;
    while (i_toggle < 4) : (i_toggle += 1) {
        try sess.send("ij"); // insert mode, type 'j'
        waited = 0;
        while (!grid.contains("INSERT")) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
            if (n == 0) {
                waited += 200;
                if (waited >= 5000) break;
            } else {
                sess.used += n;
                grid.feed(sess.out[sess.used - n .. sess.used]);
            }
            if (grid.contains("INSERT")) break;
        }
        try sess.send("k"); // jk → exit, removing the 'j'
        waited = 0;
        while (grid.contains("INSERT")) {
            const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
            if (n == 0) {
                waited += 200;
                if (waited >= 5000) break;
            } else {
                sess.used += n;
                grid.feed(sess.out[sess.used - n .. sess.used]);
            }
            if (!grid.contains("INSERT")) break;
        }
        // locate ": i32" in the first content row (row 1 = file line 0;
        // row 0 is the tab bar)
        var rr: usize = 0;
        var pos: usize = 0;
        var found_pos = false;
        while (rr < grid.rows) : (rr += 1) {
            const rt = grid.rowText(rr);
            if (std.mem.indexOf(u8, rt, "i32")) |pp| {
                pos = pp;
                found_pos = true;
                break;
            }
        }
        if (!found_pos) {
            std.debug.print("hint missing after toggle {d}:\n", .{i_toggle});
            grid.dump();
            return error.TestUnexpectedResult;
        }
        std.debug.print("jk toggle {d}: hint col {d}\n", .{ i_toggle, pos });
        if (prev_col) |p| {
            if (p != pos) {
                std.debug.print("hint drifted after jk toggle {d}: col {d} -> {d}\n", .{ i_toggle, p, pos });
                grid.dump();
                return error.TestUnexpectedResult;
            }
        }
        prev_col = pos;
    }

    // <leader>rn — cursor to "foo" (word end), rename to "renamedSymbol" via
    // the prefilled command line (mock replaces [0,4) with renamedSymbol)
    try sess.send("e rn");
    waited = 0;
    while (!grid.contains("COMMAND") or !grid.contains("foo")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("COMMAND")) break;
    }
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("renamedSymbol")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("renamedSymbol")) break;
    }
    if (!grid.contains("renamedSymbol")) {
        std.debug.print("rename result missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("renamedSymbol"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
    while (true) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) break;
        sess.used += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, sess.out[0..sess.used], "leaked") == null);
}

// Inlay-viewport coverage regression: the inlayHint request must span the
// FOCUSED WINDOW's full height (not a hard-coded 24 lines). A 40-row
// terminal shows 38 content rows; after G to the bottom of a 130-line
// file, lines ~92-129 are visible and hints must appear on lines far
// below the old top+24 request window (rows 25+ of the viewport used to
// stay hintless forever — the "below ~100 lines nothing has inlay hints"
// report).
test "lsp: inlay hints cover the whole viewport in a tall window" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}tall.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(alloc);
        var line_buf: [64]u8 = undefined;
        var i: u32 = 0;
        while (i < 130) : (i += 1) {
            const line = try std.fmt.bufPrint(&line_buf, "const v{d} = {d};\n", .{ i, i });
            try content.appendSlice(alloc, line);
        }
        try f.writeStreamingAll(io, content.items);
    }

    var sess = try Session.spawnEnvRows(io, &.{ oz_exe_path, name }, &.{ "OZ_LSP_CMD=zig-out/bin/mock_lsp", "OZ_MOCK_SCRIPT=inlay_range" }, 40);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.initSized(alloc, 40);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // LSP up: the auto-request for the top viewport band returns hints
    // echoing the mock's recorded text (": v0 = 0;" on line 0).
    waited = 0;
    while (!grid.contains(": v0 = 0;const")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": v0 = 0;const")) break;
    }
    if (!grid.contains(": v0 = 0;const")) {
        std.debug.print("inlay hint missing at top:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(": v0 = 0;const"));

    // G → the file bottom. The viewport now shows lines ~92-129; hints for
    // lines below the old top+24 window (e.g. v125/v128) must appear —
    // before the fix the request covered only top..top+23, leaving every
    // lower row of a tall window without hints.
    try sess.send("G");
    waited = 0;
    while (!grid.contains("v129 = 129;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("v129 = 129;")) break;
    }
    if (!grid.contains("v129 = 129;")) {
        std.debug.print("G did not reach the file bottom:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("v129 = 129;"));

    waited = 0;
    var bottom_hints = false;
    while (!bottom_hints) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": v125") and grid.contains(": v128")) bottom_hints = true;
    }
    if (!bottom_hints) {
        std.debug.print("bottom-of-viewport inlay hints missing:\n", .{});
        grid.dump();
    }
    try std.testing.expect(bottom_hints);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

// Focus-switch LSP regression: switching windows with Ctrl-w (windows
// showing DIFFERENT buffers) must retarget the single LSP client to the
// newly focused buffer. Without that, the client's current document stays
// the previous window's file: didChange edits from the focused window
// reach the WRONG document on the server, whose copy of the edited file
// goes stale — so its inlay hints (and hover/diagnostics) silently refer
// to old text. Flow: :vs → :e B (lands LEFT) → Ctrl-w l (right = A) →
// edit A → Ctrl-w h (left = B) → <leader>ti. The mock echoes its
// recorded text: a didChange that wrongly targeted B leaves B's copy
// corrupted with A's edit (": b0 = 0;x") while the correct flow leaves
// it clean (": b0 = 0;").
test "lsp: Ctrl-w focus switch retargets the client to the window's buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name_a = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}left.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    var name_buf2: [128:0]u8 = undefined;
    const name_b = try bufPrintZ(&name_buf2, "/tmp/oz_e2e_{d}_{d}right.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name_a) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, name_b) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name_a, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a0 = 0;\nconst a1 = 1;\nconst a2 = 2;\n");
    }
    {
        const f = try std.Io.Dir.cwd().createFile(io, name_b, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const b0 = 0;\nconst b1 = 1;\nconst b2 = 2;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name_a }, &.{ "OZ_LSP_CMD=zig-out/bin/mock_lsp", "OZ_MOCK_SCRIPT=inlay_range" });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // LSP up on A: the auto-request echoes A's recorded line 0.
    waited = 0;
    while (!grid.contains(": a0 = 0;const")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": a0 = 0;const")) break;
    }
    if (!grid.contains(": a0 = 0;const")) {
        std.debug.print("LSP never attached on A:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(": a0 = 0;const"));

    // :vs — both windows show A (focus moves to the right window). The
    // pane separator column marks the split (row text alone is ambiguous:
    // inlay labels echo the line content).
    try sess.send(":vs\r");
    waited = 0;
    var split = false;
    while (!split) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 2, "│")) split = true;
    }
    if (!split) {
        std.debug.print("after :vs:\n", .{});
        grid.dump();
    }
    try std.testing.expect(split);

    // :e B — lands in the LEFT window (firstLeaf) and retargets the client
    // to B (switchTo → ensureLsp). The right window keeps showing A.
    try sess.send(":e ");
    try sess.send(name_b);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("const b0 = 0;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 6000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("const b0 = 0;")) break;
    }
    if (!grid.contains("const b0 = 0;")) {
        std.debug.print(":e B did not open:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("const b0 = 0;"));

    // Focus the RIGHT window (A) with Ctrl-w l. This is the regression
    // step: the focused buffer changes A←B without a buffer switch, so the
    // LSP client must be retargeted here.
    try sess.send("\x17l");
    // append 'x' at the end of A's line 0: "const a0 = 0;x"
    try sess.send("Ax\x1b");
    waited = 0;
    while (!grid.contains("const a0 = 0;x")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 6000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("const a0 = 0;x")) break;
    }
    if (!grid.contains("const a0 = 0;x")) {
        std.debug.print("edit in the right window did not land:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("const a0 = 0;x"));

    // Focus the LEFT window (B) again — another retarget point — and ask
    // for hints. The mock answers from its RECORDED copy of B: correct
    // behavior ("b0 = 0;" — A's edit synced to A) vs. the bug (": b0 = 0;x"
    // — A's didChange was sent against B's uri and corrupted its copy).
    try sess.send("\x17h");
    try sess.send(" ti");
    waited = 0;
    var b_hint = false;
    while (!b_hint) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": b0 = 0;const b0")) b_hint = true;
    }
    if (!b_hint) {
        std.debug.print("B's hint missing or corrupted (didChange misrouted):\n", .{});
        grid.dump();
    }
    try std.testing.expect(b_hint);
    try std.testing.expect(!grid.contains(": b0 = 0;x"));

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

// Cross-buffer inlay-hint regression (the "right window inlay hints are
// misaligned" report): the stored hints are homogeneous — they all belong
// to whichever buffer was FOCUSED when they were fetched — so a split
// window showing a DIFFERENT buffer must never splice them into its own
// text (same line numbers, but the labels and byte columns describe the
// OTHER document). Flow: :vs → :e R (lands LEFT, focused; hints load for
// R) → the RIGHT window (still showing L) must render NO R hints; then
// Ctrl-w l (RIGHT = L focused; hints load for L) → the LEFT window
// (still showing R) must render NO L hints. The mock's `inlay_range`
// script echoes the requested file's own content as labels (": r0 = 0;"
// for "const r0 = 0;"), so a foreign splice is directly visible as
// "<label>const <other file>" text in the wrong pane.
test "lsp: split windows with different buffers never splice foreign inlay hints" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name_l = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}lft.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    var name_buf2: [128:0]u8 = undefined;
    const name_r = try bufPrintZ(&name_buf2, "/tmp/oz_e2e_{d}_{d}rgt.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name_l) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, name_r) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name_l, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const l0 = 0;\nconst l1 = 1;\nconst l2 = 2;\n");
    }
    {
        const f = try std.Io.Dir.cwd().createFile(io, name_r, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const r0 = 0;\nconst r1 = 1;\nconst r2 = 2;\n");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name_l }, &.{ "OZ_LSP_CMD=zig-out/bin/mock_lsp", "OZ_MOCK_SCRIPT=inlay_range" });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    var waited: i32 = 0;
    while (!grid.contains("NORMAL")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    // LSP up on L: hints echo L's recorded text on the single window.
    waited = 0;
    while (!grid.contains(": l0 = 0;const l0")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": l0 = 0;const l0")) break;
    }
    if (!grid.contains(": l0 = 0;const l0")) {
        std.debug.print("LSP never attached on L:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(": l0 = 0;const l0"));

    // :vs — both windows show L; the RIGHT (new, focused) window is the
    // one whose text must never carry foreign hints later. Content rows
    // start at grid row 1 (below the tab bar), so the pane separator "│"
    // lands there — row-scoped to ignore tab-bar separators.
    try sess.send(":vs\r");
    waited = 0;
    var split = false;
    while (!split) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 2, "│")) split = true;
    }
    if (!split) {
        std.debug.print("after :vs:\n", .{});
        grid.dump();
    }
    try std.testing.expect(split);

    // :e R — lands in the LEFT window (firstLeaf) and retargets the LSP
    // client to R. The LEFT window is focused, so R's hints load there;
    // the RIGHT window still shows L.
    try sess.send(":e ");
    try sess.send(name_r);
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("const r0 = 0;")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 6000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains("const r0 = 0;")) break;
    }
    if (!grid.contains("const r0 = 0;")) {
        std.debug.print(":e R did not open:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("const r0 = 0;"));

    // Wait until R's hints are actually loaded (visible in the LEFT
    // pane). Once loaded, the RIGHT pane (showing L) must contain NONE of
    // them: before the fix the whole list is drawn in every window, so L's
    // "const l0 = 0;" row became ": r0 = 0;const l0 = 0;" — a foreign
    // label spliced over L's text.
    waited = 0;
    var r_hint = false;
    while (!r_hint) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": r0 = 0;const r0")) r_hint = true;
    }
    if (!r_hint) {
        std.debug.print("R's hints never loaded in the left pane:\n", .{});
        grid.dump();
    }
    try std.testing.expect(r_hint);
    // Let any trailing repaint land before asserting the absence.
    waited = 0;
    while (waited < 600) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    // The RIGHT window still shows L's own text (sanity).
    try std.testing.expect(grid.contains("const l0 = 0;"));
    // THE FIX: no foreign R label may ever sit in front of L's text.
    if (grid.contains(": r0 = 0;const l0")) {
        std.debug.print("foreign R hint spliced into L's text in the right pane:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains(": r0 = 0;const l0"));

    // Focus the RIGHT window (L) with Ctrl-w l — a window-focus buffer
    // switch; L's hints load there now. The LEFT window (still showing R)
    // must render none of them.
    try sess.send("\x17l");
    waited = 0;
    var l_hint = false;
    while (!l_hint) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(": l0 = 0;const l0")) l_hint = true;
    }
    if (!l_hint) {
        std.debug.print("L's hints never loaded in the right pane after Ctrl-w l:\n", .{});
        grid.dump();
    }
    try std.testing.expect(l_hint);
    waited = 0;
    while (waited < 600) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    // The LEFT window still shows R's own text (sanity).
    try std.testing.expect(grid.contains("const r0 = 0;"));
    // THE FIX, mirrored: no foreign L label in front of R's text.
    if (grid.contains(": l0 = 0;const r0")) {
        std.debug.print("foreign L hint spliced into R's text in the left pane:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains(": l0 = 0;const r0"));

    const exit_code2 = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code2);
}

test "command mode: Tab completes command names, cycles, keeps path completion" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cmdt.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\n");
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
    // ":w" + Tab → ":write"
    try sess.send(":w\t");
    waited = 0;
    while (!grid.contains(":write")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(":write")) break;
    }
    if (!grid.contains(":write")) {
        std.debug.print("cmd tab write failed:\n", .{});
        grid.dump();
        var cr: usize = 0;
        while (cr < grid.rows) : (cr += 1) std.debug.print("R{d}: [{s}]\n", .{ cr, grid.rowText(cr) });
    }
    try std.testing.expect(grid.contains(":write"));
    // Esc cancels
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("COMMAND")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("COMMAND")) break;
    }
    // ":b" + Tab cycles bnext
    try sess.send(":b\t");
    waited = 0;
    while (!grid.contains(":bnext")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(":bnext")) break;
    }
    try std.testing.expect(grid.contains(":bnext"));
    // second Tab cycles to bprev
    try sess.send("\t");
    waited = 0;
    while (!grid.contains(":bprev")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(":bprev")) break;
    }
    try std.testing.expect(grid.contains(":bprev"));
    // Esc, then ":e " + Tab still completes paths (build.zig in cwd)
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("COMMAND")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("COMMAND")) break;
    }
    try sess.send(":e b\t");
    waited = 0;
    while (!grid.contains(":e build.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (grid.contains(":e build.zig")) break;
    }
    if (!grid.contains(":e build.zig")) {
        std.debug.print("cmd tab path failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains(":e build.zig"));
    // Esc alone (not Alt+:) cancels the command line, then :q! exits
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("COMMAND")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (!grid.contains("COMMAND")) break;
    }
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "keymap picker: <leader>sk filters, token colors, Esc closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}km.txt", .{ linux.getpid(), tmp_counter });
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

    // <leader>sk opens the keymap-search picker
    try sess.send(" sk");
    waited = 0;
    while (!grid.contains(" Keymaps ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains(" Keymaps "));

    // "hover" → the K entry is the only match; its "K" token renders with
    // the keyword color (kanagawa oniViolet), not the title's accent
    try sess.send("hover");
    waited = 0;
    while (!grid.contains("Hover")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Hover"));
    try std.testing.expect(grid.containsFg("K", packRgb(149, 127, 184)));

    // clear the query with backspaces, then "grep" → the space st entry;
    // its "space" prefix token renders with the accent color
    try sess.send("\x7f\x7f\x7f\x7f\x7f");
    waited = 0;
    while (grid.contains("hover")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 3000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send("grep");
    waited = 0;
    while (!grid.contains("space st")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("space st"));
    try std.testing.expect(grid.containsFg("space", packRgb(0xE6, 0xC3, 0x84)));

    // Esc closes the picker
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains(" Keymaps ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains(" Keymaps "));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "file tree: directory tree — folder glyphs, l expands, h folds" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}tr.txt", .{ linux.getpid(), tmp_counter });
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

    // <space>e — the first entry row (row 2) is the first-level dir "docs"
    // with the CLOSED folder glyph (dirs sort first, files after)
    try sess.send(" e");
    waited = 0;
    while (!grid.contains("Files")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("Files"));
    try std.testing.expect(rowContains(&grid, navBodyRow(), "\u{f07b}")); // closed folder

    // l expands the selected dir — its child appears and the folder glyph
    // flips to the OPEN variant
    try sess.send("l");
    waited = 0;
    while (!grid.contains("workspace-plan")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("workspace-plan"));
    try std.testing.expect(grid.contains("\u{f07c}")); // open folder glyph

    // h folds it again — the child disappears and no open folder remains
    try sess.send("h");
    waited = 0;
    while (grid.contains("workspace-plan")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("workspace-plan"));
    try std.testing.expect(!grid.contains("\u{f07c}"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "picker + tab: file rows and tabs carry devicons" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // spawn on build.zig (a .zig file) — the tab bar should show the zig
    // glyph in its semantic color
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
    // tab bar (row 0) icon: seti_zig glyph. The active tab now paints its
    // icon with the theme accent marker color (demo nav-icon treatment);
    // inactive tabs keep the devicon's semantic color.
    const zig_glyph = "\u{e6a9}";
    try std.testing.expect(grid.containsFg(zig_glyph, packRgb(0x7E, 0x9C, 0xD8)));

    // <leader>sf + "main" filters to src/main.zig; its picker row also
    // carries the zig icon before the path. Wait on the picker's own input
    // row ("❯ main") — NOT on "src/main.zig", which build.zig's comments
    // also contain, so the wait would pass before the picker rendered (and
    // a following Esc + ":q!" could then coalesce in the pty as Alt+':').
    try sess.send(" sfmain");
    waited = 0;
    while (!grid.contains("❯ main")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!grid.contains("❯ main")) {
        std.debug.print("icon picker grid (no picker input row):\n", .{});
        grid.dump();
    }
    try std.testing.expect(grid.contains("❯ main"));
    try std.testing.expect(grid.contains("src/main.zig"));
    try std.testing.expect(grid.containsFg(zig_glyph, packRgb(0xFF, 0xA0, 0x66)));

    // Esc closes the picker, then quit
    try sess.send("\x1b");
    waited = 0;
    while (grid.contains("❯ ")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        std.debug.print("exit after :q! failed, picker open?={}\n", .{grid.contains("❯ ")});
        grid.dump();
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "nonexistent CLI file opens as an empty named buffer; :w creates it" {
    // vim semantics: `oz <missing-path>` must NOT land on the dashboard — it
    // opens an empty buffer whose path is the arg, and only :w creates the
    // file on disk.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}_newfile.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    std.Io.Dir.cwd().deleteFile(io, name) catch {}; // make sure it's missing
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};

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
    // an empty named buffer, NOT the dashboard (its title is the giveaway)
    try std.testing.expect(!grid.contains("终端文本编辑器"));
    try std.testing.expect(grid.contains("line 1/1"));
    // the file must NOT have been created just by opening it
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only }));

    // type something, :w creates the file
    try sess.send("ihello new file\x1b");
    waited = 0;
    while (!grid.contains("hello new file")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try sess.send(":w\r");
    waited = 0;
    while (!grid.contains("written:")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("written:"));

    const f2 = try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only });
    defer f2.close(io);
    const size2 = (try f2.stat(io)).size;
    const buf2 = try alloc.alloc(u8, @intCast(size2));
    defer alloc.free(buf2);
    _ = try f2.readPositionalAll(io, buf2, 0);
    try std.testing.expectEqualStrings("hello new file", buf2);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "H/M/L move in the viewport; zz/zt/zb scroll around the cursor" {
    // 24-row pty: content area = 24 - 2 (bottom chrome) - 2 (buffer strip) =
    // 20 rows, grid rows 2..21. File: "line 001".."line 100" (plus a
    // trailing empty line 101 from the final newline).
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}_view.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const line = try std.fmt.allocPrint(alloc, "line {d:0>3}\n", .{i});
            defer alloc.free(line);
            try f.writeStreamingAll(io, line);
        }
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // feed until `needle` shows on `row` (row < 0 → anywhere in the grid)
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8, row: i32) !bool {
            var waited: i32 = 0;
            while (true) {
                const hit = if (row < 0) g.contains(needle) else rowContains(g, @intCast(row), needle);
                if (hit) return true;
                const n = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (n == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += n;
                g.feed(s.out[s.used - n .. s.used]);
            }
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "line 1/101", -1));

    // jump to line 61 (0-based line 60): ensure-visible puts view_top at 39
    try sess.send(":61\r");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 61/101", -1));

    // zz: cursor line 60 → view_top = 60 - 21/2 = 50 → first row "line 051";
    // the cursor itself stays on line 61
    try sess.send("zz");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 051", 2));
    try std.testing.expect(grid.contains("line 61/101"));

    // zt: cursor line at the top → first row "line 061"
    try sess.send("zt");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 061", 2));
    try std.testing.expect(grid.contains("line 61/101"));

    // zb: cursor line at the bottom → view_top = 60 - 19 = 41 → "line 042"
    try sess.send("zb");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 042", 2));
    try std.testing.expect(grid.contains("line 61/101"));

    // H: first visible line (view_top 41) → line 42
    try sess.send("H");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 42/101", -1));

    // M: middle visible line = 41 + (20-1)/2 = 50 → line 51
    try sess.send("M");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 51/101", -1));

    // L: last visible line = 40 + 20 = 60 → line 61
    try sess.send("L");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 61/101", -1));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "folds: za toggles, zM/zR close/open all, j/k skip closed folds" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // two foldable blocks (indent-based detection) + non-foldable top line
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}fold.py", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\top
            \\def alpha():
            \\    body a1
            \\    body a2
            \\def beta():
            \\    body b1
            \\tail
        );
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const n = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (n == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += n;
                g.feed(s.out[s.used - n .. s.used]);
            }
            return true;
        }
        fn untilGone(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (g.contains(needle)) {
                const n = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (n == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += n;
                g.feed(s.out[s.used - n .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    try std.testing.expect(try Wait.until(&sess, &grid, "body a1"));

    // cursor onto `def alpha():` (1-based line 2)
    try sess.send("j");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 2/7"));

    // za closes the fold: the two body rows vanish, a marker appears on the
    // header line, the cursor stays on the (visible) header
    try sess.send("za");
    try std.testing.expect(try Wait.until(&sess, &grid, "… 2 lines"));
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "body a1"));
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "body a2"));
    try std.testing.expect(grid.contains("def alpha()"));
    try std.testing.expect(grid.contains("line 2/7"));

    // za again reopens the same fold
    try sess.send("za");
    try std.testing.expect(try Wait.until(&sess, &grid, "body a1"));
    try std.testing.expect(grid.contains("body a2"));

    // zM closes every fold in the buffer (alpha: 2 hidden lines, beta: 1)
    try sess.send("zM");
    try std.testing.expect(try Wait.until(&sess, &grid, "… 1 lines"));
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "body a1"));
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "body b1"));
    try std.testing.expect(grid.contains("… 2 lines"));
    try std.testing.expect(grid.contains("def alpha()"));
    try std.testing.expect(grid.contains("def beta()"));

    // j from the closed alpha fold lands on beta's header — the fold body
    // counts as ONE line for vertical motion
    try sess.send("j");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 5/7"));
    // j again → tail (past the closed beta fold)
    try sess.send("j");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 7/7"));
    // k skips beta's hidden body, back to the beta header
    try sess.send("k");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 5/7"));

    // zR reopens everything
    try sess.send("zR");
    try std.testing.expect(try Wait.until(&sess, &grid, "body a1"));
    try std.testing.expect(grid.contains("body b1"));
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "… 2 lines"));

    // za on a non-foldable line: status hint, no crash, nothing folded
    try sess.send("gg");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 1/7"));
    try sess.send("za");
    try std.testing.expect(try Wait.until(&sess, &grid, "没有可折叠"));
    try std.testing.expect(grid.contains("body a1"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("GIT EXIT DUMP code={d}:\n{s}\n", .{ exit_code, sess.out[start..sess.used] });
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "git: gutter signs, ]c hunk jump, hunk stage/reset, blame ghost, branch" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // ---- temp git repo: 20-line file, commit, then modify ----
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_git_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);
    var old = std.ArrayList(u8).empty;
    defer old.deinit(alloc);
    var n: usize = 1;
    var line_buf: [32]u8 = undefined;
    while (n <= 20) : (n += 1) {
        try old.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
    }
    try writeTestFile(io, dir, "a.txt", old.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "a.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);
    const head = try runCmdCapture(io, alloc, &.{ "git", "rev-parse", "HEAD" }, dir);
    defer alloc.free(head);
    // modify: line3 → CHANGED; insert NEW after line16; drop lines 19-20.
    // The regions are >3 context lines apart → two separate hunks. The
    // deleted tail must stay ON SCREEN (22 content rows) so the ▔ marker is
    // visible: final file = 19 lines.
    var content = std.ArrayList(u8).empty;
    defer content.deinit(alloc);
    n = 1;
    while (n <= 20) : (n += 1) {
        if (n == 3) {
            try content.appendSlice(alloc, "CHANGED\n");
        } else if (n == 17) {
            try content.appendSlice(alloc, "NEW\n");
            try content.appendSlice(alloc, "line17\n");
        } else if (n >= 19) {
            continue; // deleted
        } else {
            try content.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
        }
    }
    try writeTestFile(io, dir, "a.txt", content.items);
    // final line count: 19 text lines + the trailing empty line after the
    // final '\n' (piece-table lineCount = newlines + 1) = 20
    const final_lines: usize = 20;

    var sess = try Session.spawnCwd(io, &.{ oz_exe_path, "a.txt" }, dir);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
        fn untilGone(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));

    // status bar shows the branch once the async status job lands
    try std.testing.expect(try Wait.until(&sess, &grid, "⎇ main"));

    // gutter signs: ▎ on the modified/added lines, ▔ (deleted below) marker
    // on the line above the removed tail
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}")); // ▎
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{2594}")); // ▔

    // ]c jumps from line 1 to the first hunk (CHANGED at 1-based line 3)
    try sess.send("]c");
    const needle3 = try std.fmt.allocPrint(alloc, "line 3/{d}", .{final_lines});
    defer alloc.free(needle3);
    try std.testing.expect(try Wait.until(&sess, &grid, needle3));

    // <leader>hs stages the hunk under the cursor (whole @@ block)
    try sess.send(" hs");
    var staged = try runCmdCapture(io, alloc, &.{ "git", "diff", "--cached", "--", "a.txt" }, dir);
    defer alloc.free(staged);
    var waited: i32 = 0;
    while (std.mem.indexOf(u8, staged, "CHANGED") == null and waited < 5000) {
        alloc.free(staged);
        std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
        waited += 100;
        staged = try runCmdCapture(io, alloc, &.{ "git", "diff", "--cached", "--", "a.txt" }, dir);
    }
    try std.testing.expect(std.mem.indexOf(u8, staged, "CHANGED") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged, "NEW") == null); // hunk 2 NOT staged

    // ]c → second hunk (NEW at 1-based line 17)
    try sess.send("]c");
    const needle17 = try std.fmt.allocPrint(alloc, "line 17/{d}", .{final_lines});
    defer alloc.free(needle17);
    try std.testing.expect(try Wait.until(&sess, &grid, needle17));

    // <leader>hr resets that hunk: NEW leaves the working tree
    try sess.send(" hr");
    var work_diff = try runCmdCapture(io, alloc, &.{ "git", "diff", "--", "a.txt" }, dir);
    defer alloc.free(work_diff);
    waited = 0;
    while (std.mem.indexOf(u8, work_diff, "NEW") != null and waited < 5000) {
        alloc.free(work_diff);
        std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
        waited += 100;
        work_diff = try runCmdCapture(io, alloc, &.{ "git", "diff", "--", "a.txt" }, dir);
    }
    try std.testing.expect(std.mem.indexOf(u8, work_diff, "NEW") == null);
    // hunk 2's reset must not touch the staged hunk 1
    const staged2 = try runCmdCapture(io, alloc, &.{ "git", "diff", "--cached", "--", "a.txt" }, dir);
    defer alloc.free(staged2);
    try std.testing.expect(std.mem.indexOf(u8, staged2, "CHANGED") != null);

    // current-line blame is ON BY DEFAULT (nvim current_line_blame=true):
    // "<author>, HH:MM - <summary>" ghost text on the cursor line, 1s
    // after the cursor settles — no keypress needed. The cursor sits on
    // hunk B (not moved since ]c); the hr reset invalidated and reloaded
    // the blame, so wait for the ghost to (re)appear.
    try std.testing.expect(try Wait.until(&sess, &grid, "E2E Tester, "));
    try std.testing.expect(grid.contains(" - init"));
    // <leader>tb toggles it off...
    try sess.send(" tb");
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "E2E Tester,"));
    // ...and back on (blame data is cached — the ghost returns)
    try sess.send(" tb");
    try std.testing.expect(try Wait.until(&sess, &grid, "E2E Tester, "));

    // untracked file: every line reads as added — open b.txt, the ▎ sign
    // covers the gutter
    try writeTestFile(io, dir, "b.txt", "one\ntwo\nthree\n");
    try sess.send(":e b.txt\r");
    try std.testing.expect(try Wait.until(&sess, &grid, "one"));
    // the untracked status refresh is async — wait for the added signs
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "git: blame ghost stays inside its pane in a split" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // ---- temp git repo: one long line ----
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_ghost_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);
    // 30 chars: the ghost anchored past the line end (gutter 2 + 30 = col
    // 32) overflows the left pane's 40-col right edge — clipping must use
    // the PANE edge, not the screen width, or the ghost bleeds into the
    // right pane's columns
    var long = std.ArrayList(u8).empty;
    defer long.deinit(alloc);
    try long.appendSlice(alloc, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n");
    try writeTestFile(io, dir, "a.txt", long.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "a.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);

    var sess = try Session.spawnCwd(io, &.{ oz_exe_path, "a.txt" }, dir);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 5000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    try std.testing.expect(try Wait.until(&sess, &grid, "⎇ main"));

    // :vs → both panes show the long line; focus the LEFT (40-col) pane
    try sess.send(":vs\r");
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{2502}")); // │
    try sess.send("\x17h");
    // the current-line blame ghost appears on the cursor line. It must be
    // clipped to the LEFT pane: its TAIL ("init", the commit summary,
    // which lands at col 53+ when drawn unclipped) must never cross col 40
    // into the right pane — with screen-width clipping the tail shows up
    // inside the neighbor's columns. The ghost's prefix ("E2E") sits at
    // col 33-35, so only the tail can detect the leak.
    var placed = false;
    var leaked = false;
    var waited: i32 = 0;
    while (!placed and waited < 5000) {
        const row1 = grid.rowText(2);
        const left = if (row1.len > 40) row1[0..40] else row1;
        const right = if (row1.len > 40) row1[40..] else "";
        if (std.mem.indexOf(u8, right, "init") != null) leaked = true;
        if (std.mem.indexOf(u8, left, "E2E") != null) {
            // the ghost is on the left — give the post-Ctrl-w-h frame a
            // moment to settle, then re-check the tail
            var quiet: i32 = 0;
            while (quiet < 300) {
                const nn = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
                if (nn == 0) {
                    quiet += 50;
                    continue;
                }
                sess.used += nn;
                grid.feed(sess.out[sess.used - nn .. sess.used]);
                quiet = 0;
            }
            const r2 = grid.rowText(2);
            const rr2 = if (r2.len > 40) r2[40..] else "";
            if (std.mem.indexOf(u8, rr2, "init") != null) leaked = true;
            placed = true;
            break;
        }
        const nn = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (nn == 0) {
            waited += 200;
            continue;
        }
        sess.used += nn;
        grid.feed(sess.out[sess.used - nn .. sess.used]);
    }
    if (!placed or leaked) {
        std.debug.print("ghost placement: placed={} leaked={} row1='{s}'\n", .{ placed, leaked, grid.rowText(2) });
        grid.dump();
    }
    try std.testing.expect(placed);
    try std.testing.expect(!leaked);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "git: blame ghost clips before the agent rail (120 dock / 80 drawer)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Two real commits in one temp repo. The 120-col case uses a line long
    // enough that the unclipped ghost would cross the rail; the 80-col case
    // exercises the overlay drawer, whose right side covers the line tail.
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_ghostrail_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);

    var long = std.ArrayList(u8).empty;
    defer long.deinit(alloc);
    try long.appendNTimes(alloc, 'x', 65);
    try long.append(alloc, '\n');
    try writeTestFile(io, dir, "long.txt", long.items);
    var short = std.ArrayList(u8).empty;
    defer short.deinit(alloc);
    try short.appendNTimes(alloc, 'x', 30);
    try short.append(alloc, '\n');
    try writeTestFile(io, dir, "short.txt", short.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "long.txt", "short.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);

    const Cases = [_]struct { rows: u16, cols: u16, file: []const u8 }{
        .{ .rows = 30, .cols = 120, .file = "long.txt" },
        .{ .rows = 24, .cols = 80, .file = "short.txt" },
    };
    for (Cases) |case| {
        var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, case.file }, null, case.rows, case.cols, dir);
        defer sess.close();
        defer killPid(sess.pid);
        const rows: usize = case.rows;
        const cols: usize = case.cols;
        var grid = try Grid.initSizedCols(alloc, rows, cols);
        defer grid.deinit(alloc);
        try gridWaitFor(&sess, &grid, "NORMAL", 8000);
        // Open the rail and keep it up; the prompt owns the keyboard, but the
        // blame ghost follows the EDITOR cursor and must still be clipped.
        try sess.send(" a");
        try gridWaitFor(&sess, &grid, "AGENTS", 5000);
        try gridWaitFor(&sess, &grid, "E2E Tester", 10000);

        var blame_row: ?usize = null;
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            if (std.mem.indexOf(u8, grid.rowText(r), "E2E Tester") != null) {
                blame_row = r;
                break;
            }
        }
        const row = blame_row orelse {
            std.debug.print("blame rail clip: ghost missing at {d}x{d}\n", .{ cols, rows });
            grid.dump();
            return error.TestUnexpectedResult;
        };
        const rail_col = aiRailCol(cols);
        // Never paints at/after the rail's left column, and one blank cell
        // separates the truncated ghost from the rail rule.
        const gap = aiCellText(&grid, row, rail_col - 1);
        if (gap.len != 0 and !std.mem.eql(u8, gap, " ")) {
            std.debug.print("blame rail clip {d}x{d}: gap cell {s} row={d}\n", .{ cols, rows, gap, row });
            grid.dump();
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings("│", aiCellText(&grid, row, rail_col));
        // The rail's own text was not overwritten (draw order + clipping).
        // The ghost now starts on the first content row, which lines up with
        // the rail's first thread row (the workspace line is one row up).
        try std.testing.expect(aiRowContains(&grid, row, "thread 1"));
        // The ghost's tail (the commit summary) is truncated before the rail.
        try std.testing.expect(std.mem.indexOf(u8, grid.rowText(row), "init") == null);
        // And the visible prefix is still in the editor pane, not the rail.
        const ghost_col = aiCellIndexOf(&grid, row, "E2E").?;
        try std.testing.expect(ghost_col + 1 < rail_col - 1);

        try sess.send("\x1b");
        if (cols >= 110) {
            try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
        } else {
            try gridWaitGone(&sess, &grid, "AGENTS", 3000);
        }
        try aiQuit(&sess);
    }
}

test "git: branch + gutter signs appear when oz is launched OUTSIDE the repo (absolute path)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // ---- temp git repo: 20-line file, commit, then modify on DISK ----
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_gitabs_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);
    var old = std.ArrayList(u8).empty;
    defer old.deinit(alloc);
    var n: usize = 1;
    var line_buf: [32]u8 = undefined;
    while (n <= 20) : (n += 1) {
        try old.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
    }
    try writeTestFile(io, dir, "a.txt", old.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "a.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);
    // modify: line3 → CHANGED; insert NEW after line16; drop lines 19-20
    var content = std.ArrayList(u8).empty;
    defer content.deinit(alloc);
    n = 1;
    while (n <= 20) : (n += 1) {
        if (n == 3) {
            try content.appendSlice(alloc, "CHANGED\n");
        } else if (n == 17) {
            try content.appendSlice(alloc, "NEW\n");
            try content.appendSlice(alloc, "line17\n");
        } else if (n >= 19) {
            continue; // deleted
        } else {
            try content.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
        }
    }
    try writeTestFile(io, dir, "a.txt", content.items);

    // oz is launched from /tmp — NOT inside the repo — with the repo file
    // as an ABSOLUTE argv path (the real-world `oz ~/repo/file.zig` from
    // $HOME). git must resolve the repo from the FILE's directory.
    var abs_buf: [256]u8 = undefined;
    const abs = try std.fmt.bufPrint(&abs_buf, "{s}/a.txt", .{dir});
    var sess = try Session.spawnCwd(io, &.{ oz_exe_path, abs }, "/tmp");
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 6000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    // branch + gutter signs must appear despite the outside-repo launch
    try std.testing.expect(try Wait.until(&sess, &grid, "⎇ main"));
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}")); // ▎
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{2594}")); // ▔

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "git: gutter marks live-update on UNSAVED edits (buffer vs HEAD, no :w)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // ---- temp git repo with a committed 10-line file ----
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_gitlive_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);
    var old = std.ArrayList(u8).empty;
    defer old.deinit(alloc);
    var n: usize = 1;
    var line_buf: [32]u8 = undefined;
    while (n <= 10) : (n += 1) {
        try old.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
    }
    try writeTestFile(io, dir, "a.txt", old.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "a.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);

    var sess = try Session.spawnCwd(io, &.{ oz_exe_path, "a.txt" }, dir);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 6000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    // the initial status lands → repo confirmed; a CLEAN file shows no signs
    try std.testing.expect(try Wait.until(&sess, &grid, "⎇ main"));
    try std.testing.expect(!grid.contains("\u{258e}")); // ▎ none yet

    // ---- insert a line at the end: buffer becomes dirty, NEVER saved ----
    try sess.send("GoAPPENDED");
    try std.testing.expect(try Wait.until(&sess, &grid, "APPENDED"));
    try sess.send("\x1b");
    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    // ~500ms edit hold + async buffer-vs-HEAD diff: ▎ appears WITHOUT :w,
    // while the tab bar still marks the buffer dirty (●)
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}")); // ▎
    // Dirty marker is its own reserved cell after the (possibly truncated)
    // name, so assert the tab name and the ● marker separately.
    try std.testing.expect(rowContains(&grid, 0, "a.txt"));
    try std.testing.expect(grid.contains("\u{25cf}")); // dirty ● still shown

    // ---- delete the first line: a deletion marker must appear ----
    try sess.send("ggdd");
    var waited: i32 = 0;
    var saw_del = grid.contains("\u{2581}") or grid.contains("\u{2594}"); // ▁ or ▔
    while (!saw_del and waited < 6000) {
        const nn = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (nn == 0) {
            waited += 200;
            continue;
        }
        sess.used += nn;
        grid.feed(sess.out[sess.used - nn .. sess.used]);
        saw_del = grid.contains("\u{2581}") or grid.contains("\u{2594}");
    }
    try std.testing.expect(saw_del);

    // ---- the DISK file is untouched: marks came from the buffer text ----
    std.Io.sleep(io, .fromMilliseconds(500), .real) catch {};
    const disk = try runCmdCapture(io, alloc, &.{ "git", "diff", "--", "a.txt" }, dir);
    defer alloc.free(disk);
    try std.testing.expect(disk.len == 0);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "git: marks stay glued to their lines while typing (instant shift, no refresh wait)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // ---- temp git repo: 20-line committed file, then modify line 10 on disk ----
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/oz_e2e_gitshift_{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try runCmdCapture(io, alloc, &.{ "git", "init", "-q", "-b", "main" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.email", "e2e@test" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "config", "user.name", "E2E Tester" }, dir);
    var old = std.ArrayList(u8).empty;
    defer old.deinit(alloc);
    var n: usize = 1;
    var line_buf: [32]u8 = undefined;
    while (n <= 20) : (n += 1) {
        try old.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
    }
    try writeTestFile(io, dir, "a.txt", old.items);
    _ = try runCmdCapture(io, alloc, &.{ "git", "add", "a.txt" }, dir);
    _ = try runCmdCapture(io, alloc, &.{ "git", "commit", "-qm", "init" }, dir);
    // dirty line 10 on disk (still an unsaved-looking buffer on open)
    var content = std.ArrayList(u8).empty;
    defer content.deinit(alloc);
    n = 1;
    while (n <= 20) : (n += 1) {
        if (n == 10) {
            try content.appendSlice(alloc, "MODIFIED-TEN\n");
        } else {
            try content.appendSlice(alloc, try std.fmt.bufPrint(&line_buf, "line{d}\n", .{n}));
        }
    }
    try writeTestFile(io, dir, "a.txt", content.items);

    var sess = try Session.spawnCwd(io, &.{ oz_exe_path, "a.txt" }, dir);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 6000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
        fn markRow(g: *Grid, glyph: []const u8) ?usize {
            var r: usize = 0;
            while (r < g.rows) : (r += 1) {
                if (std.mem.indexOf(u8, g.rowText(r), glyph) != null) return r;
            }
            return null;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "⎇ main"));
    // the modified line 10 shows a ▎ sign
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}"));
    const row_before = Wait.markRow(&grid, "\u{258e}").?;
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(row_before), "MODIFIED-TEN") != null);

    // ---- type at the TOP of the file WITHOUT leaving insert mode: two
    // newlines push the marked line (and its sign) down TWO rows INSTANTLY,
    // long before the async refresh could land (the typing hold is running).
    try sess.send("ggi");
    try std.testing.expect(try Wait.until(&sess, &grid, "INSERT"));
    try sess.send("A\rB\rC");
    // wait for the last typed char to render — the refresh cannot have
    // fired yet (still inside the typing hold)
    var waited: i32 = 0;
    while (!grid.contains("C")) {
        const nn = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (nn == 0) {
            waited += 50;
            if (waited >= 3000) break;
            continue;
        }
        sess.used += nn;
        grid.feed(sess.out[sess.used - nn .. sess.used]);
    }
    // the sign for the (now line-12) modified content must have shifted down
    const row_mid = Wait.markRow(&grid, "\u{258e}") orelse {
        std.debug.print("mark vanished while typing!\n", .{});
        return error.TestUnexpectedResult;
    };
    std.debug.print("gitshift: sign row before={d} while-typing={d}\n", .{ row_before, row_mid });
    try std.testing.expect(row_mid == row_before + 2);

    // ---- leave insert: the async refresh lands and confirms the shift ----
    try sess.send("\x1b");
    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));
    try std.testing.expect(try Wait.until(&sess, &grid, "\u{258e}"));
    const row_after = Wait.markRow(&grid, "\u{258e}").?;
    std.debug.print("gitshift: sign row after refresh={d}\n", .{row_after});
    try std.testing.expect(row_after == row_before + 2);

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "terminal: <M-r> float opens, keys forward, Esc returns, <M-w>/<M-e> switch, same key closes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // temp file with no "$" in it, so the shell prompt is the only "$" on
    // screen while the embedded terminal is open. The terminal spawns with
    // cwd = the buffer's directory (/tmp).
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}term.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha\nbeta\ngamma\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // first (row, col) where `needle` starts, for layout-position checks
    const findNeedle = struct {
        fn find(g: *Grid, needle: []const u8) ?struct { row: usize, col: usize } {
            var r: usize = 0;
            while (r < g.rows) : (r += 1) {
                const text = g.rowText(r);
                if (std.mem.indexOf(u8, text, needle)) |c| return .{ .row = r, .col = c };
            }
            return null;
        }
    }.find;

    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 8000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
        fn untilGone(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 8000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
        /// Poll (reading the pty every round) until `needle`'s first
        /// occurrence satisfies `pred`. A bare until() would match a stale
        /// "$" left in the grid by the PREVIOUS layout — the grid only
        /// advances when this loop reads, so position-aware waits are
        /// required across layout switches.
        fn untilWhere(s: *Session, g: *Grid, needle: []const u8, pred: fn (usize, usize) bool) !bool {
            var waited: i32 = 0;
            while (true) {
                if (findNeedle(g, needle)) |p| {
                    if (pred(p.row, p.col)) return true;
                }
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 8000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));

    // <M-r> (ESC r) opens the FLOATING terminal: $SHELL is unset in the
    // test env → /bin/sh (bash here, prompt "sh-5.3$ "). The shell takes a
    // moment to start, so just poll for the prompt.
    try sess.send("\x1br");
    try std.testing.expect(try Wait.until(&sess, &grid, "$"));

    // while the terminal is focused every key is forwarded to the shell:
    // it echoes the command line and prints the output
    try sess.send("echo TERM_E2E_OK\r");
    try std.testing.expect(try Wait.until(&sess, &grid, "TERM_E2E_OK"));

    // Esc returns to Normal: the editor must receive keys again. A lone Esc
    // is ambiguous if coalesced with the next byte in one pty read (ESC+i
    // would parse as Alt+i), so let oz process it alone before sending "ggi".
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try sess.send("ggi");
    try std.testing.expect(try Wait.until(&sess, &grid, "INSERT"));

    // Esc leaves insert mode again — the wait READS until the status bar no
    // longer shows INSERT, which also proves oz processed the Esc and
    // consumed its render before the next key write.
    try sess.send("\x1b");
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "INSERT"));

    // <M-w> switches the SAME session to the bottom strip: the resize clears
    // the terminal screen but bash redraws its prompt — the session survives,
    // and the prompt now sits in the bottom region (bottom strip of the
    // 24-row screen starts at row 15). Wait until the "$" actually MOVES
    // there (a stale "$" from the floating layout is still in the grid).
    try sess.send("\x1bw");
    try std.testing.expect(try Wait.untilWhere(&sess, &grid, "$", struct {
        fn pred(row: usize, col: usize) bool {
            _ = col;
            return row >= 14;
        }
    }.pred));

    // <M-e> switches to the right strip (40% width → cols 48..79): the
    // prompt is still there, now past column 40
    try sess.send("\x1be");
    try std.testing.expect(try Wait.untilWhere(&sess, &grid, "$", struct {
        fn pred(row: usize, col: usize) bool {
            _ = row;
            return col >= 40;
        }
    }.pred));

    // <M-r> floats the same session again (centered overlay, neither strip)
    try sess.send("\x1br");
    try std.testing.expect(try Wait.untilWhere(&sess, &grid, "$", struct {
        fn pred(row: usize, col: usize) bool {
            return row < 14 and col < 40;
        }
    }.pred));

    // <M-r> again closes the terminal: the prompt disappears from the grid.
    //
    // KNOWN ISSUE: this step currently FAILS because oz's terminal teardown
    // is broken — see the test's failure dump. Closing a live terminal
    // deadlocks oz (4/5 runs, vaxis handleSigChild blocked on global_vt_mutex
    // inside the interrupted main thread / iterating the deinit'd global_vts
    // map) or aborts it (1/5 runs, "incorrect alignment" panic in
    // Command.zig:111). The same-key close therefore never completes.
    try sess.send("\x1br");
    const closed = try Wait.untilGone(&sess, &grid, "$");
    if (!closed) {
        std.debug.print("terminal did not close after second <M-r>:\n", .{});
        grid.dump();
        if (try sess.tryWaitExit()) |code| {
            std.debug.print("oz died with code {d} (SIGABRT from the vaxis SIGCHLD handler)\n", .{code});
        } else {
            std.debug.print("oz still running (deadlocked in vaxis's handleSigChild)\n", .{});
        }
    }
    try std.testing.expect(closed);

    // reopen: the global_vts map must survive the teardown — its deinit
    // leaves the map undefined and the next spawn's put() crashed on the
    // pointer-stability assert (open -> close -> open SIGABRT)
    try sess.send("\x1br");
    try std.testing.expect(try Wait.until(&sess, &grid, "$"));
    try sess.send("\x1br");
    try std.testing.expect(try Wait.untilGone(&sess, &grid, "$"));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "terminal: :q! quits cleanly while the terminal is still open" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}termq.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha\nbeta\n");
    }

    var sess = try Session.spawn(io, &.{ oz_exe_path, name });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const Wait = struct {
        fn until(s: *Session, g: *Grid, needle: []const u8) !bool {
            var waited: i32 = 0;
            while (!g.contains(needle)) {
                const nn = try readAvailable(s.pty.master, s.out[s.used..], 200);
                if (nn == 0) {
                    waited += 200;
                    if (waited >= 8000) return false;
                    continue;
                }
                s.used += nn;
                g.feed(s.out[s.used - nn .. s.used]);
            }
            return true;
        }
    };

    try std.testing.expect(try Wait.until(&sess, &grid, "NORMAL"));

    // open the floating terminal, then quit WITHOUT closing it: teardown
    // must join the reader thread and reap the child without deadlocking
    // (the vaxis SIGCHLD handler vs global_vts map race)
    try sess.send("\x1br");
    try std.testing.expect(try Wait.until(&sess, &grid, "$"));
    try sess.send("\x1b"); // Esc back to Normal
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "terminal: shell-integration OSC sequences never print vaxis logs" {
    // Alt+r with shell integration used to flood the whole TUI with
    // `warning(vaxis_terminal): couldn't write uri[_id]` (per printed cell,
    // from vaxis's uninitialized cursor link state) plus
    // `info(terminal): unhandled osc: 133;B` / `error(terminal): osc: 7;…`
    // lines. None of those may reach the screen; the shell must still work.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}termlog.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha\nbeta\n");
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
            if (waited >= 8000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("NORMAL"));

    try sess.send("\x1br"); // floating terminal, focused
    try gridWaitFor(&sess, &grid, "$", 8000);

    // Drive the shell to emit the exact families vaxis logs: OSC 133
    // (shell integration), OSC 7 (cwd) and OSC 8 (hyperlink).
    try sess.send("printf '\\033]133;A\\007'; printf '\\033]133;B\\007'; " ++
        "printf '\\033]7;file://hostname/tmp\\007'; " ++
        "printf '\\033]8;;https://example.com\\007x\\033]8;;\\007'; echo OSC-DONE\r");
    try gridWaitFor(&sess, &grid, "OSC-DONE", 8000);

    if (grid.contains("warning(") or grid.contains("info(") or grid.contains("error(") or
        grid.contains("unhandled osc") or grid.contains("couldn't write uri"))
    {
        std.debug.print("vaxis terminal logs leaked into the TUI:\n", .{});
        grid.dump();
    }
    try std.testing.expect(!grid.contains("warning("));
    try std.testing.expect(!grid.contains("info("));
    try std.testing.expect(!grid.contains("error("));
    try std.testing.expect(!grid.contains("unhandled osc"));
    try std.testing.expect(!grid.contains("couldn't write uri"));

    // Still interactive: Esc returns to the editor; :q! quits with the
    // terminal session still alive (teardown path already covered above).
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

// ================= workspace e2e (M5) =================
//
// Shared feed-loop helpers for the workspace tests below (same shape as the
// smoke test's inline loop, factored out because these tests wait a lot).
// SPC TAB is the leader chord: bytes " \t" followed by n/./r/d/x/[ /].
//
// NOTE on the status bar: it only renders while the current buffer is a
// real file view. A fresh workspace's empty buffer hits the dashboard
// (workspace-plan §8.6), and the dashboard draws no status bar — so the
// tests below always give the workspace under test a file to display
// before asserting on its "[name]" indicator.

/// Feed the pty until `needle` appears anywhere in the grid; false on
/// timeout (ms).
fn wsWait(sess: *Session, grid: *Grid, needle: []const u8, timeout_ms: i32) !bool {
    var waited: i32 = 0;
    while (!grid.contains(needle)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= timeout_ms) return false;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    return true;
}

/// Feed until BOTH needles are present (one frame can carry both).
fn wsWaitBoth(sess: *Session, grid: *Grid, a: []const u8, b: []const u8) !bool {
    var waited: i32 = 0;
    while (!grid.contains(a) or !grid.contains(b)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) return false;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    return true;
}

/// Feed until `needle` disappears from the grid (drains the rest of the
/// frame that overwrote it — a negative assert must not race a
/// partially-read frame).
fn wsWaitGone(sess: *Session, grid: *Grid, needle: []const u8) !bool {
    var waited: i32 = 0;
    while (grid.contains(needle)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) return false;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    return true;
}

/// Feed until ROW `r` no longer contains `needle`. Tab-bar isolation
/// checks are row-scoped because the dashboard's recent-file list may
/// legitimately render a full path with the same basename on other rows
/// (CLI-opened files are added to the recent list at startup).
fn wsRowWaitGone(sess: *Session, grid: *Grid, r: usize, needle: []const u8) !bool {
    var waited: i32 = 0;
    while (rowContains(grid, r, needle)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) return false;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    return true;
}

/// :q! and expect exit 0; dump the grid + stream tail on failure.
fn wsQuit(sess: *Session, grid: *Grid) !void {
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) {
        std.debug.print("oz exited with code {d}\n", .{exit_code});
        grid.dump();
        const idx = std.mem.lastIndexOf(u8, sess.out[0..sess.used], "panic");
        const start = if (idx) |i| i -| 300 else sess.used -| 2000;
        std.debug.print("stream tail:\n{s}\n", .{sess.out[start..sess.used]});
    }
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

/// Create a unique temp file (smoke-test pattern); returns the path into
/// `name_buf`. The CALLER must delete it after the child has opened it
/// (the smoke test defers the delete at test scope, not here — deleting
/// here would remove the file before oz ever opens it).
fn wsTempFile(io: Io, name_buf: *[128:0]u8, suffix: []const u8, content: []const u8) ![:0]const u8 {
    const name = try bufPrintZ(name_buf, "/tmp/oz_e2e_{d}_{d}{s}", .{ linux.getpid(), tmp_counter, suffix });
    tmp_counter += 1;
    const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, content);
    return name;
}

test "workspace: SPC TAB n creates ws2, status bar follows, [ ] wrap between" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wna.txt", "AAA1 first\nAAA1 second\nAAA1 third\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    var nb_buf: [128:0]u8 = undefined;
    const nb = try wsTempFile(io, &nb_buf, "wnb.txt", "BBB1 first\n");
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // main renders the first file: status bar carries [main]
    const started = try wsWaitBoth(&sess, &grid, "[main]", "AAA1");
    if (!started) grid.dump();
    try std.testing.expect(started);
    try std.testing.expect(rowContains(&grid, 0, "wna.txt"));

    // SPC TAB n — new workspace ws2 (its empty buffer is a dashboard, so
    // open a second file there to make the workspace name observable)
    try sess.send(" \tn");
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    const on_ws2 = try wsWaitBoth(&sess, &grid, "[ws2]", "BBB1");
    if (!on_ws2) grid.dump();
    try std.testing.expect(on_ws2);
    // the ws2 frame fully overwrote the [main] status row
    const main_gone = try wsWaitGone(&sess, &grid, "[main]");
    if (!main_gone) grid.dump();
    try std.testing.expect(main_gone);

    // SPC TAB ] — next workspace wraps back to main
    try sess.send(" \t]");
    const back_main = try wsWaitBoth(&sess, &grid, "[main]", "AAA1");
    if (!back_main) grid.dump();
    try std.testing.expect(back_main);
    const ws2_gone = try wsWaitGone(&sess, &grid, "[ws2]");
    if (!ws2_gone) grid.dump();
    try std.testing.expect(ws2_gone);

    // SPC TAB ] again — next wraps forward to ws2
    try sess.send(" \t]");
    const fwd_ws2 = try wsWaitBoth(&sess, &grid, "[ws2]", "BBB1");
    if (!fwd_ws2) grid.dump();
    try std.testing.expect(fwd_ws2);

    // SPC TAB [ — previous wraps back to main
    try sess.send(" \t[");
    const prev_main = try wsWaitBoth(&sess, &grid, "[main]", "AAA1");
    if (!prev_main) grid.dump();
    try std.testing.expect(prev_main);

    try wsQuit(&sess, &grid);
}

test "workspace: ws2's tab bar and content are isolated from main's file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wsa.txt", "IZW alpha\nIZW beta\nIZW gamma\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // main renders the file: tab row 0 carries the basename, content below
    const started = try wsWaitBoth(&sess, &grid, "[main]", "IZW");
    if (!started) grid.dump();
    try std.testing.expect(started);
    try std.testing.expect(rowContains(&grid, 0, "wsa.txt"));

    // SPC TAB n — ws2 keeps its OWN buffer set: main's tab is gone from
    // row 0 and the file's text is gone from the content area
    try sess.send(" \tn");
    // ws2's empty buffer is a dashboard (workspace-plan §8.6)
    const dash = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!dash) grid.dump();
    try std.testing.expect(dash);
    const tab_gone = try wsRowWaitGone(&sess, &grid, 0, "wsa.txt");
    if (!tab_gone) grid.dump();
    try std.testing.expect(tab_gone);
    try std.testing.expect(!rowContains(&grid, 0, "wsa.txt"));
    const content_gone = try wsWaitGone(&sess, &grid, "IZW");
    if (!content_gone) grid.dump();
    try std.testing.expect(content_gone);

    // SPC TAB [ — back to main: tab and content return
    try sess.send(" \t[");
    const back_main = try wsWaitBoth(&sess, &grid, "[main]", "wsa.txt");
    if (!back_main) grid.dump();
    try std.testing.expect(back_main);
    try std.testing.expect(rowContains(&grid, 0, "wsa.txt"));
    const content_back = try wsWait(&sess, &grid, "IZW", 5000);
    if (!content_back) grid.dump();
    try std.testing.expect(content_back);

    try wsQuit(&sess, &grid);
}

test "workspace: SPC TAB r renames via cmdline prefilled with the current name" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wsr.txt", "RNM content line\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    try std.testing.expect(try wsWait(&sess, &grid, "[main]", 5000));

    // SPC TAB r — command mode with the cmdline PREFILLED "main" (the
    // status row is replaced by the ":"-prefixed cmdline in command mode)
    try sess.send(" \tr");
    const prefilled = try wsWait(&sess, &grid, ":main", 5000);
    if (!prefilled) grid.dump();
    try std.testing.expect(prefilled);

    // typed chars append to the prefilled name → ":mainX"
    try sess.send("X");
    const typed = try wsWait(&sess, &grid, ":mainX", 5000);
    if (!typed) grid.dump();
    try std.testing.expect(typed);

    // Enter applies the rename and returns to normal mode
    try sess.send("\r");
    const renamed = try wsWait(&sess, &grid, "[mainX]", 5000);
    if (!renamed) grid.dump();
    try std.testing.expect(renamed);
    try std.testing.expect(!grid.contains("[main]"));

    try wsQuit(&sess, &grid);
}

test "workspace: SPC TAB d deletes the workspace; the last one is refused" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wda.txt", "AAA4 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    var nb_buf: [128:0]u8 = undefined;
    const nb = try wsTempFile(io, &nb_buf, "wdb.txt", "BBB4 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const started = try wsWaitBoth(&sess, &grid, "[main]", "AAA4");
    if (!started) grid.dump();
    try std.testing.expect(started);

    // second workspace with its own file, then delete THAT workspace
    try sess.send(" \tn");
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    const on_ws2 = try wsWaitBoth(&sess, &grid, "[ws2]", "BBB4");
    if (!on_ws2) grid.dump();
    try std.testing.expect(on_ws2);

    try sess.send(" \td");
    const back_main = try wsWaitBoth(&sess, &grid, "[main]", "AAA4");
    if (!back_main) grid.dump();
    try std.testing.expect(back_main);
    // the deleted workspace's buffer died with it
    const ws2_gone = try wsWaitGone(&sess, &grid, "[ws2]");
    if (!ws2_gone) grid.dump();
    try std.testing.expect(ws2_gone);
    const nb_gone = try wsWaitGone(&sess, &grid, "BBB4");
    if (!nb_gone) grid.dump();
    try std.testing.expect(nb_gone);

    // deleting the LAST workspace is refused with a message, not a crash
    try sess.send(" \td");
    const refused = try wsWait(&sess, &grid, "cannot delete the last workspace", 5000);
    if (!refused) grid.dump();
    try std.testing.expect(refused);
    try std.testing.expect(grid.contains("[main]"));

    try wsQuit(&sess, &grid);
}

test "workspace: SPC TAB x clears the session back to a fresh single main" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wka.txt", "AAA5 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    var nb_buf: [128:0]u8 = undefined;
    const nb = try wsTempFile(io, &nb_buf, "wkb.txt", "BBB5 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const started = try wsWaitBoth(&sess, &grid, "[main]", "AAA5");
    if (!started) grid.dump();
    try std.testing.expect(started);

    // two workspaces with files, then kill the whole session
    try sess.send(" \tn");
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    const on_ws2 = try wsWaitBoth(&sess, &grid, "[ws2]", "BBB5");
    if (!on_ws2) grid.dump();
    try std.testing.expect(on_ws2);

    // SPC TAB x — clean session → ONE fresh empty main workspace (its
    // dashboard). Every workspace's buffers are gone.
    try sess.send(" \tx");
    const cleared = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!cleared) grid.dump();
    try std.testing.expect(cleared);
    const ws2_gone = try wsWaitGone(&sess, &grid, "[ws2]");
    if (!ws2_gone) grid.dump();
    try std.testing.expect(ws2_gone);
    const na_gone = try wsWaitGone(&sess, &grid, "AAA5");
    if (!na_gone) grid.dump();
    try std.testing.expect(na_gone);
    const nb_gone = try wsWaitGone(&sess, &grid, "BBB5");
    if (!nb_gone) grid.dump();
    try std.testing.expect(nb_gone);
    // only the fresh unnamed buffer remains in the tab bar
    const tab_gone = try wsRowWaitGone(&sess, &grid, 0, "wkb.txt");
    if (!tab_gone) grid.dump();
    try std.testing.expect(tab_gone);

    // the reset session is functional: reopen a file on the fresh main
    try sess.send(":e ");
    try sess.send(na);
    try sess.send("\r");
    const reopened = try wsWaitBoth(&sess, &grid, "[main]", "AAA5");
    if (!reopened) grid.dump();
    try std.testing.expect(reopened);

    try wsQuit(&sess, &grid);
}

test "workspace: SPC TAB x refuses with E37 while a buffer is dirty" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "wdi.txt", "AAA6 first\nAAA6 second\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const started = try wsWaitBoth(&sess, &grid, "[main]", "AAA6");
    if (!started) grid.dump();
    try std.testing.expect(started);

    // i X Esc — insert a char so the buffer is dirty (nothing saved)
    try sess.send("iX\x1b");
    const insert_done = try wsWaitGone(&sess, &grid, "INSERT");
    if (!insert_done) grid.dump();
    try std.testing.expect(insert_done);
    const edited = try wsWait(&sess, &grid, "XAAA6", 5000);
    if (!edited) grid.dump();
    try std.testing.expect(edited);

    // killing the session with an unsaved buffer is refused: E37 message,
    // no crash, still on main with the file still open
    try sess.send(" \tx");
    const refused = try wsWaitBoth(&sess, &grid, "E37", "unsaved");
    if (!refused) grid.dump();
    try std.testing.expect(refused);
    try std.testing.expect(grid.contains("[main]"));
    try std.testing.expect(grid.contains("AAA6"));

    try wsQuit(&sess, &grid);
}

test "workspace: :e refuses a file already open in another workspace" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "woa.txt", "AAA7 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    var nb_buf: [128:0]u8 = undefined;
    const nb = try wsTempFile(io, &nb_buf, "wob.txt", "BBB7 line\n");
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};

    var sess = try Session.spawn(io, &.{ oz_exe_path, na });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // main has the file open
    const started = try wsWaitBoth(&sess, &grid, "[main]", "AAA7");
    if (!started) grid.dump();
    try std.testing.expect(started);

    // ws2 opens its own file first (so its status bar renders)
    try sess.send(" \tn");
    try sess.send(":e ");
    try sess.send(nb);
    try sess.send("\r");
    const on_ws2 = try wsWaitBoth(&sess, &grid, "[ws2]", "BBB7");
    if (!on_ws2) grid.dump();
    try std.testing.expect(on_ws2);

    // ws2 tries to :e the SAME file (absolute path) → refused, naming the
    // owning workspace; ws2 keeps its own file and no second copy is loaded
    try sess.send(":e ");
    try sess.send(na);
    try sess.send("\r");
    const refused = try wsWait(&sess, &grid, "已在 workspace 'main' 中打开", 5000);
    if (!refused) grid.dump();
    try std.testing.expect(refused);
    try std.testing.expect(grid.contains("[ws2]"));
    try std.testing.expect(grid.contains("BBB7"));
    const not_loaded = try wsWaitGone(&sess, &grid, "AAA7");
    if (!not_loaded) grid.dump();
    try std.testing.expect(not_loaded);
    try std.testing.expect(!rowContains(&grid, 0, "woa.txt"));

    try wsQuit(&sess, &grid);
}

// ================= workspace filetree + dashboard (M5 follow-ups) =================

test "workspace: filetree expansion state is per-workspace" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Controlled project tree so the assertion doesn't depend on oz's own
    // directory contents: proj/{aa,bb}/leaf.txt — expanding `aa` reveals
    // exactly one new row ("leaf.txt") under it.
    var root_buf: [128:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_ft_{d}", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var p_buf: [160:0]u8 = undefined;
    const p_aa = try bufPrintZ(&p_buf, "{s}/aa", .{root});
    try std.Io.Dir.cwd().createDirPath(io, p_aa);
    var p2_buf: [160:0]u8 = undefined;
    const p_bb = try bufPrintZ(&p2_buf, "{s}/bb", .{root});
    try std.Io.Dir.cwd().createDirPath(io, p_bb);
    var pf_buf: [176:0]u8 = undefined;
    const p_leaf = try bufPrintZ(&pf_buf, "{s}/aa/leaf.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, p_leaf, .{});
        f.close(io);
    }
    var sess = try Session.spawnCwd(io, &.{oz_exe_path}, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // dashboard in main; open the tree and expand `aa` (first row)
    const dash = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!dash) grid.dump();
    try std.testing.expect(dash);
    try sess.send(" e"); // SPC e — open the tree
    const tree = try wsWait(&sess, &grid, "aa", 5000);
    if (!tree) grid.dump();
    try std.testing.expect(tree);
    try sess.send("l"); // expand the selected first dir (aa)
    const expanded = try wsWait(&sess, &grid, "leaf.txt", 5000);
    if (!expanded) grid.dump();
    try std.testing.expect(expanded);

    // new workspace ws2: its tree must NOT inherit main's expansion
    try sess.send(" \tn");
    const ws2 = try wsWait(&sess, &grid, "终端文本编辑器", 5000); // ws2 dashboard
    if (!ws2) grid.dump();
    try std.testing.expect(ws2);
    try sess.send(" e");
    // ws2's tree is fresh: aa is collapsed, so leaf.txt must not appear
    const leaked = try wsWaitGone(&sess, &grid, "leaf.txt");
    if (!leaked) grid.dump();
    try std.testing.expect(leaked);
    // but aa itself is listed (collapsed)
    try std.testing.expect(grid.contains("aa"));

    // back to main: main's own expansion is still there
    try sess.send(" \t[");
    const back = try wsWait(&sess, &grid, "leaf.txt", 5000);
    if (!back) grid.dump();
    try std.testing.expect(back);

    try wsQuit(&sess, &grid);
}

test "workspace: <leader>e roots the file tree at the opened file's directory" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // A controlled project dir OUTSIDE the test cwd (the oz repo root). If
    // the tree were still cwd-rooted it would show build.zig/src/…; rooted
    // at the opened file's directory it shows only this project's file.
    var ra_buf: [128:0]u8 = undefined;
    const ra = try bufPrintZ(&ra_buf, "/tmp/oz_pf_{d}", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, ra) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ra);
    try writeTestFile(io, ra, "pfr_marker.txt", "PFR-MARKER\n");

    var sess = try Session.spawn(io, &.{oz_exe_path});
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const dash = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!dash) grid.dump();
    try std.testing.expect(dash);

    // Open a file in the project dir: the workspace's root becomes that dir.
    var pa_buf: [176:0]u8 = undefined;
    const pa = try bufPrintZ(&pa_buf, "{s}/pfr_marker.txt", .{ra});
    try sess.send(":e ");
    try sess.send(pa);
    try sess.send("\r");
    const opened = try wsWait(&sess, &grid, "PFR-MARKER", 5000);
    if (!opened) grid.dump();
    try std.testing.expect(opened);

    // <leader>e shows the project's tree (pfr_marker.txt), NOT the cwd tree
    // (build.zig lives only in the process cwd).
    try sess.send(" e");
    const tree = try wsWait(&sess, &grid, "pfr_marker.txt", 5000);
    if (!tree) grid.dump();
    try std.testing.expect(tree);
    try std.testing.expect(!grid.contains("build.zig"));

    try wsQuit(&sess, &grid);
}

test "workspace: <leader>sf fuzzy-searches the opened file's project" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Same setup: a project dir outside cwd with a distinctive file name.
    var ra_buf: [128:0]u8 = undefined;
    const ra = try bufPrintZ(&ra_buf, "/tmp/oz_pp_{d}", .{linux.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, ra) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ra);
    try writeTestFile(io, ra, "ppr_unique.txt", "PPR-UNIQUE\n");

    var sess = try Session.spawn(io, &.{oz_exe_path});
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const dash = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!dash) grid.dump();
    try std.testing.expect(dash);

    var pa_buf: [176:0]u8 = undefined;
    const pa = try bufPrintZ(&pa_buf, "{s}/ppr_unique.txt", .{ra});
    try sess.send(":e ");
    try sess.send(pa);
    try sess.send("\r");
    const opened = try wsWait(&sess, &grid, "PPR-UNIQUE", 5000);
    if (!opened) grid.dump();
    try std.testing.expect(opened);

    // <leader>sf re-walks at the project root: the project's file shows up
    // (it is not under cwd, so a cwd-rooted picker would never list it).
    try sess.send(" sfppr_unique");
    const picker = try wsWait(&sess, &grid, "ppr_unique.txt", 5000);
    if (!picker) grid.dump();
    try std.testing.expect(picker);

    // Enter confirms (the file is already open → switch), closing the picker
    // so the trailing :q! reaches the buffer, not the picker's filter.
    try sess.send("\r");
    const closed = try wsWaitGone(&sess, &grid, " Files ");
    if (!closed) grid.dump();
    try std.testing.expect(closed);
    try wsQuit(&sess, &grid);
}

test "dashboard: opening the first file replaces the [No Name] scratch buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try wsTempFile(io, &na_buf, "noname.txt", "SCRATCH-REPLACED\n");
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};

    // Launch with NO file arg → dashboard (one unnamed scratch buffer)
    var sess = try Session.spawn(io, &.{oz_exe_path});
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    const dash = try wsWait(&sess, &grid, "终端文本编辑器", 5000);
    if (!dash) grid.dump();
    try std.testing.expect(dash);

    // open a file — vim semantics: it replaces the scratch buffer, so no
    // orphan [No Name] tab/buffer survives
    try sess.send(":e ");
    try sess.send(na);
    try sess.send("\r");
    const opened = try wsWait(&sess, &grid, "SCRATCH-REPLACED", 5000);
    if (!opened) grid.dump();
    try std.testing.expect(opened);
    // the tab bar (row 0) shows the file, and NO [No Name] anywhere
    try std.testing.expect(rowContains(&grid, 0, ".txt"));
    const gone = try wsWaitGone(&sess, &grid, "[No Name]");
    if (!gone) grid.dump();
    try std.testing.expect(gone);

    try wsQuit(&sess, &grid);
}

test "dashboard: snacks-style layout and menu keys" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var sess = try Session.spawn(io, &.{oz_exe_path});
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);

    // logo + subtitle + all four menu entries
    const dash = try wsWaitBoth(&sess, &grid, "终端文本编辑器", "████");
    if (!dash) grid.dump();
    try std.testing.expect(dash);
    const menu = try wsWaitBoth(&sess, &grid, "Find File", "New File");
    if (!menu) grid.dump();
    try std.testing.expect(menu);
    try std.testing.expect(grid.contains("Recent Files"));
    try std.testing.expect(grid.contains("Quit"));

    // 'f' opens the fuzzy file picker from the dashboard
    try sess.send("f");
    const picker = try wsWait(&sess, &grid, "Files", 5000);
    if (!picker) grid.dump();
    try std.testing.expect(picker);
    try sess.send("\x1b"); // back to the dashboard
    const back = try wsWait(&sess, &grid, "Find File", 5000);
    if (!back) grid.dump();
    try std.testing.expect(back);

    // 'q' quits straight from the dashboard
    try sess.send("q");
    const code = try sess.commandAndWaitExit("");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "popup geometry: hover/completion borders align; markdown rendered" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}popup.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const a = 1;\nconst b = 2;\nmo");
    }

    var sess = try Session.spawnEnv(io, &.{ oz_exe_path, name }, &.{
        "OZ_LSP_CMD=zig-out/bin/mock_lsp",
        "OZ_MOCK_SCRIPT=rich",
    });
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.init(alloc);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // --- hover: heading + arrow + fenced code + CJK, six rows ---
    try sess.send("K");
    try gridWaitFor(&sess, &grid, "mock hover", 8000);
    try gridWaitFor(&sess, &grid, "第三行", 8000);

    {
        var top: ?usize = null;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (glyphCol(&grid, r, "╭", 0) != null and glyphCol(&grid, r, "╮", 0) != null) {
                top = r;
                break;
            }
        }
        const t = top orelse {
            std.debug.print("hover box missing:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        _ = try assertPopupBox(&grid, t);
        // Solid bg_float panel: every cell between the borders, including
        // the padding after short/wide rows.
        const hline_fg: u32 = packRgb(0x22, 0x32, 0x49);
        const left = glyphCol(&grid, t, "╭", 0).?;
        const right = glyphCol(&grid, t, "╮", 0).?;
        r = t + 1;
        while (r <= t + 6) : (r += 1) {
            var c = left;
            while (c <= right) : (c += 1) {
                if (grid.bg_buf[r * grid.cols + c] != hline_fg) {
                    std.debug.print("hover row {d} cell {d} bg={x} (want {x})\n", .{ r, c, grid.bg_buf[r * grid.cols + c], hline_fg });
                    grid.dump();
                    return error.TestUnexpectedResult;
                }
            }
        }
    }

    // Markdown is RENDERED: heading/fence/backtick markers concealed, and
    // the fenced zig body keeps its tree-sitter colors.
    try std.testing.expect(!grid.contains("## mock hover"));
    try std.testing.expect(!grid.contains("```"));
    try std.testing.expect(!grid.contains("`second line`"));
    {
        var code_row: ?usize = null;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (std.mem.indexOf(u8, grid.rowText(r), "const b = 2;") != null) {
                code_row = r;
                break;
            }
        }
        const cr = code_row orelse {
            std.debug.print("hover fenced code row missing:\n", .{});
            grid.dump();
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(rowContainsFg(&grid, cr, "const", packRgb(0x95, 0x7F, 0xB8)));
        try std.testing.expect(rowContainsFg(&grid, cr, "2", packRgb(0xD2, 0x7E, 0x99)));
    }

    // --- completion menu + markdown documentation pane ---
    try sess.send("jjA\x0e");
    try gridWaitFor(&sess, &grid, "mockItem", 8000);
    try gridWaitFor(&sess, &grid, "日本語", 8000);
    try gridWaitFor(&sess, &grid, "mock docs", 8000);
    try gridWaitFor(&sess, &grid, "const q = 7;", 8000);

    {
        var boxes: usize = 0;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (glyphCol(&grid, r, "╭", 0) != null and glyphCol(&grid, r, "╮", 0) != null) {
                const bottom = try assertPopupBox(&grid, r);
                boxes += 1;
                r = bottom;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), boxes);
    }
    {
        var code_row: ?usize = null;
        var r: usize = 0;
        while (r < grid.rows) : (r += 1) {
            if (std.mem.indexOf(u8, grid.rowText(r), "const q = 7;") != null) {
                code_row = r;
                break;
            }
        }
        const cr = code_row orelse return error.TestUnexpectedResult;
        try std.testing.expect(rowContainsFg(&grid, cr, "const", packRgb(0x95, 0x7F, 0xB8)));
    }
    try std.testing.expect(!grid.contains("**mock docs**"));
    try std.testing.expect(!grid.contains("```"));

    // Esc leaves insert mode AND closes the completion menu/docs in one
    // press; the second Esc is a normal-mode no-op. Send them as separate
    // key events (a single write can be read as an alt sequence).
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "mock docs", 3000);
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 5000);
    const exit_code = try sess.commandAndWaitExit(":qa\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}
// ---------------------------------------------------------------------------
// M2a AI workspace (Agent Rail + Workbox)
// ---------------------------------------------------------------------------

/// Unique temp notes path for navigator/notes tests (OZ_NOTES_DIR seam).
fn notesTestPath(buf: []u8) ![:0]u8 {
    const dir = try bufPrintZ(buf, "/tmp/oz_notes_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    return dir;
}

/// Temp notes dir, created eagerly for tests that pre-populate it.
fn notesTestDir(io: Io, buf: []u8) ![:0]u8 {
    const dir = try notesTestPath(buf);
    try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
    return dir;
}

fn pathExists(io: Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn absFileText(io: Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024));
}

/// Navigator geometry, derived from the same pure model the renderer uses.
/// A single-window frame starts the navigator at contentTop()=2; full/peek
/// mode spends four rows on the brand border, workspace line, tabs and rule,
/// so tabs sit on row 4 and content starts on row 6.
fn navTabsRow() usize {
    return 2 + nav_model.full_header_rows - 2;
}

fn navBodyRow() usize {
    return 2 + nav_model.full_header_rows;
}

/// Compact rail: OZ at contentTop, a rule, then two rows per icon button.
fn navCompactTabRow(i: usize) usize {
    return 2 + nav_model.compact_first_tab_row + i * nav_model.compact_tab_rows;
}

/// Column of the first cell (the icon) of the named full/peek tab. The label
/// follows icon+space, so start = label column - 2. Only used outside hint
/// mode, where the icon may be covered by a hint label.
fn navTabStart(grid: *Grid, label: []const u8) ?usize {
    const row = navTabsRow();
    var c: usize = 1;
    while (c + label.len <= nav_model.panel_width - 1) : (c += 1) {
        var ok = true;
        for (label, 0..) |ch, i| {
            const cell = aiCellText(grid, row, c + i);
            if (cell.len != 1 or cell[0] != ch) {
                ok = false;
                break;
            }
        }
        if (ok) return c - 2;
    }
    return null;
}

/// True when the compact icon rail's right border is drawn. Used by the
/// <90-col tests to tell "rail visible" from "navigator fully closed".
fn navCompactRailVisible(grid: *Grid) bool {
    return std.mem.eql(u8, aiCellText(grid, 3, nav_model.compact_width - 1), "│");
}

/// Count badge drawn immediately after a full-mode tab label, if present.
/// Notes has no badge until its cached list has been loaded.
fn navTabCount(grid: *Grid, label: []const u8) ?usize {
    const row = navTabsRow();
    var label_col: ?usize = null;
    var c: usize = 1;
    while (c + label.len <= nav_model.panel_width - 1) : (c += 1) {
        var ok = true;
        for (label, 0..) |ch, i| {
            const cell = aiCellText(grid, row, c + i);
            if (cell.len != 1 or cell[0] != ch) {
                ok = false;
                break;
            }
        }
        if (ok) {
            label_col = c;
            break;
        }
    }
    var p = (label_col orelse return null) + label.len;
    var n: usize = 0;
    var any = false;
    while (p < nav_model.panel_width - 1) : (p += 1) {
        const cell = aiCellText(grid, row, p);
        if (cell.len != 1 or !std.ascii.isDigit(cell[0])) break;
        any = true;
        n = n * 10 + (cell[0] - '0');
    }
    return if (any) n else null;
}

fn navSelectedBg() u32 {
    return packRgb(0x2D, 0x4F, 0x67); // kanagawa-wave bg_sel
}

fn navEditorBg() u32 {
    return packRgb(0x1F, 0x1F, 0x28); // kanagawa-wave bg
}

fn aiMockDir(io: Io, buf: []u8) ![:0]u8 {
    const dir = try bufPrintZ(buf, "/tmp/oz_ai_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
    return dir;
}

fn aiWriteFile(io: Io, dir: []const u8, name: []const u8, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    var f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

fn aiReadFile(io: Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    // Requests may carry a bounded 64 KiB tool result plus JSON framing.
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .limited(128 * 1024));
}

/// The rail's reserved width at a terminal width (mirrors ai/workspace.zig;
/// the unit tests pin the implementation, these helpers only derive screen
/// coordinates).
fn aiRailWidth(cols: usize) usize {
    if (cols >= 110) return 38;
    if (cols >= 90) return 34;
    return @min(@as(usize, 34), cols -| 8);
}

fn aiRailCol(cols: usize) usize {
    return cols - aiRailWidth(cols);
}

/// Text of one screen cell ("" for an unpainted cell).
fn aiCellText(grid: *Grid, row: usize, col: usize) []const u8 {
    if (row >= grid.rows or col >= grid.cols) return "";
    const slot = grid.buf[(row * grid.cols + col) * 4 ..][0..4];
    var n: usize = 0;
    while (n < 4 and slot[n] != 0) : (n += 1) {}
    return slot[0..n];
}

fn aiCellBg(grid: *Grid, row: usize, col: usize) u32 {
    return grid.bg_buf[row * grid.cols + col];
}

/// First cell on `row` whose content starts with `needle` (ASCII needles:
/// the tests use file text and rail labels).
fn aiCellIndexOf(grid: *Grid, row: usize, needle: []const u8) ?usize {
    const row_text = grid.rowText(row);
    const at = std.mem.indexOf(u8, row_text, needle) orelse return null;
    var byte: usize = 0;
    var c: usize = 0;
    while (c < grid.cols and byte < row_text.len) : (c += 1) {
        if (byte == at) return c;
        byte += aiCellText(grid, row, c).len;
    }
    return null;
}

fn aiFindCell(grid: *Grid, needle: []const u8) ?struct { row: usize, col: usize } {
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        if (aiCellIndexOf(grid, r, needle)) |c| return .{ .row = r, .col = c };
    }
    return null;
}

/// First cell whose content starts with `needle` at/after `min_col`. Used to
/// distinguish the editor region (right of the 30-cell navigator) from the
/// same text shown in the note list.
fn aiFindCellFrom(grid: *Grid, needle: []const u8, min_col: usize) ?struct { row: usize, col: usize } {
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        if (aiCellIndexOf(grid, r, needle)) |c| {
            if (c >= min_col) return .{ .row = r, .col = c };
        }
    }
    return null;
}

fn aiRailBg() u32 {
    return packRgb(0x22, 0x32, 0x49); // kanagawa-wave bg_float
}

fn aiEditorBg() u32 {
    return packRgb(0x1F, 0x1F, 0x28); // kanagawa-wave bg
}

fn aiStatusBg() u32 {
    return packRgb(0x2A, 0x2A, 0x37); // kanagawa-wave bg_status
}

/// Workbox header row for a given terminal height: the row that names the
/// active thread (the thread rail above it also lists names, so tests that
/// assert attachment must look at THIS row).
fn aiWorkboxHeaderRow(rows: usize) usize {
    // Mirrors app/ai/workspace.zig metrics: two bottom chrome rows, and one
    // thread-list row is reclaimed for the tab-strip closing rule.
    const rail_rows = rows - 2;
    var thread_rows = (rail_rows -| 5) / 3;
    thread_rows = @min(@max(thread_rows, 3), 8) - 1;
    thread_rows = @max(thread_rows, 3);
    return 2 + thread_rows + 1;
}

/// Workbox tab strip: content starts after the left border + one padding
/// cell. The active tab is prefixed with an ASCII `>` marker.
fn aiTabsContentCol(rail_col: usize) usize {
    return rail_col + 2;
}

/// 38-cell rails spend two cells after `chat` (the `│ ` separator); 34-cell
/// rails stay compact (`│`).
fn aiTabsSpaced(cols: usize) bool {
    return aiRailWidth(cols) >= 38;
}

/// Column of the `changes N` label while chat is the active tab:
/// `>chat│ changes 0 │...` at 38 cells, `>chat│changes 0│...` at 34.
fn aiChangesTabCol(cols: usize) usize {
    const rail_col = aiRailCol(cols);
    const after_chat: usize = if (aiTabsSpaced(cols)) 2 else 1;
    return aiTabsContentCol(rail_col) + 1 + "chat".len + after_chat;
}

fn aiRowStatusBg(grid: *Grid, row: usize) u32 {
    return aiCellBg(grid, row, grid.cols - 1);
}

/// A blank gutter cell may be unwritten ("") or an explicit space.
fn aiCellBlank(grid: *Grid, row: usize, col: usize) bool {
    const text = aiCellText(grid, row, col);
    return text.len == 0 or std.mem.eql(u8, text, " ");
}

/// Count cells holding `ch` in the rail, excluding the bottom chrome (rule
/// + status). Used to prove a transcript's reply text disappears when
/// another thread is active and never appears in the wrong thread.
fn aiCountRailChar(grid: *Grid, ch: u8) usize {
    const rail_col = aiRailCol(grid.cols);
    var n: usize = 0;
    // Start below the `AGENTS` header/workspace group so their static "A"
    // is not counted as transcript text.
    var r: usize = 2;
    while (r + 2 < grid.rows) : (r += 1) {
        var c = rail_col;
        while (c < grid.cols) : (c += 1) {
            const txt = aiCellText(grid, r, c);
            if (txt.len > 0 and txt[0] == ch) n += 1;
        }
    }
    return n;
}

fn aiRowContains(grid: *Grid, row: usize, needle: []const u8) bool {
    return std.mem.indexOf(u8, grid.rowText(row), needle) != null;
}

fn aiEnterRail(sess: *Session, grid: *Grid) !void {
    try sess.send(" a");
    try gridWaitFor(sess, grid, "AGENTS", 4000);
    try gridWaitFor(sess, grid, "thread 1", 3000);
    try gridWaitFor(sess, grid, "changes 0", 3000);
    try gridWaitFor(sess, grid, "❯ ", 2000);
}

fn aiQuit(sess: *Session) !void {
    const exit_code = try sess.commandAndWaitExit(":q!\r");
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

/// Wait until the rail's left border reflects the expected focus (accent =
/// rail/prompt owns the keyboard, dim = editor). Esc followed immediately by
/// another printable byte can be parsed as an Alt sequence, so tests wait
/// for this observable transition before typing editor keys.
fn aiWaitRailFocus(sess: *Session, grid: *Grid, rail_col: usize, focused: bool, timeout_ms: i32) !void {
    // Kanagawa-wave literals: the default-theme tests below. Theme-matrix
    // tests pass their palette through aiWaitRailBorderColor instead.
    const want: u32 = if (focused) packRgb(0xE6, 0xC3, 0x84) else packRgb(0x54, 0x54, 0x6D);
    try aiWaitRailBorderColor(sess, grid, rail_col, want, timeout_ms);
}

fn aiWaitRailBorderColor(sess: *Session, grid: *Grid, rail_col: usize, want: u32, timeout_ms: i32) !void {
    var waited: i32 = 0;
    while (waited < timeout_ms) : (waited += 50) {
        if (grid.fg_buf[5 * grid.cols + rail_col] == want) return;
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    try std.testing.expectEqual(want, grid.fg_buf[5 * grid.cols + rail_col]);
}

test "ai workspace: 120-col docked rail keeps editor+filetree, streams, focus returns to editor" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aiw.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const answer = 42;\nsecond visible line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try aiWriteFile(io, dir, "stream.sse", "data: {\"choices\":[{\"delta\":{\"content\":\"mock \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"reply\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");

    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);

    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // Docked rail: 38 cells reserved on the right (editor width 81 + one
    // blank gutter column before the rail).
    try aiEnterRail(&sess, &grid);
    const rail_col = aiRailCol(120);
    try std.testing.expectEqual(@as(usize, 82), rail_col);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 0, rail_col));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 5, rail_col));
    // Focused rail border is accent; the whole rail is bg_float.
    try std.testing.expectEqual(packRgb(0xE6, 0xC3, 0x84), grid.fg_buf[5 * grid.cols + rail_col]);
    try std.testing.expectEqual(aiRailBg(), aiCellBg(&grid, 5, 100));
    // Editor cells to the left keep the normal background.
    try std.testing.expectEqual(aiEditorBg(), aiCellBg(&grid, 20, 40));
    // The status bar stays full width and owns its row.
    try std.testing.expectEqual(aiStatusBg(), aiRowStatusBg(&grid, 29));

    // Editor + filetree stay visible beside the rail.
    try sess.send("\x1b"); // prompt -> editor (rail stays docked)
    try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try gridWaitFor(&sess, &grid, "const answer = 42", 5000);
    try std.testing.expect(aiFindCell(&grid, "const answer = 42") != null);
    const content_cell = aiFindCell(&grid, "const answer = 42").?;
    try std.testing.expect(content_cell.col < rail_col);
    try std.testing.expect(grid.contains("╭─ OZ"));
    // Re-enter the rail from the file tree (Ctrl+w a) and attach to the
    // prompt with Enter. This is the editor -> rail re-entry path.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, rail_col, true, 3000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "❯ ", 2000);

    // Type in the prompt (it must not reach the editor), send, stream.
    try sess.send("hello");
    try gridWaitFor(&sess, &grid, "hello", 2000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "mock reply", 8000);
    try gridWaitFor(&sess, &grid, "idle", 4000);
    try std.testing.expect(aiRowContains(&grid, 29, "thread 1"));
    try std.testing.expect(aiRowContains(&grid, 29, "mock-model"));
    try std.testing.expect(aiRowContains(&grid, 29, "idle"));
    try std.testing.expect(!grid.contains("helloconst"));

    const req = try aiReadFile(io, alloc, dir, "request.json");
    defer alloc.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"model\":\"mock-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, name) != null);

    // Esc returns the keyboard to the editor; the rail stays visible and
    // its border turns faint.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
    try std.testing.expect(aiCellText(&grid, 5, rail_col).len > 0);
    // The file tree still has App focus after leaving the rail; Ctrl+w l
    // hands the keyboard back to the buffer.
    try sess.send("\x17l");
    try sess.send("i");
    try sess.send("zz");
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "zzconst answer = 42", 4000);

    // <leader>a toggles the rail closed from the editor...
    try sess.send(" a");
    try gridWaitGone(&sess, &grid, "changes 0", 4000);
    // The navigator's "agents" TAB also contains that word, so assert the
    // rail's own thread-bar header is gone instead (and the old decorative
    // glyph is gone everywhere).
    try std.testing.expect(!grid.contains("AGENTS"));
    try std.testing.expect(!grid.contains("▥"));
    // ...and reopening restores the session transcript (not persisted, but
    // it survives rail close).
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "mock reply", 3000);
    // Esc gives the editor back while the rail remains docked.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
    // Ctrl+w a re-enters the rail at the thread list; q returns to editor.
    try sess.send("\x17a");
    try gridWaitFor(&sess, &grid, "thread 1", 3000);
    try sess.send("q");
    try sess.send("u"); // undo the inserted "zz" — only works if editor has focus
    try gridWaitFor(&sess, &grid, "const answer = 42", 4000);
    try std.testing.expect(grid.contains("changes 0"));

    try aiQuit(&sess);
}

test "ai workspace: 80-col drawer overlays the full-width editor without overflow" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aid.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "LINESTART_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789_TAILDRAWER\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try aiWriteFile(io, dir, "stream.sse", "data: [DONE]\n\n");
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    // The long line is rendered at the terminal's full 80-column width
    // before the drawer opens.
    try gridWaitFor(&sess, &grid, "TAILDRAWER", 4000);
    const tail = aiFindCell(&grid, "TAILDRAWER").?;
    try std.testing.expect(tail.col > aiRailCol(80));

    try aiEnterRail(&sess, &grid);
    const rail_col = aiRailCol(80);
    try std.testing.expectEqual(@as(usize, 46), rail_col);
    // 80-col drawer: 34 cells, covering the right side only.
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 0, rail_col));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 5, rail_col));
    try std.testing.expectEqual(aiRailBg(), aiCellBg(&grid, 5, 79));
    try std.testing.expectEqual(aiStatusBg(), aiRowStatusBg(&grid, 23));
    // The rail stops above the status bar: no fake scrim, no overflow.
    // The drawer covers the long line's tail, while the left part of the
    // (unchanged, full-width) editor remains visible underneath.
    try std.testing.expect(aiFindCell(&grid, "TAILDRAWER") == null);
    try std.testing.expect(aiFindCell(&grid, "LINESTART_ABCDEF") != null);

    // Esc closes the narrow drawer and restores the editor.
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "TAILDRAWER", 4000);

    // Keys don't trap: reopen, attach to a new thread, then Esc closes.
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "changes 0", 3000);
    try sess.send("\t");
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 3000);
    try sess.send("beta");
    try gridWaitFor(&sess, &grid, "beta", 2000);
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "changes 0", 4000);
    // The navigator's "agents" TAB also contains that word, so assert the
    // rail's own thread-bar header is gone instead (and the old decorative
    // glyph is gone everywhere).
    try std.testing.expect(!grid.contains("AGENTS"));
    try std.testing.expect(!grid.contains("▥"));
    // Editor focus after the drawer closes.
    try sess.send("i");
    try sess.send("X");
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "XLINESTART", 4000);

    try aiQuit(&sess);
}

test "ui chrome: 120x30 rail header, rules, tabs and status boundary" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}chrome120.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var long = std.ArrayList(u8).empty;
        defer long.deinit(alloc);
        try long.appendSlice(alloc, "CHROME_MARKER ");
        try long.appendNTimes(alloc, 'x', 120);
        try long.appendSlice(alloc, "\nsecond chrome line\n");
        try f.writeStreamingAll(io, long.items);
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // Navigator: OZ brand border + workspace line + icon tabs with real
    // counts, separator cells and a filled active tab.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try std.testing.expect(aiRowContains(&grid, navTabsRow() - 1, "main"));
    const files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    const notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
    const agents_col = navTabStart(&grid, "Agents") orelse return error.TestUnexpectedResult;
    try std.testing.expect(aiRowContains(&grid, navTabsRow(), "Files"));
    try std.testing.expect(aiRowContains(&grid, navTabsRow(), "Notes"));
    try std.testing.expect(aiRowContains(&grid, navTabsRow(), "Agents"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), notes_col - 1));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), agents_col - 1));
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navTabsRow(), files_col));
    try std.testing.expectEqual(navEditorBg(), aiCellBg(&grid, navTabsRow(), notes_col));
    // Active-tab underline and the frame around the first content row.
    try frame.expectCellUl(&grid, navTabsRow(), files_col, packRgb(0x7E, 0x9C, 0xD8));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 0));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 29));

    // Rail: AGENTS header band, readable count, active thread marker.
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "❯ ", 4000);
    const rail_col = aiRailCol(120);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 0, rail_col));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 0, rail_col));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 0, 119));
    try std.testing.expect(aiRowContains(&grid, 0, "AGENTS  1"));
    try std.testing.expect(aiRowContains(&grid, 2, "> thread 1"));
    try std.testing.expect(aiRowContains(&grid, 1, "main / workspace"));
    // Blank gutters: one column between the navigator box and editor text,
    // one between the editor's last text cell and the rail border.
    try std.testing.expect(aiCellBlank(&grid, 1, 30));
    try std.testing.expect(!aiCellBlank(&grid, 1, 31));
    try std.testing.expect(!aiCellBlank(&grid, 1, 80));
    try std.testing.expect(aiCellBlank(&grid, 1, 81));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 1, 82));

    // Divider between the thread list and workbox header; second divider
    // between the tab strip and body.
    const divider_row = aiWorkboxHeaderRow(30) - 1;
    try std.testing.expectEqualStrings("├", aiCellText(&grid, divider_row, rail_col));
    try std.testing.expectEqualStrings("─", aiCellText(&grid, divider_row, rail_col + 2));
    const tabs_row = aiTabsRow(30);
    try std.testing.expect(aiRowContains(&grid, tabs_row, ">chat│ changes 0 │ tools │ terminal"));
    const content_col = aiTabsContentCol(rail_col);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, tabs_row, content_col + 5));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, tabs_row, content_col + 17));
    // Active chat tab: bold `fg` text on bg_sel with an accent_alt
    // underline and accent marker; the inactive badge stays on the rail
    // background.
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, tabs_row, content_col + 1));
    try std.testing.expectEqual(packRgb(0xDC, 0xD7, 0xBA), grid.fg_buf[tabs_row * grid.cols + content_col + 1]);
    try frame.expectCellUl(&grid, tabs_row, content_col + 1, packRgb(0x7E, 0x9C, 0xD8));
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[tabs_row * grid.cols + content_col]);
    try std.testing.expectEqual(aiRailBg(), aiCellBg(&grid, tabs_row, content_col + 7));
    try std.testing.expectEqualStrings("├", aiCellText(&grid, aiTabsSepRow(30), rail_col));
    try std.testing.expectEqualStrings("─", aiCellText(&grid, aiTabsSepRow(30), rail_col + 2));

    // Switching tabs moves the marker and selection to the new label while
    // every tab keeps its cell position.
    try sess.send("\t");
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try std.testing.expect(aiRowContains(&grid, tabs_row, "chat│ >changes 0 │ tools │ terminal"));
    // Tab separators use the dim secondary accent, the `>` marker sits on
    // the selection background, and the new label/underline follow it.
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[tabs_row * grid.cols + content_col + 5]);
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, tabs_row, content_col + 6));
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[tabs_row * grid.cols + content_col + 6]);
    try frame.expectCellUl(&grid, tabs_row, content_col + 6, packRgb(0x7E, 0x9C, 0xD8));
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, tabs_row, content_col + 7));
    try std.testing.expectEqual(packRgb(0xDC, 0xD7, 0xBA), grid.fg_buf[tabs_row * grid.cols + content_col + 7]);
    try frame.expectCellUl(&grid, tabs_row, content_col + 7, packRgb(0x7E, 0x9C, 0xD8));
    try sess.send("c");
    try gridWaitFor(&sess, &grid, ">chat│ changes 0", 4000);

    // Status: rule row + section separators + mode badge + layout section.
    try std.testing.expectEqualStrings("─", aiCellText(&grid, 28, 0));
    try std.testing.expectEqualStrings("─", aiCellText(&grid, 28, 119));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 28, 0));
    try std.testing.expect(aiRowContains(&grid, 29, "│ [NORMAL] │"));
    try std.testing.expect(aiRowContains(&grid, 29, "line 1/"));
    try std.testing.expect(aiRowContains(&grid, 29, "dock"));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 29, 0));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // No tofu-prone glyphs in the new AI/nav chrome.
    try std.testing.expect(!grid.contains("▥"));
    try expectNoForbiddenGlyphs(&grid, .{ .top = 0, .left = 0, .right = 29, .bottom = 28 });
    try expectNoForbiddenGlyphs(&grid, .{ .top = 0, .left = rail_col, .right = 119, .bottom = 27 });

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
    try aiQuit(&sess);
}

test "ui chrome: 80x24 drawer header, tabs and status boundary" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}chrome80.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var long = std.ArrayList(u8).empty;
        defer long.deinit(alloc);
        try long.appendSlice(alloc, "CHROME80_MARKER ");
        try long.appendNTimes(alloc, 'y', 120);
        try long.append(alloc, '\n');
        try f.writeStreamingAll(io, long.items);
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "❯ ", 4000);

    const rail_col = aiRailCol(80);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 0, rail_col));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 0, rail_col));
    try std.testing.expect(aiRowContains(&grid, 0, "AGENTS  1"));
    // Drawer gutter: the editor keeps its full layout width but its last
    // visible cell before the rail is blanked, so text never touches `│`.
    try std.testing.expect(!aiCellBlank(&grid, 1, 44));
    try std.testing.expect(aiCellBlank(&grid, 1, 45));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 1, 46));
    const tabs_row = aiTabsRow(24);
    try std.testing.expect(aiRowContains(&grid, tabs_row, ">chat│changes 0│tools│terminal"));
    try std.testing.expectEqualStrings("├", aiCellText(&grid, aiTabsSepRow(24), rail_col));
    try std.testing.expectEqualStrings("├", aiCellText(&grid, aiWorkboxHeaderRow(24) - 1, rail_col));
    // Bottom chrome: full-width rule + one status row, drawer layout cell.
    try std.testing.expectEqualStrings("─", aiCellText(&grid, 22, 0));
    try std.testing.expectEqual(aiStatusBg(), aiCellBg(&grid, 22, 79));
    try std.testing.expect(aiRowContains(&grid, 23, "│ [NORMAL] │"));
    try std.testing.expect(aiRowContains(&grid, 23, "drawer"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try std.testing.expect(!grid.contains("▥"));
    try expectNoForbiddenGlyphs(&grid, .{ .top = 0, .left = rail_col, .right = 79, .bottom = 21 });

    try sess.send("\x1b"); // narrow drawer closes
    try gridWaitGone(&sess, &grid, "AGENTS", 3000);
    try aiQuit(&sess);
}

/// Palette literals for the theme-style e2e. Mirror the semantic slots in
/// `src/theme.zig` (the e2e binary cannot import the app module); every value
/// is the exact RGB the renderer must emit for that theme.
const ThemeStyleCase = struct {
    name: []const u8,
    bg: u32,
    bg_sel: u32,
    fg: u32,
    fg_dim: u32,
    fg_faint: u32,
    accent: u32,
    accent_alt: u32,
    win_sep: u32,
    win_sep_active: u32,
};

const theme_style_cases = [_]ThemeStyleCase{
    .{
        .name = "kanagawa-wave",
        .bg = packRgb(0x1F, 0x1F, 0x28),
        .bg_sel = packRgb(0x2D, 0x4F, 0x67),
        .fg = packRgb(0xDC, 0xD7, 0xBA),
        .fg_dim = packRgb(0x72, 0x71, 0x69),
        .fg_faint = packRgb(0x54, 0x54, 0x6D),
        .accent = packRgb(0xE6, 0xC3, 0x84),
        .accent_alt = packRgb(0x7E, 0x9C, 0xD8),
        .win_sep = packRgb(0x54, 0x54, 0x6D),
        .win_sep_active = packRgb(0xE6, 0xC3, 0x84),
    },
    .{
        .name = "catppuccin-mocha",
        .bg = packRgb(0x1E, 0x1E, 0x2E),
        .bg_sel = packRgb(0x58, 0x5B, 0x70),
        .fg = packRgb(0xCD, 0xD6, 0xF4),
        .fg_dim = packRgb(0x7F, 0x84, 0x9C),
        .fg_faint = packRgb(0x58, 0x5B, 0x70),
        .accent = packRgb(0xF5, 0xE0, 0xDC),
        .accent_alt = packRgb(0x89, 0xB4, 0xFA),
        .win_sep = packRgb(0x58, 0x5B, 0x70),
        .win_sep_active = packRgb(0xF5, 0xE0, 0xDC),
    },
    .{
        .name = "flexoki-light",
        .bg = packRgb(0xFF, 0xFC, 0xF0),
        .bg_sel = packRgb(0xDA, 0xD8, 0xCE),
        .fg = packRgb(0x10, 0x0F, 0x0F),
        .fg_dim = packRgb(0x6F, 0x6E, 0x69),
        .fg_faint = packRgb(0xB7, 0xB5, 0xAC),
        .accent = packRgb(0xAD, 0x83, 0x01),
        .accent_alt = packRgb(0x20, 0x5E, 0xA6),
        .win_sep = packRgb(0xB7, 0xB5, 0xAC),
        .win_sep_active = packRgb(0xAD, 0x83, 0x01),
    },
};

/// The chrome colors every theme must produce, sampled from one live frame.
const ThemeStyleSample = struct {
    nav_tab_bg: u32 = 0,
    nav_tab_fg: u32 = 0,
    nav_tab_ul: u32 = 0,
    nav_sep_fg: u32 = 0,
    nav_border_fg: u32 = 0,
    rail_border_fg: u32 = 0,
    workbox_tab_bg: u32 = 0,
    workbox_tab_fg: u32 = 0,
    workbox_tab_ul: u32 = 0,
    workbox_sep_fg: u32 = 0,
    workbox_rule_fg: u32 = 0,
    thread_marker_fg: u32 = 0,
    thread_marker_bg: u32 = 0,
    status_rule_fg: u32 = 0,
    buffer_tab_fg: u32 = 0,
    buffer_tab_ul: u32 = 0,
};

test "ui chrome: theme matrix colors active tabs, separators and focused borders" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var samples: [theme_style_cases.len]ThemeStyleSample = @splat(.{});
    var sample_i: usize = 0;

    for (theme_style_cases) |tc| {
        var root_buf: [192]u8 = undefined;
        const root = try bufPrintZ(&root_buf, "/tmp/oz_theme_{d}_{d}", .{ linux.getpid(), tmp_counter });
        tmp_counter += 1;
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try std.Io.Dir.createDirAbsolute(io, root, .default_dir);

        var fixture_buf: [224]u8 = undefined;
        const fixture = try std.fmt.bufPrint(&fixture_buf, "{s}/fixture.txt", .{root});
        {
            const f = try std.Io.Dir.createFileAbsolute(io, fixture, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "theme matrix fixture\n");
        }

        var home_buf: [224]u8 = undefined;
        const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{root});
        try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
        var cache_buf: [256]u8 = undefined;
        const cache_dir = try std.fmt.bufPrint(&cache_buf, "{s}/.cache", .{home});
        try std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir);
        var oz_cache_buf: [288]u8 = undefined;
        const oz_cache = try std.fmt.bufPrint(&oz_cache_buf, "{s}/oz", .{cache_dir});
        try std.Io.Dir.createDirAbsolute(io, oz_cache, .default_dir);
        // This is the production load seam (`loadTheme`): a fresh HOME plus
        // ~/.cache/oz/theme, not a test-only env override.
        var theme_path_buf: [320]u8 = undefined;
        const theme_path = try std.fmt.bufPrint(&theme_path_buf, "{s}/theme", .{oz_cache});
        {
            const f = try std.Io.Dir.createFileAbsolute(io, theme_path, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, tc.name);
            try f.writeStreamingAll(io, "\n");
        }

        var mock_buf: [224]u8 = undefined;
        const mock = try std.fmt.bufPrint(&mock_buf, "{s}/mock", .{root});
        try std.Io.Dir.createDirAbsolute(io, mock, .default_dir);

        const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{home});
        defer alloc.free(home_env);
        const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{mock});
        defer alloc.free(mock_env);
        const env_extra = [_][]const u8{ home_env, mock_env, "OZ_AI_MODEL=mock-model" };

        var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, "fixture.txt" }, &env_extra, 30, 120, root);
        defer sess.close();
        defer killPid(sess.pid);
        var grid = try Grid.initSizedCols(alloc, 30, 120);
        defer grid.deinit(alloc);

        try gridWaitFor(&sess, &grid, "NORMAL", 8000);
        try gridWaitFor(&sess, &grid, "theme matrix fixture", 5000);
        try sess.send(" e");
        try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
        try gridWaitFor(&sess, &grid, "Files", 5000);

        const nav_row = navTabsRow();
        const files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
        const notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
        var sample = ThemeStyleSample{};
        sample.nav_tab_bg = aiCellBg(&grid, nav_row, files_col);
        sample.nav_tab_fg = grid.fg_buf[nav_row * grid.cols + files_col + 2];
        sample.nav_tab_ul = frame.cellUl(&grid, nav_row, files_col);
        sample.nav_sep_fg = grid.fg_buf[nav_row * grid.cols + notes_col - 1]; // "│"
        // Navigator owns the keyboard after <leader>e: active panel border.
        sample.nav_border_fg = grid.fg_buf[2 * grid.cols + 0];

        try std.testing.expectEqual(tc.bg_sel, sample.nav_tab_bg);
        try std.testing.expectEqual(tc.fg, sample.nav_tab_fg);
        try std.testing.expectEqual(tc.accent_alt, sample.nav_tab_ul);
        try std.testing.expect(frame.cellUnderlined(&grid, nav_row, files_col));
        try std.testing.expectEqual(tc.accent_alt, sample.nav_sep_fg);
        try std.testing.expect(sample.nav_sep_fg != tc.fg_faint);
        try std.testing.expectEqual(tc.win_sep_active, sample.nav_border_fg);

        try sess.send(" a");
        try gridWaitFor(&sess, &grid, "AGENTS", 5000);
        try gridWaitFor(&sess, &grid, "❯ ", 4000);

        const rail_col = aiRailCol(120);
        const tabs_row = aiTabsRow(30);
        const content_col = aiTabsContentCol(rail_col);
        sample.nav_border_fg = grid.fg_buf[2 * grid.cols + 0]; // now inactive
        sample.rail_border_fg = grid.fg_buf[5 * grid.cols + rail_col];
        sample.workbox_tab_bg = aiCellBg(&grid, tabs_row, content_col + 1);
        sample.workbox_tab_fg = grid.fg_buf[tabs_row * grid.cols + content_col + 1];
        sample.workbox_tab_ul = frame.cellUl(&grid, tabs_row, content_col + 1);
        // The first tab separator sits right after "chat".
        sample.workbox_sep_fg = grid.fg_buf[tabs_row * grid.cols + content_col + 5];
        sample.workbox_rule_fg = grid.fg_buf[aiTabsSepRow(30) * grid.cols + rail_col + 2];
        // Attached thread row (the rail header is row 0, the workspace
        // group row 1, thread rows start at row 2). Prompt focus puts the
        // active row on bg_sel and its `>` marker on accent_alt.
        sample.thread_marker_fg = grid.fg_buf[2 * grid.cols + rail_col + 2];
        sample.thread_marker_bg = grid.bg_buf[2 * grid.cols + rail_col + 2];
        sample.status_rule_fg = grid.fg_buf[28 * grid.cols + 0];

        // The buffer tab bar lives at row 0 from contentCol (31 with the
        // navigator open). Find the active tab's accent underline.
        sample.buffer_tab_fg = 0;
        sample.buffer_tab_ul = 0;
        var bc: usize = 31;
        while (bc < 70) : (bc += 1) {
            if (grid.bg_buf[bc] == tc.bg_sel and
                grid.fg_buf[bc] == tc.fg and
                frame.cellUl(&grid, 0, bc) == tc.accent_alt and
                frame.cellUnderlined(&grid, 0, bc))
            {
                sample.buffer_tab_fg = grid.fg_buf[bc];
                sample.buffer_tab_ul = frame.cellUl(&grid, 0, bc);
                break;
            }
        }

        // The active workbox tab and buffer tab use the shared style; rules
        // and separators use the theme's secondary accent, never the old
        // fixed gray.
        try std.testing.expectEqual(tc.bg_sel, sample.workbox_tab_bg);
        try std.testing.expectEqual(tc.fg, sample.workbox_tab_fg);
        try std.testing.expectEqual(tc.accent_alt, sample.workbox_tab_ul);
        try std.testing.expect(frame.cellUnderlined(&grid, tabs_row, content_col + 1));
        try std.testing.expectEqual(tc.accent_alt, sample.workbox_sep_fg);
        try std.testing.expectEqual(tc.accent_alt, sample.workbox_rule_fg);
        try std.testing.expectEqual(tc.accent_alt, sample.thread_marker_fg);
        try std.testing.expectEqual(tc.bg_sel, sample.thread_marker_bg);
        try std.testing.expectEqual(tc.accent_alt, sample.status_rule_fg);
        try std.testing.expectEqual(tc.win_sep, sample.nav_border_fg);
        try std.testing.expectEqual(tc.win_sep_active, sample.rail_border_fg);
        try std.testing.expectEqual(tc.fg, sample.buffer_tab_fg);
        try std.testing.expectEqual(tc.accent_alt, sample.buffer_tab_ul);

        samples[sample_i] = sample;
        sample_i += 1;

        // Return focus to the editor before `:q!`; an immediate Esc+":"
        // would be decoded as an Alt sequence.
        try sess.send("\x1b");
        try aiWaitRailBorderColor(&sess, &grid, rail_col, tc.win_sep, 3000);
        try aiQuit(&sess);
    }

    // Prove the rendered bytes differ per theme (not just that each theme's
    // literal was hardcoded in the assertions): the accent underline,
    // separator and focused-border samples must all be distinct.
    var i: usize = 0;
    while (i < samples.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < samples.len) : (j += 1) {
            try std.testing.expect(samples[i].nav_tab_ul != samples[j].nav_tab_ul);
            try std.testing.expect(samples[i].nav_tab_bg != samples[j].nav_tab_bg);
            try std.testing.expect(samples[i].workbox_sep_fg != samples[j].workbox_sep_fg);
            try std.testing.expect(samples[i].status_rule_fg != samples[j].status_rule_fg);
            try std.testing.expect(samples[i].thread_marker_fg != samples[j].thread_marker_fg);
            try std.testing.expect(samples[i].rail_border_fg != samples[j].rail_border_fg);
        }
    }
}

test "ai workspace: thread B streams while A is frozen; transcripts never mix" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ait.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "threads\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // Slow "A" stream: enough events that switching away interrupts it.
    var stream_a = std.ArrayList(u8).empty;
    defer stream_a.deinit(alloc);
    var ai: usize = 0;
    while (ai < 300) : (ai += 1) {
        try stream_a.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"AAA-\"}}]}\n\n");
    }
    try aiWriteFile(io, dir, "stream.sse", stream_a.items);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);

    const header_row = aiWorkboxHeaderRow(30);
    // Thread A streams.
    try sess.send("alpha\r");
    try gridWaitFor(&sess, &grid, "streaming…", 4000);
    // "AAA" is unique to the reply (the status bar's NORMAL also has an A).
    try gridWaitFor(&sess, &grid, "AAA", 5000);
    const req_a = try aiReadFile(io, alloc, dir, "request.json");
    defer alloc.free(req_a);
    try std.testing.expect(std.mem.indexOf(u8, req_a, "alpha") != null);

    // New thread: switching away cancels A. The rail shows thread 2 and A's
    // status is frozen as cancelled.
    try sess.send("\t");
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 3000);
    try gridWaitFor(&sess, &grid, "cancelled", 4000);
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(300 * std.time.ns_per_ms), .real) catch {};

    // Let A's worker finish before replacing the mock stream (a truncate
    // while the cancelled worker still reads would race the test seam).
    try aiWriteFile(io, dir, "stream.sse", "data: {\"choices\":[{\"delta\":{\"content\":\"banana\"}}]}\n\ndata: [DONE]\n\n");
    try sess.send("beta\r");
    try gridWaitFor(&sess, &grid, "banana", 8000);
    try gridWaitFor(&sess, &grid, "idle", 4000);
    try std.testing.expect(aiRowContains(&grid, header_row, "thread 2"));

    const req_b = try aiReadFile(io, alloc, dir, "request.json");
    defer alloc.free(req_b);
    try std.testing.expect(std.mem.indexOf(u8, req_b, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_b, "alpha") == null);
    // B's transcript has no A reply cells.
    try std.testing.expectEqual(@as(usize, 0), aiCountRailChar(&grid, 'A'));

    // Switching back to A shows the frozen transcript and no B reply.
    try sess.send("\t");
    try sess.send("k");
    try sess.send("\r");
    // "thread 1 · cancelled" is unique to the workbox header (the thread
    // rail renders the same title and status in separate columns), so this
    // also waits for the switched-to frame to arrive.
    try gridWaitFor(&sess, &grid, "thread 1 · cancelled", 4000);
    try std.testing.expect(aiRowContains(&grid, header_row, "thread 1"));
    try gridWaitGone(&sess, &grid, "banana", 4000);
    try gridWaitFor(&sess, &grid, "cancelled", 3000);
    const frozen = aiCountRailChar(&grid, 'A');
    try std.testing.expect(frozen > 0);
    // No late cancelled-stream deltas may land after the switch.
    var ticks: usize = 0;
    while (ticks < 6) : (ticks += 1) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    try std.testing.expectEqual(frozen, aiCountRailChar(&grid, 'A'));

    // And back to B: A's reply text is gone, B's is present.
    try sess.send("\t");
    try sess.send("j");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "banana", 4000);
    try std.testing.expect(aiRowContains(&grid, header_row, "thread 2"));
    try std.testing.expectEqual(@as(usize, 0), aiCountRailChar(&grid, 'A'));

    try sess.send("\x1b"); // prompt -> editor (wide rail stays)
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "ai workspace: workbox tabs show honest empty states and badge 0" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aitab.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "tab test\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try aiWriteFile(io, dir, "stream.sse", "data: [DONE]\n\n");
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    const rail_col = aiRailCol(120);

    // From the prompt, Tab focuses the thread list; c/d/t/r switch tabs.
    try sess.send("\t");
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "no pending changes", 3000);
    try std.testing.expect(grid.contains("changes 0"));
    try std.testing.expect(!grid.contains("diff --"));
    try std.testing.expect(!grid.contains("approve"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 5, rail_col));

    try sess.send("t");
    try gridWaitFor(&sess, &grid, "no tool calls yet", 3000);
    try std.testing.expect(!grid.contains("avg "));
    try std.testing.expect(!grid.contains("p95 "));
    try std.testing.expect(!grid.contains("calls 1"));
    try std.testing.expect(!grid.contains("older"));

    try sess.send("r");
    try gridWaitFor(&sess, &grid, "no pending terminal command", 3000);
    try gridWaitFor(&sess, &grid, "editor terminal: Alt+r", 3000);
    try gridWaitFor(&sess, &grid, "editor terminal: Alt+r", 3000);
    try std.testing.expect(!grid.contains("$ "));

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "❯ ", 2000);
    try sess.send("hi");
    try gridWaitFor(&sess, &grid, "hi", 2000);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, aiPromptRow(30), rail_col));

    try sess.send("\x1b"); // editor (wide rail stays)
    try aiWaitRailFocus(&sess, &grid, rail_col, false, 3000);
    try aiQuit(&sess);
}

test "ai workspace: visual selection context is still included in the request body" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aiv.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha\nbeta\ngamma\ndelta\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try aiWriteFile(io, dir, "stream.sse", "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n");

    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // V j selects lines 1-2, then <leader>a opens the drawer with the
    // selection still active.
    try sess.send("Vj a");
    try gridWaitFor(&sess, &grid, "AGENTS", 4000);
    try sess.send("what");
    try gridWaitFor(&sess, &grid, "what", 2000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "ok", 6000);

    const req = try aiReadFile(io, alloc, dir, "request.json");
    defer alloc.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Selected lines 1-2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "alpha\\nbeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "what") != null);

    try sess.send("\x1b"); // narrow drawer closes
    try gridWaitGone(&sess, &grid, "AGENTS", 4000);
    try sess.send("\x1b"); // leave visual
    try gridWaitFor(&sess, &grid, "NORMAL", 3000);
    try aiQuit(&sess);
}

test "ai workspace: Ctrl+c cancels a stream without further transcript changes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aic.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "cancel me\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(alloc);
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        try stream.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n");
    }
    try aiWriteFile(io, dir, "stream.sse", stream.items);

    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try aiEnterRail(&sess, &grid);
    try sess.send("go\r");
    try gridWaitFor(&sess, &grid, "streaming…", 4000);
    var waited: i32 = 0;
    while (waited < 400) : (waited += 100) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    try sess.send("\x03");
    try gridWaitFor(&sess, &grid, "cancelled", 4000);
    const before = aiCountRailChar(&grid, 'x');
    var ticks: usize = 0;
    while (ticks < 6) : (ticks += 1) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
    }
    try std.testing.expectEqual(before, aiCountRailChar(&grid, 'x'));
    try std.testing.expect(before > 0);

    // Still usable after the cancel.
    try sess.send("still");
    try gridWaitFor(&sess, &grid, "still", 2000);
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "changes 0", 4000);
    try aiQuit(&sess);
}

test "ai workspace: error surfaces in the thread and leaves the editor usable" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}aie.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "error test\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try aiWriteFile(io, dir, "error.txt", "mock boom\n");
    try aiWriteFile(io, dir, "stream.sse", "data: [DONE]\n\n");

    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try aiEnterRail(&sess, &grid);
    try sess.send("hi\r");
    try gridWaitFor(&sess, &grid, "mock boom", 6000);
    try std.testing.expect(grid.contains("error"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 5, aiRailCol(80)));
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "changes 0", 4000);
    try aiQuit(&sess);
}

// ---------------------------------------------------------------------------
// M2.6a keyboard hints (DESIGN.md §19)
// ---------------------------------------------------------------------------

/// Charset of the hint labels (mirrors src/app/hints.zig; the unit tests pin
/// the implementation, this only reads labels off the drawn grid).
const hint_charset = "asdfghjkl";

fn hintIsChar(ch: u8) bool {
    return std.mem.indexOfScalar(u8, hint_charset, ch) != null;
}

/// Label length implied by the target count shown in the HINTS status.
fn hintLabelLenFor(count: usize) usize {
    if (count == 0) return 0;
    if (count <= 9) return 1;
    if (count <= 81) return 2;
    return 3;
}

/// Parse "HINTS · N targets · Esc cancel" from the bottom row. Returns null
/// for "HINTS · no targets".
fn hintTargetCount(grid: *Grid) ?usize {
    const row = grid.rowText(grid.rows - 1);
    const at = std.mem.indexOf(u8, row, "HINTS · ") orelse return null;
    var i = at + "HINTS · ".len;
    var n: usize = 0;
    var digits: usize = 0;
    while (i < row.len and row[i] >= '0' and row[i] <= '9') : (i += 1) {
        n = n * 10 + (row[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return n;
}

/// Read a drawn hint label from the cells starting at (row, col): exactly
/// `want` charset glyphs (the length derives from the status target count,
/// never from a hard-coded letter).
fn hintLabelAt(grid: *Grid, buf: *[3]u8, row: usize, col: usize, want: usize) []const u8 {
    var n: usize = 0;
    const cap = @min(@min(want, buf.len), 3);
    while (n < cap) : (n += 1) {
        const text = aiCellText(grid, row, col + n);
        if (text.len != 1 or !hintIsChar(text[0])) break;
        buf[n] = text[0];
    }
    return buf[0..n];
}

/// Workbox tabs row (the rail metrics place it one row below the header).
fn aiTabsRow(rows: usize) usize {
    return aiWorkboxHeaderRow(rows) + 1;
}

/// Chat prompt row: the last rail row, above the bottom chrome.
fn aiPromptRow(rows: usize) usize {
    return rows - 3;
}

/// Rule between the workbox tab strip and the body.
fn aiTabsSepRow(rows: usize) usize {
    return aiTabsRow(rows) + 1;
}

/// Glyphs that historically came from nerd-font/geometric ranges and can
/// render as tofu on a plain terminal. `❯` (the existing prompt cursor) is
/// deliberately excluded: it predates this chrome and is asserted elsewhere.
fn expectNoForbiddenGlyphs(grid: *Grid, rect: frame.Rect) !void {
    const forbidden = [_][]const u8{ "▥", "●", "○", "◌", "✖", "▸", "▾" };
    var r = rect.top;
    while (r <= rect.bottom and r < grid.rows) : (r += 1) {
        var c = rect.left;
        while (c <= rect.right and c < grid.cols) : (c += 1) {
            const text = aiCellText(grid, r, c);
            for (forbidden) |glyph| {
                if (std.mem.eql(u8, text, glyph)) {
                    std.debug.print("forbidden chrome glyph {s} at ({d},{d})\n", .{ glyph, r, c });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "hints: 120x30 dock labels the filetree and activates the docs row" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}hintd.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hint docs fixture\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // File tree rooted at the project cwd: row 3 is the first entry "docs"
    // (the navigator starts below the two-row buffer strip).
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try gridWaitFor(&sess, &grid, "docs", 5000);

    // Docked rail with a thread + prompt, then Esc back to the editor. The
    // hint entry point is only reachable while the prompt does NOT own the
    // keyboard.
    try sess.send("\x17a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "thread 1", 4000);
    try gridWaitFor(&sess, &grid, "❯ ", 4000);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    // <leader>j: labels + status, focus unchanged (editor).
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    try std.testing.expect(grid.contains("NORMAL"));

    const count = hintTargetCount(&grid) orelse {
        std.debug.print("docs hints: no target count in status\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    // filetree rows + one buffer tab + thread + 4 workbox tabs + "+" + prompt
    try std.testing.expect(count >= 7);
    const want = hintLabelLenFor(count);
    try std.testing.expect(want >= 1 and want <= 3);

    // The docs row is the first filetree entry row; its label is drawn at the
    // row's top-left (the inner column after the border). Derive the label
    // from the frame instead of hard-coding a letter.
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, navBodyRow(), 1, want);
    if (label.len != want) {
        std.debug.print("docs hints: could not read label at ({d},1): got {d} of {d} chars\n", .{ navBodyRow(), label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    // Borders stay intact under the overlay: the label starts inside the
    // panel, and the status bar keeps NORMAL + HINTS on its own row.
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 0));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Typing the full label expands docs exactly like Enter: its children
    // appear, the folder glyph flips open, hint mode exits.
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "workspace-plan", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 4000);
    try std.testing.expect(grid.contains("\u{f07c}")); // open folder glyph
    try std.testing.expect(grid.contains("NORMAL"));

    try aiQuit(&sess);
}

test "hints: 120x30 dock buffer tab, workbox tab and agent thread targets" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const tag = tmp_counter;
    tmp_counter += 1;
    var path_a_buf: [160:0]u8 = undefined;
    const path_a = try bufPrintZ(&path_a_buf, "/tmp/ozhint_{d}_{d}a.txt", .{ linux.getpid(), tag });
    var path_b_buf: [160:0]u8 = undefined;
    const path_b = try bufPrintZ(&path_b_buf, "/tmp/ozhint_{d}_{d}b.txt", .{ linux.getpid(), tag });
    defer std.Io.Dir.cwd().deleteFile(io, path_a) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path_b) catch {};
    {
        const fa = try std.Io.Dir.cwd().createFile(io, path_a, .{ .truncate = true });
        defer fa.close(io);
        try fa.writeStreamingAll(io, "HINTS_BUFFER_A\n");
        const fb = try std.Io.Dir.cwd().createFile(io, path_b, .{ .truncate = true });
        defer fb.close(io);
        try fb.writeStreamingAll(io, "HINTS_BUFFER_B\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, path_a }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "HINTS_BUFFER_A", 5000);

    // Second buffer via :e, then back to A so the tab target has an
    // observable effect (B's marker must disappear then reappear).
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":e {s}\r", .{path_b});
    try sess.send(cmd);
    try gridWaitFor(&sess, &grid, "HINTS_BUFFER_B", 6000);
    try sess.send("gT");
    try gridWaitFor(&sess, &grid, "HINTS_BUFFER_A", 5000);
    try gridWaitGone(&sess, &grid, "HINTS_BUFFER_B", 3000);

    // Rail + second thread, then back to the editor for hint entry.
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "thread 1", 4000);
    try sess.send("\x0e"); // Ctrl+n: new thread -> thread 2, prompt focus
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try sess.send("\t"); // prompt -> thread list
    try sess.send("\x1b"); // thread list -> editor (docked rail stays)
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    // Locate the B tab from the DRAWN frame before the overlay replaces its
    // name: at the width cap the middle ellipsis keeps the extension/stem,
    // so search for the unique `b.txt` suffix, not the full temp path.
    const b_name = aiCellIndexOf(&grid, 0, "b.txt") orelse {
        std.debug.print("tab hints: B tab not found in row 0\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(b_name >= 3);
    // The name suffix sits at the END of the truncated tab, so derive the
    // tab start from the `│` separator before it; the select target begins
    // two cells in (two-cell inner padding), at the icon.
    var sep_col: ?usize = null;
    var scan: usize = 0;
    while (scan < b_name) : (scan += 1) {
        if (std.mem.eql(u8, aiCellText(&grid, 0, scan), "│")) sep_col = scan;
    }
    const tab_start = (sep_col orelse (b_name -| 16)) + 1;
    const target_col = tab_start + 2;

    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const count = hintTargetCount(&grid) orelse return error.TestUnexpectedResult;
    const want = hintLabelLenFor(count);
    var label_buf: [3]u8 = undefined;
    const tab_label = hintLabelAt(&grid, &label_buf, 0, target_col, want);
    if (tab_label.len != want) {
        std.debug.print("tab hints: could not read buffer-tab label at (0,{d}): {d}/{d}\n", .{ target_col, tab_label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(tab_label);
    try gridWaitFor(&sess, &grid, "HINTS_BUFFER_B", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);

    // Workbox tab target: the changes tab starts after "chat" + one space in
    // the rail's tabs row. Its label activates the tab -> body changes.
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const changes_col = aiChangesTabCol(120);
    const want2 = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label2_buf: [3]u8 = undefined;
    const changes_label = hintLabelAt(&grid, &label2_buf, aiTabsRow(30), changes_col, want2);
    if (changes_label.len != want2) {
        std.debug.print("tab hints: could not read workbox-tab label at ({d},{d}): {d}/{d}\n", .{ aiTabsRow(30), changes_col, changes_label.len, want2 });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(changes_label);
    try gridWaitFor(&sess, &grid, "no pending changes", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);

    // Agent thread target: thread 1's row is the first thread row; attaching
    // makes it the workbox header ("thread 1 · idle").
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const want3 = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label3_buf: [3]u8 = undefined;
    const thread_label = hintLabelAt(&grid, &label3_buf, 2, aiRailCol(120) + 2, want3);
    if (thread_label.len != want3) {
        std.debug.print("thread hints: could not read thread label: {d}/{d}\n", .{ thread_label.len, want3 });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(thread_label);
    try gridWaitFor(&sess, &grid, "thread 1 ·", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);
    // Attaching focused the prompt; hand keys back to the editor before :q.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    try aiQuit(&sess);
}

test "hints: 80x24 drawer target works, Esc cancels without side effects" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}hint80.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "hint drawer fixture\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // Drawer: <leader>a focuses the prompt, Tab moves to the thread list,
    // and <leader>j there enters hint mode (the prompt itself keeps text
    // input, exactly like the design's "prompt not focused" rule).
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "thread 1", 4000);
    try sess.send("\t");
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);

    const rail_col = aiRailCol(80);
    try std.testing.expectEqual(@as(usize, 46), rail_col);
    // Drawer borders survive the overlay; labels live inside the panel.
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 5, rail_col));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    const status_rect = frame.Rect{ .top = 23, .left = 0, .right = 79, .bottom = 23 };
    try std.testing.expect(std.mem.startsWith(u8, grid.rowText(23), "[main]"));
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(23), "NORMAL") != null);

    // Activate the changes workbox tab through its drawn label.
    const count = hintTargetCount(&grid) orelse return error.TestUnexpectedResult;
    const want = hintLabelLenFor(count);
    const changes_col = aiChangesTabCol(80);
    var label_buf: [3]u8 = undefined;
    const changes_label = hintLabelAt(&grid, &label_buf, aiTabsRow(24), changes_col, want);
    if (changes_label.len != want) {
        std.debug.print("drawer hints: could not read workbox-tab label: {d}/{d}\n", .{ changes_label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(changes_label);
    try gridWaitFor(&sess, &grid, "no pending changes", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);
    // The action itself does not steal focus from the thread list.
    try std.testing.expectEqual(packRgb(0xE6, 0xC3, 0x84), grid.fg_buf[5 * grid.cols + rail_col]);

    // Re-enter from the rail, type a non-label key (ignored, still active),
    // then Esc: no state change (changes tab + rail focus survive).
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    try sess.send("q");
    try std.testing.expect(grid.contains("HINTS ·"));
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);
    try std.testing.expect(grid.contains("no pending changes"));
    try std.testing.expectEqual(packRgb(0xE6, 0xC3, 0x84), grid.fg_buf[5 * grid.cols + rail_col]);
    try frame.expectNoOverlap(status_rect, frame.Rect{ .top = 0, .left = rail_col, .right = 79, .bottom = 22 });

    // Esc from the thread list closes the drawer and returns keys to the
    // editor; only then does ":q!" reach the cmdline.
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "changes 0", 3000);
    try aiQuit(&sess);
}

test "hints: plain f still runs find-char (not hint mode)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}hintf.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "abcdef hint find target\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "abcdef", 5000);

    // f{char} = vim find, then x deletes the char under the cursor. If `f`
    // had opened hint mode instead, the delete would never happen.
    try sess.send("fd");
    try sess.send("x");
    try gridWaitFor(&sess, &grid, "abcef hint find target", 5000);
    try std.testing.expect(!grid.contains("abcdef"));
    try std.testing.expect(!grid.contains("HINTS"));

    try aiQuit(&sess);
}

test "hints: no targets shows the empty status and Esc exits" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // No file argument -> dashboard; no filetree/rail -> no hint targets
    // (the dashboard's empty "[No Name]" tab is deliberately not a target).
    var sess = try Session.spawnEnvSize(io, &.{oz_exe_path}, null, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "终端文本编辑器", 8000);

    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS · no targets", 4000);
    // A label character with zero targets is ignored; hint mode stays.
    try sess.send("a");
    try std.testing.expect(grid.contains("HINTS · no targets"));
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);

    try aiQuit(&sess);
}

// ---------------------------------------------------------------------------
// M2b1 navigator tabs + notes
// ---------------------------------------------------------------------------

test "navigator: 120x30 tabs switch files/notes/agents with real content" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}nav.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "NAV_MARKER\n");
    }

    var notes_buf: [128]u8 = undefined;
    // Deliberately NOT created: the navigator must not create the notes dir
    // at startup; only the first Notes-tab entry (lazy list) may do that.
    const notes_dir = try notesTestPath(&notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    try std.testing.expect(!pathExists(io, notes_dir));
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{notes_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    // Files: branded full navigator with OZ, workspace/branch, icon tabs.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "build.zig", 6000);
    try gridWaitFor(&sess, &grid, "╭─ OZ", 6000);
    try std.testing.expect(!pathExists(io, notes_dir));

    const top_row = navTabsRow() - 2;
    try std.testing.expect(aiRowContains(&grid, top_row, "OZ"));
    try std.testing.expect(aiRowContains(&grid, top_row, "╮"));
    // Real workspace + git branch from the running repo (never a placeholder).
    try std.testing.expect(aiRowContains(&grid, navTabsRow() - 1, "main"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow() - 1, 0));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow() - 1, 29));
    // Rule row closes the header before the content.
    try std.testing.expectEqualStrings("├", aiCellText(&grid, navTabsRow() + 1, 0));
    try std.testing.expectEqualStrings("┤", aiCellText(&grid, navTabsRow() + 1, 29));

    const tab_row = grid.rowText(navTabsRow());
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "Notes") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "Agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "\u{f07b}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "\u{f0219}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_row, "\u{f0c0}") != null);
    // Real cached counts: Files is the visible tree-row count; Notes has no
    // badge until its lazy list loads; Agents counts the real threads (0
    // until the Agents view/rail creates the lazy session thread).
    try std.testing.expect(navTabCount(&grid, "Files") != null);
    try std.testing.expectEqual(@as(?usize, 0), navTabCount(&grid, "Agents"));
    try std.testing.expectEqual(@as(?usize, null), navTabCount(&grid, "Notes"));

    var files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    var notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
    var agents_col = navTabStart(&grid, "Agents") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), notes_col - 1));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), agents_col - 1));
    // Active tab uses bg_sel; the inactive ones keep the editor bg.
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navTabsRow(), files_col));
    try std.testing.expectEqual(navEditorBg(), aiCellBg(&grid, navTabsRow(), notes_col));
    try std.testing.expectEqual(navEditorBg(), aiCellBg(&grid, navTabsRow(), agents_col));
    try frame.expectCellUl(&grid, navTabsRow(), files_col, packRgb(0x7E, 0x9C, 0xD8));

    // Tab -> Notes: empty state + lazy directory creation on first list. Its
    // real count (0) appears once the cached list is loaded.
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "no notes yet", 5000);
    try std.testing.expect(pathExists(io, notes_dir));
    try std.testing.expectEqual(@as(?usize, 0), navTabCount(&grid, "Notes"));
    files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    notes_col = navTabStart(&grid, "Notes") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navTabsRow(), notes_col));
    try std.testing.expectEqual(navEditorBg(), aiCellBg(&grid, navTabsRow(), files_col));
    // Border frame intact around the content.
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 0));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 29));

    // Tab -> Agents: real thread model, grouped under the current workspace.
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try std.testing.expect(aiRowContains(&grid, navBodyRow(), "main"));
    try std.testing.expect(aiRowContains(&grid, navBodyRow() + 1, "thread 1"));
    try std.testing.expect(aiRowContains(&grid, navBodyRow() + 1, "idle"));
    try std.testing.expectEqual(@as(?usize, 1), navTabCount(&grid, "Agents"));
    agents_col = navTabStart(&grid, "Agents") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navTabsRow(), agents_col));

    // Shift-Tab goes back to Notes, direct "1" returns to Files.
    try sess.send("\x1b[Z");
    try gridWaitFor(&sess, &grid, "no notes yet", 5000);
    try sess.send("1");
    try gridWaitFor(&sess, &grid, "build.zig", 5000);
    try std.testing.expect(!grid.contains("no notes yet"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try aiQuit(&sess);
}

test "navigator: notes create, edit, save and reopen from the list" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}notefix.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "OTHER_BUFFER\n");
    }

    var notes_buf: [128]u8 = undefined;
    const notes_dir = try notesTestDir(io, &notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{notes_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "OTHER_BUFFER", 5000);

    // Files -> Notes, then `n`: a real note file + normal buffer.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "no notes yet", 5000);
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "Untitled note", 5000);

    var p1_buf: [256]u8 = undefined;
    const p1 = try std.fmt.bufPrint(&p1_buf, "{s}/note-1.md", .{notes_dir});
    try std.testing.expect(pathExists(io, p1));
    {
        const created = try absFileText(io, alloc, p1);
        defer alloc.free(created);
        try std.testing.expectEqualStrings("# Untitled note\n\n", created);
    }

    // Edit a marker on a new line below the template, then :w.
    try sess.send("Go");
    try sess.send("NOTE_MARKER_1");
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "NORMAL", 4000);
    try sess.send(":w\r");
    try gridWaitFor(&sess, &grid, "written:", 5000);
    {
        const saved = try absFileText(io, alloc, p1);
        defer alloc.free(saved);
        try std.testing.expect(std.mem.indexOf(u8, saved, "# Untitled note") != null);
        try std.testing.expect(std.mem.indexOf(u8, saved, "NOTE_MARKER_1") != null);
    }

    // Switch to another buffer, focus the navigator (Notes tab is still
    // active), refresh on tab entry, then Enter reopens the note.
    var cmd_buf: [320]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":e {s}\r", .{name});
    try sess.send(cmd);
    try gridWaitFor(&sess, &grid, "OTHER_BUFFER", 5000);
    // The note's title/snippet (including the saved marker) is in the LIST,
    // but the editor region right of the 30-cell navigator now shows the
    // other buffer, not the note.
    try std.testing.expect(aiFindCellFrom(&grid, "NOTE_MARKER_1", 30) == null);
    try sess.send("\x17h");
    try sess.send("2"); // explicit tab entry -> refresh
    try gridWaitFor(&sess, &grid, "note-1.md", 5000);
    try gridWaitFor(&sess, &grid, "Untitled note", 5000);
    try sess.send("\r");
    // The list already contains the marker (snippet); wait for the editor
    // region right of the 30-cell navigator to show it, proving the note
    // buffer itself was reopened.
    var reopened_wait: i32 = 0;
    while (reopened_wait < 5000 and aiFindCellFrom(&grid, "NOTE_MARKER_1", 30) == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) {
            reopened_wait += 100;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(aiFindCellFrom(&grid, "NOTE_MARKER_1", 30) != null);
    // The opened note is a normal buffer: its filename owns a tab title.
    try std.testing.expect(aiRowContains(&grid, 0, "note-1.md"));

    // Notes are project-independent: Files still shows the repo tree, not
    // the global data directory (opening a note must not re-root the
    // workspace's filetree/picker).
    try sess.send("\x17h");
    try sess.send("1");
    try gridWaitFor(&sess, &grid, "build.zig", 5000);
    try sess.send("2");
    try gridWaitFor(&sess, &grid, "note-1.md", 5000);

    // A second `n` allocates the next collision-free name (never overwrites).
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "note-2.md", 5000);
    var p2_buf: [256]u8 = undefined;
    const p2 = try std.fmt.bufPrint(&p2_buf, "{s}/note-2.md", .{notes_dir});
    try std.testing.expect(pathExists(io, p2));
    {
        const second = try absFileText(io, alloc, p2);
        defer alloc.free(second);
        try std.testing.expectEqualStrings("# Untitled note\n\n", second);
    }
    const first_again = try absFileText(io, alloc, p1);
    defer alloc.free(first_again);
    try std.testing.expect(std.mem.indexOf(u8, first_again, "NOTE_MARKER_1") != null);

    try aiQuit(&sess);
}

test "navigator: agents tab Enter attaches the selected real thread" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}navagent.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AGENT_NAV_MARKER\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // Files -> Agents. thread 1 is the real lazily-created session thread.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try sess.send("\t\t");
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try std.testing.expect(aiRowContains(&grid, navBodyRow(), "main"));

    // `n` on the navigator = aiNewThread: the rail opens on thread 2.
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try gridWaitFor(&sess, &grid, "thread 2 ·", 5000);
    try std.testing.expect(aiRowContains(&grid, aiWorkboxHeaderRow(30), "thread 2 · idle"));

    // Back to the navigator (Esc returns keys to the editor; the App focus
    // is still the navigator), select thread 1, Enter attaches it. Wait for
    // the rail's faint border before typing so Esc is not merged with the
    // next key into an Alt sequence.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("k");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "thread 1 ·", 5000);
    try std.testing.expect(aiRowContains(&grid, aiWorkboxHeaderRow(30), "thread 1 · idle"));

    // And again to thread 2: the workbox header/status follow the attach.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("j");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "thread 2 ·", 5000);
    try std.testing.expect(aiRowContains(&grid, aiWorkboxHeaderRow(30), "thread 2 · idle"));

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "hints: navigator tab and note row labels activate targets" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}navhint.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "NAV_HINT_MARKER\n");
    }

    var notes_buf: [128]u8 = undefined;
    const notes_dir = try notesTestDir(io, &notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    try aiWriteFile(io, notes_dir, "alpha.md", "# Alpha note\n\nsnippet body\n");
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{notes_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);

    // Enter hint mode; the hint label covers the tab's icon cell, which is
    // the target's top-left. Record the (pre-label) starts first.
    const files_start = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const count = hintTargetCount(&grid) orelse return error.TestUnexpectedResult;
    const want = hintLabelLenFor(count);
    var label_buf: [3]u8 = undefined;
    const files_label = hintLabelAt(&grid, &label_buf, navTabsRow(), files_start, want);
    if (files_label.len != want) {
        std.debug.print("nav hints: no files-tab label at ({d},{d}): {d}/{d}\n", .{ navTabsRow(), files_start, files_label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(files_label);
    try gridWaitFor(&sess, &grid, "build.zig", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 4000);
    try std.testing.expect(!grid.contains("Alpha note"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 0));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Back to Notes and open the note through its drawn row label. The
    // first content row is the note title; its target starts at column 1.
    try sess.send("2");
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want2 = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var note_label_buf: [3]u8 = undefined;
    const note_label = hintLabelAt(&grid, &note_label_buf, navBodyRow(), 1, want2);
    if (note_label.len != want2) {
        std.debug.print("nav hints: no note-row label at ({d},1): {d}/{d}\n", .{ navBodyRow(), note_label.len, want2 });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(note_label);
    try gridWaitGone(&sess, &grid, "HINTS ·", 4000);
    // The note buffer now owns a tab title; the fixture buffer is still open.
    var waited: i32 = 0;
    while (waited < 5000 and !aiRowContains(&grid, 0, "alpha.md")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) {
            waited += 100;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(aiRowContains(&grid, 0, "alpha.md"));
    try std.testing.expect(grid.contains("NORMAL"));

    try aiQuit(&sess);
}

test "navigator: unavailable notes dir shows a clear error, no crash" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}naverr.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "NAV_ERR_MARKER\n");
    }

    // /dev/null/notes cannot be a directory: the lazy create/list fails and
    // the Notes tab must show an error instead of crashing or scanning per
    // frame.
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{"OZ_NOTES_DIR=/dev/null/notes"}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "! notes unavailable", 5000);
    try std.testing.expect(grid.contains("NORMAL"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    // The editor remains usable beside the error: Ctrl-w l hands keys back
    // to the buffer (no Esc+key merge into an Alt sequence).
    try sess.send("\x17l");
    try sess.send("i");
    try sess.send("X");
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "XNAV_ERR_MARKER", 5000);

    try aiQuit(&sess);
}

test "navigator: 80x24 compact rail + notes peek scroll" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}nav80.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "NAV80_MARKER\n");
    }

    var notes_buf: [128]u8 = undefined;
    const notes_dir = try notesTestDir(io, &notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        var fname_buf: [32]u8 = undefined;
        const fname = try std.fmt.bufPrint(&fname_buf, "note-{d:0>2}.md", .{i});
        var body_buf: [96]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "# Note {d:0>2}\n\nbody {d}\n", .{ i, i });
        try aiWriteFile(io, notes_dir, fname, body);
    }
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{notes_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    // <leader>e at 80 opens the compact rail's 30-cell peek. The peek is a
    // real navigator box (brand + tabs + content), not a label-only stub.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try std.testing.expectEqualStrings("╮", aiCellText(&grid, navTabsRow() - 2, 29));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), 29));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 29));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Files -> Notes through the peek; 12 notes, 7 fit in the peek's 15
    // content rows (2 rows each). A page of j scrolls three notes off.
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "Note 12", 5000);
    try std.testing.expect(aiRowContains(&grid, navBodyRow(), "Note 12"));
    try std.testing.expect(aiRowContains(&grid, navBodyRow() + 1, "note-12.md"));
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navBodyRow(), 1));

    try sess.send("jjjjjjjjj");
    try gridWaitGone(&sess, &grid, "Note 12", 5000);
    try std.testing.expect(aiRowContains(&grid, navBodyRow(), "Note 09"));
    try std.testing.expect(grid.contains("Note 03"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // ...and back up: the list restores the first note.
    try sess.send("kkkkkkkkk");
    try gridWaitFor(&sess, &grid, "Note 12", 5000);
    try std.testing.expect(aiRowContains(&grid, navBodyRow(), "Note 12"));

    // Esc closes only the peek; the icon rail remains and the editor uses
    // the full width again.
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "Note 12", 4000);
    try std.testing.expect(grid.contains("OZ"));
    try std.testing.expect(!grid.contains("╭─ OZ"));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, 3, nav_model.compact_width - 1));
    const marker = aiFindCell(&grid, "NAV80_MARKER");
    try std.testing.expect(marker != null);
    try std.testing.expect(marker.?.col >= nav_model.compact_width + nav_model.gutter);

    try aiQuit(&sess);
}

test "navigator: 120x30 brand header shows workspace, real branch and counts" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Open a file inside the repo (the test cwd) so the workspace root stays
    // the git checkout and the header can read the real branch.
    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, "build.zig" }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "⎇", 5000); // async git status settled

    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try gridWaitFor(&sess, &grid, "Files", 5000);
    const top = navTabsRow() - 2;
    try std.testing.expect(aiRowContains(&grid, top, "OZ"));
    // OZ uses the theme accent (bold is not carried by the cell grid; the
    // generated style is unit-covered by chrome's theme matrix).
    try std.testing.expectEqual(packRgb(0xE6, 0xC3, 0x84), grid.fg_buf[top * grid.cols + 3]);
    try std.testing.expectEqualStrings("╮", aiCellText(&grid, top, 29));
    // "main / <branch>" is only produced when a real branch is available.
    try std.testing.expect(aiRowContains(&grid, navTabsRow() - 1, "main / "));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow() - 1, 0));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow() - 1, 29));
    // Real cached counts: Files > 0, Notes unknown until loaded, Agents 0.
    try std.testing.expect(navTabCount(&grid, "Files") != null);
    try std.testing.expectEqual(@as(?usize, null), navTabCount(&grid, "Notes"));
    try std.testing.expectEqual(@as(?usize, 0), navTabCount(&grid, "Agents"));
    // Active icon uses the accent marker color on bg_sel.
    const files_col = navTabStart(&grid, "Files") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navTabsRow(), files_col));
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[navTabsRow() * grid.cols + files_col]);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 0));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 29));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try aiQuit(&sess);
}

test "navigator: 80x24 compact rail 1/2/3, hints, outside click and drawer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_compact_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var sub_buf: [200]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/sub", .{root});
    try std.Io.Dir.cwd().createDirPath(io, sub);
    try aiWriteFile(io, root, "second.txt", "INNER_COMPACT_MARKER\n");
    var fixture_buf: [200:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/fixture.txt", .{root});
    try aiWriteFile(io, root, "fixture.txt", "COMPACT_MARKER\n");

    var notes_buf: [128]u8 = undefined;
    const notes_dir = try notesTestDir(io, &notes_buf);
    defer std.Io.Dir.cwd().deleteTree(io, notes_dir) catch {};
    try aiWriteFile(io, notes_dir, "alpha.md", "# Alpha note\n\ncompact note body\n");
    const notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{notes_dir});
    defer alloc.free(notes_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, fixture }, &.{notes_env}, 24, 80, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "COMPACT_MARKER", 5000);

    // Explicit navigator entry opens the real 30-cell peek over the editor.
    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try gridWaitFor(&sess, &grid, "Files", 5000);
    try gridWaitFor(&sess, &grid, "sub", 5000);
    try std.testing.expectEqualStrings("╮", aiCellText(&grid, navTabsRow() - 2, 29));
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navTabsRow(), 29));

    // 2/3/1 switch the peek's real content while the navigator owns keys;
    // Tab/Shift-Tab cycle the same model.
    try sess.send("2");
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try sess.send("3");
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try sess.send("1");
    try gridWaitFor(&sess, &grid, "sub", 5000);
    try sess.send("\t");
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try sess.send("\x1b[Z");
    try gridWaitFor(&sess, &grid, "sub", 5000);

    // Esc closes only the peek: the icon rail remains and the editor gets
    // its full width back (text starts at the compact gutter).
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));
    try std.testing.expect(aiRowContains(&grid, 2, "OZ"));
    try std.testing.expectEqualStrings("\u{f07b}", aiCellText(&grid, navCompactTabRow(0), 2));
    try std.testing.expectEqualStrings("\u{f0219}", aiCellText(&grid, navCompactTabRow(1), 2));
    try std.testing.expectEqualStrings("\u{f0c0}", aiCellText(&grid, navCompactTabRow(2), 2));
    // Active icon: bg_sel across both rows + accent left bar/icon; inactive
    // Notes keeps the panel bg and fg_dim.
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navCompactTabRow(0), 1));
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navCompactTabRow(0) + 1, 1));
    try std.testing.expectEqual(navSelectedBg(), aiCellBg(&grid, navCompactTabRow(0), 2));
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[navCompactTabRow(0) * grid.cols]);
    try std.testing.expectEqual(packRgb(0x7E, 0x9C, 0xD8), grid.fg_buf[navCompactTabRow(0) * grid.cols + 2]);
    try std.testing.expectEqual(navEditorBg(), aiCellBg(&grid, navCompactTabRow(1), 1));
    try std.testing.expectEqual(packRgb(0x72, 0x71, 0x69), grid.fg_buf[navCompactTabRow(1) * grid.cols + 2]);
    const marker_cell = aiFindCell(&grid, "COMPACT_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(marker_cell.col >= nav_model.compact_width + nav_model.gutter);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Mouse: clicking an icon opens the peek; clicking the editor closes it
    // without falling through to a cursor placement.
    try mouseClickAt(&sess, 2, navCompactTabRow(1));
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    // A click on the peek header (no target) must not fall through to the
    // editor pane underneath and close the peek.
    try mouseClickAt(&sess, 20, navTabsRow() - 1);
    _ = try uiPump(&sess, &grid, 250);
    try std.testing.expect(grid.contains("╭─ OZ"));
    // A click outside the 30-cell peek does close it and returns the editor.
    try mouseClickAt(&sess, 40, 10);
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));

    // Keyboard hints target the compact icons too (labels sit at the rail's
    // first cell), and activating one opens the corresponding peek.
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const count = hintTargetCount(&grid) orelse return error.TestUnexpectedResult;
    const want = hintLabelLenFor(count);
    var label_buf: [3]u8 = undefined;
    const notes_label = hintLabelAt(&grid, &label_buf, navCompactTabRow(1), 0, want);
    if (notes_label.len != want) {
        std.debug.print("compact hints: no notes icon label at ({d},0): {d}/{d}\n", .{ navCompactTabRow(1), notes_label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(notes_label);
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try std.testing.expect(grid.contains("╭─ OZ"));
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);

    // Opening a note closes the peek and returns the editor.
    try mouseClickAt(&sess, 2, navCompactTabRow(1));
    try gridWaitFor(&sess, &grid, "Alpha note", 5000);
    try mouseClickAt(&sess, 5, navBodyRow());
    try gridWaitFor(&sess, &grid, "# Alpha note", 5000);
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));

    // Opening a file from Files closes the peek as well. second.txt lives in
    // the workspace root, so opening it does not re-root/close the tree.
    try mouseClickAt(&sess, 2, navCompactTabRow(0));
    try gridWaitFor(&sess, &grid, "sub", 5000);
    try gridWaitFor(&sess, &grid, "second.txt", 5000);
    try sess.send("jj\r");
    try gridWaitFor(&sess, &grid, "INNER_COMPACT_MARKER", 5000);
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Agent drawer still opens over the compact rail, never sharing it with
    // the navigator peek; Esc closes the drawer and leaves the rail.
    try sess.send("\x17a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try std.testing.expect(!grid.contains("╭─ OZ"));
    try std.testing.expect(navCompactRailVisible(&grid));
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "AGENTS", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));

    // Agents peek: `n` creates a real thread and opens the drawer, closing
    // the peek (no stacked overlays).
    try mouseClickAt(&sess, 2, navCompactTabRow(2));
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "AGENTS", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));

    // <leader>e hides the navigator completely; the editor keeps its width.
    try sess.send(" e");
    var waited: i32 = 0;
    while (navCompactRailVisible(&grid)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 100);
        if (n == 0) {
            waited += 100;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!navCompactRailVisible(&grid));
    try std.testing.expect(aiFindCell(&grid, "INNER_COMPACT_MARKER") != null);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try aiQuit(&sess);
}

test "navigator: 60x24 compact peek and rail never overflow" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_compact60_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var fixture_buf: [200:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/fixture.txt", .{root});
    try aiWriteFile(io, root, "fixture.txt", "COMPACT60_MARKER\n");

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, fixture }, null, 24, 60, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 60);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    try sess.send(" e");
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try std.testing.expectEqualStrings("│", aiCellText(&grid, navBodyRow(), 29));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));
    const marker_cell = aiFindCell(&grid, "COMPACT60_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(marker_cell.col >= nav_model.compact_width + nav_model.gutter);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try mouseClickAt(&sess, 2, navCompactTabRow(0));
    try gridWaitFor(&sess, &grid, "╭─ OZ", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "╭─ OZ", 4000);
    try std.testing.expect(navCompactRailVisible(&grid));

    try aiQuit(&sess);
}

// ---------------------------------------------------------------------------
// M3a agent tools (read-only loop, cards, metrics, chart)
// ---------------------------------------------------------------------------

/// JSON-escape `text` for embedding as an OpenAI `arguments` STRING value.
fn aiJsonQuote(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(text, .{}, &out.writer);
    return out.toOwnedSlice();
}

const AiToolSpec = struct { id: []const u8, name: []const u8, args: []const u8 };

/// Build the JSON arguments for one `apply_patch` tool call from patch text.
fn aiPatchArgs(alloc: std.mem.Allocator, patch_text: []const u8) ![]u8 {
    const quoted = try aiJsonQuote(alloc, patch_text);
    defer alloc.free(quoted);
    return std.fmt.allocPrint(alloc, "{{\"patch\":{s}}}", .{quoted});
}

/// JSON arguments for one `terminal` call (M3b3).
fn aiTerminalArgs(alloc: std.mem.Allocator, command: []const u8, timeout_ms: ?u32) ![]u8 {
    const quoted = try aiJsonQuote(alloc, command);
    defer alloc.free(quoted);
    if (timeout_ms) |t| {
        return std.fmt.allocPrint(alloc, "{{\"command\":{s},\"timeout_ms\":{d}}}", .{ quoted, t });
    }
    return std.fmt.allocPrint(alloc, "{{\"command\":{s}}}", .{quoted});
}

fn aiFileExists(io: Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
    file.close(io);
    return true;
}

/// One OpenAI tool-call stream chunk sequence with `specs` as parallel calls
/// in a single delta (index = position). `arguments` is JSON-escaped here.
fn aiToolCallsSse(alloc: std.mem.Allocator, specs: []const AiToolSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[");
    for (specs, 0..) |spec, i| {
        if (i > 0) try out.append(alloc, ',');
        const quoted = try aiJsonQuote(alloc, spec.args);
        defer alloc.free(quoted);
        const entry = try std.fmt.allocPrint(alloc, "{{\"index\":{d},\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ i, spec.id, spec.name, quoted });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n");
    return out.toOwnedSlice(alloc);
}

fn aiTextSse(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\ndata: [DONE]\n\n",
        .{text},
    );
}

test "tools: read_file loop renders card, executes against the workspace, metrics and chart" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var fixture_buf: [220:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/tool_fixture.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, fixture, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "TOOL_MARKER alpha line\nTOOL_SECOND beta line\n");
    }
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "EDITOR_MARKER for tools\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{.{ .id = "call_1", .name = "read_file", .args = "{\"path\":\"tool_fixture.txt\"}" }});
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "TOOL_DONE final reply");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("read the fixture");
    try gridWaitFor(&sess, &grid, "read the fixture", 3000);
    try sess.send("\r");

    // Round 1 tool card: running then ok with a real result excerpt.
    try gridWaitFor(&sess, &grid, "read_file", 10000);
    try gridWaitFor(&sess, &grid, "tool_fixture.txt", 5000);
    try gridWaitFor(&sess, &grid, "TOOL_MARKER alpha line", 10000);
    try gridWaitFor(&sess, &grid, "TOOL_DONE final reply", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(grid.contains("ok "));
    try std.testing.expect(!grid.contains("approval required"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // The follow-up request carries the assistant tool-call turn and the
    // role:"tool" result with the exact id, bounded content and tools.
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "TOOL_MARKER alpha line") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_choice\":\"auto\"") != null);
    const req1 = try aiReadFile(io, alloc, dir, "request-1.json");
    defer alloc.free(req1);
    try std.testing.expect(std.mem.indexOf(u8, req1, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req1, "read_file") != null);

    // Tools tab: real per-tool counts and a latency chart (braille at 120).
    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "ok 1", 5000);
    try gridWaitFor(&sess, &grid, "avg ", 5000);
    try gridWaitFor(&sess, &grid, "p95 ", 5000);
    try gridWaitFor(&sess, &grid, "max ", 5000);
    try gridWaitFor(&sess, &grid, "older", 5000);
    try gridWaitFor(&sess, &grid, "now", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    // p95 is real: exactly one executed call, so avg == p95 and both are a
    // plausible millisecond duration (the mock has no injected latency).
    const avg_ms = gridMetricMs(&grid, "avg ") orelse {
        grid.dump();
        return error.TestUnexpectedResult;
    };
    const p95_ms = gridMetricMs(&grid, "p95 ") orelse {
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(p95_ms <= 60_000);
    try std.testing.expectEqual(avg_ms, p95_ms);
    // Metrics are real: exactly one call, no fabricated baseline rows.
    try std.testing.expect(!grid.contains("grep · calls"));
    try std.testing.expect(!grid.contains("no tool calls yet"));

    // Tools tab was opened from the thread list; Esc hands keys back to the
    // editor (wide rail stays), then :q! reaches the cmdline.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "tools: parallel read_file + grep cards and real counts" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_par_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var fixture_buf: [220:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/par_fixture.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, fixture, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "NEEDLE_PAR first line\nsecond par line\n");
    }
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/par_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "PAR_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_par_a", .name = "read_file", .args = "{\"path\":\"par_fixture.txt\"}" },
        .{ .id = "call_par_b", .name = "grep", .args = "{\"pattern\":\"NEEDLE_PAR\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "PARALLEL_DONE final");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("check both");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "read_file", 10000);
    try gridWaitFor(&sess, &grid, "grep", 8000);
    try gridWaitFor(&sess, &grid, "NEEDLE_PAR first line", 10000);
    try gridWaitFor(&sess, &grid, "PARALLEL_DONE final", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_par_a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_par_b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "NEEDLE_PAR first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "par_fixture.txt:1:NEEDLE_PAR") != null);

    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "2 calls", 5000);
    try gridWaitFor(&sess, &grid, "read_file", 3000);
    try gridWaitFor(&sess, &grid, "grep", 3000);
    try gridWaitFor(&sess, &grid, "ok 1", 3000);
    try gridWaitFor(&sess, &grid, "older", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "tools: missing file card is a real error and the follow-up still completes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_err_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/err_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "ERR_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_missing", .name = "read_file", .args = "{\"path\":\"does_not_exist.txt\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "ERROR_DONE follow-up completed");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("read the missing file");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "does_not_exist.txt", 10000);
    try gridWaitFor(&sess, &grid, "error: not found", 8000);
    try gridWaitFor(&sess, &grid, "ERROR_DONE follow-up completed", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(!grid.contains("ok 1 · err 0"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "error: not found: does_not_exist.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"tool\"") != null);

    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "ok 0 · err 1", 5000);
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "older", 5000);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "approval: edit_file stages a diff, approve applies to buffer, save and undo behave" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/appr.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "ALPHA old marker\nsecond line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_appr", .name = "edit_file", .args = "{\"path\":\"appr.txt\",\"old_string\":\"old marker\",\"new_string\":\"NEW marker\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "APPROVAL_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "ALPHA old marker", 5000);
    try expectNoDirtyMarker(&grid);

    try aiEnterRail(&sess, &grid);
    try sess.send("edit the marker");
    try sess.send("\r");

    // The agent request produced a staged review, not a write: Changes badge
    // and a real diff are visible before anything is applied.
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "-1 +1", 5000);
    try gridWaitFor(&sess, &grid, "- ALPHA old marker", 5000);
    try gridWaitFor(&sess, &grid, "+ ALPHA NEW marker", 5000);
    try gridWaitFor(&sess, &grid, "approve", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try expectNoDirtyMarker(&grid);

    const disk_before = try absFileText(io, alloc, editor);
    defer alloc.free(disk_before);
    try std.testing.expectEqualStrings("ALPHA old marker\nsecond line\n", disk_before);

    // Chat card: approval required, staged (never a fake success). The
    // follow-up text also arrives while the review is still pending.
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "edit_file", 8000);
    try gridWaitFor(&sess, &grid, "approval required", 8000);
    try gridWaitFor(&sess, &grid, "staged · review", 5000);
    try gridWaitFor(&sess, &grid, "APPROVAL_DONE follow-up", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // The follow-up tool result is truthful: staged, NOT applied.
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "approval required: edit_file staged for review; not applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"tool\"") != null);

    // Back to Changes; approve. The buffer changes (dirty), the file on disk
    // does not.
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "approve", 4000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try gridWaitFor(&sess, &grid, "ALPHA NEW marker", 5000);
    try std.testing.expect(grid.contains("\u{25cf}"));
    const disk_after_approve = try absFileText(io, alloc, editor);
    defer alloc.free(disk_after_approve);
    try std.testing.expectEqualStrings("ALPHA old marker\nsecond line\n", disk_after_approve);

    // `u` undoes the whole staged replacement (ONE undo group), redo brings
    // it back, then `:w` is the separate, user-driven disk write.
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "ALPHA old marker", 5000);
    try std.testing.expect(!grid.contains("ALPHA NEW marker"));
    try sess.send("\x12"); // Ctrl+r redo
    try gridWaitFor(&sess, &grid, "ALPHA NEW marker", 5000);
    try sess.send(":w\r");
    try gridWaitFor(&sess, &grid, "written:", 5000);

    const disk_after_save = try absFileText(io, alloc, editor);
    defer alloc.free(disk_after_save);
    try std.testing.expectEqualStrings("ALPHA NEW marker\nsecond line\n", disk_after_save);

    // Metrics count the staged call once, and the approval as its success.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "ok 1 · err 0 · appr 1", 5000);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    try aiQuit(&sess);
}

test "approval: reject (including its hint) leaves buffer, file and history untouched" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_rej_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/reject.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "KEEP untouched line\nsecond line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_rej", .name = "edit_file", .args = "{\"path\":\"reject.txt\",\"old_string\":\"untouched\",\"new_string\":\"MUTATED\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "REJECT_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("edit then reject");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "- KEEP untouched line", 5000);
    try gridWaitFor(&sess, &grid, "+ KEEP MUTATED line", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);

    // The Chat card truthfully says approval required; it is not a success.
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "approval required", 8000);
    try gridWaitFor(&sess, &grid, "REJECT_DONE follow-up", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try expectNoDirtyMarker(&grid);

    // Back to Changes; reject through the drawn hint label (same path as r).
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "approve", 5000);
    // Capture the button cell BEFORE hint labels overwrite its first glyph.
    const reject_cell = aiFindCell(&grid, "[r] reject") orelse {
        std.debug.print("approval reject: no reject button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, reject_cell.row, reject_cell.col, want);
    if (label.len != want) {
        std.debug.print("approval reject: no hint label ({d}/{d})\n", .{ label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 4000);
    try std.testing.expect(!grid.contains("MUTATED"));
    try expectNoDirtyMarker(&grid);

    // The card is rejected, not silently forgotten; undo has nothing to undo.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "rejected", 5000);
    try expectNoDirtyMarker(&grid);
    // The rejection is a real decision in metrics (not an executed call).
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "ok 0 · err 0 · appr 1 · denied 1", 5000);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 3000);
    try std.testing.expect(!grid.contains("MUTATED"));

    const on_disk = try absFileText(io, alloc, editor);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("KEEP untouched line\nsecond line\n", on_disk);

    try aiQuit(&sess);
}

test "approval: stale buffer change refuses apply and keeps the diff reviewable" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_stale_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/stale.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one original\nsecond original\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_stale", .name = "edit_file", .args = "{\"path\":\"stale.txt\",\"old_string\":\"one original\",\"new_string\":\"REPLACED\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "STALE_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "one original", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("stage then edit");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "+ REPLACED", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);

    // Leave the review, edit the target buffer (revision + text change).
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("iX\x1b");
    try gridWaitFor(&sess, &grid, "Xone original", 5000);

    // Returning to Changes and approving must refuse, not corrupt.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "stale edit", 5000);
    try gridWaitFor(&sess, &grid, "changes 1", 3000);
    try std.testing.expect(grid.contains("Xone original"));
    // The staged diff stays reviewable, but its +REPLACED line lives in the
    // rail only; the editor's changed buffer was not overwritten.
    const preview = aiFindCell(&grid, "REPLACED") orelse return error.TestUnexpectedResult;
    try std.testing.expect(preview.col >= aiRailCol(120));

    // Reject is still available and leaves the user's edit intact.
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "Xone original", 3000);
    try std.testing.expect(!grid.contains("REPLACED"));

    const on_disk = try absFileText(io, alloc, editor);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("one original\nsecond original\n", on_disk);

    try aiQuit(&sess);
}

test "approval: 80x24 drawer diff/buttons fit and the approve hint applies" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_80_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/small.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "tiny old line\nsecond\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_80", .name = "edit_file", .args = "{\"path\":\"small.txt\",\"old_string\":\"tiny old\",\"new_string\":\"tiny NEW\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "SMALL_APPROVAL_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 24, 80, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "tiny old line", 5000);

    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try sess.send("stage at 80");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "+ tiny NEW line", 5000);
    try gridWaitFor(&sess, &grid, "[a] approve", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try frame.expectNoHorizontalOverflow(&grid, 80);

    // Hint labels are drawn on the review buttons; capture the cell first,
    // then activating the approve label uses the same path as `a`.
    const approve_cell = aiFindCell(&grid, "[a] approve") orelse {
        std.debug.print("approval 80: no approve button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, approve_cell.row, approve_cell.col, want);
    if (label.len != want) {
        std.debug.print("approval 80: no approve label ({d}/{d})\n", .{ label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "tiny NEW line", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try std.testing.expect(!grid.contains("HINTS ·"));
    try frame.expectNoHorizontalOverflow(&grid, 80);

    try aiQuit(&sess);
}

test "approval: second write while pending is refused; pending survives a thread switch" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_one_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/one.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "first old line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // Thread 1's client: request 1 stages, request 2 is the follow-up text,
    // request 3 is the (refused) second write, request 4 is its follow-up.
    const stage1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_one", .name = "edit_file", .args = "{\"path\":\"one.txt\",\"old_string\":\"first old\",\"new_string\":\"first ONE\"}" },
    });
    defer alloc.free(stage1);
    try aiWriteFile(io, dir, "stream-1.sse", stage1);
    const text2 = try aiTextSse(alloc, "FIRST_DONE");
    defer alloc.free(text2);
    try aiWriteFile(io, dir, "stream-2.sse", text2);
    const stage3 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_two", .name = "edit_file", .args = "{\"path\":\"one.txt\",\"old_string\":\"first old\",\"new_string\":\"second TWO\"}" },
    });
    defer alloc.free(stage3);
    try aiWriteFile(io, dir, "stream-3.sse", stage3);
    const text4 = try aiTextSse(alloc, "SECOND_DONE");
    defer alloc.free(text4);
    try aiWriteFile(io, dir, "stream-4.sse", text4);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "first old line", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("stage the first edit");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "idle", 10000);

    // Chat tab + Enter attaches the prompt; the second edit is refused, not
    // queued, and the first diff is untouched.
    try sess.send("c");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "❯ ", 3000);
    try sess.send("try a second edit");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "resolve the pending edit", 10000);
    try gridWaitFor(&sess, &grid, "SECOND_DONE", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(grid.contains("changes 1"));
    try std.testing.expect(!grid.contains("second TWO"));

    // A new thread hides the review (badge 0) but does not lose it.
    try sess.send("\t");
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try sess.send("\t");
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);

    // Return to thread 1 and approve the surviving diff.
    try sess.send("k");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "❯ ", 3000);
    try sess.send("\t");
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "changes 1", 5000);
    try gridWaitFor(&sess, &grid, "approve", 5000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "first ONE line", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try std.testing.expect(!grid.contains("second TWO"));

    try aiQuit(&sess);
}

test "approval: apply_patch stages while an unknown tool stays unsupported" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_unsup_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/unsup.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "UNSUP editor marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const patch_args = try aiPatchArgs(alloc,
        \\--- a/unsup.txt
        \\+++ b/unsup.txt
        \\@@ -1 +1 @@
        \\-UNSUP editor marker
        \\+UNSUP STAGED marker
        \\
    );
    defer alloc.free(patch_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch", .name = "apply_patch", .args = patch_args },
        .{ .id = "call_unknown", .name = "mystery", .args = "{}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "BLOCKED_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("try the blocked tools");
    try sess.send("\r");

    // apply_patch is now a real staged review; the other two never execute.
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "- UNSUP editor marker", 5000);
    try gridWaitFor(&sess, &grid, "+ UNSUP STAGED marker", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try std.testing.expect(!grid.contains("HACKED"));
    try expectNoDirtyMarker(&grid);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "apply_patch", 8000);
    try gridWaitFor(&sess, &grid, "mystery", 8000);
    try gridWaitFor(&sess, &grid, "approval required", 8000);
    try gridWaitFor(&sess, &grid, "unsupported", 8000);
    try gridWaitFor(&sess, &grid, "BLOCKED_DONE", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "approval required: apply_patch staged for review; not applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "unsupported tool: mystery") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_patch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_unknown\"") != null);

    // Nothing touched the file or the buffer before a human decision.
    const before = try absFileText(io, alloc, editor);
    defer alloc.free(before);
    try std.testing.expectEqualStrings("UNSUP editor marker\n", before);
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "[r] reject", 5000);
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try gridWaitFor(&sess, &grid, "UNSUP editor marker", 4000);
    try std.testing.expect(!grid.contains("STAGED"));
    try expectNoDirtyMarker(&grid);

    // Rejected patch + unsupported unknown both show real metrics.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "2 calls", 5000);
    try gridWaitFor(&sess, &grid, "apply_patch", 3000);
    try gridWaitFor(&sess, &grid, "mystery", 3000);
    try gridWaitFor(&sess, &grid, "appr 1", 3000);
    try gridWaitFor(&sess, &grid, "denied 1", 3000);
    try gridWaitFor(&sess, &grid, "unsup 1", 3000);

    const after = try absFileText(io, alloc, editor);
    defer alloc.free(after);
    try std.testing.expectEqualStrings("UNSUP editor marker\n", after);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: stages approval, runs nothing before allow, then executes and follows up" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_run_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "TERM_EDITOR_ORIGINAL\n");
    }
    var ran_buf: [220:0]u8 = undefined;
    const ran = try bufPrintZ(&ran_buf, "{s}/ran.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const command = "printf 'TERM_OUTPUT_OK\\n'; printf RAN > ran.txt";
    const args = try aiTerminalArgs(alloc, command, null);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_ok", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "TERMINAL_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "TERM_EDITOR_ORIGINAL", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("run the terminal tool");
    try sess.send("\r");

    // Approval surface: command, timeout and explicit buttons. No process has
    // been spawned and the editor file is untouched.
    try gridWaitFor(&sess, &grid, "approval required", 10000);
    try gridWaitFor(&sess, &grid, "terminal · approval required", 5000);
    try gridWaitFor(&sess, &grid, "[a] allow", 5000);
    try gridWaitFor(&sess, &grid, "your permissions · not sandboxed", 5000);
    try gridWaitFor(&sess, &grid, "printf", 5000);
    try gridWaitFor(&sess, &grid, "timeout 5000ms", 5000);
    // The thread stays parked on the approval (status `approval…`), not idle,
    // and no follow-up request may be sent before the human decides.
    try gridWaitFor(&sess, &grid, "approval…", 5000);
    try std.testing.expect(!aiFileExists(io, ran));
    const before = try absFileText(io, alloc, editor);
    defer alloc.free(before);
    try std.testing.expectEqualStrings("TERM_EDITOR_ORIGINAL\n", before);
    try frame.expectNoHorizontalOverflow(&grid, 120);

    // Explicit allow -> background command -> real output + exit status.
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · ok", 8000);
    try gridWaitFor(&sess, &grid, "TERM_OUTPUT_OK", 8000);
    try gridWaitFor(&sess, &grid, "exit 0", 5000);
    try gridWaitFor(&sess, &grid, "idle", 8000);
    try std.testing.expect(aiFileExists(io, ran));

    // The model follow-up carries the real tool result (Chat tab).
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "TERMINAL_FOLLOWUP_DONE", 10000);
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_term_ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "exit: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "TERM_OUTPUT_OK") != null);

    const after = try absFileText(io, alloc, editor);
    defer alloc.free(after);
    try std.testing.expectEqualStrings("TERM_EDITOR_ORIGINAL\n", after);

    // Chat card carries the same real status; Tools tab counts the call and
    // its real duration.
    try gridWaitFor(&sess, &grid, "exit 0 · TERM_OUTPUT_OK", 5000);
    try gridWaitFor(&sess, &grid, "ok ", 3000);
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "1 calls", 5000);
    try gridWaitFor(&sess, &grid, "ok 1", 5000);
    try gridWaitFor(&sess, &grid, "avg ", 5000);
    try frame.expectNoHorizontalOverflow(&grid, 120);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: deny spawns no process, reports rejected and metrics" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_deny_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "DENY_EDITOR_MARKER\n");
    }
    var side_buf: [220:0]u8 = undefined;
    const side = try bufPrintZ(&side_buf, "{s}/deny_side.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "printf NOPE > deny_side.txt", 2500);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_deny", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "DENY_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "DENY_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("stage a denied terminal command");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "terminal · approval required", 10000);
    try gridWaitFor(&sess, &grid, "[a] allow", 5000);
    try gridWaitFor(&sess, &grid, "timeout 2500ms", 5000);
    try std.testing.expect(!aiFileExists(io, side));

    try sess.send("r");
    try gridWaitFor(&sess, &grid, "terminal · rejected", 5000);
    try gridWaitFor(&sess, &grid, "denied · not executed", 5000);
    try std.testing.expect(!aiFileExists(io, side));
    const disk = try absFileText(io, alloc, editor);
    defer alloc.free(disk);
    try std.testing.expectEqualStrings("DENY_EDITOR_MARKER\n", disk);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "DENY_FOLLOWUP_DONE", 10000);
    try gridWaitFor(&sess, &grid, "rejected", 5000);
    try gridWaitFor(&sess, &grid, "denied · not executed", 3000);
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_term_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "denied: user rejected the command; not executed") != null);

    try sess.send("t");
    try gridWaitFor(&sess, &grid, "1 calls", 5000);
    try gridWaitFor(&sess, &grid, "denied 1", 5000);
    try std.testing.expect(!grid.contains("TERM_OUTPUT"));

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: failing command reports the real exit code and error result" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_fail_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "FAIL_EDITOR_MARKER\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "printf 'FAIL_OUT\\n'; exit 7", null);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_fail", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "FAIL_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "FAIL_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("run a failing command");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "[a] allow", 10000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · error", 8000);
    try gridWaitFor(&sess, &grid, "exit 7", 5000);
    try gridWaitFor(&sess, &grid, "FAIL_OUT", 5000);
    try gridWaitFor(&sess, &grid, "idle", 8000);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "FAIL_FOLLOWUP_DONE", 10000);
    try gridWaitFor(&sess, &grid, "exit 7 · FAIL_OUT", 5000);
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "error: exit code 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "FAIL_OUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_term_fail\"") != null);

    try sess.send("t");
    try gridWaitFor(&sess, &grid, "err 1", 5000);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: timeout kills the process group, bounded, no late side effect" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_timeout_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "TIMEOUT_EDITOR_MARKER\n");
    }
    var late_buf: [220:0]u8 = undefined;
    const late = try bufPrintZ(&late_buf, "{s}/late.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // The delayed write runs in a background subshell in the same process
    // group, so killing only the shell would still create `late.txt`.
    const args = try aiTerminalArgs(alloc, "(sleep 1; printf LATE > late.txt) & wait", 150);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_timeout", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "TIMEOUT_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "TIMEOUT_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("run until the deadline");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "timeout 150ms", 10000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · error", 4000);
    try gridWaitFor(&sess, &grid, "timeout · killed", 4000);
    try gridWaitFor(&sess, &grid, "idle", 8000);
    // If only the shell had died, the background subshell would write this
    // after ~1s; the group kill must prevent it.
    std.Io.sleep(io, .fromMilliseconds(1300), .real) catch {};
    try std.testing.expect(!aiFileExists(io, late));

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "TIMEOUT_FOLLOWUP_DONE", 10000);
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "timeout; process group killed") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_term_timeout\"") != null);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: output is capped at 64 KiB with a truthful truncation marker" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_cap_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "CAP_EDITOR_MARKER\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "yes TRUNCLINE | head -c 70000", 8000);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_cap", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "CAP_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "CAP_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("flood the terminal tool output");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "[a] allow", 10000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · ok", 8000);
    try gridWaitFor(&sess, &grid, "output truncated", 5000);
    try gridWaitFor(&sess, &grid, "idle", 8000);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "CAP_FOLLOWUP_DONE", 10000);
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(req2.len < 80 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, req2, "output_truncated:") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "bytes dropped") != null);
    // The protocol's own 64 KiB cap may append its generic marker after our
    // detailed header/marker; either truthful form is accepted.
    try std.testing.expect(std.mem.indexOf(u8, req2, "[truncated]") != null or
        std.mem.indexOf(u8, req2, "[output truncated:") != null);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: hint allow and mouse deny use the real approval path" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_hint_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "HINT_EDITOR_MARKER\n");
    }
    var denied_buf: [220:0]u8 = undefined;
    const denied = try bufPrintZ(&denied_buf, "{s}/mouse_deny.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args1 = try aiTerminalArgs(alloc, "printf 'HINT_APPROVE_OK\\n'", null);
    defer alloc.free(args1);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_hint", .name = "terminal", .args = args1 },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "HINT_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const args3 = try aiTerminalArgs(alloc, "printf NOPE > mouse_deny.txt", null);
    defer alloc.free(args3);
    const round3 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_mouse", .name = "terminal", .args = args3 },
    });
    defer alloc.free(round3);
    try aiWriteFile(io, dir, "stream-3.sse", round3);
    const round4 = try aiTextSse(alloc, "MOUSE_FOLLOWUP_DONE");
    defer alloc.free(round4);
    try aiWriteFile(io, dir, "stream-4.sse", round4);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "HINT_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("first terminal command");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "[a] allow", 10000);
    const allow_cell = aiFindCell(&grid, "[a] allow") orelse return error.TestUnexpectedResult;
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, allow_cell.row, allow_cell.col, want);
    if (label.len != want) {
        std.debug.print("terminal hint: no allow label ({d}/{d})\n", .{ label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "terminal · ok", 8000);
    try gridWaitFor(&sess, &grid, "exit 0", 8000);
    try gridWaitFor(&sess, &grid, "idle", 8000);
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "HINT_FOLLOWUP_DONE", 10000);

    // Second turn: Enter attaches the prompt (the rail owns printable keys),
    // then click the real Deny target with the mouse.
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "❯ ", 3000);
    try sess.send("second terminal command");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "terminal · approval required", 10000);
    try gridWaitFor(&sess, &grid, "[r] deny", 5000);
    const deny_cell = aiFindCell(&grid, "[r] deny") orelse return error.TestUnexpectedResult;
    try mouseClickAt(&sess, deny_cell.col + 3, deny_cell.row);
    try gridWaitFor(&sess, &grid, "terminal · rejected", 5000);
    try gridWaitFor(&sess, &grid, "denied · not executed", 5000);
    try std.testing.expect(!aiFileExists(io, denied));
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "MOUSE_FOLLOWUP_DONE", 10000);
    try gridWaitFor(&sess, &grid, "rejected", 5000);
    try frame.expectNoHorizontalOverflow(&grid, 120);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: 80x24 drawer approval fits and keyboard deny leaves no process" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_80_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "DRAWER_TERM_MARKER\n");
    }
    var side_buf: [220:0]u8 = undefined;
    const side = try bufPrintZ(&side_buf, "{s}/drawer_side.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "printf NOPE > drawer_side.txt", 3000);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_80", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "DRAWER_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 24, 80, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "DRAWER_TERM_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("drawer terminal");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "terminal · approval required", 10000);
    try gridWaitFor(&sess, &grid, "[a] allow", 5000);
    try gridWaitFor(&sess, &grid, "timeout 3000ms", 5000);
    try frame.expectNoHorizontalOverflow(&grid, 80);

    try sess.send("r");
    try gridWaitFor(&sess, &grid, "terminal · rejected", 5000);
    try gridWaitFor(&sess, &grid, "denied · not executed", 5000);
    try std.testing.expect(!aiFileExists(io, side));
    try frame.expectNoHorizontalOverflow(&grid, 80);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "DRAWER_FOLLOWUP_DONE", 10000);

    // Drawer mode: Esc closes the overlay and returns to the editor.
    try sess.send("\x1b");
    std.Io.sleep(io, .fromMilliseconds(250), .real) catch {};
    try aiQuit(&sess);
}

test "terminal: Ctrl+c kills a running command and sends no follow-up" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_ctrlc_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "CTRLC_EDITOR_MARKER\n");
    }
    var late_buf: [220:0]u8 = undefined;
    const late = try bufPrintZ(&late_buf, "{s}/ctrl_late.txt", .{root});
    var req2_buf: [260]u8 = undefined;
    const req2_path = try std.fmt.bufPrint(&req2_buf, "{s}/request-2.json", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "(sleep 1; printf LATE > ctrl_late.txt) & wait", 10000);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_ctrlc", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "CTRLC_FOLLOWUP_SHOULD_NOT_APPEAR");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "CTRLC_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("start then ctrl+c");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "[a] allow", 10000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · running", 5000);
    try sess.send("\x03");
    try gridWaitFor(&sess, &grid, "terminal · cancelled", 5000);
    try gridWaitFor(&sess, &grid, "cancelled · command stopped", 5000);
    std.Io.sleep(io, .fromMilliseconds(1300), .real) catch {};
    try std.testing.expect(!aiFileExists(io, late));
    const dir_req2 = req2_path; // keep the path construction explicit
    _ = dir_req2;
    try std.testing.expect(!pathExists(io, req2_path));
    try std.testing.expect(!grid.contains("CTRLC_FOLLOWUP_SHOULD_NOT_APPEAR"));

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: thread switch kills a running command; no result crosses threads" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_switch_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "SWITCH_EDITOR_MARKER\n");
    }
    var late_buf: [220:0]u8 = undefined;
    const late = try bufPrintZ(&late_buf, "{s}/switch_late.txt", .{root});
    var req2_buf: [260]u8 = undefined;
    const req2_path = try std.fmt.bufPrint(&req2_buf, "{s}/request-2.json", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "(sleep 1; printf LATE > switch_late.txt) & wait", 10000);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_switch", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "SWITCH_FOLLOWUP_SHOULD_NOT_APPEAR");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "SWITCH_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("start then leave");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "[a] allow", 10000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "terminal · running", 5000);
    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    // Thread 2's Terminal tab is empty, not the other thread's result.
    // A new thread focuses the prompt; Tab returns to the thread list.
    try sess.send("\t");
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "no pending terminal command", 5000);
    try std.testing.expect(!grid.contains("running…"));
    std.Io.sleep(io, .fromMilliseconds(1300), .real) catch {};
    try std.testing.expect(!aiFileExists(io, late));
    try std.testing.expect(!pathExists(io, req2_path));

    // Back to thread 1: the frozen card says cancelled, and no follow-up ran.
    try sess.send("k");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    // Selecting a thread focuses its prompt/Chat; re-open the Terminal tab.
    try sess.send("\t");
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "terminal · cancelled", 5000);
    try gridWaitFor(&sess, &grid, "cancelled · command stopped", 5000);
    try std.testing.expect(!grid.contains("SWITCH_FOLLOWUP_SHOULD_NOT_APPEAR"));

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "terminal: a pending approval survives a thread switch and is still denyable" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_term_pending_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/term.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "PENDING_EDITOR_MARKER\n");
    }
    var side_buf: [220:0]u8 = undefined;
    const side = try bufPrintZ(&side_buf, "{s}/pending_side.txt", .{root});

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = try aiTerminalArgs(alloc, "printf NOPE > pending_side.txt", 4000);
    defer alloc.free(args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_term_pending", .name = "terminal", .args = args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "PENDING_FOLLOWUP_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "PENDING_EDITOR_MARKER", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("stage and switch away");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "terminal · approval required", 10000);
    try std.testing.expect(!aiFileExists(io, side));

    try sess.send("n");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try sess.send("\t");
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "no pending terminal command", 5000);
    try sess.send("k");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "thread 1", 5000);
    try sess.send("\t");
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "terminal · approval required", 5000);
    try gridWaitFor(&sess, &grid, "[a] allow", 5000);
    try std.testing.expect(!aiFileExists(io, side));

    try sess.send("r");
    try gridWaitFor(&sess, &grid, "terminal · rejected", 5000);
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "PENDING_FOLLOWUP_DONE", 10000);
    try std.testing.expect(!aiFileExists(io, side));

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "approval: apply_patch stages, approve patches the buffer, undo and :w behave" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/patch.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha one\nbeta two\ngamma three\ndelta four\nepsilon five\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const patch_args = try aiPatchArgs(alloc,
        \\--- a/patch.txt
        \\+++ b/patch.txt
        \\@@ -1,2 +1,2 @@
        \\ alpha one
        \\-beta two
        \\+BETA two
        \\@@ -4,2 +4,2 @@
        \\ delta four
        \\-epsilon five
        \\+EPSILON five
        \\
    );
    defer alloc.free(patch_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch_appr", .name = "apply_patch", .args = patch_args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "PATCH_APPROVAL_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "alpha one", 5000);
    try expectNoDirtyMarker(&grid);

    try aiEnterRail(&sess, &grid);
    try sess.send("patch the file");
    try sess.send("\r");

    // Review, never a write: both hunks are shown and the buffer/file are
    // untouched until the human approves.
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "-2 +2", 5000);
    try gridWaitFor(&sess, &grid, "- beta two", 5000);
    try gridWaitFor(&sess, &grid, "+ BETA two", 5000);
    try gridWaitFor(&sess, &grid, "- epsilon five", 5000);
    try gridWaitFor(&sess, &grid, "+ EPSILON five", 5000);
    try gridWaitFor(&sess, &grid, "approve", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try expectNoDirtyMarker(&grid);

    const disk_before = try absFileText(io, alloc, editor);
    defer alloc.free(disk_before);
    try std.testing.expectEqualStrings("alpha one\nbeta two\ngamma three\ndelta four\nepsilon five\n", disk_before);

    // Chat card: approval required and the staged tool result. The follow-up
    // stream already told the model "not applied".
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "apply_patch", 8000);
    try gridWaitFor(&sess, &grid, "approval required", 8000);
    try gridWaitFor(&sess, &grid, "staged · review", 5000);
    try gridWaitFor(&sess, &grid, "PATCH_APPROVAL_DONE follow-up", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);

    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "approval required: apply_patch staged for review; not applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"role\":\"tool\"") != null);

    // Approve: the whole patch becomes ONE buffer change (dirty), the file on
    // disk still waits for the user's `:w`.
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "approve", 4000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try gridWaitFor(&sess, &grid, "BETA two", 5000);
    try gridWaitFor(&sess, &grid, "EPSILON five", 5000);
    try std.testing.expect(grid.contains("\u{25cf}"));
    const disk_after_approve = try absFileText(io, alloc, editor);
    defer alloc.free(disk_after_approve);
    try std.testing.expectEqualStrings("alpha one\nbeta two\ngamma three\ndelta four\nepsilon five\n", disk_after_approve);

    // One `u` restores both hunks (one undo group); redo brings them back.
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "beta two", 5000);
    try std.testing.expect(!grid.contains("BETA two"));
    try std.testing.expect(!grid.contains("EPSILON five"));
    try sess.send("\x12"); // Ctrl+r redo
    try gridWaitFor(&sess, &grid, "BETA two", 5000);
    try sess.send(":w\r");
    try gridWaitFor(&sess, &grid, "written:", 5000);
    const disk_after_save = try absFileText(io, alloc, editor);
    defer alloc.free(disk_after_save);
    try std.testing.expectEqualStrings("alpha one\nBETA two\ngamma three\ndelta four\nEPSILON five\n", disk_after_save);

    // Staged call + approve decision, no fabricated latency sample.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "ok 1 · err 0 · appr 1", 5000);
    try gridWaitFor(&sess, &grid, "apply_patch", 3000);
    try gridWaitFor(&sess, &grid, "no latency samples", 3000);
    try std.testing.expect(!grid.contains("p95 "));
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    try aiQuit(&sess);
}

test "approval: apply_patch reject through its hint leaves buffer/history/file untouched" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_rej_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/reject_patch.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "KEEP untouched line\nsecond line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const patch_args = try aiPatchArgs(alloc,
        \\--- a/reject_patch.txt
        \\+++ b/reject_patch.txt
        \\@@ -1,2 +1,2 @@
        \\ KEEP untouched line
        \\-second line
        \\+MUTATED second line
        \\
    );
    defer alloc.free(patch_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch_rej", .name = "apply_patch", .args = patch_args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "PATCH_REJECT_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("patch then reject");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "-1 +1", 5000);
    try gridWaitFor(&sess, &grid, "- second line", 5000);
    try gridWaitFor(&sess, &grid, "+ MUTATED second line", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try expectNoDirtyMarker(&grid);

    try sess.send("c");
    try gridWaitFor(&sess, &grid, "approval required", 8000);
    try gridWaitFor(&sess, &grid, "PATCH_REJECT_DONE follow-up", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);

    // Reject through the drawn hint label (same path as `r`).
    try sess.send("d");
    try gridWaitFor(&sess, &grid, "[r] reject", 5000);
    const reject_cell = aiFindCell(&grid, "[r] reject") orelse {
        std.debug.print("patch reject: no reject button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, reject_cell.row, reject_cell.col, want);
    if (label.len != want) {
        std.debug.print("patch reject: no hint label ({d}/{d})\n", .{ label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "changes 0", 5000);
    try gridWaitFor(&sess, &grid, "no pending changes", 4000);
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 4000);
    try std.testing.expect(!grid.contains("MUTATED"));
    try expectNoDirtyMarker(&grid);

    // The card is rejected and metrics count a real denied decision.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("c");
    try gridWaitFor(&sess, &grid, "rejected", 5000);
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "ok 0 · err 0 · appr 1 · denied 1", 5000);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "KEEP untouched line", 3000);
    try std.testing.expect(!grid.contains("MUTATED"));

    const on_disk = try absFileText(io, alloc, editor);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("KEEP untouched line\nsecond line\n", on_disk);

    try aiQuit(&sess);
}

test "approval: stale apply_patch refuses with stale patch and keeps the diff reviewable" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_stale_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/stale_patch.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one original\nsecond original\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const patch_args = try aiPatchArgs(alloc,
        \\--- a/stale_patch.txt
        \\+++ b/stale_patch.txt
        \\@@ -1 +1 @@
        \\-one original
        \\+PATCHED one
        \\
    );
    defer alloc.free(patch_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch_stale", .name = "apply_patch", .args = patch_args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "PATCH_STALE_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "one original", 5000);

    try aiEnterRail(&sess, &grid);
    try sess.send("stage a patch then edit");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "+ PATCHED one", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);

    // Leave the review and edit the target buffer; revision + full text no
    // longer match the staging snapshot.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("iX\x1b");
    try gridWaitFor(&sess, &grid, "Xone original", 5000);

    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "stale patch", 5000);
    try gridWaitFor(&sess, &grid, "changes 1", 3000);
    try std.testing.expect(grid.contains("Xone original"));
    // The patch preview lives in the rail only; the edited buffer was not
    // replaced by the staged result.
    const preview = aiFindCell(&grid, "PATCHED one") orelse return error.TestUnexpectedResult;
    try std.testing.expect(preview.col >= aiRailCol(120));

    try sess.send("r");
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "Xone original", 3000);
    try std.testing.expect(!grid.contains("PATCHED one"));

    const on_disk = try absFileText(io, alloc, editor);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("one original\nsecond original\n", on_disk);

    try aiQuit(&sess);
}

test "approval: 80x24 apply_patch drawer diff/buttons fit and the approve hint applies" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_80_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/small_patch.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "tiny old line\nsecond\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const patch_args = try aiPatchArgs(alloc,
        \\--- a/small_patch.txt
        \\+++ b/small_patch.txt
        \\@@ -1,2 +1,2 @@
        \\-tiny old line
        \\+tiny NEW line
        \\ second
        \\
    );
    defer alloc.free(patch_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch_80", .name = "apply_patch", .args = patch_args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "SMALL_PATCH_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 24, 80, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "tiny old line", 5000);

    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try sess.send("stage a patch at 80");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 10000);
    try gridWaitFor(&sess, &grid, "+ tiny NEW line", 5000);
    try gridWaitFor(&sess, &grid, "[a] approve", 5000);
    try gridWaitFor(&sess, &grid, "idle", 10000);
    try frame.expectNoHorizontalOverflow(&grid, 80);

    const approve_cell = aiFindCell(&grid, "[a] approve") orelse {
        std.debug.print("patch 80: no approve button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, approve_cell.row, approve_cell.col, want);
    if (label.len != want) {
        std.debug.print("patch 80: no approve label ({d}/{d})\n", .{ label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "tiny NEW line", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try std.testing.expect(!grid.contains("HINTS ·"));
    try frame.expectNoHorizontalOverflow(&grid, 80);

    try aiQuit(&sess);
}

test "approval: malformed or missing-target apply_patch calls never stage" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_appr_patch_bad_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/guard.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "guard line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const multi_args = try aiPatchArgs(alloc,
        \\--- a/guard.txt
        \\+++ b/guard.txt
        \\@@ -1 +1 @@
        \\-guard line
        \\+GUARD
        \\--- a/other.txt
        \\+++ b/other.txt
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\
    );
    defer alloc.free(multi_args);
    const mismatch_args = try aiPatchArgs(alloc,
        \\--- a/guard.txt
        \\+++ b/guard.txt
        \\@@ -1 +1 @@
        \\-wrong line
        \\+GUARD
        \\
    );
    defer alloc.free(mismatch_args);
    const missing_args = try aiPatchArgs(alloc,
        \\--- a/missing.txt
        \\+++ b/missing.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    );
    defer alloc.free(missing_args);
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_patch_multi", .name = "apply_patch", .args = multi_args },
        .{ .id = "call_patch_ctx", .name = "apply_patch", .args = mismatch_args },
        .{ .id = "call_patch_missing", .name = "apply_patch", .args = missing_args },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "BAD_PATCH_DONE follow-up");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("try malformed patches");
    try sess.send("\r");

    // Compact cards clip the message; the full text is asserted on the
    // follow-up request body below.
    try gridWaitFor(&sess, &grid, "multi-file patches", 10000);
    try gridWaitFor(&sess, &grid, "patch context does not", 8000);
    try gridWaitFor(&sess, &grid, "not found: missing.txt", 8000);
    try gridWaitFor(&sess, &grid, "BAD_PATCH_DONE follow-up", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try expectNoDirtyMarker(&grid);
    try std.testing.expect(!grid.contains("changes 1"));
    try std.testing.expect(!grid.contains("approval required"));

    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "error: multi-file patches are not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "error: patch context does not match guard.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "error: not found: missing.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_patch_multi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_patch_ctx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"call_patch_missing\"") != null);

    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "3 calls", 5000);
    try gridWaitFor(&sess, &grid, "ok 0 · err 3", 5000);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);

    const on_disk = try absFileText(io, alloc, editor);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("guard line\n", on_disk);

    try aiQuit(&sess);
}

test "tools: four-round bound stops execution and sends one final no-tools request" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_rounds_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/round_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "ROUND_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var round: usize = 1;
    while (round <= 4) : (round += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "stream-{d}.sse", .{round});
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "call_round_{d}", .{round});
        const sse = try aiToolCallsSse(alloc, &.{
            .{ .id = id, .name = "read_file", .args = "{\"path\":\"round_editor.txt\"}" },
        });
        defer alloc.free(sse);
        try aiWriteFile(io, dir, name, sse);
    }
    const final_sse = try aiTextSse(alloc, "ROUND_CAP final reply");
    defer alloc.free(final_sse);
    try aiWriteFile(io, dir, "stream-5.sse", final_sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("keep reading");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "ROUND_CAP final reply", 20000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(grid.contains("tool loop stopped: max rounds"));
    try std.testing.expect(!grid.contains("call_round_5"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Five requests total: 1 initial + 3 tool follow-ups + 1 final no-tools
    // (the 4th tool round is followed by the final request). No 6th request.
    var req_buf: [300]u8 = undefined;
    var last_path_buf: [512]u8 = undefined;
    const req5_path = try std.fmt.bufPrint(&last_path_buf, "{s}/request-5.json", .{dir});
    try std.testing.expect(pathExists(io, req5_path));
    const req5 = try aiReadFile(io, alloc, dir, "request-5.json");
    defer alloc.free(req5);
    try std.testing.expect(std.mem.indexOf(u8, req5, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, req5, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, req5, "\"role\":\"tool\"") != null);
    const req6_path = try std.fmt.bufPrint(&req_buf, "{s}/request-6.json", .{dir});
    try std.testing.expect(!pathExists(io, req6_path));

    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 4", 5000);
    try gridWaitFor(&sess, &grid, "ok 4 · err 0", 5000);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

/// A long text stream: enough paced chunks that a Ctrl+c after the first
/// visible token arrives before the terminator.
fn aiSlowTextSse(alloc: std.mem.Allocator, chunks: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < chunks) : (i += 1) {
        try out.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"SLOWSTREAM \"}}]}\n\n");
    }
    try out.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"SLOW_END\"}}]}\n\ndata: [DONE]\n\n");
    return out.toOwnedSlice(alloc);
}

test "tools: eight-call cap reports the overflow and sends a final no-tools request" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_calls_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/calls_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "CALL_CAP marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const args = "{\"path\":\"calls_editor.txt\"}";
    const specs = [_]AiToolSpec{
        .{ .id = "cap_1", .name = "read_file", .args = args },
        .{ .id = "cap_2", .name = "read_file", .args = args },
        .{ .id = "cap_3", .name = "read_file", .args = args },
        .{ .id = "cap_4", .name = "read_file", .args = args },
        .{ .id = "cap_5", .name = "read_file", .args = args },
        .{ .id = "cap_6", .name = "read_file", .args = args },
        .{ .id = "cap_7", .name = "read_file", .args = args },
        .{ .id = "cap_8", .name = "read_file", .args = args },
        .{ .id = "cap_9", .name = "read_file", .args = args },
    };
    const round1 = try aiToolCallsSse(alloc, &specs);
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "CALL_CAP final reply");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("read it nine times");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "CALL_CAP final reply", 20000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(grid.contains("tool loop stopped: max calls"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // The ninth call is answered truthfully but never executed; the
    // follow-up is the final no-tools request and there is no third one.
    const req2 = try aiReadFile(io, alloc, dir, "request-2.json");
    defer alloc.free(req2);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "\"tool_call_id\":\"cap_9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req2, "tool call limit (8) reached; not executed") != null);
    var req3_buf: [300]u8 = undefined;
    const req3_path = try std.fmt.bufPrint(&req3_buf, "{s}/request-3.json", .{dir});
    try std.testing.expect(!pathExists(io, req3_path));

    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 9", 5000);
    try gridWaitFor(&sess, &grid, "ok 8 · err 0 · unsup 1", 5000);
    try gridWaitFor(&sess, &grid, "older", 5000);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "tools: Ctrl+c cancels the follow-up loop; thread 2 has no cards/metrics" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_cancel_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/cancel_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "CANCEL_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_cancel", .name = "read_file", .args = "{\"path\":\"cancel_editor.txt\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiSlowTextSse(alloc, 180);
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("read then talk");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "read_file", 10000);
    try gridWaitFor(&sess, &grid, "SLOWSTREAM", 10000);
    try sess.send("\x03");
    try gridWaitFor(&sess, &grid, "cancelled", 6000);
    try gridWaitFor(&sess, &grid, "[stream cancelled]", 4000);
    // No second follow-up was issued; the cancelled stream never appends its
    // terminator or a late tool result.
    try std.testing.expect(!grid.contains("SLOW_END"));
    var req3_buf: [300]u8 = undefined;
    const req3_path = try std.fmt.bufPrint(&req3_buf, "{s}/request-3.json", .{dir});
    try std.testing.expect(!pathExists(io, req3_path));

    // New thread: empty Tools tab, no read_file card from thread 1.
    try sess.send("\x0e");
    try gridWaitFor(&sess, &grid, "thread 2", 5000);
    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "no tool calls yet", 4000);
    // The empty state legitimately names the read-only tools; cards/metrics
    // from thread 1 must not appear (no counts, no chart).
    try std.testing.expect(!grid.contains("calls 1"));
    try std.testing.expect(!grid.contains("older"));

    // Back to thread 1: the tool result/card survives, metrics are thread-1
    // only. Enter attaches to the prompt (and returns to Chat); Tab reaches
    // the thread list again before the `t` tab-switch key.
    try sess.send("k");
    try sess.send("\r");
    try sess.send("\t");
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "cancelled", 3000);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "tools: malformed tool-call protocol becomes a chat error, not a panic or card" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_bad_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/bad_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BAD_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // Valid JSON, but the tool-call entry has no `index`: the accumulator
    // rejects it and the client surfaces a typed chat error.
    try aiWriteFile(io, dir, "stream.sse", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_bad\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}\n\ndata: [DONE]\n\n");
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try aiEnterRail(&sess, &grid);
    try sess.send("trigger a bad call");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "tool call protocol", 8000);
    try gridWaitFor(&sess, &grid, "error", 5000);
    try std.testing.expect(!grid.contains("calls 1"));
    try std.testing.expect(!grid.contains("approval required"));
    var req2_buf: [300]u8 = undefined;
    const req2_path = try std.fmt.bufPrint(&req2_buf, "{s}/request-2.json", .{dir});
    try std.testing.expect(!pathExists(io, req2_path));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "tools: 80x24 drawer fits cards/chart and a hint expands the card" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_tools_80_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var fixture_buf: [220:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/drawer_fixture.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, fixture, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "TOOL_MARKER drawer first\nTOOL_SECOND drawer second\n");
    }
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/drawer_editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "DRAWER_EDITOR marker\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{
        .{ .id = "call_drawer", .name = "read_file", .args = "{\"path\":\"drawer_fixture.txt\"}" },
    });
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "DRAWER_DONE final");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 24, 80, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "thread 1", 4000);
    try sess.send("read drawer fixture");
    try sess.send("\r");

    try gridWaitFor(&sess, &grid, "read_file", 10000);
    try gridWaitFor(&sess, &grid, "TOOL_MARKER drawer first", 10000);
    try gridWaitFor(&sess, &grid, "DRAWER_DONE final", 10000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try std.testing.expect(!grid.contains("TOOL_SECOND drawer second"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Hint mode from the drawer's thread list; the card's top row keeps its
    // name visible beyond the 1–2 char label, so derive the label from the
    // drawn frame instead of hard-coding it.
    try sess.send("\t");
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const rail_col = aiRailCol(80);
    var card_row: ?usize = null;
    var r: usize = 0;
    while (r + 1 < grid.rows) : (r += 1) {
        if (std.mem.indexOf(u8, grid.rowText(r), "read_file") != null) {
            card_row = r;
            break;
        }
    }
    const row = card_row orelse {
        std.debug.print("drawer tools: no card row found\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    const count = hintTargetCount(&grid) orelse return error.TestUnexpectedResult;
    const want = hintLabelLenFor(count);
    var label_buf: [3]u8 = undefined;
    const label = hintLabelAt(&grid, &label_buf, row, rail_col + 2, want);
    if (label.len != want) {
        std.debug.print("drawer tools: no card label at ({d},{d}): {d}/{d}\n", .{ row, rail_col + 2, label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    try sess.send(label);
    try gridWaitFor(&sess, &grid, "TOOL_SECOND drawer second", 5000);
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);

    // Tools tab at 80x24: real counts + chart, still no overflow.
    try sess.send("t");
    try gridWaitFor(&sess, &grid, "calls 1", 5000);
    try gridWaitFor(&sess, &grid, "avg ", 5000);
    try gridWaitFor(&sess, &grid, "p95 ", 5000);
    try gridWaitFor(&sess, &grid, "older", 5000);
    try gridWaitFor(&sess, &grid, "now", 5000);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    try sess.send("\x1b"); // thread list -> editor (drawer closes)
    try gridWaitFor(&sess, &grid, "NORMAL", 3000);
    try aiQuit(&sess);
}

// ---------------------------------------------------------------------------
// Scenario matrix (M2.5): data-driven layout + AI workspace coverage
// ---------------------------------------------------------------------------
const frame = @import("frame.zig");
const ai_ws = @import("ai_workspace");
const nav_model = @import("navigator");

const scenario_fixture =
    "GOLDEN_EDITOR_MARKER\n" ++
    "second line for the layout matrix\n" ++
    "third line\n";

const scenario_sse =
    "data: {\"choices\":[{\"delta\":{\"content\":\"mock \"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"reply\"}}]}\n\n" ++
    "data: [DONE]\n\n";

// ---------------------------------------------------------------------------
// Inline assistant (M2b2)
// ---------------------------------------------------------------------------

fn inlineSse(alloc: std.mem.Allocator, replacement: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\ndata: [DONE]\n\n",
        .{replacement},
    );
}

fn expectNoDirtyMarker(grid: *Grid) !void {
    try std.testing.expect(!grid.contains("\u{25cf}"));
}

test "inline: selection streams a diff, approve applies one undo group" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}inlinea.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha one\nbeta two\ngamma three\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const sse = try inlineSse(alloc, "ALPHA ONE ONLY");
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "alpha one", 4000);

    // Vj selects the first two lines linewise; <leader>i opens the prompt.
    try sess.send("Vj");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "inline edit", 4000);
    try gridWaitFor(&sess, &grid, "lines 1-2", 4000);
    // Prompt is cell-exact and floats without painting the screen edges.
    const box = frame.findBoxByTitle(&grid, "inline edit") orelse {
        std.debug.print("inline prompt: no box\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    try frame.expectBorderBox(&grid, box, packRgb(0xE6, 0xC3, 0x84));
    try std.testing.expectEqual(@as(usize, 64), box.width());
    try std.testing.expectEqual(@as(usize, 6), box.height());
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Typing fills the prompt, never the buffer.
    try sess.send("uppercase these lines");
    try gridWaitFor(&sess, &grid, "uppercase these lines", 3000);
    try std.testing.expect(grid.contains("alpha one"));
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 8000);
    try gridWaitFor(&sess, &grid, "approve", 4000);
    try gridWaitFor(&sess, &grid, "- alpha one", 4000);
    try gridWaitFor(&sess, &grid, "- beta two", 4000);
    try gridWaitFor(&sess, &grid, "+ ALPHA ONE ONLY", 4000);
    try std.testing.expect(grid.contains("-2 +1"));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);
    // The replacement is only in the rail's diff; the editor still shows the
    // original line while review is pending.
    const added_cell = aiFindCell(&grid, "+ ALPHA ONE ONLY").?;
    try std.testing.expect(added_cell.col > aiRailCol(120));
    try std.testing.expect(grid.contains("alpha one"));

    const req = try aiReadFile(io, alloc, dir, "request.json");
    defer alloc.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "lines 1-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "uppercase these lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "alpha one") != null);
    // Standalone inline turn: fixed system + exactly one user message.
    try std.testing.expect(std.mem.indexOf(u8, req, "\"role\":\"assistant\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, req, "You are an inline code editor") != null);

    // Approve: buffer changes, badge clears, the whole edit is one undo group.
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "ALPHA ONE ONLY", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "no pending changes", 3000);
    try std.testing.expect(!grid.contains("- alpha one"));
    // dirty marker on the buffer tab
    try std.testing.expect(grid.contains("\u{25cf}"));
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "alpha one", 5000);
    try gridWaitFor(&sess, &grid, "beta two", 4000);
    try std.testing.expect(!grid.contains("ALPHA ONE ONLY"));
    try std.testing.expect(grid.contains("changes 0"));

    try aiQuit(&sess);
}

test "inline: reject leaves the buffer byte-identical; pending blocks a new request" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}inliner.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "keep this line\nand this one\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const sse = try inlineSse(alloc, "SHOULD NOT APPLY");
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "keep this line", 4000);
    try expectNoDirtyMarker(&grid);

    try sess.send("V");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "inline edit", 4000);
    try sess.send("rewrite");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 8000);
    try gridWaitFor(&sess, &grid, "+ SHOULD NOT APPLY", 4000);

    // One-pending policy: back to the editor, select again, <leader>i must
    // refuse and leave the existing review untouched.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("V");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "reject the pending change first", 4000);
    try std.testing.expect(!grid.contains("Enter generate"));
    try std.testing.expect(grid.contains("changes 1"));
    // Return to the review and reject it.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "no pending changes", 3000);
    try gridWaitFor(&sess, &grid, "keep this line", 3000);
    try std.testing.expect(!grid.contains("SHOULD NOT APPLY"));
    try expectNoDirtyMarker(&grid);
    // Undo has nothing to undo: the buffer stays byte-identical.
    try sess.send("u");
    try gridWaitFor(&sess, &grid, "keep this line", 3000);
    try std.testing.expect(!grid.contains("SHOULD NOT APPLY"));

    try aiQuit(&sess);
}

test "inline: stale revision refuses apply and keeps the pending diff" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}inlines.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "one original\nsecond original\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const sse = try inlineSse(alloc, "REPLACED");
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "one original", 4000);

    try sess.send("Vj");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "inline edit", 4000);
    try sess.send("replace");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 8000);
    try gridWaitFor(&sess, &grid, "+ REPLACED", 4000);

    // Edit the buffer after generation. The cursor is still on line 2.
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try sess.send("iX\x1b");
    try gridWaitFor(&sess, &grid, "Xsecond original", 4000);
    // Return to Changes and try to approve.
    try sess.send("\x17a");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), true, 3000);
    try sess.send("a");
    try gridWaitFor(&sess, &grid, "stale selection", 4000);
    // Stale keeps the diff reviewable, does not corrupt the buffer, and the
    // badge stays 1 until an explicit reject.
    try std.testing.expect(grid.contains("changes 1"));
    try gridWaitFor(&sess, &grid, "Xsecond original", 3000);
    try std.testing.expect(!grid.contains("one original\nX") and grid.contains("one original"));
    try sess.send("r");
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try gridWaitFor(&sess, &grid, "Xsecond original", 3000);
    try std.testing.expect(grid.contains("one original"));

    try aiQuit(&sess);
}

test "inline: Esc cancels an in-flight replacement without touching the buffer" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}inlinec.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "cancel original\ntrailing line\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const big = try alloc.alloc(u8, 20000);
    defer alloc.free(big);
    @memset(big, 'x');
    const sse = try inlineSse(alloc, big);
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "cancel original", 4000);

    try sess.send("V");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "inline edit", 4000);
    try sess.send("replace");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "streaming…", 5000);
    try sess.send("\x1b");
    try gridWaitFor(&sess, &grid, "inline edit cancelled", 4000);
    try gridWaitGone(&sess, &grid, "streaming…", 4000);
    try gridWaitFor(&sess, &grid, "cancel original", 3000);
    try expectNoDirtyMarker(&grid);
    try std.testing.expect(!grid.contains("replacement too large"));
    // The rail was never opened: cancel leaves no review surface. Wait for
    // the cancelled worker to finish so a late terminal event would have
    // been drained (it must not create a pending edit).
    try gridSettle(&sess, &grid, 300, 7000);
    try std.testing.expect(!grid.contains("changes 1"));
    try std.testing.expect(!grid.contains("approve"));
    try std.testing.expect(grid.contains("cancel original"));

    try aiQuit(&sess);
}

test "inline: 80x24 prompt/diff fit and approve/reject hint labels work" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}inline80.zig", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "tiny line\nsecond\n");
    }

    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const sse = try inlineSse(alloc, "SMALL CHANGE");
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{mock_env}, 24, 80);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 24, 80);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "tiny line", 4000);

    try sess.send("V");
    try sess.send(" i");
    try gridWaitFor(&sess, &grid, "inline edit", 4000);
    const box = frame.findBoxByTitle(&grid, "inline edit") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 64), box.width());
    try frame.expectBorderBox(&grid, box, packRgb(0xE6, 0xC3, 0x84));
    try frame.expectNoHorizontalOverflow(&grid, 80);
    // The float is above the status bar and inside the screen.
    try std.testing.expect(box.bottom < 23);
    try sess.send("shorten");
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "changes 1", 8000);
    try gridWaitFor(&sess, &grid, "+ SMALL CHANGE", 4000);
    try frame.expectNoHorizontalOverflow(&grid, 80);

    const approve_cell = aiFindCell(&grid, "[a] approve") orelse {
        std.debug.print("inline 80: no approve button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    const reject_cell = aiFindCell(&grid, "[r] reject") orelse {
        std.debug.print("inline 80: no reject button\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    // Hint mode from the rail: both review buttons are labeled and activate
    // through the normal hint path.
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label_buf: [3]u8 = undefined;
    const approve_label = hintLabelAt(&grid, &label_buf, approve_cell.row, approve_cell.col, want);
    if (approve_label.len != want) {
        std.debug.print("inline 80: approve label missing ({d}/{d})\n", .{ approve_label.len, want });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    var reject_buf: [3]u8 = undefined;
    const reject_label = hintLabelAt(&grid, &reject_buf, reject_cell.row, reject_cell.col, want);
    try std.testing.expectEqual(want, reject_label.len);
    try sess.send("\x1b");
    try gridWaitGone(&sess, &grid, "HINTS ·", 3000);
    // Re-enter and accept via the drawn label.
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const want2 = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var label2_buf: [3]u8 = undefined;
    const label2 = hintLabelAt(&grid, &label2_buf, approve_cell.row, approve_cell.col, want2);
    try std.testing.expectEqual(want2, label2.len);
    try sess.send(label2);
    try gridWaitFor(&sess, &grid, "SMALL CHANGE", 5000);
    try gridWaitFor(&sess, &grid, "changes 0", 4000);
    try std.testing.expect(!grid.contains("HINTS ·"));
    try frame.expectNoHorizontalOverflow(&grid, 80);

    try aiQuit(&sess);
}

const ScenarioSetup = enum { plain, ai_mock };
const ScenarioRail = enum { hidden, docked, drawer };

const ScenarioStep = struct {
    keys: []const u8,
    wait_for: ?[]const u8 = null,
    timeout_ms: i32 = 5000,
};

const Scenario = struct {
    name: []const u8,
    tags: []const []const u8,
    rows: u16,
    cols: u16,
    setup: ScenarioSetup = .plain,
    filetree: bool = false,
    /// The final frame is the resting compact icon rail (the peek was closed
    /// by a step), not the 30-cell panel. Used by <90-col scenarios.
    compact_rail: bool = false,
    rail: ScenarioRail = .hidden,
    /// Extra keystrokes after the state setup (filetree/rail/prompt).
    steps: []const ScenarioStep = &.{},
    /// Sends `prompt`, Enter, then waits for the mock stream + idle.
    prompt: ?[]const u8 = null,
    expect_text: []const []const u8 = &.{},
    expect_absent: []const []const u8 = &.{},
    /// Substrings that must be present in the mock request body.
    request_contains: []const []const u8 = &.{},
    /// Enter hint mode as the final step (prompt -> Tab -> <leader>j) and
    /// assert the overlay/status on the settled frame.
    hints: bool = false,
    /// Create a temp OZ_NOTES_DIR containing one "Scenario note" markdown
    /// file, so the Notes tab is deterministic and never touches $HOME.
    notes: bool = false,
    /// M2b2: select the first two lines, run <leader>i with this instruction,
    /// and wait for the pending-review surface (rail opens on Changes).
    inline_prompt: ?[]const u8 = null,
    /// M3a: write a fixed /tmp fixture plus tool-call round 1 and a text
    /// round 2, so the agent loop really executes read_file for this
    /// scenario (instead of a plain text stream).
    tool_fixture: bool = false,
    /// M3b1: round 1 stages an edit_file on the scenario's own opened buffer;
    /// the scenario presses `a` and expects the applied buffer.
    approval_fixture: bool = false,
    /// M3b2: round 1 stages an apply_patch on the scenario's own opened
    /// buffer; the scenario approves and expects the patched buffer.
    patch_approval_fixture: bool = false,
    /// M3b3: round 1 stages a terminal command; the scenario allows it and
    /// expects the real output/follow-up (cwd = /tmp, the fixture's root).
    terminal_fixture: bool = false,
};

/// Pairwise layout matrix: 3 widths × filetree {closed,open} × rail
/// {closed,open}, plus the two streaming sizes. 80 cols uses the drawer;
/// 100/120 use the docked rail.
const scenario_matrix = [_]Scenario{
    .{
        .name = "editor 80x24",
        .tags = &.{ "@layout", "@80col" },
        .rows = 24,
        .cols = 80,
        .expect_text = &.{"GOLDEN_EDITOR_MARKER"},
    },
    .{
        .name = "editor 100x30",
        .tags = &.{ "@layout", "@100col" },
        .rows = 30,
        .cols = 100,
        .expect_text = &.{"GOLDEN_EDITOR_MARKER"},
    },
    .{
        .name = "editor 120x30",
        .tags = &.{ "@layout", "@120col" },
        .rows = 30,
        .cols = 120,
        .expect_text = &.{"GOLDEN_EDITOR_MARKER"},
    },
    .{
        .name = "filetree 80x24",
        .tags = &.{ "@layout", "@filetree", "@80col" },
        .rows = 24,
        .cols = 80,
        .filetree = true,
        .expect_text = &.{"Files"},
    },
    .{
        .name = "navigator compact rail 80x24",
        .tags = &.{ "@layout", "@navigator", "@compact", "@80col" },
        .rows = 24,
        .cols = 80,
        .filetree = true,
        .compact_rail = true,
        .steps = &.{.{ .keys = "\x1b", .wait_for = "  OZ  " }},
        .expect_text = &.{"OZ"},
    },
    .{
        .name = "filetree 100x30",
        .tags = &.{ "@layout", "@filetree", "@100col" },
        .rows = 30,
        .cols = 100,
        .filetree = true,
        .expect_text = &.{ "Files", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "filetree 120x30",
        .tags = &.{ "@layout", "@filetree", "@120col" },
        .rows = 30,
        .cols = 120,
        .filetree = true,
        .expect_text = &.{ "Files", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai rail 80x24 drawer",
        .tags = &.{ "@layout", "@ai", "@drawer", "@80col" },
        .rows = 24,
        .cols = 80,
        .rail = .drawer,
        .expect_text = &.{ "AGENTS", "thread 1", "changes 0", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai rail 100x30 dock",
        .tags = &.{ "@layout", "@ai", "@docked", "@100col" },
        .rows = 30,
        .cols = 100,
        .rail = .docked,
        .expect_text = &.{ "AGENTS", "thread 1", "changes 0", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai rail 120x30 dock",
        .tags = &.{ "@layout", "@ai", "@docked", "@120col" },
        .rows = 30,
        .cols = 120,
        .rail = .docked,
        .expect_text = &.{ "AGENTS", "thread 1", "changes 0", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai rail + filetree 80x24",
        .tags = &.{ "@layout", "@ai", "@filetree", "@drawer", "@80col" },
        .rows = 24,
        .cols = 80,
        .filetree = true,
        .rail = .drawer,
        .expect_text = &.{ "OZ", "AGENTS", "changes 0" },
    },
    .{
        .name = "ai rail + filetree 100x30",
        .tags = &.{ "@layout", "@ai", "@filetree", "@docked", "@100col" },
        .rows = 30,
        .cols = 100,
        .filetree = true,
        .rail = .docked,
        .expect_text = &.{ "Files", "AGENTS", "changes 0", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai rail + filetree 120x30",
        .tags = &.{ "@layout", "@ai", "@filetree", "@docked", "@120col" },
        .rows = 30,
        .cols = 120,
        .filetree = true,
        .rail = .docked,
        .expect_text = &.{ "Files", "AGENTS", "changes 0", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "ai chat stream 120x30 dock",
        .tags = &.{ "@layout", "@ai", "@stream", "@docked", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .rail = .docked,
        .prompt = "hello",
        .expect_text = &.{ "mock reply", "hello", "idle" },
        .request_contains = &.{ "hello", "mock-model" },
    },
    .{
        .name = "ai chat stream 80x24 drawer",
        .tags = &.{ "@layout", "@ai", "@stream", "@drawer", "@80col" },
        .rows = 24,
        .cols = 80,
        .setup = .ai_mock,
        .rail = .drawer,
        .prompt = "hello",
        .expect_text = &.{ "mock reply", "hello", "idle" },
        .request_contains = &.{ "hello", "mock-model" },
    },
    .{
        .name = "hints 120x30 dock",
        .tags = &.{ "@layout", "@ai", "@hints", "@mouse", "@docked", "@120col" },
        .rows = 30,
        .cols = 120,
        .filetree = true,
        .rail = .docked,
        .hints = true,
        .expect_text = &.{ "HINTS", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "hints 80x24 drawer",
        .tags = &.{ "@layout", "@ai", "@hints", "@drawer", "@80col" },
        .rows = 24,
        .cols = 80,
        .filetree = true,
        .rail = .drawer,
        .hints = true,
        // The drawer + filetree leave ~16 editor cells visible, so the
        // fixture marker is clipped; "files" is covered by the box check.
        .expect_text = &.{"HINTS"},
    },
    .{
        .name = "inline edit 120x30",
        .tags = &.{ "@layout", "@ai", "@inline", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .inline_prompt = "rewrite the selected lines",
        .expect_text = &.{ "changes 1", "approve", "reject", "mock reply", "GOLDEN_EDITOR_MARKER" },
        .request_contains = &.{ "Selected text", "GOLDEN_EDITOR_MARKER", "rewrite the selected lines" },
    },
    .{
        .name = "ai tools read 120x30",
        .tags = &.{ "@layout", "@ai", "@tools", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .tool_fixture = true,
        .rail = .docked,
        .prompt = "read the scenario fixture",
        .steps = &.{
            .{ .keys = "", .wait_for = "TOOL_SCENARIO_MARKER" },
            .{ .keys = "\t", .wait_for = "thread 1" },
            .{ .keys = "t", .wait_for = "calls 1" },
        },
        // The final frame shows the Tools tab, so the card excerpt is
        // asserted by the step above (and by request_contains); the Tools
        // tab itself proves the real call count/chart.
        .expect_text = &.{ "read_file", "calls 1", "p95 ", "older" },
        .request_contains = &.{ "\"tool_choice\":\"auto\"", "\"role\":\"tool\"", "TOOL_SCENARIO_MARKER", "read_file" },
    },
    .{
        .name = "ai tools read 100x30",
        .tags = &.{ "@layout", "@ai", "@tools", "@100col" },
        .rows = 30,
        .cols = 100,
        .setup = .ai_mock,
        .tool_fixture = true,
        .rail = .docked,
        .prompt = "read the scenario fixture",
        .steps = &.{
            .{ .keys = "", .wait_for = "TOOL_SCENARIO_MARKER" },
            .{ .keys = "\t", .wait_for = "thread 1" },
            .{ .keys = "t", .wait_for = "calls 1" },
        },
        // 100 columns uses the 34-cell rail; the compact latency fallback must
        // still show p95 without clipping the labels.
        .expect_text = &.{ "read_file", "calls 1", "avg ", "p95 ", "older" },
        .request_contains = &.{ "\"tool_choice\":\"auto\"", "\"role\":\"tool\"", "TOOL_SCENARIO_MARKER", "read_file" },
    },
    .{
        .name = "ai approval 120x30",
        .tags = &.{ "@layout", "@ai", "@tools", "@approval", "@mouse", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .approval_fixture = true,
        .rail = .docked,
        .steps = &.{
            .{ .keys = "edit the approval fixture\r", .wait_for = "changes 1" },
            .{ .keys = "", .wait_for = "+ second line APPROVAL_SCENARIO_NEW" },
            .{ .keys = "", .wait_for = "idle" },
            // The card is on Chat while the review is on Changes.
            .{ .keys = "c", .wait_for = "approval required" },
            .{ .keys = "d", .wait_for = "[a] approve" },
            .{ .keys = "a", .wait_for = "changes 0" },
            // Approve returns focus to the editor; re-enter the rail before
            // switching to the Chat card.
            .{ .keys = "\x17a", .wait_for = "tools │ terminal" },
            .{ .keys = "c", .wait_for = "approved" },
        },
        .expect_text = &.{ "approved", "changes 0", "APPROVAL_SCENARIO_NEW", "GOLDEN_EDITOR_MARKER" },
        .request_contains = &.{
            "approval required: edit_file staged for review; not applied",
            "\"role\":\"tool\"",
            "edit_file",
        },
    },
    .{
        .name = "ai patch approval 120x30",
        .tags = &.{ "@layout", "@ai", "@tools", "@approval", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .patch_approval_fixture = true,
        .rail = .docked,
        .steps = &.{
            .{ .keys = "patch the approval fixture\r", .wait_for = "changes 1" },
            .{ .keys = "", .wait_for = "+ second line PATCH_SCENARIO_NEW" },
            .{ .keys = "", .wait_for = "idle" },
            .{ .keys = "c", .wait_for = "approval required" },
            .{ .keys = "d", .wait_for = "[a] approve" },
            .{ .keys = "a", .wait_for = "changes 0" },
            .{ .keys = "\x17a", .wait_for = "tools │ terminal" },
            .{ .keys = "c", .wait_for = "approved" },
            // The approved card shows the real shown-hunk counts, not a
            // fabricated success summary.
            .{ .keys = "", .wait_for = "-1 +1 · applied" },
        },
        .expect_text = &.{ "approved", "u to undo", "changes 0", "PATCH_SCENARIO_NEW", "GOLDEN_EDITOR_MARKER" },
        .request_contains = &.{
            "approval required: apply_patch staged for review; not applied",
            "\"role\":\"tool\"",
            "apply_patch",
        },
    },
    .{
        .name = "ai terminal approval 120x30",
        .tags = &.{ "@layout", "@ai", "@tools", "@approval", "@terminal", "@120col" },
        .rows = 30,
        .cols = 120,
        .setup = .ai_mock,
        .terminal_fixture = true,
        .rail = .docked,
        .steps = &.{
            .{ .keys = "run the terminal fixture\r", .wait_for = "terminal · approval required" },
            .{ .keys = "", .wait_for = "[a] allow" },
            .{ .keys = "", .wait_for = "timeout 5000ms" },
            .{ .keys = "a", .wait_for = "terminal · ok" },
            .{ .keys = "", .wait_for = "TERM_SCENARIO_MARKER" },
            .{ .keys = "", .wait_for = "idle" },
            .{ .keys = "c", .wait_for = "exit 0 · TERM_SCENARIO_MARKER" },
        },
        .expect_text = &.{ "exit 0", "TERM_SCENARIO_MARKER", "GOLDEN_EDITOR_MARKER" },
        .request_contains = &.{
            "\"role\":\"tool\"",
            "terminal",
            "TERM_SCENARIO_MARKER",
        },
    },
    .{
        .name = "navigator notes 120x30",
        .tags = &.{ "@layout", "@navigator", "@notes", "@120col" },
        .rows = 30,
        .cols = 120,
        .filetree = true,
        .notes = true,
        .steps = &.{.{ .keys = "\t", .wait_for = "Scenario note" }},
        .expect_text = &.{ "Files", "Notes", "Agents", "Scenario note", "GOLDEN_EDITOR_MARKER" },
    },
    .{
        .name = "navigator agents 100x30",
        .tags = &.{ "@layout", "@navigator", "@100col" },
        .rows = 30,
        .cols = 100,
        .filetree = true,
        .steps = &.{.{ .keys = "\t\t", .wait_for = "thread 1" }},
        .expect_text = &.{ "Files", "Notes", "Agents", "thread 1", "idle" },
    },
};

/// Every feature tag that must have at least one scenario. A new layout/AI
/// feature adds its tag here and to at least one Scenario; the coverage test
/// fails with a clear message otherwise (instead of silently dropping it).
const required_scenario_tags = [_][]const u8{
    "@layout",   "@ai",       "@filetree", "@stream", "@hints",  "@mouse",  "@navigator", "@notes", "@inline", "@tools",
    "@approval", "@terminal", "@80col",    "@100col", "@120col", "@drawer", "@docked", "@compact",
};

fn expectedRailMode(rail: ScenarioRail) ai_ws.RailMode {
    return switch (rail) {
        .hidden => .hidden,
        .docked => .docked,
        .drawer => .drawer,
    };
}

/// Read whatever is pending until the stream has been quiet for `quiet_ms`.
fn gridSettle(sess: *Session, grid: *Grid, quiet_ms: i32, timeout_ms: i32) !void {
    var waited: i32 = 0;
    var quiet: i32 = 0;
    while (waited < timeout_ms) : (waited += 50) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 50);
        if (n == 0) {
            quiet += 50;
            if (quiet >= quiet_ms) return;
            continue;
        }
        quiet = 0;
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
}

/// Navigator box without depending on its title text: hint mode labels the
/// three tabs, so "files" may be overwritten in a hint frame. The navigator
/// is the only 30-cell box starting at column 0.
fn findNavigatorBox(grid: *Grid) ?frame.Rect {
    var r: usize = 0;
    while (r + 2 < grid.rows) : (r += 1) {
        if (!std.mem.eql(u8, frame.cellText(grid, r, 0), "╭")) continue;
        const rect = frame.boxRect(grid, r) orelse continue;
        if (rect.left == 0 and rect.right == 29) return rect;
    }
    return null;
}

/// The full/peek navigator is a closed box whose header contains one
/// internal `├──┤` rule (below the tab strip). `frame.expectBorderBox` treats
/// every interior row as `│`, so assert the real structure here.
fn expectNavigatorPanel(grid: *Grid, rect: frame.Rect) !void {
    try std.testing.expectEqualStrings("╭", frame.cellText(grid, rect.top, rect.left));
    try std.testing.expectEqualStrings("╮", frame.cellText(grid, rect.top, rect.right));
    try std.testing.expectEqualStrings("╰", frame.cellText(grid, rect.bottom, rect.left));
    try std.testing.expectEqualStrings("╯", frame.cellText(grid, rect.bottom, rect.right));
    const rule_row = rect.top + nav_model.full_header_rows - 1;
    var r = rect.top + 1;
    while (r < rect.bottom) : (r += 1) {
        const want_left = if (r == rule_row) "├" else "│";
        const want_right = if (r == rule_row) "┤" else "│";
        try std.testing.expectEqualStrings(want_left, frame.cellText(grid, r, rect.left));
        try std.testing.expectEqualStrings(want_right, frame.cellText(grid, r, rect.right));
    }
}

fn assertScenario(sc: Scenario, grid: *Grid) !void {
    try std.testing.expectEqual(@as(usize, sc.rows), grid.rows);
    try std.testing.expectEqual(@as(usize, sc.cols), grid.cols);

    const cols: u32 = sc.cols;
    const rows: u32 = sc.rows;
    // A completed inline edit opens the rail on the Changes tab, so the
    // settled frame's rail state is derived from the terminal width.
    const final_rail: ScenarioRail = if (sc.inline_prompt != null)
        (if (cols < 90) .drawer else .docked)
    else
        sc.rail;
    const lay = ai_ws.layout(cols, final_rail != .hidden);
    try std.testing.expectEqual(expectedRailMode(final_rail), lay.mode);

    // Layout algebra: the rail and editor partition the width exactly.
    if (lay.mode == .docked) {
        // editor + blank gutter + rail partitions the screen.
        try std.testing.expectEqual(cols, lay.editor_width + lay.rail_gutter + lay.rail_width);
        try std.testing.expectEqual(cols, lay.rail_col + lay.rail_width);
        try std.testing.expectEqual(lay.editor_width + lay.rail_gutter, lay.rail_col);
        try std.testing.expectEqual(@as(u32, 1), lay.rail_gutter);
    } else if (lay.mode == .drawer) {
        try std.testing.expectEqual(cols, lay.editor_width);
        try std.testing.expectEqual(cols, lay.rail_col + lay.rail_width);
        try std.testing.expect(lay.rail_width <= cols);
        try std.testing.expect(lay.rail_col >= 8);
        try std.testing.expectEqual(@as(u32, 1), lay.rail_gutter);
    } else {
        try std.testing.expectEqual(cols, lay.editor_width);
        try std.testing.expectEqual(@as(u32, 0), lay.rail_width);
    }

    if (sc.filetree and cols >= nav_model.full_min_cols) {
        // One blank column separates the 30-cell navigator box from editor
        // content; the editor's first text cell is at column 31.
        try frame.expectCellBg(grid, 1, 30, aiEditorBg());
        try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, frame.cellText(grid, 1, 30), " ").len);
        try std.testing.expect(std.mem.trim(u8, frame.cellText(grid, 1, 31), " ").len > 0);
    }

    const status_rect = frame.Rect{
        .top = @as(usize, rows) - 1,
        .left = 0,
        .right = @as(usize, cols) - 1,
        .bottom = @as(usize, rows) - 1,
    };
    // The status bar owns the last row; only the right-aligned AI status
    // block paints a solid status background (the left status text does not
    // extend to the screen edge).
    try frame.expectTextInRegion(grid, status_rect, "NORMAL");

    var rail_rect: ?frame.Rect = null;
    if (lay.mode != .hidden) {
        const rr = frame.Rect{
            .top = 0,
            .left = @intCast(lay.rail_col),
            .right = @as(usize, cols) - 1,
            .bottom = @as(usize, rows) - 3,
        };
        rail_rect = rr;
        // The rail is a solid panel: no unpainted holes, top-left and
        // top-right cells have the float background, and the left border is
        // a continuous vertical line.
        try frame.expectRegionPainted(grid, rr);
        // The header band keeps the rail's left rule but uses the status
        // background; the rest of the panel stays bg_float.
        try frame.expectCellBg(grid, 0, rr.left, aiStatusBg());
        try frame.expectCellBg(grid, 0, rr.right, aiStatusBg());
        try frame.expectCellBg(grid, 1, rr.left, aiRailBg());
        try std.testing.expectEqualStrings("│", frame.cellText(grid, 0, rr.left));
        try std.testing.expectEqualStrings("│", frame.cellText(grid, rr.bottom, rr.left));
        // The column immediately left of the rail border is blank in both
        // modes (dock reserves it; drawer paints it over the editor).
        try frame.expectCellBg(grid, 0, rr.left - 1, aiEditorBg());
        try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, frame.cellText(grid, 1, rr.left - 1), " ").len);
        try frame.expectTextInRegion(grid, rr, "AGENTS");
        // Hint labels are drawn on the thread rows / workbox tabs' top-left
        // cells, so those labels cover the first 1-3 text cells. The hint
        // assertion below checks the overlay instead; every other scenario
        // keeps the full text assertions.
        if (!sc.hints) {
            try frame.expectTextInRegion(grid, rr, "thread 1");
            try frame.expectTextInRegion(grid, rr, if (sc.inline_prompt != null) "changes 1" else "changes 0");
        }
        try frame.expectCellBg(grid, @as(usize, rows) - 1, @as(usize, cols) - 1, aiStatusBg());
        // The rail stops above the status bar and never shares a cell with
        // it; the editor keeps its reserved width to the left.
        // A full-width rule separates the last content/rail row from the
        // status band; no pane may paint it.
        const rule_row = @as(usize, rows) - 2;
        try frame.expectCellBg(grid, rule_row, 0, aiStatusBg());
        try frame.expectCellBg(grid, rule_row, @as(usize, cols) - 1, aiStatusBg());
        try std.testing.expectEqualStrings("─", frame.cellText(grid, rule_row, 0));
        try frame.expectNoOverlap(rr, frame.Rect{
            .top = rule_row,
            .left = 0,
            .right = @as(usize, cols) - 1,
            .bottom = rule_row,
        });
        try frame.expectNoOverlap(rr, status_rect);
        try expectNoForbiddenGlyphs(grid, rr);
        try frame.expectNoHorizontalOverflow(grid, @as(usize, cols));

        // The editor content is visible to the left of the rail (in drawer
        // mode the rail overlays the right side only).
        const visible_editor = frame.Rect{
            .top = 0,
            .left = 0,
            .right = if (lay.mode == .drawer)
                rr.left - 1 - lay.rail_gutter
            else
                @as(usize, lay.editor_width) - 1,
            .bottom = @as(usize, rows) - 1,
        };
        const editor_marker = if (lay.mode == .drawer and sc.filetree) "GOLDEN_EDIT" else "GOLDEN_EDITOR";
        try frame.expectTextInRegion(grid, visible_editor, editor_marker);
    } else {
        try frame.expectNoHorizontalOverflow(grid, @as(usize, cols));
    }

    if (sc.hints) {
        const status_row = grid.rowText(@as(usize, rows) - 1);
        try std.testing.expect(std.mem.indexOf(u8, status_row, "HINTS ·") != null);
        // The left status text is never overwritten (labels stay on content
        // rows), and the overlay stays inside the screen.
        try std.testing.expect(std.mem.startsWith(u8, status_row, "["));
        try frame.expectNoHorizontalOverflow(grid, @as(usize, cols));
        if (lay.mode != .hidden) {
            // Every workbox tab is a target: the first one's top-left cell
            // holds a charset label glyph, while the rail's left border and
            // right edge stay untouched.
            const tabs_row = aiTabsRow(@as(usize, rows));
            const label_cell = frame.cellText(grid, tabs_row, @as(usize, lay.rail_col) + 2);
            try std.testing.expect(label_cell.len == 1 and hintIsChar(label_cell[0]));
            try std.testing.expectEqualStrings("│", frame.cellText(grid, tabs_row, @as(usize, lay.rail_col)));
        }
    }

    if (sc.filetree) {
        // <90 cols with the Agent drawer open: opening the rail closed the
        // peek, so the resting compact icon rail is what remains.
        const compact_rail = sc.compact_rail or (cols < nav_model.full_min_cols and final_rail != .hidden);
        if (compact_rail) {
            const rail_w: usize = nav_model.compact_width;
            try frame.expectTextInRegion(grid, frame.Rect{
                .top = 2,
                .left = 0,
                .right = rail_w - 1,
                .bottom = 2,
            }, "OZ");
            var rr: usize = 2;
            while (rr + 2 < rows) : (rr += 1) {
                try std.testing.expectEqualStrings("│", frame.cellText(grid, rr, rail_w - 1));
            }
            try std.testing.expectEqualStrings("\u{f07b}", frame.cellText(grid, navCompactTabRow(0), 2));
            try std.testing.expectEqualStrings("\u{f0219}", frame.cellText(grid, navCompactTabRow(1), 2));
            try std.testing.expectEqualStrings("\u{f0c0}", frame.cellText(grid, navCompactTabRow(2), 2));
            // No content drawer, no overlap with the rail or status band.
            try frame.expectNoOverlap(frame.Rect{
                .top = 2,
                .left = 0,
                .right = rail_w - 1,
                .bottom = rows - 3,
            }, status_rect);
        } else {
            const ft = findNavigatorBox(grid) orelse {
                std.debug.print("scenario {s}: no 30-cell navigator box in {d}x{d}\n", .{
                    sc.name, sc.rows, sc.cols,
                });
                return error.TestUnexpectedResult;
            };
            try expectNavigatorPanel(grid, ft);
            if (!sc.hints) try frame.expectTextInRegion(grid, ft, "Files");
            if (rail_rect) |rr| try frame.expectNoOverlap(ft, rr);
            try frame.expectNoOverlap(ft, status_rect);
            try std.testing.expect(ft.bottom <= @as(usize, rows) - 2);
        }
    }

    for (sc.expect_text) |needle| {
        const whole = frame.Rect{
            .top = 0,
            .left = 0,
            .right = @as(usize, cols) - 1,
            .bottom = @as(usize, rows) - 1,
        };
        try frame.expectTextInRegion(grid, whole, needle);
    }
    for (sc.expect_absent) |needle| {
        if (grid.contains(needle)) {
            std.debug.print("scenario {s}: unexpected text '{s}'\n", .{ sc.name, needle });
            return error.TestUnexpectedResult;
        }
    }
}

fn runScenario(sc: Scenario) !void {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [160:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/oz_scenario_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, scenario_fixture);
    }

    var dir_buf: [128]u8 = undefined;
    var mock_dir: ?[:0]const u8 = null;
    var mock_env: ?[]u8 = null;
    defer {
        if (mock_env) |e| alloc.free(e);
    }
    defer {
        if (mock_dir) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};
    }
    defer if (sc.tool_fixture) std.Io.Dir.cwd().deleteFile(io, "/tmp/oz_scenario_tool_fixture.txt") catch {};
    if (sc.setup == .ai_mock) {
        const d = try aiMockDir(io, &dir_buf);
        mock_dir = d;
        if (sc.approval_fixture) {
            // Stage an edit on the scenario's own opened buffer: the target
            // path is its basename and /tmp is the detected project root.
            const base = std.fs.path.basename(name);
            const args = try std.fmt.allocPrint(
                alloc,
                "{{\"path\":\"{s}\",\"old_string\":\"second line for the layout matrix\",\"new_string\":\"second line APPROVAL_SCENARIO_NEW\"}}",
                .{base},
            );
            defer alloc.free(args);
            const round1 = try aiToolCallsSse(alloc, &.{
                .{ .id = "call_scenario_appr", .name = "edit_file", .args = args },
            });
            defer alloc.free(round1);
            try aiWriteFile(io, d, "stream-1.sse", round1);
            const round2 = try aiTextSse(alloc, "mock reply approval scenario done");
            defer alloc.free(round2);
            try aiWriteFile(io, d, "stream-2.sse", round2);
        } else if (sc.patch_approval_fixture) {
            // Stage a patch on the scenario's own opened buffer: the target
            // path is its basename and /tmp is the detected project root.
            const base = std.fs.path.basename(name);
            const patch_text = try std.fmt.allocPrint(
                alloc,
                "--- a/{s}\n+++ b/{s}\n@@ -1,2 +1,2 @@\n GOLDEN_EDITOR_MARKER\n-second line for the layout matrix\n+second line PATCH_SCENARIO_NEW\n",
                .{ base, base },
            );
            defer alloc.free(patch_text);
            const args = try aiPatchArgs(alloc, patch_text);
            defer alloc.free(args);
            const round1 = try aiToolCallsSse(alloc, &.{
                .{ .id = "call_scenario_patch", .name = "apply_patch", .args = args },
            });
            defer alloc.free(round1);
            try aiWriteFile(io, d, "stream-1.sse", round1);
            const round2 = try aiTextSse(alloc, "mock reply patch approval scenario done");
            defer alloc.free(round2);
            try aiWriteFile(io, d, "stream-2.sse", round2);
        } else if (sc.terminal_fixture) {
            const args = try aiTerminalArgs(alloc, "printf 'TERM_SCENARIO_MARKER\\n'", null);
            defer alloc.free(args);
            const round1 = try aiToolCallsSse(alloc, &.{
                .{ .id = "call_scenario_term", .name = "terminal", .args = args },
            });
            defer alloc.free(round1);
            try aiWriteFile(io, d, "stream-1.sse", round1);
            const round2 = try aiTextSse(alloc, "mock reply terminal scenario done");
            defer alloc.free(round2);
            try aiWriteFile(io, d, "stream-2.sse", round2);
        } else if (sc.tool_fixture) {
            // The scenario's opened file lives in /tmp, so /tmp is its
            // project root; the tool path is relative and fixed.
            try aiWriteFile(io, "/tmp", "oz_scenario_tool_fixture.txt", "TOOL_SCENARIO_MARKER matrix line\n");
            const round1 = try aiToolCallsSse(alloc, &.{
                .{ .id = "call_scenario", .name = "read_file", .args = "{\"path\":\"oz_scenario_tool_fixture.txt\"}" },
            });
            defer alloc.free(round1);
            try aiWriteFile(io, d, "stream-1.sse", round1);
            const round2 = try aiTextSse(alloc, "mock reply tool scenario done");
            defer alloc.free(round2);
            try aiWriteFile(io, d, "stream-2.sse", round2);
        } else {
            try aiWriteFile(io, d, "stream.sse", scenario_sse);
        }
        mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{d});
    }
    var notes_dir_buf: [128]u8 = undefined;
    var notes_dir: ?[:0]const u8 = null;
    var notes_env: ?[]u8 = null;
    defer {
        if (notes_env) |e| alloc.free(e);
    }
    defer {
        if (notes_dir) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};
    }
    if (sc.notes) {
        const d = try notesTestDir(io, &notes_dir_buf);
        notes_dir = d;
        try aiWriteFile(io, d, "scenario-note.md", "# Scenario note\n\nnavigator matrix fixture\n");
        notes_env = try std.fmt.allocPrint(alloc, "OZ_NOTES_DIR={s}", .{d});
    }
    var env_storage: [4][]const u8 = undefined;
    var env_extra: ?[]const []const u8 = null;
    var env_len: usize = 0;
    if (mock_env) |e| {
        env_storage[env_len] = e;
        env_len += 1;
        env_storage[env_len] = "OZ_AI_MODEL=mock-model";
        env_len += 1;
    }
    if (notes_env) |e| {
        env_storage[env_len] = e;
        env_len += 1;
    }
    if (env_len > 0) env_extra = env_storage[0..env_len];

    // Tool scenarios run with cwd=/tmp so the workspace root is exactly the
    // directory holding the opened fixture (no dependency on repo .git).
    var sess = if (sc.tool_fixture or sc.approval_fixture or sc.patch_approval_fixture or sc.terminal_fixture)
        try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, name }, env_extra, sc.rows, sc.cols, "/tmp")
    else
        try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, env_extra, sc.rows, sc.cols);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, sc.rows, sc.cols);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);

    if (sc.filetree) {
        try sess.send(" e");
        try gridWaitFor(&sess, &grid, "Files", 5000);
    }
    if (sc.rail != .hidden) {
        // From the file tree, Ctrl+w a is the documented re-entry path;
        // from the editor, <leader>a opens the rail focused on the prompt.
        if (sc.filetree) try sess.send("\x17a") else try sess.send(" a");
        try gridWaitFor(&sess, &grid, "AGENTS", 5000);
        try gridWaitFor(&sess, &grid, "thread 1", 4000);
        try gridWaitFor(&sess, &grid, "changes 0", 4000);
    }
    if (sc.prompt) |prompt| {
        try sess.send(prompt);
        try gridWaitFor(&sess, &grid, prompt, 3000);
        try sess.send("\r");
        try gridWaitFor(&sess, &grid, "mock reply", 8000);
        try gridWaitFor(&sess, &grid, "idle", 5000);
    }
    for (sc.steps) |step| {
        if (step.keys.len > 0) try sess.send(step.keys);
        if (step.wait_for) |needle| try gridWaitFor(&sess, &grid, needle, step.timeout_ms);
    }
    if (sc.inline_prompt) |instruction| {
        try sess.send("Vj");
        try sess.send(" i");
        try gridWaitFor(&sess, &grid, "inline edit", 5000);
        try sess.send(instruction);
        try sess.send("\r");
        try gridWaitFor(&sess, &grid, "changes 1", 8000);
        try gridWaitFor(&sess, &grid, "approve", 5000);
    }
    if (sc.hints) {
        // Enter hint mode exactly as documented: printable keys only reach
        // editor.Mode with editor/filetree focus. <leader>a lands on the
        // prompt (Tab moves to the thread list); the filetree setup above
        // uses Ctrl+w a, which already lands on the thread list — sending
        // Tab there would cycle the Workbox tab instead.
        if (sc.rail != .hidden and !sc.filetree) try sess.send("\t");
        try sess.send(" j");
        try gridWaitFor(&sess, &grid, "HINTS ·", 5000);
    }
    try gridSettle(&sess, &grid, 250, 5000);

    assertScenario(sc, &grid) catch |err| {
        std.debug.print("scenario failed: {s} (tags:", .{sc.name});
        for (sc.tags) |tag| std.debug.print(" {s}", .{tag});
        std.debug.print(")\n", .{});
        grid.dump();
        return err;
    };

    if (mock_dir) |d| {
        for (sc.request_contains) |needle| {
            const req = try aiReadFile(io, alloc, d, "request.json");
            defer alloc.free(req);
            if (std.mem.indexOf(u8, req, needle) == null) {
                std.debug.print("scenario {s}: request body missing '{s}'\n", .{ sc.name, needle });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "scenario matrix: layout and AI workspace combinations" {
    for (scenario_matrix) |sc| {
        try runScenario(sc);
    }
}

test "scenario matrix: every required tag is covered" {
    for (required_scenario_tags) |tag| {
        var found = false;
        for (scenario_matrix) |sc| {
            for (sc.tags) |t| {
                if (std.mem.eql(u8, t, tag)) found = true;
            }
        }
        if (!found) {
            std.debug.print(
                "scenario matrix: tag '{s}' has no scenario (add one to scenario_matrix)\n",
                .{tag},
            );
            return error.UncoveredScenarioTag;
        }
    }
    for (scenario_matrix) |sc| {
        if (sc.tags.len == 0) {
            std.debug.print("scenario matrix: scenario '{s}' has no tags\n", .{sc.name});
            return error.UntaggedScenario;
        }
        for (sc.tags) |tag| {
            var declared = false;
            for (required_scenario_tags) |t| {
                if (std.mem.eql(u8, t, tag)) declared = true;
            }
            if (!declared) {
                std.debug.print(
                    "scenario matrix: scenario '{s}' uses undeclared tag '{s}' (add it to required_scenario_tags)\n",
                    .{ sc.name, tag },
                );
                return error.UndeclaredScenarioTag;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Golden frames (M2.5)
// ---------------------------------------------------------------------------
const golden = @import("golden.zig");

/// Run the deterministic AI workspace frame used by both goldens: a fixed
/// plain-text file in a fixed non-git cwd, a fixed theme/HOME, the mock
/// stream, and the same key sequence. Volatile inputs (paths, branch, time)
/// are absent by construction; the frame is stable across runs.
fn runAiGolden(name: []const u8, rows: u16, cols: u16, golden_rel_path: []const u8) !void {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root_buf: [128]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/oz_golden_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);

    var fixture_buf: [192]u8 = undefined;
    const fixture = try std.fmt.bufPrint(&fixture_buf, "{s}/fixture.txt", .{root});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, fixture, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "alpha line one\nbeta line two\ngamma line three\n");
    }
    var home_buf: [192]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{root});
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    var mock_buf: [192]u8 = undefined;
    const mock = try std.fmt.bufPrint(&mock_buf, "{s}/mock", .{root});
    try std.Io.Dir.createDirAbsolute(io, mock, .default_dir);
    try aiWriteFile(io, mock, "stream.sse", "data: {\"choices\":[{\"delta\":{\"content\":\"mock \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"reply\"}}]}\n\n" ++
        "data: [DONE]\n\n");

    const home_env = try std.fmt.allocPrint(alloc, "HOME={s}", .{home});
    defer alloc.free(home_env);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{mock});
    defer alloc.free(mock_env);
    const env_extra = [_][]const u8{ home_env, mock_env, "OZ_AI_MODEL=mock-model" };

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, "fixture.txt" }, &env_extra, rows, cols, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, rows, cols);
    defer grid.deinit(alloc);

    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "alpha line one", 5000);
    // The text-file LSP probe settles to this deterministic label; waiting
    // for it keeps the status bar identical between fresh and warm runs.
    try gridWaitFor(&sess, &grid, "NoLspServer", 5000);
    try sess.send(" a");
    try gridWaitFor(&sess, &grid, "AGENTS", 5000);
    try gridWaitFor(&sess, &grid, "thread 1", 4000);
    try gridWaitFor(&sess, &grid, "❯ ", 4000);
    try sess.send("hello");
    try gridWaitFor(&sess, &grid, "hello", 3000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "mock reply", 8000);
    try gridWaitFor(&sess, &grid, "idle", 5000);
    try gridSettle(&sess, &grid, 400, 6000);

    try golden.check(io, alloc, &grid, name, golden_rel_path);
}

test "golden: 120x30 docked AI workspace" {
    try runAiGolden("ai-dock-120x30", 30, 120, "test/golden/ai-dock-120x30.txt");
}

test "golden: 80x24 narrow AI drawer" {
    try runAiGolden("ai-drawer-80x24", 24, 80, "test/golden/ai-drawer-80x24.txt");
}

// ---------------------------------------------------------------------------
// UI polish: two-row buffer strip (§18.11) and motion (§18.12)
// ---------------------------------------------------------------------------

/// Pump the pty for `ms`, feeding every byte into the grid; returns bytes.
fn uiPump(sess: *Session, grid: *Grid, ms: i32) !usize {
    var total: usize = 0;
    var waited: i32 = 0;
    while (waited < ms) {
        const slice = @min(@as(i32, 25), ms - waited);
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], slice);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
            total += n;
        }
        waited += slice;
    }
    return total;
}

fn uiCountText(grid: *Grid, row: usize, text: []const u8) usize {
    var n: usize = 0;
    var c: usize = 0;
    while (c < grid.cols) : (c += 1) {
        if (std.mem.eql(u8, aiCellText(grid, row, c), text)) n += 1;
    }
    return n;
}

const UiRun = struct { start: usize, end: usize };

/// Overall span of cells with `fg` on `row` (the strip underlines are a
/// single contiguous run; a split layer may share x positions, so callers
/// that need per-pane spans look at the label row's bg_sel run instead).
fn uiFgRun(grid: *Grid, row: usize, fg: u32) ?UiRun {
    var start: ?usize = null;
    var end: usize = 0;
    for (0..grid.cols) |c| {
        if (grid.fg_buf[row * grid.cols + c] == fg) {
            if (start == null) start = c;
            end = c;
        }
    }
    if (start) |s| return .{ .start = s, .end = end };
    return null;
}

fn uiCellBg(grid: *Grid, row: usize, col: usize) u32 {
    return grid.bg_buf[row * grid.cols + col];
}

fn uiExpectRuleRow(grid: *Grid, row: usize, bg: u32) !void {
    var c: usize = 0;
    while (c < grid.cols) : (c += 1) {
        try std.testing.expectEqualStrings("─", aiCellText(grid, row, c));
        try std.testing.expectEqual(bg, uiCellBg(grid, row, c));
    }
    // The rule is the neutral strip border, not the accent underline; both
    // must appear so the active-tab segment reads as a distinct inset.
    var saw_rule = false;
    var c2: usize = 0;
    while (c2 < grid.cols) : (c2 += 1) {
        if (grid.fg_buf[row * grid.cols + c2] == packRgb(0x54, 0x54, 0x6D)) saw_rule = true;
    }
    try std.testing.expect(saw_rule);
}

/// One 120/100/80 buffer-strip scenario: five real files (short, long,
/// plain, note, diff), the active tab visible and underlined, a close hint
/// target on the active tab, and content starting below the shared rule.
fn bufferStripCase(io: Io, alloc: std.mem.Allocator, cols: u16) !void {
    const rows: u16 = 30;
    const tag = tmp_counter;
    tmp_counter += 1;
    const names = [_][]const u8{
        "ab.zig",
        "bbbb_long_buffer_name_that_ellipsizes.zig",
        "cc_main.zig",
        "dd_todo.md",
        "ee_diff.patch",
    };
    var dir_buf: [160:0]u8 = undefined;
    const dir = try bufPrintZ(&dir_buf, "/tmp/ozstrip_{d}_{d}", .{ linux.getpid(), tag });
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var paths: [5][160]u8 = undefined;
    var lens: [5]usize = undefined;
    for (names, 0..) |n, i| {
        const path = try std.fmt.bufPrint(paths[i][0..], "{s}/{s}", .{ dir, n });
        lens[i] = path.len;
        const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "STRIP_MARKER\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, paths[0][0..lens[0]] }, null, rows, cols);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, rows, cols);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "STRIP_MARKER", 5000);
    var i: usize = 1;
    while (i < names.len) : (i += 1) {
        var cmd_buf: [256]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, ":e {s}\r", .{paths[i][0..lens[i]]});
        try sess.send(cmd);
        // Truncated names keep their prefix, which is distinct per file.
        try gridWaitFor(&sess, &grid, names[i][0..@min(names[i].len, 8)], 5000);
    }
    try gridSettle(&sess, &grid, 120, 3000);

    // Two-row strip: label row 0 + shared rule row 1; content starts at 2.
    const marker = aiFindCell(&grid, "STRIP_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), marker.row);
    try uiExpectRuleRow(&grid, 1, aiStatusBg());
    // Every visible active tab has a full-body accent inset on the rule row
    // and the same span has bg_sel on the label row.
    const active_underline = uiFgRun(&grid, 1, packRgb(0x7E, 0x9C, 0xD8)) orelse {
        std.debug.print("no active underline at {d}x{d}\n", .{ rows, cols });
        grid.dump();
        return error.TestUnexpectedResult;
    };
    const underline_w = active_underline.end - active_underline.start + 1;
    try std.testing.expect(underline_w >= tabstrip_min_body);
    try std.testing.expect(active_underline.end < cols);
    try std.testing.expectEqual(aiStatusBg(), uiCellBg(&grid, 1, active_underline.start - 1));

    // Scan the label row's bg_sel run (the whole tab body, including padding
    // and close) and require the underline to span exactly it.
    var bg_start: ?usize = null;
    var bg_end: usize = 0;
    for (0..grid.cols) |c| {
        if (uiCellBg(&grid, 0, c) == navSelectedBg()) {
            if (bg_start == null) bg_start = c;
            bg_end = c;
        }
    }
    try std.testing.expect(bg_start != null);
    try std.testing.expectEqual(active_underline.start, bg_start.?);
    try std.testing.expectEqual(active_underline.end, bg_end);
    // The `×` is the close target, three cells before the body's right edge
    // (two-cell right padding + the glyph itself).
    const close_col = bg_end - 2;
    try std.testing.expectEqualStrings("×", aiCellText(&grid, 0, close_col));
    // Inactive tab body uses the strip surface, separators are accent-dim.
    const sep_count = uiCountText(&grid, 0, "│");
    try std.testing.expect(sep_count >= 1);
    try std.testing.expectEqual(@as(usize, 0), uiCountText(&grid, 2, "│"));
    // The number of close affordances equals the number of visible tabs.
    const visible_tabs = sep_count + 1;
    try std.testing.expectEqual(visible_tabs, uiCountText(&grid, 0, "×"));

    // Switching to the previous buffer moves the active tab; the underline
    // follows it and remains complete at every width.
    try sess.send("gT");
    try gridSettle(&sess, &grid, 100, 3000);
    const moved = uiFgRun(&grid, 1, packRgb(0x7E, 0x9C, 0xD8)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(moved.start != active_underline.start or moved.end != active_underline.end);
    try std.testing.expect(moved.end < cols);
    try std.testing.expect(moved.end - moved.start + 1 >= tabstrip_min_body);

    // Hint mode: both the tab body and its close cell are targets. Read the
    // close label from the drawn frame and activate it; the buffer count
    // drops by one and no new destructive path is used.
    const before_close = uiCountText(&grid, 0, "×");
    try sess.send(" j");
    try gridWaitFor(&sess, &grid, "HINTS ·", 4000);
    const want = hintLabelLenFor(hintTargetCount(&grid) orelse return error.TestUnexpectedResult);
    var tab_buf: [3]u8 = undefined;
    const tab_label = hintLabelAt(&grid, &tab_buf, 0, moved.start + 2, want);
    try std.testing.expectEqual(want, tab_label.len);
    var close_buf: [3]u8 = undefined;
    const close_label = hintLabelAt(&grid, &close_buf, 0, moved.end - 2, want);
    if (close_label.len != want) {
        std.debug.print("close hint missing at ({d},{d}) at {d}x{d}\n", .{ 0, moved.end - 2, rows, cols });
        grid.dump();
        return error.TestUnexpectedResult;
    }
    try sess.send(close_label);
    try gridWaitGone(&sess, &grid, "HINTS ·", 4000);
    try gridWaitGone(&sess, &grid, "dd_todo", 4000);
    // Closing a tab may pull the next hidden buffer into the scrolled
    // window, so the count can stay equal; it must never grow.
    try std.testing.expect(uiCountText(&grid, 0, "×") <= before_close);
    try std.testing.expect(uiCountText(&grid, 0, "×") >= 1);
    try std.testing.expect(aiFindCell(&grid, "STRIP_MARKER").?.row == 2);
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    // Quit cleanly; the strip change must not trap keys.
    try sess.send("\x1b");
    _ = try sess.commandAndWaitExit(":qa!\r");
}

/// Kanagawa-wave strip minimum body width (§18.11). Kept local because the
/// e2e binary cannot import the app module.
const tabstrip_min_body: usize = 20;

test "ui buffer strip: 120x30 two-row tabs, underline, close hint" {
    try bufferStripCase(std.testing.io, std.testing.allocator, 120);
}

test "ui buffer strip: 100x30 keeps the active tab fully visible" {
    try bufferStripCase(std.testing.io, std.testing.allocator, 100);
}

test "ui buffer strip: 80x24 keeps the active tab fully visible" {
    try bufferStripCase(std.testing.io, std.testing.allocator, 80);
}

test "ui buffer strip: split layers share one rule row" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tag = tmp_counter;
    tmp_counter += 1;
    var dir_buf: [160:0]u8 = undefined;
    const dir = try bufPrintZ(&dir_buf, "/tmp/ozsplit_{d}_{d}", .{ linux.getpid(), tag });
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var paths: [2][160]u8 = undefined;
    var lens: [2]usize = undefined;
    const names = [_][]const u8{ "split_alpha.zig", "split_bravo.zig" };
    for (names, 0..) |n, i| {
        const path = try std.fmt.bufPrint(paths[i][0..], "{s}/{s}", .{ dir, n });
        lens[i] = path.len;
        const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "SPLIT_MARKER\n");
    }

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, paths[0][0..lens[0]] }, null, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":e {s}\r", .{paths[1][0..lens[1]]});
    try sess.send(cmd);
    try gridWaitFor(&sess, &grid, "split_bravo", 5000);
    try sess.send(":sp\r");
    try gridWaitFor(&sess, &grid, "split_alpha", 5000);
    try gridSettle(&sess, &grid, 150, 3000);

    // Stacked panes: one label layer each, then ONE shared rule row.
    try std.testing.expect(aiCellIndexOf(&grid, 0, "split_") != null);
    try std.testing.expect(aiCellIndexOf(&grid, 1, "split_") != null);
    try uiExpectRuleRow(&grid, 2, aiStatusBg());
    // The focused (bottom) pane's own buffer carries the selection; the
    // hidden sibling's tab on the upper layer stays inactive, so exactly one
    // label layer is selected here.
    try std.testing.expectEqual(navSelectedBg(), uiCellBg(&grid, 1, 2));
    try std.testing.expectEqual(aiStatusBg(), uiCellBg(&grid, 0, 2));
    const underline = uiFgRun(&grid, 2, packRgb(0x7E, 0x9C, 0xD8));
    try std.testing.expect(underline != null);
    // Content starts below both layers and the shared rule.
    const marker = aiFindCell(&grid, "SPLIT_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), marker.row);
    try std.testing.expectEqual(@as(usize, 0), uiCountText(&grid, 2, " "));
    try frame.expectNoHorizontalOverflow(&grid, grid.cols);

    _ = try sess.commandAndWaitExit(":qa!\r");
}

/// Build a long mock SSE stream: `chunks` content deltas at the client's 8ms
/// pace keep a real streaming state observable for roughly chunks*8ms.
fn uiLongSse(alloc: std.mem.Allocator, chunks: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < chunks) : (i += 1) {
        try out.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n");
    }
    try out.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");
    try out.appendSlice(alloc, "data: [DONE]\n\n");
    return out.toOwnedSlice(alloc);
}

test "animation: streaming status pulses only while streaming; idle is stable" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var name_buf: [128:0]u8 = undefined;
    const name = try bufPrintZ(&name_buf, "/tmp/ozanim_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "ANIM_MARKER\n");
    }
    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const sse = try uiLongSse(alloc, 220);
    defer alloc.free(sse);
    try aiWriteFile(io, dir, "stream.sse", sse);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSize(io, &.{ oz_exe_path, name }, &.{ mock_env, "OZ_AI_MODEL=mock-model" }, 30, 120);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "NoLspServer", 5000);
    try aiEnterRail(&sess, &grid);
    try sess.send("animate");
    try gridWaitFor(&sess, &grid, "animate", 2000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "streaming", 6000);

    const header_row = aiWorkboxHeaderRow(30);
    const status_col = aiCellIndexOf(&grid, header_row, "streaming") orelse {
        std.debug.print("streaming label not on the workbox header\n", .{});
        grid.dump();
        return error.TestUnexpectedResult;
    };
    var colors: [8]u32 = undefined;
    var color_count: usize = 0;
    var waited: i32 = 0;
    while (waited < 900 and color_count < 4) {
        _ = try uiPump(&sess, &grid, 45);
        waited += 45;
        const fg = grid.fg_buf[header_row * grid.cols + status_col];
        var seen = false;
        for (colors[0..color_count]) |c| {
            if (c == fg) seen = true;
        }
        if (!seen and color_count < colors.len) {
            colors[color_count] = fg;
            color_count += 1;
        }
    }
    if (color_count < 2) {
        std.debug.print("streaming pulse did not animate: {d} distinct colors\n", .{color_count});
        grid.dump();
        return error.TestUnexpectedResult;
    }

    try gridWaitFor(&sess, &grid, "idle", 10000);
    try gridSettle(&sess, &grid, 250, 4000);
    const idle_text = grid.rowText(header_row);
    const idle_fg = grid.fg_buf[header_row * grid.cols + status_col];
    const bytes = try uiPump(&sess, &grid, 300);
    try std.testing.expectEqual(@as(usize, 0), bytes);
    try std.testing.expectEqualStrings(idle_text, grid.rowText(header_row));
    try std.testing.expectEqual(idle_fg, grid.fg_buf[header_row * grid.cols + status_col]);
    // Idle status is the static dim label (not the pulsing accent pair).
    try std.testing.expectEqual(packRgb(0x72, 0x71, 0x69), idle_fg);
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}

test "animation: running tool spinner changes, stops, and idles" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var root_buf: [160:0]u8 = undefined;
    const root = try bufPrintZ(&root_buf, "/tmp/ozspinner_{d}_{d}", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var fixture_buf: [220:0]u8 = undefined;
    const fixture = try bufPrintZ(&fixture_buf, "{s}/spin_fixture.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, fixture, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "SPIN_MARKER\n");
    }
    var editor_buf: [220:0]u8 = undefined;
    const editor = try bufPrintZ(&editor_buf, "{s}/editor.txt", .{root});
    {
        const f = try std.Io.Dir.cwd().createFile(io, editor, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "EDITOR_SPIN\n");
    }
    var dir_buf: [128]u8 = undefined;
    const dir = try aiMockDir(io, &dir_buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const round1 = try aiToolCallsSse(alloc, &.{.{ .id = "call_spin", .name = "read_file", .args = "{\"path\":\"spin_fixture.txt\"}" }});
    defer alloc.free(round1);
    try aiWriteFile(io, dir, "stream-1.sse", round1);
    const round2 = try aiTextSse(alloc, "SPIN_DONE");
    defer alloc.free(round2);
    try aiWriteFile(io, dir, "stream-2.sse", round2);
    const mock_env = try std.fmt.allocPrint(alloc, "OZ_AI_MOCK_DIR={s}", .{dir});
    defer alloc.free(mock_env);

    var sess = try Session.spawnEnvSizeCwd(io, &.{ oz_exe_path, editor }, &.{ mock_env, "OZ_AI_MODEL=mock-model", "OZ_AI_TOOL_DELAY_MS=700" }, 30, 120, root);
    defer sess.close();
    defer killPid(sess.pid);
    var grid = try Grid.initSizedCols(alloc, 30, 120);
    defer grid.deinit(alloc);
    try gridWaitFor(&sess, &grid, "NORMAL", 8000);
    try gridWaitFor(&sess, &grid, "EDITOR_SPIN", 5000);
    try aiEnterRail(&sess, &grid);
    try sess.send("read it");
    try gridWaitFor(&sess, &grid, "read it", 2000);
    try sess.send("\r");
    try gridWaitFor(&sess, &grid, "read_file", 8000);

    // The running card's glyph is the first header cell, two cells left of
    // the tool name (glyph + one space).
    const name_cell = aiFindCell(&grid, "read_file") orelse return error.TestUnexpectedResult;
    try std.testing.expect(name_cell.col >= 2);
    const icon_col = name_cell.col - 2;
    var glyphs: [8]u8 = undefined;
    var glyph_count: usize = 0;
    var waited: i32 = 0;
    while (waited < 450 and glyph_count < 4) {
        _ = try uiPump(&sess, &grid, 35);
        waited += 35;
        const text = aiCellText(&grid, name_cell.row, icon_col);
        if (text.len == 1) {
            const g = text[0];
            if (std.mem.indexOfScalar(u8, "|/-\\", g) == null) continue;
            var seen = false;
            for (glyphs[0..glyph_count]) |old| {
                if (old == g) seen = true;
            }
            if (!seen and glyph_count < glyphs.len) {
                glyphs[glyph_count] = g;
                glyph_count += 1;
            }
        }
    }
    if (glyph_count < 2) {
        std.debug.print("tool spinner did not animate: {d} glyphs\n", .{glyph_count});
        grid.dump();
        return error.TestUnexpectedResult;
    }

    try gridWaitFor(&sess, &grid, "SPIN_DONE", 10000);
    try gridWaitFor(&sess, &grid, "idle", 6000);
    try gridSettle(&sess, &grid, 250, 4000);
    const done_cell = aiFindCell(&grid, "read_file") orelse return error.TestUnexpectedResult;
    const done_icon_col = done_cell.col - 2;
    const done_icon = aiCellText(&grid, done_cell.row, done_icon_col);
    try std.testing.expect(!std.mem.eql(u8, done_icon, "|"));
    try std.testing.expect(!std.mem.eql(u8, done_icon, "/"));
    try std.testing.expect(!std.mem.eql(u8, done_icon, "-"));
    try std.testing.expect(!std.mem.eql(u8, done_icon, "\\"));
    const idle_bytes = try uiPump(&sess, &grid, 300);
    try std.testing.expectEqual(@as(usize, 0), idle_bytes);
    try std.testing.expectEqualStrings(done_icon, aiCellText(&grid, done_cell.row, done_icon_col));
    try sess.send("\x1b");
    try aiWaitRailFocus(&sess, &grid, aiRailCol(120), false, 3000);
    try aiQuit(&sess);
}
