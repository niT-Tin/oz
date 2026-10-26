//! One in-flight streaming chat request (M1).
//!
//! The worker runs on a plain `std.Thread`; the UI thread never blocks.
//! Threads share only owned bytes: the request spec is duplicated into the
//! client before spawn, and the worker pushes owned `Event` payloads into a
//! mutex-protected FIFO. `pop` transfers ownership back to the App.
//!
//! Cancellation is cooperative: `requestCancel` sets an atomic that the
//! worker checks between chunks. The App additionally stops applying events
//! as soon as the user cancels, so a late chunk can never mutate the
//! transcript.
//!
//! Transport:
//!   - normal: `std.http.Client` POST {base}/chat/completions, TLS via the
//!     standard CA bundle (verification stays enabled),
//!   - test seam: `OZ_AI_MOCK_DIR` writes `request.json` and replays
//!     `stream.sse` in small paced chunks (plus an optional `error.txt`).
//!     Deliberately undocumented outside the code/DESIGN.
const std = @import("std");
const sse = @import("sse.zig");
const openai = @import("openai.zig");
const tools = @import("tools.zig");

pub const Event = union(enum) {
    /// A content delta (owned).
    delta: []u8,
    /// The stream completed (finish_reason or [DONE]).
    done,
    /// A human-readable failure (owned).
    err: []u8,
    /// Cancellation acknowledged by the worker.
    cancelled,
    /// One assistant turn's finalized tool calls (ordered by stream index).
    /// Ownership transfers to the receiver; free with `tools.freeCalls`.
    tool_calls: []tools.ToolCall,

    pub fn deinit(self: Event, alloc: std.mem.Allocator) void {
        switch (self) {
            .delta => |d| alloc.free(d),
            .err => |e| alloc.free(e),
            .tool_calls => |calls| tools.freeCalls(alloc, calls),
            .done, .cancelled => {},
        }
    }
};

pub const Spec = struct {
    /// Full completions endpoint URL (already includes /chat/completions).
    url: []const u8,
    /// Optional `Authorization: Bearer ...` credential.
    api_key: ?[]const u8 = null,
    /// Serialized JSON request body.
    body: []const u8,
    /// Test seam: replay this directory instead of doing HTTP.
    mock_dir: ?[]const u8 = null,
    /// Mock pacing: bytes per read and delay between reads.
    chunk_bytes: usize = 32,
    chunk_delay_ms: u64 = 8,
};

