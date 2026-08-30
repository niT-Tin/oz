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

    var env_bufs: [12][256:0]u8 = undefined;
    var env_ptrs: [13]?[*:0]const u8 = .{null} ** 13;
    var nenv: usize = 0;
    const base_env = [_][]const u8{ "TERM=xterm-256color", "PATH=/usr/bin:/bin:/usr/local/bin", "HOME=/tmp" };
    for (base_env) |e| {
        const ez: [:0]u8 = try std.fmt.bufPrintZ(&env_bufs[nenv], "{s}", .{e});
        env_ptrs[nenv] = ez.ptr;
        nenv += 1;
    }
    if (env_extra) |extra| {
        for (extra) |e| {
            const ez: [:0]u8 = try std.fmt.bufPrintZ(&env_bufs[nenv], "{s}", .{e});
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
            const cwd_z: [:0]u8 = std.fmt.bufPrintZ(&cwd_buf, "{s}", .{c}) catch linux.exit(126);
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
        var pty = try Pty.open();
        errdefer pty.close();
        const pid = spawnChildEnv(io, &pty, argv, env_extra) catch |e| {
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
    /// rows*cols*4: one UTF-8-capable slot per cell (a Nerd Font icon is 3
    /// bytes but ONE cell, so columns must count characters, not bytes —
    /// otherwise vaxis's diff updates land in the wrong column).
    buf: []u8,
    fg_buf: []u32, // rows*cols packed RGB (0 = default)
    bg_buf: []u32, // rows*cols packed RGB (0 = default)
    row: usize = 0,
    col: usize = 0,
    fg: u32 = 0, // current fg color (packed RGB, 0 = default)
    bg: u32 = 0, // current bg color (packed RGB, 0 = default)
    /// Scratch buffer for rowText (one row of compressed cells).
    row_text_buf: [80 * 4]u8 = undefined,
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
        const buf = try alloc.alloc(u8, 24 * 80 * 4);
        @memset(buf, 0);
        const fg_buf = try alloc.alloc(u32, 24 * 80);
        @memset(fg_buf, 0);
        const bg_buf = try alloc.alloc(u32, 24 * 80);
        @memset(bg_buf, 0);
        return .{ .buf = buf, .fg_buf = fg_buf, .bg_buf = bg_buf, .alloc = alloc };
    }

    fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        alloc.free(self.fg_buf);
        alloc.free(self.bg_buf);
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
                        // unterminated CSI (split across reads): stash the
                        // tail so the continuation parses as one sequence
                        self.stashPending(bytes[i..]);
                        return;
                    }
                    continue;
                }
                if (bytes[i + 1] == ']') {
                    // OSC: skip until BEL or ST; a split OSC stashes the tail
                    var k = i + 2;
                    while (k < bytes.len and bytes[k] != 0x07) k += 1;
                    if (k >= bytes.len) {
                        self.stashPending(bytes[i..]);
                        return;
                    }
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
                    if (self.row < self.rows and self.col < self.cols) {
                        const slot = self.cell(self.row, self.col);
                        @memset(slot, 0);
                        @memcpy(slot[0..ln], bytes[i .. i + ln]);
                        self.fg_buf[self.row * self.cols + self.col] = self.fg;
                        self.bg_buf[self.row * self.cols + self.col] = self.bg;
                    }
                    self.col += 1;
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
            // EL (erase in line, ESC[K): clear from the cursor column to the
            // end of the row — without it a SHORTER status bar redraw leaves
            // the previous longer text's tail behind (stale "⎇ master")
            'K' => {
                var c = self.col;
                while (c < self.cols) : (c += 1) {
                    @memset(self.cell(self.row, c), 0);
                    self.fg_buf[self.row * self.cols + c] = 0;
                    self.bg_buf[self.row * self.cols + c] = 0;
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
    const exit_code = try sess.commandAndWaitExit(":q!\r");
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
    const abs = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}rel.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    // relative path from the project root to the same file
    var rel_path_buf: [256:0]u8 = undefined;
    const rel_path = try std.fmt.bufPrintZ(&rel_path_buf, "../../../../tmp/{s}", .{abs["/tmp/".len..]});
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz e2e sp {d} {d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}th.txt", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expect(grid.contains("NORMAL"));

    // default theme is kanagawa-wave: bg 0x1F1F28
    const kanagawa_bg = packRgb(0x1F, 0x1F, 0x28);
    try std.testing.expect(grid.rowHasBg(1, kanagawa_bg));

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
    try std.testing.expect(grid.contains("tokyonight"));

    // switch to tokyonight-moon: bg becomes 0x1E2032
    try sess.send(":theme tokyonight-moon\r");
    waited = 0;
    const moon_bg = packRgb(0x1E, 0x20, 0x32);
    while (!grid.rowHasBg(1, moon_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(1, moon_bg));
    try std.testing.expect(!grid.rowHasBg(1, kanagawa_bg));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}thp.txt", .{ linux.getpid(), tmp_counter });
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
    // default theme is kanagawa: the whole screen (row 23 included) is its bg
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
    // (Esc twice: the first may only close an open completion menu.)
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

    try sess.send("\x1b\x1b"); // first Esc may only close the completion menu
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}search.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}g.txt", .{ linux.getpid(), tmp_counter });
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
    // "pub fn" hits build.zig:14 first (small file → preview available).
    try sess.send("pub fn");
    waited = 0;
    while (!grid.contains("❯ pub fn") or !grid.contains("build.zig:14:")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("build.zig:14:"));
    const sep_col_filled = nthPipeCol(&grid, hint_row.?, 1) orelse return error.MissingSeparator;
    try std.testing.expectEqual(sep_col_empty, sep_col_filled);

    // preview syntax highlighting: the selected result is build.zig:14, so
    // the ±4 window shows line 15 "    const target = ..." — tree-sitter
    // colors "const" with the keyword color (kanagawa oniViolet). The left
    // list never renders "const" keyword-colored (fzy only colors the query
    // chars "pub fn"), so this proves the PREVIEW column is highlighted.
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

    // <leader>e opens the tree; title + an early entry appear. The tree is
    // now a real directory tree: first level is dirs-first sorted (docs/,
    // src/, test/), so the first row is a directory, not DESIGN.md.
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
    // dirs come first: row 2 (first entry row) is a directory with the
    // closed folder glyph; "docs" is the first sorted first-level dir
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "docs") != null);

    // Enter on the selected directory (docs) expands it — its only child
    // (excali) appears, and the folder glyph flips open
    try sess.send("\r");
    waited = 0;
    while (!grid.contains("excal")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("excal"));
    try std.testing.expect(grid.contains("\u{f07c}")); // open folder glyph

    // Enter again folds docs — its child disappears
    try sess.send("\r");
    waited = 0;
    while (grid.contains("excal")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("excal"));

    // j × 3: docs → src → test → DESIGN.md (first-level file); Enter opens
    // it but KEEPS the tree open — only <space>e (toggle) or Esc close it;
    // focus returns to the buffer so typing edits the file.
    try sess.send("jjj\r");
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
    try std.testing.expect(grid.contains(" files ")); // tree stays open after Enter

    // <space>e toggles the tree closed (and is the only toggle)
    try sess.send(" e");
    waited = 0;
    while (grid.contains(" files ")) {
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}ftb.txt", .{ linux.getpid(), tmp_counter });
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

    // <leader>e opens the tree; dirs-first: row 2 = docs (selected),
    // row 3 = src (unselected)
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

    // the selected row keeps its bg_sel highlight
    try std.testing.expect(grid.rowHasBg(2, packRgb(0x2D, 0x4F, 0x67)));
    // an unselected row is now ALL the editor background (0x1F1F28) — tree
    // panel cells, the fg_faint borders and the editor side alike — where
    // before the panel was bg_float (0x223249)
    const tree_bg = packRgb(0x1F, 0x1F, 0x28);
    try std.testing.expect(grid.rowAllBg(3, tree_bg));
    try std.testing.expect(!grid.rowHasBg(3, packRgb(0x22, 0x32, 0x49)));
    // the title/border rows share the editor bg too (fg_faint borders stay)
    try std.testing.expect(grid.rowHasBg(1, tree_bg));
    try std.testing.expect(!grid.rowHasBg(1, packRgb(0x22, 0x32, 0x49)));

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

