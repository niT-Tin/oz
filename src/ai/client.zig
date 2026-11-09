//! One in-flight streaming chat request (M1).
//!
//! The worker runs on a plain `std.Thread`; the UI thread never blocks.
//! Threads share only owned bytes: the request spec is duplicated into the
//! client before spawn, and the worker pushes owned `Event` payloads into a
//! mutex-protected FIFO. `pop` transfers ownership back to the App.
//!
//! The transport runs in a cancellable `std.Io` task. A small supervisor
//! handles cancellation off the UI thread, including a blocked DNS lookup,
//! connect, TLS handshake, response header or body read. The App additionally
//! drops events as soon as the user cancels.
//!
//! Transport:
//!   - normal: `std.http.Client` POST {base}/chat/completions, TLS via the
//!     standard CA bundle (verification stays enabled),
//!   - test seam: `OZ_AI_MOCK_DIR` writes `request.json` and replays
//!     `stream.sse` in small paced chunks (plus an optional `error.txt`).
//!     Deliberately undocumented outside the code/DESIGN.
const std = @import("std");
const acp = @import("acp.zig");
const sse = @import("sse.zig");
const openai = @import("openai.zig");
const telemetry = @import("telemetry.zig");
const tools = @import("tools.zig");

pub const Event = union(enum) {
    /// Transport progressed without changing the transcript.
    acp_permission: []u8,
    phase: telemetry.Phase,
    /// Provider-reported token accounting (DeepSeek sends a final usage-only chunk).
    usage: telemetry.Usage,
    /// A content delta (owned).
    delta: []u8,
    /// The stream completed ([DONE] or EOF after any usage-only chunk).
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
            .acp_permission => |d| alloc.free(d),
            .delta => |d| alloc.free(d),
            .err => |e| alloc.free(e),
            .tool_calls => |calls| tools.freeCalls(alloc, calls),
            .phase, .usage, .done, .cancelled => {},
        }
    }
};

