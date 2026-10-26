//! Background execution for the `terminal` tool (M3b3).
//!
//! One `Job` runs exactly one command, and only after the App has an explicit
//! human approval. The worker thread:
//!
//!   1. spawns `/bin/sh -c <command>` with cwd = the captured workspace root,
//!      empty stdin, a bounded environment, and a fresh process group
//!      (`pgid = 0`);
//!   2. reads both pipes with `poll(2)` until EOF, storing at most
//!      `terminal_tool.max_output_bytes` and draining the remainder (so the
//!      child can never block on a full pipe);
//!   3. waits for the child; a watchdog thread kills the whole process group
//!      with SIGKILL on the real deadline or on `requestCancel`.
//!
//! This is deliberately **not** a shell UI or PTY: no input is forwarded and
//! there is no VT emulation. The editor terminal (`Alt+r`, `src/term.zig`)
//! is untouched and independent.
//!
//! ## Security limits (no sandbox claim)
//!
//! The command runs with the user's own permissions. There is no sandbox,
//! seccomp, container or network restriction. The environment is filtered to
//! `terminal_tool.env_allowlist`; stdin is /dev/null; output and wall-clock
//! time are capped; timeout/cancel kill the process group. These are bounds,
//! not isolation.
//!
//! ## Ownership
//!
//! `start` takes ownership of the `Environ.Map` and of the command/root
//! copies. The result (`output`) is written by the worker and published with
//! `done` (acquire/release); `takeResult` joins and transfers it. A result
//! that is never taken is freed by `deinit`.
const std = @import("std");
const builtin = @import("builtin");
const terminal_tool = @import("../ai/terminal_tool.zig");

/// POSIX `poll(2)` is used for bounded pipe reads. Linux/macOS are the
/// supported platforms of the editor's terminal stack as well.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub const Status = enum {
    /// Process exited with code 0 and the output was read completely.
    ok,
    /// Spawn failure, nonzero exit, signal, timeout, or a read error. The
    /// caller derives the card text from `meta`.
    err,
    /// Our deadline fired; the process group was killed.
    timed_out,
    /// The user/thread-switch cancelled it; the result is never applied.
    cancelled,
};

pub const Result = struct {
    status: Status,
    meta: terminal_tool.ResultMeta,
    output: []u8,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
        self.* = undefined;
    }
};