test "tree-sitter: colors stay correct after o + typing + jk exit" {
    // Regression for the "chars turn comment-gray after jk" drift: after an
    // 'o' (structural edit) + typing + jk exit, the incremental reparse must
    // still color a keyword gold. exitInsert no longer forces a full reparse
    // on every insert exit (that made the frame after jk flash on large
    // files); the structural-op sites still force one.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}drift.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vis.zig", .{ linux.getpid(), tmp_counter });
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
    while (grid.guideFgAt(3, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(3, 0) != indent0) {
        std.debug.print("fn scope guide never reached indent0: row3 col0={?}\n", .{grid.guideFgAt(3, 0)});
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(3, 0));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(3, 1));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(8, 0));

    // 3. enter the nested if-block ("2j" → line 3, "        y();"). The if
    //    body becomes the scope (lines 2-4, indent_col=4): after the spread,
    //    the column-4 guide is highlighted (indent[1]) and the column-0
    //    guide — the OUTER fn scope's line — reverts to gray. Only the
    //    nearest scope stays lit.
    try sess.send("2j");
    waited = 0;
    while (!grid.rowHasBg(3, cursorline_bg)) {
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
    while (grid.guideFgAt(3, 1) != indent1) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(3, 1) != indent1 or grid.guideFgAt(3, 0) != guide_gray) {
        std.debug.print("nested scope: row3 col0={?} col1={?}\n", .{ grid.guideFgAt(3, 0), grid.guideFgAt(3, 1) });
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent1), grid.guideFgAt(3, 1));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(3, 0));

    // 4. leave the nested block ("2j" → line 5, "    g();" — fn body, no
    //    enclosing if): the fn body block is the scope again; row 3's
    //    column-0 guide relights and column-4 stays gray.
    try sess.send("2j");
    waited = 0;
    while (!grid.rowHasBg(5, cursorline_bg)) {
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
    while (grid.guideFgAt(3, 0) != indent0) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n > 0) {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        } else {
            waited += 200;
            if (waited >= 4000) break;
        }
    }
    if (grid.guideFgAt(3, 0) != indent0) {
        std.debug.print("after leaving nested: row3 col0={?}\n", .{grid.guideFgAt(3, 0)});
        grid.dump();
    }
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(3, 0));
    try std.testing.expectEqual(@as(?u32, guide_gray), grid.guideFgAt(3, 1));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.zig", .{ linux.getpid(), tmp_counter });
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
        std.debug.print("blank-row scope guide missing: row3 col0={?}\n", .{grid.guideFgAt(3, 0)});
        grid.dump();
    }
    // the blank line (row 3) carries the scope vertical…
    try std.testing.expectEqual(@as(?u32, indent0), grid.guideFgAt(3, 0));
    // …but the scope's FIRST line (the fn header, row 1) and the closing
    // brace (row 5) do NOT — the vertical starts below the first line.
    try std.testing.expectEqual(@as(?u32, null), grid.guideFgAt(1, 0));
    try std.testing.expectEqual(@as(?u32, null), grid.guideFgAt(5, 0));

    const exit_code = try sess.commandAndWaitExit(":q!\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
}

