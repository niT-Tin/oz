//! Background read-only tool execution (M3a).
//!
//! One `Job` is one batch of tool calls for one thread. The worker owns an
//! `ai.tool_exec.Executor` (canonicalized against the thread's workspace
//! root) and runs calls sequentially, checking cooperative cancellation
//! between calls. Results are written into a preallocated array and
//! published by the `done` acquire/release flag; the App consumes them from
//! the run loop (`drainToolJobs`), so no file read or grep ever blocks a
//! frame or an input event.
//!
//! Ownership:
//!   - `start` takes ownership of the call slice and frees it in
//!     `takeResults`/`deinit`;
//!   - `takeResults` transfers the result contents to the caller and joins
//!     the worker;
//!   - a cancelled job still finishes its in-flight call (the executor is
//!     bounded), marks every not-yet-started call `cancelled`, and is then
//!     discarded by the App (generation mismatch) without touching a
//!     transcript.
const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../ai/agent.zig");

pub const Result = struct {
    status: agent.CardStatus,
    /// True only when the executor actually ran the tool (ok/err reads).
    /// approval_required/unsupported/cancelled are truthful non-executions.
    executed: bool,
    content: []u8,
    duration_ms: u32,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        self.* = undefined;
    }
};

pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    calls: []ai.tools.ToolCall,
    results: []Result,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// True once `takeResults` transferred the result slice to the caller.
    results_taken: bool = false,
    /// App-side identity used to discard results for a cancelled/other
    /// thread turn.
    generation: u64,
    /// Internal e2e seam (`OZ_AI_TOOL_DELAY_MS`): hold the worker before
    /// executing so a test can observe the running card's spinner across
    /// frames. 0 for every normal run.
    delay_ms: u32 = 0,

    /// Spawn one batch. Ownership of `calls` transfers on every return path
    /// (freed by the caller-visible job on success, here on failure).
    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        calls: []ai.tools.ToolCall,
        generation: u64,
        delay_ms: u32,
    ) !*Job {
        errdefer ai.tools.freeCalls(alloc, calls);
        const root_copy = try alloc.dupe(u8, root);
        errdefer alloc.free(root_copy);
        const results = try alloc.alloc(Result, calls.len);
        errdefer alloc.free(results);
        const self = try alloc.create(Job);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .root = root_copy,
            .calls = calls,
            .results = results,
            .generation = generation,
            .delay_ms = delay_ms,
        };
        for (self.results) |*r| {
            r.* = .{ .status = .cancelled, .executed = false, .content = &.{}, .duration_ms = 0 };
        }
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.ThreadSpawnFailed;
        return self;
    }

    /// Admit a batch into its sole owning slot. A cancelled worker still
    /// owns its in-flight read until it finishes; never overwrite that
    /// pointer. Completed stale workers can be reclaimed without waiting.
    /// `calls` ownership transfers on every return path, including Busy.
    pub fn startInSlot(
        slot: *?*Job,
        alloc: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        calls: []ai.tools.ToolCall,
        generation: u64,
        delay_ms: u32,
    ) !*Job {
        reapFinished(slot);
        if (slot.* != null) {
            ai.tools.freeCalls(alloc, calls);
            return error.Busy;
        }
        const job = try start(alloc, io, root, calls, generation, delay_ms);
        slot.* = job;
        return job;
    }

    /// Reclaim only a finished worker; this function never waits for file
    /// I/O. In particular, cancellation does not relinquish slot ownership.
    pub fn reapFinished(slot: *?*Job) void {
        const job = slot.* orelse return;
        if (!job.isDone()) return;
        job.deinit();
        slot.* = null;
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn isRunning(self: *const Job) bool {
        return !self.isDone();
    }

    pub fn requestCancel(self: *Job) void {
        self.cancel.store(true, .release);
    }

    /// Join, free the call strings, and transfer ownership of the result
    /// slice (its contents and backing array) to the caller. The caller must
    /// free each `Result.content` and then `alloc.free(results)`; `deinit`
    /// afterwards only frees the job itself.
    pub fn takeResults(self: *Job) []Result {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        ai.tools.freeCalls(self.alloc, self.calls);
        self.calls = &.{};
        self.results_taken = true;
        return self.results;
    }

    /// Free a job whose results were consumed (or never will be). Must be
    /// called after `takeResults` or with an unfinished job (cancels first).
    pub fn deinit(self: *Job) void {
        self.requestCancel();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.calls.len > 0) ai.tools.freeCalls(self.alloc, self.calls);
        if (!self.results_taken) {
            for (self.results) |*r| {
                if (r.content.len > 0) self.alloc.free(r.content);
            }
            self.alloc.free(self.results);
        }
        self.alloc.free(self.root);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn workerMain(self: *Job) void {
        defer self.done.store(true, .release);

        var executor = ai.tool_exec.Executor.init(self.alloc, self.io, self.root) catch {
            for (self.results) |*r| {
                r.* = .{
                    .status = .err,
                    .executed = false,
                    .content = self.alloc.dupe(u8, "error: workspace root unavailable") catch &.{},
                    .duration_ms = 0,
                };
            }
            return;
        };
        defer executor.deinit();

        if (self.delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(self.delay_ms), .real) catch {};
        }

        for (self.calls, 0..) |call, i| {
            if (self.cancel.load(.acquire)) {
                self.results[i] = .{
                    .status = .cancelled,
                    .executed = false,
                    .content = self.alloc.dupe(u8, "cancelled: not executed") catch &.{},
                    .duration_ms = 0,
                };
                continue;
            }
            const start_ms = nowMs(self.io);
            const outcome = executor.execute(call) catch {
                self.results[i] = .{
                    .status = .err,
                    .executed = false,
                    .content = self.alloc.dupe(u8, "error: tool execution failed") catch &.{},
                    .duration_ms = 0,
                };
                continue;
            };
            const elapsed = nowMs(self.io) - start_ms;
            const duration: u32 = @intCast(@min(@max(elapsed, 0), std.math.maxInt(u32)));
            self.results[i] = .{
                .status = mapStatus(outcome.status),
                .executed = outcome.status == .ok or outcome.status == .err,
                .content = outcome.content,
                .duration_ms = duration,
            };
            if (outcome.summary) |summary| self.alloc.free(summary);
        }
    }

    fn mapStatus(status: ai.tool_exec.Status) agent.CardStatus {
        return switch (status) {
            .ok => .ok,
            .err => .err,
            .approval_required => .approval_required,
            .unsupported => .unsupported,
        };
    }
};