pub const Job = if (supported) struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    command: []u8,
    timeout_ms: u32,
    env: std.process.Environ.Map,
    thread: ?std.Thread = null,
    watchdog: ?std.Thread = null,

    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the worker after `wait` so the watchdog stops.
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    read_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Process-group id (== child pid). Written before the watchdog starts.
    child_pid: std.posix.pid_t = 0,

    result: ?Result = null,
    result_taken: bool = false,

    /// Spawn one command. `env` ownership moves to the job. On every error
    /// path `env`, the copies and the job are released.
    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        command: []const u8,
        timeout_ms: u32,
        env: std.process.Environ.Map,
    ) !*Job {
        if (root.len == 0) {
            var env_mut = env;
            env_mut.deinit();
            return error.InvalidWorkspaceRoot;
        }
        const root_copy = try alloc.dupe(u8, root);
        const command_copy = alloc.dupe(u8, command) catch |e| {
            alloc.free(root_copy);
            var env_mut = env;
            env_mut.deinit();
            return e;
        };
        const self = alloc.create(Job) catch |e| {
            alloc.free(root_copy);
            alloc.free(command_copy);
            var env_mut = env;
            env_mut.deinit();
            return e;
        };
        self.* = .{
            .alloc = alloc,
            .io = io,
            .root = root_copy,
            .command = command_copy,
            .timeout_ms = terminal_tool.clampTimeout(timeout_ms),
            .env = env,
        };
        const thread = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            self.env.deinit();
            alloc.free(root_copy);
            alloc.free(command_copy);
            alloc.destroy(self);
            return error.ThreadSpawnFailed;
        };
        self.thread = thread;
        return self;
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    /// Ask the watchdog to kill the process group. Safe from the UI thread.
    pub fn requestCancel(self: *Job) void {
        self.cancel.store(true, .release);
    }

    /// Join and transfer the result. The caller frees `result.output` and
    /// then must not reuse the job except through `deinit` (which only frees
    /// the job itself after that).
    pub fn takeResult(self: *Job) Result {
        self.join();
        self.result_taken = true;
        return self.result orelse .{
            .status = .err,
            .meta = .{ .read_error = true },
            .output = &.{},
        };
    }

    /// Release a job whose result was consumed or will never be used. An
    /// in-flight command is cancelled first (the watchdog kills its group).
    pub fn deinit(self: *Job) void {
        self.requestCancel();
        self.join();
        if (!self.result_taken) {
            if (self.result) |*r| {
                if (r.output.len > 0) self.alloc.free(r.output);
            }
        }
        self.alloc.free(self.root);
        self.alloc.free(self.command);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn join(self: *Job) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.watchdog) |t| {
            t.join();
            self.watchdog = null;
        }
    }

    fn workerMain(self: *Job) void {
        defer self.done.store(true, .release);
        // The child receives a filtered clone during spawn; the parent copy
        // is no longer needed once `spawn` returns.
        defer self.env.deinit();

        const start_ms = nowMs(self.io);
        var out: terminal_tool.OutputBuffer = .{};
        defer out.deinit(self.alloc);

        var child = std.process.spawn(self.io, .{
            .argv = &.{ terminal_tool.shell_program, "-c", self.command },
            .cwd = .{ .path = self.root },
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            // New process group so a timeout/cancel can kill every process
            // the shell started, not just the shell itself.
            .pgid = 0,
        }) catch |e| {
            const text: []u8 = std.fmt.allocPrint(self.alloc, "spawn failed: {s}", .{@errorName(e)}) catch &.{};
            self.result = .{
                .status = .err,
                .meta = .{ .duration_ms = elapsedMs(start_ms, nowMs(self.io)) },
                .output = text,
            };
            return;
        };
        self.child_pid = child.id orelse 0;

        self.watchdog = std.Thread.spawn(.{}, watchdogMain, .{self}) catch blk: {
            // Without a watchdog the deadline cannot be enforced while
            // blocked in wait(); kill now and report a real error instead of
            // risking an unbounded command.
            self.read_error.store(true, .release);
            killGroup(self);
            break :blk null;
        };

        const stdout_file = child.stdout.?;
        const stderr_file = child.stderr.?;
        var stdout_eof = false;
        var stderr_eof = false;
        var scratch: [16 * 1024]u8 = undefined;

        while (!(stdout_eof and stderr_eof)) {
            // Timeout/cancel/read-failure ends the read loop even if a
            // `setsid` descendant still holds a pipe open: waiting for that
            // EOF would defeat the deadline and hang the job.
            if (self.timed_out.load(.acquire) or self.cancelled.load(.acquire) or
                self.read_error.load(.acquire))
            {
                break;
            }
            var fds: [2]std.posix.pollfd = undefined;
            var which: [2]u2 = undefined;
            var n: usize = 0;
            if (!stdout_eof) {
                fds[n] = .{ .fd = stdout_file.handle, .events = std.posix.POLL.IN };
                which[n] = 0;
                n += 1;
            }
            if (!stderr_eof) {
                fds[n] = .{ .fd = stderr_file.handle, .events = std.posix.POLL.IN };
                which[n] = 1;
                n += 1;
            }
            if (n == 0) break;
            const ready = std.posix.poll(fds[0..n], 50) catch {
                // Treat an unexpected poll failure as end-of-input; the child
                // is still waited for (and the watchdog still bounds it).
                self.read_error.store(true, .release);
                stdout_eof = true;
                stderr_eof = true;
                break;
            };
            if (ready == 0) continue;
            for (fds[0..n], which[0..n]) |fd, w| {
                if (fd.revents == 0) continue;
                if (w == 0) {
                    readOne(self, stdout_file, &scratch, &out, &stdout_eof);
                } else {
                    readOne(self, stderr_file, &scratch, &out, &stderr_eof);
                }
            }
        }

        const term: ?std.process.Child.Term = blk: {
            if (self.cancelled.load(.acquire) or self.timed_out.load(.acquire)) {
                // wait() still returns the signal; the watchdog already
                // killed the group, so this is bounded.
                break :blk child.wait(self.io) catch null;
            }
            break :blk child.wait(self.io) catch null;
        };
        self.finished.store(true, .release);
        if (self.watchdog) |t| {
            t.join();
            self.watchdog = null;
        }

        const duration = elapsedMs(start_ms, nowMs(self.io));
        var meta = terminal_tool.ResultMeta{
            .duration_ms = duration,
            .dropped_bytes = out.dropped,
            .read_error = self.read_error.load(.acquire),
            .timed_out = self.timed_out.load(.acquire),
        };
        if (term) |t| switch (t) {
            .exited => |code| meta.exit_code = code,
            .signal => |sig| meta.signal = @intCast(@backingInt(sig)),
            .stopped => |sig| meta.signal = @intCast(@backingInt(sig)),
            .unknown => {},
        };

        if (self.cancelled.load(.acquire)) {
            self.storeResult(.cancelled, meta, &out);
        } else if (self.timed_out.load(.acquire)) {
            self.storeResult(.timed_out, meta, &out);
        } else if (term == null or terminal_tool.isError(meta)) {
            self.storeResult(.err, meta, &out);
        } else {
            self.storeResult(.ok, meta, &out);
        }
    }

    fn storeResult(
        self: *Job,
        status: Status,
        meta: terminal_tool.ResultMeta,
        out: *terminal_tool.OutputBuffer,
    ) void {
        const output: []u8 = if (out.bytes.items.len == 0)
            &.{}
        else
            self.alloc.dupe(u8, out.bytes.items) catch &.{};
        self.result = .{ .status = status, .meta = meta, .output = output };
    }

    fn watchdogMain(self: *Job) void {
        const start_ms = nowMs(self.io);
        while (true) {
            if (self.finished.load(.acquire)) return;
            if (self.cancel.load(.acquire)) {
                self.cancelled.store(true, .release);
                killGroup(self);
                return;
            }
            if (elapsedMs(start_ms, nowMs(self.io)) >= self.timeout_ms) {
                self.timed_out.store(true, .release);
                killGroup(self);
                return;
            }
            std.Io.sleep(self.io, .fromMilliseconds(5), .real) catch {};
        }
    }

    fn killGroup(self: *Job) void {
        const pid = self.child_pid;
        if (pid <= 0) return;
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    }

    fn readOne(
        self: *Job,
        file: std.Io.File,
        scratch: []u8,
        out: *terminal_tool.OutputBuffer,
        eof: *bool,
    ) void {
        const n = file.readStreaming(self.io, &.{scratch}) catch |e| switch (e) {
            error.EndOfStream => {
                eof.* = true;
                return;
            },
            error.WouldBlock => return,
            else => {
                eof.* = true;
                self.read_error.store(true, .release);
                return;
            },
        };
        if (n == 0) {
            eof.* = true;
            return;
        }
        out.append(self.alloc, scratch[0..n]) catch {
            self.read_error.store(true, .release);
        };
    }
} else struct {
    // Non-POSIX builds keep the App compiling; the tool reports this through
    // the App's `supported` check before an approval can spawn anything. No
    // instance is ever created, so these accessors are inert.
    pub fn isDone(_: *const @This()) bool {
        return true;
    }

    pub fn requestCancel(_: *@This()) void {}

    pub fn takeResult(_: *@This()) Result {
        return .{ .status = .err, .meta = .{ .read_error = true }, .output = &.{} };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        command: []const u8,
        timeout_ms: u32,
        env: std.process.Environ.Map,
    ) !*@This() {
        _ = alloc;
        _ = io;
        _ = root;
        _ = command;
        _ = timeout_ms;
        var env_mut = env;
        env_mut.deinit();
        return error.UnsupportedPlatform;
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn elapsedMs(start: i64, end: i64) u32 {
    const delta = @max(end - start, 0);
    return @intCast(@min(delta, std.math.maxInt(u32)));
}

// ---------------------------------------------------------------------------
// Tests: real /bin/sh children, bounded and killed for real.
// ---------------------------------------------------------------------------

fn testEnv(alloc: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.put("PATH", terminal_tool.default_path);
    try map.put("HOME", "/tmp");
    try map.put("TERM", "dumb");
    return map;
}

fn waitDone(job: *Job, io: std.Io, timeout_ms: u32) !void {
    var waited: u32 = 0;
    while (!job.isDone()) {
        if (waited >= timeout_ms) return error.TestUnexpectedResult;
        std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        waited += 5;
    }
}

test "terminal_job: runs a command, captures output and exit code" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var job = try Job.start(alloc, std.testing.io, "/tmp", "printf 'hello'", 5000, try testEnv(alloc));
    defer job.deinit();
    try waitDone(job, std.testing.io, 5000);
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.ok, result.status);
    try std.testing.expectEqualStrings("hello", result.output);
    try std.testing.expectEqual(@as(?u8, 0), result.meta.exit_code);
    try std.testing.expect(!result.meta.timed_out);
    try std.testing.expect(result.meta.duration_ms < 5000);
}