pub const Spec = struct {
    /// Full completions endpoint URL (already includes /chat/completions).
    acp_command: ?[]const u8 = null,
    acp_cwd: ?[]const u8 = null,
    acp_root: ?[]const u8 = null,
    acp_prompt: ?[]const u8 = null,
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
    acp_command: ?[]u8,
    acp_cwd: ?[]u8,
    acp_root: ?[]u8,
    acp_prompt: ?[]u8,
    url: []u8,
    api_key: ?[]u8,
    body: []u8,
    mock_dir: ?[]u8,
    chunk_bytes: usize,
    chunk_delay_ms: u64,
    /// 1-based request number for this client (OZ_AI_MOCK_DIR fixtures).
    seq: u32,

    fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        inline for (.{ "acp_command", "acp_cwd", "acp_root", "acp_prompt" }) |f| {
            if (@field(self, f)) |v| alloc.free(v);
        }
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
    acp_connection: ?acp.Connection = null,
    permission: std.atomic.Value(u8) = .init(0),
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
        if (self.acp_connection) |*c| c.deinit();
        for (self.events.items) |ev| ev.deinit(self.alloc);
        self.events.deinit(self.alloc);
    }

    /// Begin one stream. Fails with `error.Busy` while a previous worker is
    /// still alive; the caller must cancel and let it finish first.
    pub fn start(self: *Client, spec: Spec) StartError!void {
        // Joining a live transport here would block the UI on the provider.
        // Cancellation is handled by the supervisor; a retry can reuse this
        // client as soon as it has published `running = false`.
        if (self.running.load(.acquire)) return error.Busy;
        self.joinThread();
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

        var acp_fields: [4]?[]u8 = @splat(null);
        errdefer for (acp_fields) |v| {
            if (v) |b| self.alloc.free(b);
        };
        inline for (.{ "acp_command", "acp_cwd", "acp_root", "acp_prompt" }, 0..) |f, i| {
            if (@field(spec, f)) |v| acp_fields[i] = self.alloc.dupe(u8, v) catch return error.OutOfMemory;
        }
        self.permission.store(0, .release);
        self.request_seq +%= 1;
        self.job = .{
            .acp_command = acp_fields[0],
            .acp_cwd = acp_fields[1],
            .acp_root = acp_fields[2],
            .acp_prompt = acp_fields[3],
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

    /// Request cancellation without waiting on the UI thread. The supervisor
    /// interrupts the transport's current cancellable I/O operation.
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
        if (self.cancel.load(.acquire)) return;
        const copy = self.alloc.dupe(u8, text) catch return;
        self.push(.{ .err = copy }) catch {};
    }

    fn pushErrorFmt(self: *Client, comptime fmt: []const u8, args: anytype) void {
        if (self.cancel.load(.acquire)) return;
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.push(.{ .err = text }) catch {};
    }

    fn checkCancel(self: *Client) error{Cancelled}!void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
    }

    fn workerMain(self: *Client) void {
        defer self.running.store(false, .release);
        var transport_done = std.atomic.Value(bool).init(false);
        var task = self.io.concurrent(transportMain, .{ self, &transport_done }) catch |e| {
            self.pushErrorFmt("transport start failed: {s}", .{@errorName(e)});
            return;
        };
        while (!transport_done.load(.acquire)) {
            if (self.cancel.load(.acquire)) {
                // Future.cancel both interrupts blocked std.Io operations
                // and awaits cleanup. Only this supervisor ever accesses
                // the Future, so cancellation cannot race task destruction.
                task.cancel(self.io);
                return;
            }
            std.Io.sleep(self.io, .fromMilliseconds(1), .real) catch {};
        }
        task.await(self.io);
    }

    fn transportMain(self: *Client, done: *std.atomic.Value(bool)) void {
        defer done.store(true, .release);
        defer if (self.cancel.load(.acquire)) self.push(.cancelled) catch {};
        const job = &self.job.?;
        const result = if (job.acp_command != null)
            self.runAcp(job)
        else if (job.mock_dir) |dir|
            self.runMock(job, dir)
        else
            self.runHttp(job);
        result catch |e| switch (e) {
            error.Cancelled, error.Canceled => {},
            else => self.pushErrorFmt("{s}", .{@errorName(e)}),
        };
    }

    pub fn acpText(self: *Client, text: []const u8) !void {
        try self.push(.{ .delta = try self.alloc.dupe(u8, text) });
    }
    pub fn acpPermission(self: *Client, title: []const u8) !bool {
        self.permission.store(0, .release);
        try self.push(.{ .acp_permission = try self.alloc.dupe(u8, title) });
        while (self.permission.load(.acquire) == 0) {
            try self.checkCancel();
            try std.Io.sleep(self.io, .fromMilliseconds(10), .real);
        }
        return self.permission.load(.acquire) == 1;
    }
    pub fn decidePermission(self: *Client, allow: bool) void {
        self.permission.store(if (allow) 1 else 2, .release);
    }
    fn runAcp(self: *Client, job: *const Job) !void {
        errdefer if (self.acp_connection) |*c| {
            c.deinit();
            self.acp_connection = null;
        };
        if (self.acp_connection == null) self.acp_connection = try acp.Connection.start(self.alloc, self.io, job.acp_command.?, job.acp_cwd orelse job.acp_root.?);
        try self.push(.{ .phase = .streaming });
        try self.acp_connection.?.prompt(job.acp_root.?, job.acp_prompt.?, self);
        try self.push(.done);
    }

    // ---- mock transport (e2e seam) ----

    fn runMock(self: *Client, job: *const Job, dir: []const u8) !void {
        try self.checkCancel();
        try self.push(.{ .phase = .waiting });
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
        if (try self.finishStream(&acc)) return;
        self.push(.done) catch {};
    }

    // ---- HTTP transport ----

    fn runHttp(self: *Client, job: *const Job) !void {
        try self.checkCancel();
        try self.push(.{ .phase = .connecting });
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
        // SSE must stay uncompressed: `Response.reader(&transfer)` passes the
        // 4 KiB transfer buffer as the decompression window, which is smaller
        // than gzip's 32 KiB window. A gzip SSE body then reads as immediate
        // EOF, producing a silent empty completion. Only request identity.
        req.accept_encoding = @splat(false);
        req.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;
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
        try self.push(.{ .phase = .waiting });

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
                if (n == 0) continue;
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
            // `readVec` can return 0 after filling the reader's internal
            // buffer; it is not EOF. The next call drains that buffer.
            if (n == 0) continue;
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
        if (try self.finishStream(&acc)) return;
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
                    if (delta.error_message) |message| {
                        // A 200 response can still carry an error object
                        // inside the SSE stream. Treat it as terminal; a
                        // silent "complete" with no transcript is worse.
                        self.pushErrorFmt("provider error: {s}", .{message});
                        protocol_failed.* = true;
                        return;
                    }
                    try self.push(.{ .phase = .streaming });
                    if (delta.usage) |usage| try self.push(.{ .usage = usage });
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
                        self.push(.{ .delta = copy }) catch {};
                    }
                    // A finish_reason may be followed by DeepSeek's usage-only
                    // chunk. Stop on [DONE] or EOF, not before that accounting.
                },
            }
        }
    }

    /// Convert a completed stream into exactly one terminal event. A reply
    /// with neither text nor tool calls is a provider/proxy failure, not a
    /// successful blank answer: returning `true` means an error was queued
    /// and the caller must not emit `.done`.
    fn finishStream(self: *Client, acc: *tools.Accumulator) !bool {
        if (!acc.sawText() and !acc.hasToolCalls()) {
            if (acc.finishReason()) |reason| {
                if (reason == .tool_calls) {
                    self.pushError("tool call protocol: tool_calls finish without calls");
                } else {
                    self.pushErrorFmt("provider returned an empty response ({s})", .{@tagName(reason)});
                }
            } else {
                self.pushError("provider returned an empty response");
            }
            return true;
        }
        try self.finalizeToolTurn(acc);
        return false;
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

test "client: mock stream emits phases, deltas, DeepSeek usage and done" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"mock \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"reply\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1200,\"completion_tokens\":42,\"total_tokens\":1242}}\n\n" ++
        "data: [DONE]\n\n";
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
    var saw_waiting = false;
    var saw_streaming = false;
    var got_usage: ?telemetry.Usage = null;
    var done = false;
    var waited_ms: u32 = 0;
    while (!done and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .acp_permission => unreachable,
                .phase => |phase| switch (phase) {
                    .waiting => saw_waiting = true,
                    .streaming => saw_streaming = true,
                    else => {},
                },
                .usage => |usage| got_usage = usage,
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
    try std.testing.expect(saw_waiting);
    try std.testing.expect(saw_streaming);
    try std.testing.expectEqualStrings("mock reply", got.items);
    try std.testing.expectEqual(@as(u64, 1242), got_usage.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 1200), got_usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 42), got_usage.?.completion_tokens);

    const req = try tmp.dir.readFileAlloc(io, "request.json", alloc, .limited(4096));
    defer alloc.free(req);
    try std.testing.expectEqualStrings("{\"model\":\"mock-model\"}", req);
}