/// Monotonic milliseconds, clamped by the caller. `awake` matches the run
/// loop's clock so duration numbers are comparable with the UI.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn testCalls(alloc: std.mem.Allocator) ![]ai.tools.ToolCall {
    const calls = try alloc.alloc(ai.tools.ToolCall, 1);
    errdefer alloc.free(calls);
    const id = try alloc.dupe(u8, "call_slot");
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, "list_directory");
    errdefer alloc.free(name);
    calls[0] = .{ .id = id, .name = name, .arguments_json = try alloc.dupe(u8, "{\"path\":\".\"}") };
    return calls;
}

test "tool_job: cancelled slot retains ownership until reaped, then admits a new generation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    var slot: ?*Job = null;
    defer if (slot) |job| job.deinit();
    const first = try Job.startInSlot(&slot, alloc, io, root, try testCalls(alloc), 1, 150);
    first.requestCancel();
    // The worker is deliberately still alive: cancellation alone must not
    // permit the second batch to lose the only pointer to the first one.
    Job.reapFinished(&slot);
    try std.testing.expectEqual(first, slot.?);
    try std.testing.expectError(error.Busy, Job.startInSlot(&slot, alloc, io, root, try testCalls(alloc), 2, 0));
    try std.testing.expectEqual(first, slot.?);
    const deadline = nowMs(io) + 2000;
    while (!first.isDone()) {
        if (nowMs(io) >= deadline) return error.TestUnexpectedResult;
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    }
    // startInSlot must also reclaim a *finished but not yet drained* stale
    // batch: drainAi runs before drainToolJobs in the real App loop.
    const second = try Job.startInSlot(&slot, alloc, io, root, try testCalls(alloc), 2, 0);
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    while (!second.isDone()) {
        if (nowMs(io) >= deadline) return error.TestUnexpectedResult;
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    }
    Job.reapFinished(&slot);
    try std.testing.expect(slot == null);
    // std.testing.allocator additionally proves that the refused batch and
    // both completed/cancelled results/call arrays were freed.
}