test "terminal_job: nonzero exit and stderr are captured" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var job = try Job.start(alloc, std.testing.io, "/tmp", "echo FAIL_OUT; exit 7", 5000, try testEnv(alloc));
    defer job.deinit();
    try waitDone(job, std.testing.io, 5000);
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.err, result.status);
    try std.testing.expectEqual(@as(?u8, 7), result.meta.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FAIL_OUT") != null);
}

test "terminal_job: timeout really kills the process group and stays bounded" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const started = nowMs(std.testing.io);
    var job = try Job.start(alloc, std.testing.io, "/tmp", "sleep 30", 100, try testEnv(alloc));
    defer job.deinit();
    try waitDone(job, std.testing.io, 3000);
    const elapsed = elapsedMs(started, nowMs(std.testing.io));
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.timed_out, result.status);
    try std.testing.expect(result.meta.timed_out);
    try std.testing.expect(terminal_tool.isError(result.meta));
    // 100ms deadline + scheduling/poll/watchdog slack, never 30s.
    try std.testing.expect(elapsed < 2500);
    try std.testing.expect(result.meta.duration_ms < 2500);
}

test "terminal_job: a setsid descendant holding the pipe cannot defeat the deadline" {
    if (!supported or builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const started = nowMs(std.testing.io);
    // The daemon escapes the process group and keeps stdout open; without
    // the timed-out read-loop break the job would wait for its EOF.
    var job = try Job.start(
        alloc,
        std.testing.io,
        "/tmp",
        "setsid sh -c 'sleep 5' & sleep 30",
        150,
        try testEnv(alloc),
    );
    defer job.deinit();
    try waitDone(job, std.testing.io, 3000);
    const elapsed = elapsedMs(started, nowMs(std.testing.io));
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.timed_out, result.status);
    try std.testing.expect(elapsed < 2500);
}