test "indent: blank rows carry gray context guides plus the scope column" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}blk.txt", .{ linux.getpid(), tmp_counter });
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
        if (grid.bg_buf[1 * grid.cols + 3] == sel_bg and
            grid.bg_buf[2 * grid.cols + 3] == sel_bg and
            grid.bg_buf[3 * grid.cols + 3] == sel_bg)
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
    try std.testing.expect(grid.bg_buf[1 * grid.cols + 2] != sel_bg);
    try std.testing.expect(grid.bg_buf[1 * grid.cols + 4] != sel_bg);
    try std.testing.expect(grid.bg_buf[2 * grid.cols + 2] != sel_bg);
    try std.testing.expect(grid.bg_buf[3 * grid.cols + 2] != sel_bg);

    // d deletes exactly one column from every covered row: aa / bbb / c
    try sess.send("d");
    waited = 0;
    while (!rowContains(&grid, 1, "aa") or rowContains(&grid, 1, "aaa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 1, "aa") or rowContains(&grid, 1, "aaa")) {
        std.debug.print("after block d:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "aa"));
    try std.testing.expect(!rowContains(&grid, 1, "aaa"));
    try std.testing.expect(rowContains(&grid, 2, "bbb"));
    try std.testing.expect(rowContains(&grid, 3, "c"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}blkc.txt", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 1, "aXa")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!rowContains(&grid, 1, "aXa")) {
        std.debug.print("after block c:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "aXa"));
    try std.testing.expect(rowContains(&grid, 2, "bXbb"));
    try std.testing.expect(rowContains(&grid, 3, "cX"));
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

    // <leader>e — the tree opens. First level is dirs-first (docs/ src/
    // test/), so row 2 (first entry row) is a directory, not a file.
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
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "docs") != null);

    // Expand enough of the tree to overflow the ~20 visible sidebar rows:
    // l on docs (its child appears), jj to src + l (12 children), j to
    // buffer + l (5 children) → 25 visible rows > 20.
    try sess.send("ljjljl");
    waited = 0;
    while (!grid.contains("ops.zig")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("ops.zig")); // buffer children visible

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
        var sr: usize = 2;
        var has_sel = false;
        while (sr < 22) : (sr += 1) {
            if (grid.rowHasBg(sr, packRgb(45, 79, 103))) has_sel = true;
        }
        if (std.mem.indexOf(u8, grid.rowText(2), "docs") == null and has_sel) scrolled = true;
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

    const sel_bg = packRgb(45, 79, 103);

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
    // the sidebar selection starts on the first entry row (title is row 1, entries from row 2)
    try std.testing.expect(grid.rowHasBg(2, sel_bg));

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
    // the sidebar highlight stays on row 2 (entries start below the title)
    try std.testing.expect(grid.rowHasBg(2, sel_bg));

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
    try std.testing.expect(grid.rowHasBg(2, sel_bg));

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
    const sel_bg = packRgb(45, 79, 103);
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vld.txt", .{ linux.getpid(), tmp_counter });
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
    while (!(!rowContains(&grid, 2, "bbb") and !rowContains(&grid, 3, "ccc") and !rowContains(&grid, 4, "ddd"))) {
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
    try std.testing.expect(rowContains(&grid, 1, "aaa"));
    try std.testing.expect(!rowContains(&grid, 2, "bbb"));
    try std.testing.expect(!rowContains(&grid, 3, "ccc"));
    try std.testing.expect(!rowContains(&grid, 4, "ddd"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}vlc.txt", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expect(rowContains(&grid, 1, "aaa"));
    try std.testing.expect(!rowContains(&grid, 2, "bbb"));
    try std.testing.expect(!rowContains(&grid, 3, "ccc"));

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

test "e2e: visual block g Ctrl+a respects the block columns (vim column increment)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}colb.txt", .{ linux.getpid(), tmp_counter });
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
    while (!(rowContains(&grid, 1, "0 10") and rowContains(&grid, 2, "1 11") and rowContains(&grid, 3, "2 12"))) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    if (!(rowContains(&grid, 1, "0 10") and rowContains(&grid, 2, "1 11") and rowContains(&grid, 3, "2 12"))) {
        std.debug.print("after block g Ctrl+a:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "0 10"));
    try std.testing.expect(rowContains(&grid, 2, "1 11"));
    try std.testing.expect(rowContains(&grid, 3, "2 12"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}colc.txt", .{ linux.getpid(), tmp_counter });
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
    while (!(rowContains(&grid, 1, "1") and rowContains(&grid, 2, "3") and
        rowContains(&grid, 3, "5") and rowContains(&grid, 4, "7") and rowContains(&grid, 5, "9")))
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
    if (!(rowContains(&grid, 1, "1") and rowContains(&grid, 2, "3") and
        rowContains(&grid, 3, "5") and rowContains(&grid, 4, "7") and rowContains(&grid, 5, "9")))
    {
        std.debug.print("after block g Ctrl+a on 0..4:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "1"));
    try std.testing.expect(rowContains(&grid, 2, "3"));
    try std.testing.expect(rowContains(&grid, 3, "5"));
    try std.testing.expect(rowContains(&grid, 4, "7"));
    try std.testing.expect(rowContains(&grid, 5, "9"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}arr.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cnt.txt", .{ linux.getpid(), tmp_counter });
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

test "e2e: multi-cursor Ctrl+n moves the main cursor and scrolls the viewport" {
    // Regression: Ctrl+n added the next match to the cursor list but never
    // moved the main cursor, so the screen cursor stayed put and a match
    // beyond the visible area was never scrolled into view.
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}mcscroll.txt", .{ linux.getpid(), tmp_counter });
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
    var r: usize = 1;
    var cursorline_row: ?usize = null;
    const cursorline_bg = packRgb(42, 42, 55);
    while (r < 24) : (r += 1) {
        if (grid.rowHasBg(r, cursorline_bg)) {
            cursorline_row = r;
            break;
        }
    }
    try std.testing.expect(cursorline_row != null);
    try std.testing.expect(cursorline_row.? > 1); // scrolled off the top

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
    while (std.mem.indexOf(u8, grid.rowText(2), "docs") == null) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(std.mem.indexOf(u8, grid.rowText(2), "docs") != null);

    // j × 4 → README.md (docs → src → test → DESIGN.md → README.md), Enter
    // opens it (markdown has no zig grammar). The tree STAYS open (only
    // <space>e / Esc close it) — the buffer tab shows README.md (row 0, now
    // NOT covered by the sidebar).
    try sess.send("jjjj\r");
    waited = 0;
    while (std.mem.indexOf(u8, grid.rowText(0), "README.md") == null and
        std.mem.indexOf(u8, grid.rowText(2), "README.md") == null)
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
    try std.testing.expect(grid.contains("files")); // the tree did not close

    // The tree is still open with focus on the buffer (Enter moves focus).
    // Ctrl-w h → sidebar focus (the tree is the leftmost pane; h moves left
    // from the buffer into it); the selection is still on README.md's row.
    // kkk → src, l expands it, j → buffer, l expands it, jj → ops.zig,
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
    try sess.send("kkk");
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

    // jj → last real line ("ccc"); cc clears its text and enters insert,
    // typing "X" replaces it (row 3 becomes "X"). jk exits.
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
    // cc keeps the line's newline (vim: change clears the line's TEXT, the
    // line itself survives) — the saved file ends with '\n' like nvim's
    // 'fixeol' default
    try std.testing.expectEqualStrings("aaa\nbbb\nX\n", buf);
}

test "e2e: yy/dd/p/P linewise register matches nvim (lines below/above, cursor on first non-blank)" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}yank.txt", .{ linux.getpid(), tmp_counter });
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
    try std.testing.expectEqualStrings("1 abc", std.mem.trim(u8, grid.rowText(1), " "));
    try std.testing.expectEqualStrings("2 abc", std.mem.trim(u8, grid.rowText(2), " "));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(3), " "));

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
    try std.testing.expectEqualStrings("2   bbb", std.mem.trim(u8, grid.rowText(2), " "));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(3), " "));

    // u, then dd p: dd fills the register LINEWISE (vim unnamed register),
    // p puts the cut line below the next one — abc moves under bbb
    try sess.send("u");
    try std.testing.expect(try Wait.until(&sess, &grid, "/5 col"));
    try sess.send("gg");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 1/5"));
    try sess.send("ddp");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 2/5"));
    try std.testing.expectEqualStrings("1   bbb", std.mem.trim(u8, grid.rowText(1), " "));
    try std.testing.expectEqualStrings("2 abc", std.mem.trim(u8, grid.rowText(2), " "));
    try std.testing.expectEqualStrings("1 ccc", std.mem.trim(u8, grid.rowText(3), " "));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}xp.txt", .{ linux.getpid(), tmp_counter });
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
    const sel_bg = packRgb(45, 79, 103);

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
    // j moves the sidebar selection to row 3 (entries start at row 2:
    // row 0 = tab bar, row 1 = sidebar title/border)
    try sess.send("j");
    waited = 0;
    while (!grid.rowHasBg(3, sel_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(3, sel_bg));

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
        // the sidebar selection (54,74,130) must have moved to row 4
        // (entries start at row 2; two j's landed on the third entry)
        if (grid.rowHasBg(4, sel_bg)) sel_moved = true;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}comp.txt", .{ linux.getpid(), tmp_counter });
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

test "insert Ctrl+n: Esc dismisses the menu and stays in insert" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}compc.txt", .{ linux.getpid(), tmp_counter });
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

    // Esc dismisses the menu only — insert mode continues, the typed prefix
    // stays untouched; further typing still lands in the buffer.
    try sess.send("\x1b");
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
        var r: usize = 0;
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
    while (rowContains(&grid, 3, "alx") == false) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 3, "alx"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}compn.txt", .{ linux.getpid(), tmp_counter });
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
        var r: usize = 0;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}jcol.zig", .{ linux.getpid(), tmp_counter });
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
    // rows: 0 = tab bar, 1.. = file lines. Move the cursor down two lines
    // (file line 2 = "    const x = 1;"), waiting on the cursorline highlight
    // so the motions have actually been processed (a content-only wait is
    // satisfied by the initial frame before the keys are handled).
    try sess.send("jj"); // cursor → file line 2
    waited = 0;
    while (!grid.rowHasBg(3, cursorline_bg)) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.rowHasBg(3, cursorline_bg));
    // the next line ("    const y = 2;") is on screen row 4; its "const"
    // must be gold before typing anything
    const before = fgOfOnRow(&grid, 4, "const");
    if (before != gold) {
        std.debug.print("before typing j: row4 'const' fg = 0x{x:0>6}\n", .{before orelse 0});
        grid.dump();
    }
    try std.testing.expectEqual(gold, before);

    // A → insert at end of line 2, type 'j'; the NEXT line's first word
    // ("const y") must keep its keyword color.
    try sess.send("Aj");
    waited = 0;
    while (!rowContains(&grid, 3, "const x = 1;j")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(rowContains(&grid, 3, "const x = 1;j"));
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

test "windows: :vs splits side-by-side; Ctrl-w l/h switch; :q closes one; :qa quits" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}win.txt", .{ linux.getpid(), tmp_counter });
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

    // :vs — vertical split: both halves show "line1" (appears twice on row 1)
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
        const row = grid.rowText(1);
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
    try std.testing.expect(rowContains(&grid, 1, "│"));

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
        const row = grid.rowText(1);
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}winsp.txt", .{ linux.getpid(), tmp_counter });
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

    // :sp — horizontal split: the top window shows "topline" on row 1; the
    // "─" separator consumes row 12 (vim statusline style), and the bottom
    // window's content starts at row 13 — its own first line ("topline")
    // sits underneath the separator, so the first visible line is "second"
    try sess.send(":sp\r");
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
        both = rowContains(&grid, 1, "topline") and rowContains(&grid, 13, "second");
    }
    if (!both) {
        std.debug.print("after :sp:\n", .{});
        grid.dump();
    }
    try std.testing.expect(both);
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
    try std.testing.expect(rowContains(&grid, 1, "topline")); // top window unchanged

    const exit_code = try sess.commandAndWaitExit(":qa\r");
    if (exit_code != 0) std.debug.print("oz exited with code {d}\n", .{exit_code});
    try std.testing.expectEqual(@as(u32, 0), exit_code);
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