const Job = struct {
    url: []u8,
    api_key: ?[]u8,
    body: []u8,
    mock_dir: ?[]u8,
    chunk_bytes: usize,
    chunk_delay_ms: u64,
    /// 1-based request number for this client (OZ_AI_MOCK_DIR fixtures).
    seq: u32,

    fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        if (self.api_key) |k| alloc.free(k);
        alloc.free(self.body);
        if (self.mock_dir) |m| alloc.free(m);
        self.* = undefined;
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Event) = .empty,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    job: ?Job = null,
    /// Monotonic request counter. The mock seam uses it to pick
    /// `stream-<n>.sse` and to keep every round's `request-<n>.json`, which
    /// is what lets the agent-loop e2e inspect follow-up tool messages.
    request_seq: u32 = 0,

    pub const StartError = error{ Busy, OutOfMemory, ThreadSpawnFailed };

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Client {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Client) void {
        self.requestCancel();
        self.joinThread();
        for (self.events.items) |ev| ev.deinit(self.alloc);
        self.events.deinit(self.alloc);
    }

    /// Begin one stream. Fails with `error.Busy` while a previous worker is
    /// still alive; the caller must cancel and let it finish first.
    pub fn start(self: *Client, spec: Spec) StartError!void {
        if (self.running.load(.acquire)) {
            // A cancelled worker winds down at its next chunk boundary and
            // is joined here so a retry can reuse the client. A wedged
            // network read can delay this; the App reports it as a start
            // error rather than silently sharing the transcript.
            if (!self.cancel.load(.acquire)) return error.Busy;
            self.joinThread();
        } else {
            self.joinThread();
        }
        // Never let a finished stream's queued bytes leak into the next
        // request's transcript.
        self.clearEvents();
        self.cancel.store(false, .release);

        const url = self.alloc.dupe(u8, spec.url) catch return error.OutOfMemory;
        errdefer self.alloc.free(url);
        const body = self.alloc.dupe(u8, spec.body) catch return error.OutOfMemory;
        errdefer self.alloc.free(body);
        var api_key: ?[]u8 = null;
        if (spec.api_key) |k| {
            api_key = self.alloc.dupe(u8, k) catch return error.OutOfMemory;
        }
        errdefer if (api_key) |k| self.alloc.free(k);
        var mock_dir: ?[]u8 = null;
        if (spec.mock_dir) |m| {
            mock_dir = self.alloc.dupe(u8, m) catch return error.OutOfMemory;
        }
        errdefer if (mock_dir) |m| self.alloc.free(m);

        self.request_seq +%= 1;
        self.job = .{
            .url = url,
            .api_key = api_key,
            .body = body,
            .mock_dir = mock_dir,
            .chunk_bytes = @max(spec.chunk_bytes, 1),
            .chunk_delay_ms = spec.chunk_delay_ms,
            .seq = self.request_seq,
        };
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            self.running.store(false, .release);
            if (self.job) |*j| j.deinit(self.alloc);
            self.job = null;
            return error.ThreadSpawnFailed;
        };
    }

    /// Drop every queued event (main thread).
    pub fn clearEvents(self: *Client) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.events.items) |ev| ev.deinit(self.alloc);
        self.events.clearRetainingCapacity();
    }

    /// Request cooperative cancellation. Safe from any thread.
    pub fn requestCancel(self: *Client) void {
        self.cancel.store(true, .release);
    }

    /// Pop one event; ownership transfers to the caller.
    pub fn pop(self: *Client) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    /// True while the worker thread is alive.
    pub fn isRunning(self: *Client) bool {
        return self.running.load(.acquire);
    }

    /// True when at least one event is queued. The run loop uses this (with
    /// isRunning) to keep polling until a fast worker's events are drained.
    pub fn hasEvents(self: *Client) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.events.items.len > 0;
    }

    /// Join the worker after a terminal event (`done`/`err`/`cancelled`).
    /// The terminal push is the worker's last significant action, so this is
    /// a short wait; the App calls it before reusing the client for a tool
    /// follow-up, which removes the "done seen but worker still alive"
    /// `error.Busy` race without polling.
    pub fn joinAfterTerminal(self: *Client) void {
        self.joinThread();
    }

    fn joinThread(self: *Client) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.job) |*j| j.deinit(self.alloc);
        self.job = null;
    }

    fn push(self: *Client, ev: Event) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        errdefer ev.deinit(self.alloc);
        try self.events.append(self.alloc, ev);
    }

    fn pushError(self: *Client, text: []const u8) void {
        const copy = self.alloc.dupe(u8, text) catch return;
        self.push(.{ .err = copy }) catch self.alloc.free(copy);
    }

    fn pushErrorFmt(self: *Client, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.push(.{ .err = text }) catch self.alloc.free(text);
    }

    fn checkCancel(self: *Client) error{Cancelled}!void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
    }

    fn workerMain(self: *Client) void {
        defer self.running.store(false, .release);
        const job = &self.job.?;
        const result = if (job.mock_dir) |dir|
            self.runMock(job, dir)
        else
            self.runHttp(job);
        result catch |e| switch (e) {
            error.Cancelled => self.push(.cancelled) catch {},
            else => self.pushErrorFmt("{s}", .{@errorName(e)}),
        };
    }

    // ---- mock transport (e2e seam) ----

    fn runMock(self: *Client, job: *const Job, dir: []const u8) !void {
        try self.checkCancel();
        const seq_name = try std.fmt.allocPrint(self.alloc, "request-{d}.json", .{job.seq});
        defer self.alloc.free(seq_name);
        try writeRequestFile(self.alloc, self.io, dir, "request.json", job.body);
        try writeRequestFile(self.alloc, self.io, dir, seq_name, job.body);

        const err_name = try std.fmt.allocPrint(self.alloc, "error-{d}.txt", .{job.seq});
        defer self.alloc.free(err_name);
        if (readOptionalFile(self.alloc, self.io, dir, err_name, 4096) orelse
            readOptionalFile(self.alloc, self.io, dir, "error.txt", 4096)) |err_text|
        {
            defer self.alloc.free(err_text);
            const trimmed = std.mem.trim(u8, err_text, " \t\r\n");
            self.pushError(if (trimmed.len > 0) trimmed else "mock error");
            return;
        }

        const stream_name = try std.fmt.allocPrint(self.alloc, "stream-{d}.sse", .{job.seq});
        defer self.alloc.free(stream_name);
        const stream_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir, stream_name });
        defer self.alloc.free(stream_path);
        const fallback_path = try std.fmt.allocPrint(self.alloc, "{s}/stream.sse", .{dir});
        defer self.alloc.free(fallback_path);
        var file = std.Io.Dir.cwd().openFile(self.io, stream_path, .{ .mode = .read_only }) catch
            std.Io.Dir.cwd().openFile(self.io, fallback_path, .{ .mode = .read_only }) catch {
            self.pushErrorFmt("mock: {s} not found", .{stream_name});
            return;
        };
        defer file.close(self.io);

        var parser = sse.Parser.init(self.alloc);
        defer parser.deinit();
        var acc = tools.Accumulator.init(self.alloc);
        defer acc.deinit();
        var protocol_failed = false;
        var saw_done = false;
        var buf: [256]u8 = undefined;
        const chunk = @min(job.chunk_bytes, buf.len);
        while (true) {
            try self.checkCancel();
            const n = file.readStreaming(self.io, &.{buf[0..chunk]}) catch |e| {
                self.pushErrorFmt("mock read: {s}", .{@errorName(e)});
                return;
            };
            if (n == 0) break;
            parser.feed(buf[0..n]) catch {
                // A malformed/oversized SSE line ends this mock stream.
                self.pushError("mock: malformed stream.sse");
                return;
            };
            try self.drainSse(&parser, &saw_done, &acc, &protocol_failed);
            if (saw_done or protocol_failed) break;
            if (job.chunk_delay_ms > 0) {
                std.Io.sleep(self.io, .fromMilliseconds(@intCast(job.chunk_delay_ms)), .real) catch {};
            }
        }
        if (!saw_done and !protocol_failed) {
            parser.finish() catch {};
            try self.drainSse(&parser, &saw_done, &acc, &protocol_failed);
        }
        if (protocol_failed) return;
        try self.finalizeToolTurn(&acc);
        if (protocol_failed) return;
        self.push(.done) catch {};
    }

    // ---- HTTP transport ----

    fn runHttp(self: *Client, job: *const Job) !void {
        try self.checkCancel();
        const uri = std.Uri.parse(job.url) catch {
            self.pushError("invalid OZ_AI_BASE_URL");
            return;
        };
        var http: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer http.deinit();

        var auth_buf: ?[]u8 = null;
        defer if (auth_buf) |a| self.alloc.free(a);
        var headers_buf: [3]std.http.Header = undefined;
        var headers_len: usize = 0;
        headers_buf[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
        headers_len += 1;
        headers_buf[headers_len] = .{ .name = "Accept", .value = "text/event-stream" };
        headers_len += 1;
        if (job.api_key) |key| {
            auth_buf = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{key}) catch return error.OutOfMemory;
            headers_buf[headers_len] = .{ .name = "Authorization", .value = auth_buf.? };
            headers_len += 1;
        }

        var req = http.request(.POST, uri, .{
            .redirect_behavior = .not_allowed,
            .extra_headers = headers_buf[0..headers_len],
        }) catch |e| {
            self.pushErrorFmt("request failed: {s}", .{@errorName(e)});
            return;
        };
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = job.body.len };
        var body = req.sendBodyUnflushed(&.{}) catch |e| {
            self.pushErrorFmt("send failed: {s}", .{@errorName(e)});
            return;
        };
        body.writer.writeAll(job.body) catch |e| {
            self.pushErrorFmt("send failed: {s}", .{@errorName(e)});
            return;
        };
        body.end() catch |e| {
            self.pushErrorFmt("send failed: {s}", .{@errorName(e)});
            return;
        };
        req.connection.?.flush() catch |e| {
            self.pushErrorFmt("send failed: {s}", .{@errorName(e)});
            return;
        };

        var response = req.receiveHead(&.{}) catch |e| {
            self.pushErrorFmt("response failed: {s}", .{@errorName(e)});
            return;
        };
        if (response.head.status != .ok) {
            var transfer: [4096]u8 = undefined;
            const rdr = response.reader(&transfer);
            var err_buf: [8192]u8 = undefined;
            var err_len: usize = 0;
            while (err_len < err_buf.len) {
                var slices = [_][]u8{err_buf[err_len..]};
                const n = rdr.readVec(&slices) catch break;
                if (n == 0) break;
                err_len += n;
            }
            const body_text = err_buf[0..err_len];
            const msg_opt = openai.parseErrorBody(self.alloc, body_text) catch null;
            defer if (msg_opt) |m| self.alloc.free(m);
            const cleaner = if (msg_opt) |m| m else std.mem.trim(u8, body_text, " \t\r\n");
            self.pushErrorFmt("HTTP {d}: {s}", .{ @backingInt(response.head.status), cleaner });
            return;
        }

        var transfer: [4096]u8 = undefined;
        const rdr = response.reader(&transfer);
        var parser = sse.Parser.init(self.alloc);
        defer parser.deinit();
        var acc = tools.Accumulator.init(self.alloc);
        defer acc.deinit();
        var protocol_failed = false;
        var saw_done = false;
        var buf: [4096]u8 = undefined;
        while (true) {
            try self.checkCancel();
            var slices = [_][]u8{buf[0..]};
            const n = rdr.readVec(&slices) catch |e| switch (e) {
                error.EndOfStream => break,
                else => {
                    self.pushErrorFmt("stream read failed: {s}", .{@errorName(e)});
                    return;
                },
            };
            if (n == 0) break;
            parser.feed(buf[0..n]) catch {
                self.pushError("stream parse failed");
                return;
            };
            try self.drainSse(&parser, &saw_done, &acc, &protocol_failed);
            if (saw_done or protocol_failed) break;
        }
        if (!saw_done and !protocol_failed) {
            parser.finish() catch {};
            try self.drainSse(&parser, &saw_done, &acc, &protocol_failed);
        }
        if (protocol_failed) return;
        try self.finalizeToolTurn(&acc);
        if (protocol_failed) return;
        self.push(.done) catch {};
    }

    fn drainSse(
        self: *Client,
        parser: *sse.Parser,
        saw_done: *bool,
        acc: *tools.Accumulator,
        protocol_failed: *bool,
    ) !void {
        while (parser.next()) |ev| {
            switch (ev) {
                .done => {
                    ev.deinit(self.alloc);
                    saw_done.* = true;
                },
                .data => |json| {
                    defer ev.deinit(self.alloc);
                    var delta = openai.parseDelta(self.alloc, json) catch |e| switch (e) {
                        // Malformed JSON chunks were ignored before M3
                        // (gateways send keep-alive/metadata); preserving
                        // that keeps text-only streams tolerant. Once the
                        // chunk IS valid JSON, tool-call field errors are
                        // protocol failures and surface as a chat error.
                        error.InvalidJson => continue,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    defer delta.deinit(self.alloc);
                    acc.feedChunk(json) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            self.pushErrorFmt("tool call protocol: {s}", .{@errorName(e)});
                            protocol_failed.* = true;
                            return;
                        },
                    };
                    if (delta.content) |content| {
                        const copy = try self.alloc.dupe(u8, content);
                        self.push(.{ .delta = copy }) catch self.alloc.free(copy);
                    }
                    if (delta.finish_reason != null) saw_done.* = true;
                },
            }
        }
    }

    /// Finalize accumulated calls and queue exactly one `.tool_calls` event.
    /// Text-only streams (zero calls) behave exactly as before. A malformed
    /// tool-call turn becomes a plain chat error; no calls are queued.
    fn finalizeToolTurn(self: *Client, acc: *tools.Accumulator) !void {
        if (!acc.hasToolCalls()) {
            if (acc.finishReason() == .tool_calls) {
                self.pushError("tool call protocol: tool_calls finish without calls");
            }
            return;
        }
        try self.checkCancel();
        const calls = acc.finalize() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.pushErrorFmt("tool call protocol: {s}", .{@errorName(e)});
                return;
            },
        };
        if (calls.len == 0) {
            tools.freeCalls(self.alloc, calls);
            return;
        }
        self.push(.{ .tool_calls = calls }) catch {
            tools.freeCalls(self.alloc, calls);
            return error.OutOfMemory;
        };
    }
};