test "terminal_job: cancel stops a running command" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var job = try Job.start(alloc, std.testing.io, "/tmp", "sleep 30", 9000, try testEnv(alloc));
    defer job.deinit();
    job.requestCancel();
    try waitDone(job, std.testing.io, 3000);
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.cancelled, result.status);
    try std.testing.expect(result.meta.duration_ms < 2500);
}

test "terminal_job: output cap is enforced while the child keeps running" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var job = try Job.start(
        alloc,
        std.testing.io,
        "/tmp",
        "yes A | head -c 70000",
        8000,
        try testEnv(alloc),
    );
    defer job.deinit();
    try waitDone(job, std.testing.io, 8000);
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.ok, result.status);
    try std.testing.expectEqual(terminal_tool.max_output_bytes, result.output.len);
    try std.testing.expect(result.meta.dropped_bytes > 0);
    try std.testing.expect(terminal_tool.isError(.{ .dropped_bytes = result.meta.dropped_bytes, .exit_code = 0 }) == false);
}

test "terminal_job: a bad spawn reports an error without hanging" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var job = try Job.start(
        alloc,
        std.testing.io,
        "/nonexistent/oz_terminal_root",
        "true",
        1000,
        try testEnv(alloc),
    );
    defer job.deinit();
    try waitDone(job, std.testing.io, 3000);
    var result = job.takeResult();
    defer result.deinit(alloc);
    try std.testing.expectEqual(Status.err, result.status);
    try std.testing.expect(terminal_tool.isError(result.meta));
}