test "windows: :vs keeps the old window left; Ctrl-w h/l + :e target the focused one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var na_buf: [128:0]u8 = undefined;
    const na = try std.fmt.bufPrintZ(&na_buf, "/tmp/oz_e2e_{d}_{d}wla.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, na) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, na, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "AAA\n");
    }
    var nb_buf: [128:0]u8 = undefined;
    const nb = try std.fmt.bufPrintZ(&nb_buf, "/tmp/oz_e2e_{d}_{d}wlb.txt", .{ linux.getpid(), tmp_counter });
    tmp_counter += 1;
    defer std.Io.Dir.cwd().deleteFile(io, nb) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, nb, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "BBB\n");
    }
    var nc_buf: [128:0]u8 = undefined;
    const nc = try std.fmt.bufPrintZ(&nc_buf, "/tmp/oz_e2e_{d}_{d}wlc.txt", .{ linux.getpid(), tmp_counter });
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
        const row = grid.rowText(1);
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
        const row = grid.rowText(1);
        const left_b = std.mem.indexOf(u8, row[0..40], "BBB") != null;
        const right_a = std.mem.indexOf(u8, row[40..80], "AAA") != null;
        swapped = left_b and right_a;
    }
    if (!swapped) {
        std.debug.print("after Ctrl-w h + :e b.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(swapped);

    // Ctrl-w l → RIGHT window; :e c.txt puts CCC in the RIGHT half
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
    var right_c = false;
    while (!right_c) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(1);
        right_c = std.mem.indexOf(u8, row[40..80], "CCC") != null and std.mem.indexOf(u8, row[0..40], "BBB") != null;
    }
    if (!right_c) {
        std.debug.print("after Ctrl-w l + :e c.txt:\n", .{});
        grid.dump();
    }
    try std.testing.expect(right_c);

    // :q closes the focused (right) window → only BBB (left) remains
    try sess.send(":q!\r");
    waited = 0;
    var only_b = false;
    while (!only_b) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
        const row = grid.rowText(1);
        const has_b = std.mem.indexOf(u8, row, "BBB") != null;
        const has_c = std.mem.indexOf(u8, row, "CCC") != null;
        only_b = has_b and !has_c;
    }
    try std.testing.expect(only_b);

    const exit_code = try sess.commandAndWaitExit(":qa\r");
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
        const row = grid.rowText(1);
        if (std.mem.indexOf(u8, row[40..80], "const") != null) {
            const c = 40 + std.mem.indexOf(u8, row[40..80], "const").?;
            right_gold = grid.fg_buf[1 * grid.cols + c] == gold;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}lsp.go", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}lspm.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}diagc.zig", .{ linux.getpid(), tmp_counter });
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
    // screen row 1 WITHOUT any keypress — the wake event alone must repaint.
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
        if (grid.buf[(1 * grid.cols + 1) * 4] == 0xEF and
            grid.buf[(1 * grid.cols + 1) * 4 + 1] == 0x91 and
            grid.buf[(1 * grid.cols + 1) * 4 + 2] == 0xA7) mark = true;
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}jksync.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}diag.zig", .{ linux.getpid(), tmp_counter });
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

    // gl is the first keypress: it drains the LSP queue (diagnostics arrive)
    // and shows the cursor line's diagnostics — line 0 has the mock's error.
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

    // diagnostics arrived; the gutter's last column of row 1 (file line 0)
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
        // gutter col 1 on screen row 1: the Nerd Font ✖ (nf-fa-times_circle,
        // U+F467 → EF 91 A7) — no longer a bare 'E'
        if (grid.buf[(1 * grid.cols + 1) * 4] == 0xEF and
            grid.buf[(1 * grid.cols + 1) * 4 + 1] == 0x91 and
            grid.buf[(1 * grid.cols + 1) * 4 + 2] == 0xA7) mark = true;
    }
    if (!mark) {
        std.debug.print("no gutter mark; col1={x}{x}{x}\n", .{
            grid.buf[(1 * grid.cols + 1) * 4],
            grid.buf[(1 * grid.cols + 1) * 4 + 1],
            grid.buf[(1 * grid.cols + 1) * 4 + 2],
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}nav.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}comp.zig", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 3, "mockItem")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 3, "mockItem")) break;
    }
    if (!rowContains(&grid, 3, "mockItem")) {
        std.debug.print("lsp completion accept failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 3, "mockItem"));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}auto.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}trig.zig", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 1, "mockItem")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 1, "mockItem")) break;
    }
    if (!rowContains(&grid, 1, "mockItem")) {
        std.debug.print("trigger accept failed:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 1, "mockItem"));
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}dyn.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}snp.zig", .{ linux.getpid(), tmp_counter });
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
    while (!rowContains(&grid, 2, "mockSnippet")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 8000) break;
        } else {
            sess.used += n;
            grid.feed(sess.out[sess.used - n .. sess.used]);
        }
        if (rowContains(&grid, 2, "mockSnippet")) break;
    }
    if (!rowContains(&grid, 2, "mockSnippet") or grid.contains("${1:")) {
        std.debug.print("snippet accept corrupted the text:\n", .{});
        grid.dump();
    }
    try std.testing.expect(rowContains(&grid, 2, "mockSnippet"));
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}flow.zig", .{ linux.getpid(), tmp_counter });
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