// ---------------------------------------------------------------------------
// Mock file helpers
// ---------------------------------------------------------------------------

/// Write the request body atomically (temp + rename) so a test reading the
/// file concurrently never observes a partial write.
fn writeRequestFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    body: []const u8,
) !void {
    const dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(dest);
    const tmp = try std.fmt.allocPrint(alloc, "{s}/.{s}.tmp", .{ dir, name });
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    var f = cwd.createFile(io, tmp, .{ .truncate = true }) catch |e| return e;
    var closed = false;
    defer if (!closed) f.close(io);
    f.writeStreamingAll(io, body) catch |e| {
        f.close(io);
        closed = true;
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
    f.close(io);
    closed = true;
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), dest, io) catch |e| {
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
}

fn readOptionalFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    limit: usize,
) ?[]u8 {
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .limited(limit)) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "client: mock stream emits deltas then done and writes request.json" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"mock \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"reply\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "stream.sse", .data = stream });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..n];

    var client = Client.init(alloc, io);
    defer client.deinit();
    try client.start(.{
        .url = "http://127.0.0.1:1/v1/chat/completions",
        .body = "{\"model\":\"mock-model\"}",
        .mock_dir = dir_path,
        .chunk_bytes = 7,
        .chunk_delay_ms = 0,
    });

    var got = std.ArrayList(u8).empty;
    defer got.deinit(alloc);
    var done = false;
    var waited_ms: u32 = 0;
    while (!done and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .delta => |d| try got.appendSlice(alloc, d),
                .done => done = true,
                .err => |e| {
                    std.debug.print("unexpected client error: {s}\n", .{e});
                    return error.TestUnexpectedResult;
                },
                .cancelled => return error.TestUnexpectedResult,
                .tool_calls => |calls| {
                    tools.freeCalls(alloc, calls);
                    return error.TestUnexpectedResult;
                },
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    try std.testing.expect(done);
    try std.testing.expectEqualStrings("mock reply", got.items);

    const req = try tmp.dir.readFileAlloc(io, "request.json", alloc, .limited(4096));
    defer alloc.free(req);
    try std.testing.expectEqualStrings("{\"model\":\"mock-model\"}", req);
}