test "client: SSE error payload becomes a terminal error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "stream.sse",
        .data = "data: {\"error\":{\"message\":\"Insufficient Balance\"}}\n\n",
    });

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

    var saw_error = false;
    var waited_ms: u32 = 0;
    while (!saw_error and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .acp_permission => unreachable,
                .err => |e| {
                    try std.testing.expect(std.mem.indexOf(u8, e, "Insufficient Balance") != null);
                    saw_error = true;
                },
                .done => return error.TestUnexpectedResult,
                else => {},
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    try std.testing.expect(saw_error);
}

test "client: stream with no text or tool calls reports an empty response" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "stream.sse",
        .data = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"insufficient_system_resource\"}]}\n\n" ++
            "data: [DONE]\n\n",
    });

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

    var saw_error = false;
    var waited_ms: u32 = 0;
    while (!saw_error and waited_ms < 3000) : (waited_ms += 5) {
        if (client.pop()) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .acp_permission => unreachable,
                .err => |e| {
                    try std.testing.expect(std.mem.indexOf(u8, e, "empty response") != null);
                    try std.testing.expect(std.mem.indexOf(u8, e, "insufficient_system_resource") != null);
                    saw_error = true;
                },
                .done => return error.TestUnexpectedResult,
                else => {},
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(5), .real) catch {};
        }
    }
    try std.testing.expect(saw_error);
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
                .acp_permission => unreachable,
                .err => |e| saw_err = e,
                .phase, .usage, .delta, .done, .cancelled => ev.deinit(alloc),
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