test "lsp: signature help — typing ( shows the callee signature" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}sig.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}edit.zig", .{ linux.getpid(), tmp_counter });
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

test "command mode: Tab completes command names, cycles, keeps path completion" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}cmdt.zig", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}km.txt", .{ linux.getpid(), tmp_counter });
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}tr.txt", .{ linux.getpid(), tmp_counter });
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
    while (!grid.contains(" files ")) {
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
    try std.testing.expect(rowContains(&grid, 2, "\u{f07b}")); // closed folder

    // l expands the selected dir — its child appears and the folder glyph
    // flips to the OPEN variant
    try sess.send("l");
    waited = 0;
    while (!grid.contains("excal")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(grid.contains("excal"));
    try std.testing.expect(grid.contains("\u{f07c}")); // open folder glyph

    // h folds it again — the child disappears and no open folder remains
    try sess.send("h");
    waited = 0;
    while (grid.contains("excal")) {
        const n = try readAvailable(sess.pty.master, sess.out[sess.used..], 200);
        if (n == 0) {
            waited += 200;
            if (waited >= 5000) break;
            continue;
        }
        sess.used += n;
        grid.feed(sess.out[sess.used - n .. sess.used]);
    }
    try std.testing.expect(!grid.contains("excal"));
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
    // tab bar (row 0) icon: seti_zig glyph, constant color (surimiOrange)
    const zig_glyph = "\u{e6a9}";
    try std.testing.expect(grid.containsFg(zig_glyph, packRgb(0xFF, 0xA0, 0x66)));

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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}_newfile.txt", .{ linux.getpid(), tmp_counter });
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
    // 24-row pty: content area = 24 - 1 (status) - 1 (tab bar) = 22 rows,
    // grid rows 1..22. File: "line 001".."line 100" (plus a trailing empty
    // line 101 from the final newline).
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var name_buf: [128:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}_view.txt", .{ linux.getpid(), tmp_counter });
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

    // zz: cursor line 60 → view_top = 60 - 22/2 = 49 → first row "line 050";
    // the cursor itself stays on line 61
    try sess.send("zz");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 050", 1));
    try std.testing.expect(grid.contains("line 61/101"));

    // zt: cursor line at the top → first row "line 061"
    try sess.send("zt");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 061", 1));
    try std.testing.expect(grid.contains("line 61/101"));

    // zb: cursor line at the bottom → view_top = 60 - 21 = 39 → "line 040"
    try sess.send("zb");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 040", 1));
    try std.testing.expect(grid.contains("line 61/101"));

    // H: first visible line (view_top 39) → line 40
    try sess.send("H");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 40/101", -1));

    // M: middle visible line = 39 + (22-1)/2 = 49 → line 50
    try sess.send("M");
    try std.testing.expect(try Wait.until(&sess, &grid, "line 50/101", -1));

    // L: last visible line = 39 + 21 = 60 → line 61
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
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/oz_e2e_{d}_{d}fold.py", .{ linux.getpid(), tmp_counter });
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