test "client: mock error.txt becomes an error event" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "error.txt", .data = "mock boom\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stream.sse", .data = "data: {\"choices\":[]}\n\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var client = Client.init(alloc, io);
    defer client.deinit();
    try client.start(.{
        .url = "http://127.0.0.1:1/v1/chat/completions",
        .body = "{}",
        .mock_dir = path_buf[0..n],
        .chunk_delay_ms = 0,
    });

    var saw_err: ?[]u8 = null;
    var waited_ms: u32 = 0;
    while (saw_err == null and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            switch (ev) {
                .err => |e| saw_err = e,
                .delta, .done, .cancelled => ev.deinit(alloc),
                .tool_calls => |calls| {
                    tools.freeCalls(alloc, calls);
                    return error.TestUnexpectedResult;
                },
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    defer if (saw_err) |e| alloc.free(e);
    try std.testing.expect(saw_err != null);
    try std.testing.expectEqualStrings("mock boom", saw_err.?);
}

test "client: cancel stops deltas" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(alloc);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try stream.appendSlice(alloc, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n");
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "stream.sse", .data = stream.items });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var client = Client.init(alloc, io);
    defer client.deinit();
    try client.start(.{
        .url = "http://127.0.0.1:1/v1/chat/completions",
        .body = "{}",
        .mock_dir = path_buf[0..n],
        .chunk_bytes = 4,
        .chunk_delay_ms = 5,
    });

    // Wait for the first delta, then cancel.
    var first = false;
    var waited_ms: u32 = 0;
    while (!first and waited_ms < 3000) : (waited_ms += 2) {
        if (client.pop()) |ev| {
            defer ev.deinit(alloc);
            if (ev == .delta) first = true;
        } else {
            std.Io.sleep(io, .fromMilliseconds(2), .real) catch {};
        }
    }
    try std.testing.expect(first);
    client.requestCancel();
    std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
    // Drain whatever raced the cancel; then no further deltas may arrive.
    while (client.pop()) |ev| ev.deinit(alloc);
    std.Io.sleep(io, .fromMilliseconds(60), .real) catch {};
    try std.testing.expect(client.pop() == null);
    try std.testing.expect(!client.isRunning());
}