/// A real loopback peer that reads the request (or TLS ClientHello), then
/// deliberately stops sending bytes. The deadline only makes a regression
/// fail instead of hanging the test runner; a correct client cancels while
/// the peer is still waiting.
const StalledPeer = struct {
    server: std.Io.net.Server,
    mode: enum { headers, body, tls },
    ready: std.Io.Event = .unset,
    release: std.Io.Event = .unset,

    fn run(self: *StalledPeer, io: std.Io) !void {
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var request: [8192]u8 = undefined;
        var slices: [1][]u8 = .{&request};
        _ = try stream.readWithControl(io, &slices, &.{});
        if (self.mode == .body) {
            var writer = stream.writer(io, &.{});
            try writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                    "33\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n\r\n",
            );
            try writer.interface.flush();
        }
        self.ready.set(io);
        self.release.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => {},
            else => return e,
        };
    }
};

fn waitClientStopped(client: *Client, io: std.Io) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(1));
    while (client.isRunning()) {
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return error.TestUnexpectedResult;
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    }
}

test "client: cancel interrupts silent HTTP headers, SSE body and TLS handshake" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ .headers, .body, .tls }) |mode| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var peer: StalledPeer = .{ .server = try address.listen(io, .{ .reuse_address = true }), .mode = mode };
        defer peer.server.deinit(io);
        var peer_task = try io.concurrent(StalledPeer.run, .{ &peer, io });
        defer peer_task.cancel(io) catch {};
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}://127.0.0.1:{d}/chat/completions", .{
            if (mode == .tls) "https" else "http", peer.server.socket.address.ip4.port,
        });
        var client = Client.init(alloc, io);
        defer client.deinit();
        try client.start(.{ .url = url, .body = "{}" });
        try peer.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        // Make the body case prove a parsed delta preceded the stalled read.
        if (mode == .body) {
            var got_delta = false;
            var waited: u32 = 0;
            while (!got_delta and waited < 1000) : (waited += 1) {
                while (client.pop()) |ev| {
                    if (ev == .delta) got_delta = true;
                    ev.deinit(alloc);
                }
                if (!got_delta) try std.Io.sleep(io, .fromMilliseconds(1), .real);
            }
            try std.testing.expect(got_delta);
        }
        client.requestCancel();
        // start must never join a live worker. It can report Busy while the
        // supervisor interrupts I/O, then the same client must be reusable.
        const before = std.Io.Timestamp.now(io, .awake).nanoseconds;
        client.start(.{ .url = "invalid", .body = "{}" }) catch |e| try std.testing.expectEqual(error.Busy, e);
        const start_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - before, std.time.ns_per_ms);
        try std.testing.expect(start_ms < 250);
        client.requestCancel();
        try waitClientStopped(&client, io);
        peer.release.set(io);
        try peer_task.await(io);
        try client.start(.{ .url = "invalid", .body = "{}" });
        try waitClientStopped(&client, io);
    }
}

test "client: deinit interrupts a peer that never sends HTTP headers" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var peer: StalledPeer = .{ .server = try address.listen(io, .{ .reuse_address = true }), .mode = .headers };
    defer peer.server.deinit(io);
    var peer_task = try io.concurrent(StalledPeer.run, .{ &peer, io });
    defer peer_task.cancel(io) catch {};
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/chat/completions", .{peer.server.socket.address.ip4.port});
    var client = Client.init(std.testing.allocator, io);
    var client_live = true;
    defer if (client_live) client.deinit();
    try client.start(.{ .url = url, .body = "{}" });
    try peer.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const before = std.Io.Timestamp.now(io, .awake).nanoseconds;
    client.deinit();
    client_live = false;
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - before, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 1000);
    peer.release.set(io);
    try peer_task.await(io);
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
                .acp_permission => unreachable,
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
                .phase, .usage => {},
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
                .acp_permission => unreachable,
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
                .acp_permission => unreachable,
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
                .acp_permission => unreachable,
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
                .phase, .usage => {},
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

fn testAcp(mode: []const u8, allow: bool, expected_error: ?[]const u8, turns: usize) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const script = try std.fs.path.join(a, &.{ root, "test/fixtures/acp_agent.py" });
    defer a.free(script);
    const command = try std.json.Stringify.valueAlloc(a, .{ "python3", "-u", script, mode }, .{});
    defer a.free(command);
    var c = Client.init(a, io);
    defer c.deinit();
    for (0..turns) |turn| {
        try c.start(.{ .url = "", .body = "", .acp_command = command, .acp_root = root, .acp_prompt = "hello" });
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        var terminal = false;
        var saw_permission = false;
        var failed = false;
        var ticks: usize = 0;
        while (!terminal and ticks < 3000) : (ticks += 1) {
            if (c.pop()) |ev| {
                defer ev.deinit(a);
                switch (ev) {
                    .delta => |bytes| try text.appendSlice(a, bytes),
                    .acp_permission => {
                        saw_permission = true;
                        c.decidePermission(allow);
                    },
                    .done => terminal = true,
                    .cancelled => {
                        terminal = true;
                        failed = true;
                    },
                    .err => |message| {
                        terminal = true;
                        failed = true;
                        if (expected_error) |expected| try std.testing.expect(std.mem.indexOf(u8, message, expected) != null) else return error.UnexpectedAcpError;
                    },
                    .phase => {},
                    else => return error.UnexpectedAcpEvent,
                }
            } else try std.Io.sleep(io, .fromMilliseconds(2), .real);
            if (std.mem.eql(u8, mode, "hang") and ticks == 20) c.requestCancel();
        }
        try std.testing.expect(terminal);
        c.joinAfterTerminal();
        if (expected_error == null and !std.mem.eql(u8, mode, "hang")) {
            try std.testing.expect(!failed);
            const reply = try std.fmt.allocPrint(a, "ACP_REPLY_{d} 中文", .{turn + 1});
            defer a.free(reply);
            try std.testing.expect(std.mem.indexOf(u8, text.items, reply) != null);
            try std.testing.expect(std.mem.indexOf(u8, text.items, "WRONG_SESSION") == null);
        } else try std.testing.expect(failed);
        if (std.mem.eql(u8, mode, "permission")) {
            try std.testing.expect(saw_permission);
            try std.testing.expect(std.mem.indexOf(u8, text.items, if (allow) "PERMISSION_yes" else "PERMISSION_no") != null);
        }
    }
}
test "ACP fragmented UTF-8, tool updates, session isolation and two turns" {
    try testAcp("normal", false, null, 2);
}
test "ACP permission string IDs allow once" {
    try testAcp("permission", true, null, 1);
}
test "ACP permission rejects explicitly" {
    try testAcp("permission", false, null, 1);
}
test "ACP disconnect and malformed JSON settle as errors" {
    try testAcp("disconnect", false, "AcpDisconnected", 1);
    try testAcp("malformed", false, "SyntaxError", 1);
}
test "ACP rejects version mismatch and remote errors" {
    try testAcp("version", false, "UnsupportedAcpVersion", 1);
    try testAcp("error", false, "AcpRemoteError", 1);
}
test "ACP frame size bound" {
    try testAcp("oversized", false, "AcpFrameTooLarge", 1);
}
test "ACP cancellation interrupts blocked harness" {
    try testAcp("hang", false, null, 1);
}