test "client: tool_calls fragments accumulate while text deltas still stream" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"I will read \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"pattern\\\":\\\"x\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\".zig\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "stream.sse", .data = stream });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var client = Client.init(alloc, io);
    defer client.deinit();
    try client.start(.{
        .url = "http://127.0.0.1:1/v1/chat/completions",
        .body = "{}",
        .mock_dir = path_buf[0..n],
        .chunk_bytes = 3,
        .chunk_delay_ms = 0,
    });

    var got = std.ArrayList(u8).empty;
    defer got.deinit(alloc);
    var calls: ?[]tools.ToolCall = null;
    var done = false;
    var waited_ms: u32 = 0;
    while (!done and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            switch (ev) {
                .delta => |d| {
                    defer alloc.free(d);
                    try got.appendSlice(alloc, d);
                },
                .tool_calls => |c| calls = c,
                .done => done = true,
                .err => |e| {
                    std.debug.print("unexpected client error: {s}\n", .{e});
                    alloc.free(e);
                    return error.TestUnexpectedResult;
                },
                .cancelled => return error.TestUnexpectedResult,
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    defer if (calls) |c| tools.freeCalls(alloc, c);
    try std.testing.expect(done);
    try std.testing.expectEqualStrings("I will read ", got.items);
    const list = calls orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("call_a", list[0].id);
    try std.testing.expectEqualStrings("read_file", list[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", list[0].arguments_json);
    try std.testing.expectEqualStrings("call_b", list[1].id);
    try std.testing.expectEqualStrings("{\"pattern\":\"x\"}", list[1].arguments_json);
}

test "client: malformed tool-call fields become a chat error, not a panic" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid JSON, but the tool-call entry lacks `index`.
    const stream =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_x\",\"function\":{\"name\":\"grep\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: [DONE]\n\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "stream.sse", .data = stream });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var client = Client.init(alloc, io);
    defer client.deinit();
    try client.start(.{
        .url = "http://127.0.0.1:1/v1/chat/completions",
        .body = "{}",
        .mock_dir = path_buf[0..n],
        .chunk_bytes = 5,
        .chunk_delay_ms = 0,
    });

    var err_text: ?[]u8 = null;
    var waited_ms: u32 = 0;
    while (err_text == null and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            switch (ev) {
                .err => |e| err_text = e,
                else => ev.deinit(alloc),
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    defer if (err_text) |e| alloc.free(e);
    try std.testing.expect(err_text != null);
    try std.testing.expect(std.mem.indexOf(u8, err_text.?, "tool call protocol") != null);
    // Wait for the worker to finish so deinit's join is fast.
    waited_ms = 0;
    while (client.isRunning() and waited_ms < 3000) : (waited_ms += 5) {
        while (client.pop()) |ev| ev.deinit(alloc);
        std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
    }
}

test "client: per-request mock fixtures and request-<n>.json for follow-ups" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "stream-1.sse",
        .data = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"pattern\\\":\\\"x\\\"}\"}}]}}]}\n\ndata: [DONE]\n\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "stream-2.sse",
        .data = "data: {\"choices\":[{\"delta\":{\"content\":\"final\"}}]}\n\ndata: [DONE]\n\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var client = Client.init(alloc, io);
    defer client.deinit();

    // Round 1: tool calls.
    try client.start(.{ .url = "u", .body = "{\"round\":1}", .mock_dir = path_buf[0..n], .chunk_delay_ms = 0 });
    var calls: ?[]tools.ToolCall = null;
    var waited_ms: u32 = 0;
    while (calls == null and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            switch (ev) {
                .tool_calls => |c| calls = c,
                else => ev.deinit(alloc),
            }
        } else std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
    }
    defer if (calls) |c| tools.freeCalls(alloc, c);
    try std.testing.expect(calls != null);
    // Drain the terminal done, then join before reusing the client.
    while (client.pop()) |ev| ev.deinit(alloc);
    client.joinAfterTerminal();
    try std.testing.expect(!client.isRunning());

    // Round 2: text-only final reply.
    try client.start(.{ .url = "u", .body = "{\"round\":2}", .mock_dir = path_buf[0..n], .chunk_delay_ms = 0 });
    var got = std.ArrayList(u8).empty;
    defer got.deinit(alloc);
    var done = false;
    waited_ms = 0;
    while (!done and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            switch (ev) {
                .delta => |d| {
                    defer alloc.free(d);
                    try got.appendSlice(alloc, d);
                },
                .done => done = true,
                .err => |e| {
                    std.debug.print("unexpected client error: {s}\n", .{e});
                    alloc.free(e);
                    return error.TestUnexpectedResult;
                },
                .cancelled, .tool_calls => return error.TestUnexpectedResult,
            }
        } else std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
    }
    try std.testing.expect(done);
    try std.testing.expectEqualStrings("final", got.items);

    const r1 = try tmp.dir.readFileAlloc(io, "request-1.json", alloc, .limited(4096));
    defer alloc.free(r1);
    try std.testing.expectEqualStrings("{\"round\":1}", r1);
    const r2 = try tmp.dir.readFileAlloc(io, "request-2.json", alloc, .limited(4096));
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("{\"round\":2}", r2);
    const latest = try tmp.dir.readFileAlloc(io, "request.json", alloc, .limited(4096));
    defer alloc.free(latest);
    try std.testing.expectEqualStrings("{\"round\":2}", latest);
}
