//! LSP client core (DESIGN.md §9.1): spawns a language server per filetype,
//! performs the initialize handshake, keeps text in sync (didOpen/didChange/
//! didClose) and funnels every incoming message through a reader thread into
//! a queue the main loop drains each frame. Requests carry an id and a result
//! slot; notifications are handed to a caller-supplied handler.
//!
//! Design notes:
//! - one Client per filetype (the App owns the current one); buffer switches
//!   didClose + didOpen, and the App replaces the client when the filetype
//!   changes.
//! - the queue moves RAW frame content across threads (duped bytes); parsing
//!   happens on the main thread in `drain`, so no JSON value is shared
//!   between threads.
//! - a missing server binary is not an error: `start` returns
//!   error.NoLspServer and the App simply renders without LSP.

const std = @import("std");
const json_rpc = @import("../util/json_rpc.zig");
const server_config = @import("server_config.zig");

/// Thread-safe FIFO of raw JSON-RPC frame contents (owned bytes). Uses the
/// io-aware primitives from std.Io (Zig 0.16 moved Mutex/Condition there).
const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,

    fn push(self: *Queue, alloc: std.mem.Allocator, content: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const copy = try alloc.dupe(u8, content);
        errdefer alloc.free(copy);
        try self.items.append(alloc, copy);
        self.cond.signal(self.io);
    }

    /// Non-blocking pop; null when empty.
    fn pop(self: *Queue) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Block up to `timeout_ns` for an item; null on timeout. Polls at 20ms —
    /// used only for the one-shot initialize handshake, so latency is fine.
    fn popTimeout(self: *Queue, timeout_ns: i128) ?[]u8 {
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const deadline = now + timeout_ns;
        while (true) {
            if (self.pop()) |c| return c;
            if (std.Io.Timestamp.now(self.io, .real).nanoseconds >= deadline) return null;
            std.Io.sleep(self.io, .fromNanoseconds(20 * std.time.ns_per_ms), .real) catch {};
        }
    }

    fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        for (self.items.items) |c| alloc.free(c);
        self.items.deinit(alloc);
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Filetype this client serves (borrowed; App owns the string).
    lang: []const u8,
    /// Document URI currently open in this client (owned).
    uri: []u8,
    /// Incremented on every didChange (LSP version).
    version: i32 = 0,

    proc: std.process.Child,
    stdin: std.Io.File,
    next_id: u64 = 1,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue: Queue,

    /// Pending request result slots, keyed by id (main-thread only).
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        id: u64,
        slot: *?std.json.Value, // filled on the matching response
    };

    /// Spawn the server for `lang`, handshake, and open `uri` with `text`.
    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        lang: []const u8,
        uri: []const u8,
        text: []const u8,
    ) !*Client {
        const argv = server_config.commandFor(lang) orelse return error.NoLspServer;
        var proc = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
        });
        errdefer {
            _ = proc.kill(io);
            _ = proc.wait(io) catch {};
        }

        const self = try alloc.create(Client);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .lang = lang,
            .uri = try alloc.dupe(u8, uri),
            .proc = proc,
            .stdin = proc.stdin orelse return error.NoStdin,
            .queue = .{ .io = io },
        };
        errdefer self.alloc.free(self.uri);

        // Reader thread first: the initialize response arrives through it.
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
        errdefer self.thread.?.join();

        // initialize request (synchronous handshake, 5s cap). The response
        // (capabilities) is discarded for now — future features consume it.
        const init_id = self.next_id;
        self.next_id += 1;
        {
            var init_params = try initParams(self);
            defer json_rpc.freeValue(self.alloc, &init_params);
            const content = try json_rpc.encodeRequest(self.alloc, init_id, "initialize", init_params);
            defer self.alloc.free(content);
            try self.writeFrameToStdin(content);
        }
        var init_msg = try self.waitResponse(init_id);
        defer init_msg.deinit(self.alloc);

        // empty initialized notification
        {
            var empty = try std.json.ObjectMap.init(alloc, &.{}, &.{});
            defer empty.deinit(alloc);
            const content = try json_rpc.encodeNotification(self.alloc, "initialized", .{ .object = empty });
            defer self.alloc.free(content);
            try self.writeFrameToStdin(content);
        }
        try self.didOpen(text);
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        _ = self.proc.kill(self.io);
        _ = self.proc.wait(self.io) catch {};
        self.queue.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        self.alloc.free(self.uri);
        self.alloc.destroy(self);
    }

    // ---- text sync ----

    fn didOpen(self: *Client, text: []const u8) !void {
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        try td.put(self.alloc, "uri", .{ .string = self.uri });
        try td.put(self.alloc, "version", .{ .integer = 1 });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "text", .{ .string = text });
        var v = std.json.Value{ .object = params };
        defer json_rpc.freeValue(self.alloc, &v);
        try self.notify("textDocument/didOpen", v);
    }

    pub fn didChange(self: *Client, text: []const u8) !void {
        self.version += 1;
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        try td.put(self.alloc, "uri", .{ .string = self.uri });
        try td.put(self.alloc, "version", .{ .integer = self.version });
        var change = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer change.deinit(self.alloc);
        try change.put(self.alloc, "text", .{ .string = text });
        var changes = std.json.Array.init(self.alloc);
        errdefer changes.deinit();
        try changes.append(.{ .object = change });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "contentChanges", .{ .array = changes });
        var v = std.json.Value{ .object = params };
        defer json_rpc.freeValue(self.alloc, &v);
        try self.notify("textDocument/didChange", v);
    }

    pub fn didClose(self: *Client) !void {
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        try td.put(self.alloc, "uri", .{ .string = self.uri });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        var v = std.json.Value{ .object = params };
        defer json_rpc.freeValue(self.alloc, &v);
        try self.notify("textDocument/didClose", v);
    }

    // ---- requests / notifications ----

    /// Send a request; the response result lands in `slot` when `drain`
    /// matches it (main thread). Caller frees `slot` once set.
    pub fn request(self: *Client, method: []const u8, params: std.json.Value, slot: *?std.json.Value) !void {
        const id = self.next_id;
        self.next_id += 1;
        try self.pending.append(self.alloc, .{ .id = id, .slot = slot });
        const content = try json_rpc.encodeRequest(self.alloc, id, method, params);
        defer self.alloc.free(content);
        try self.writeFrameToStdin(content);
    }

    /// Send a notification (no id, no response expected).
    pub fn notify(self: *Client, method: []const u8, params: std.json.Value) !void {
        const content = try json_rpc.encodeNotification(self.alloc, method, params);
        defer self.alloc.free(content);
        try self.writeFrameToStdin(content);
    }

    fn writeFrameToStdin(self: *Client, content: []const u8) !void {
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{content.len});
        try std.Io.File.writeStreamingAll(self.stdin, self.io, hdr);
        try std.Io.File.writeStreamingAll(self.stdin, self.io, content);
    }

    /// Drain all queued messages. Responses fill pending request slots;
    /// notifications go to `handler` (main thread — safe to touch editor
    /// state there). `msg` is deinit'd by drain after the handler returns.
    pub fn drain(self: *Client, ctx: anytype, handler: *const fn (@TypeOf(ctx), *Client, *json_rpc.Message) void) void {
        while (self.queue.pop()) |content| {
            defer self.alloc.free(content);
            var msg = json_rpc.parseMessage(self.alloc, content) catch continue;
            if (msg.id) |id| {
                // response → pending slot
                var i: usize = 0;
                while (i < self.pending.items.len) : (i += 1) {
                    if (self.pending.items[i].id == id) {
                        self.pending.items[i].slot.* = msg.result;
                        msg.result = null; // ownership moved
                        _ = self.pending.orderedRemove(i);
                        break;
                    }
                }
            } else if (msg.method) |_| {
                handler(ctx, self, &msg);
            }
            msg.deinit(self.alloc);
        }
    }

    /// Synchronous wait for the response with `want_id` (handshake).
    fn waitResponse(self: *Client, want_id: u64) !json_rpc.Message {
        while (self.queue.popTimeout(5 * std.time.ns_per_s)) |content| {
            defer self.alloc.free(content);
            var msg = json_rpc.parseMessage(self.alloc, content) catch continue;
            if (msg.id) |id| {
                if (id == want_id) return msg;
            }
            msg.deinit(self.alloc);
        }
        return error.LspHandshakeTimeout;
    }

    // ---- reader thread ----

    fn readerMain(self: *Client) void {
        const stdout = self.proc.stdout orelse return;
        while (!self.stop.load(.acquire)) {
            const content = readFrameFromFile(self.alloc, stdout, self.io) catch break;
            if (content) |c| {
                self.queue.push(self.alloc, c) catch {
                    self.alloc.free(c);
                    break;
                };
            } else {
                break; // clean EOF
            }
        }
        self.stop.store(true, .release);
    }

    // ---- params builders ----

    fn initParams(self: *Client) !std.json.Value {
        var inner = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer inner.deinit(self.alloc);
        var cap = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer cap.deinit(self.alloc);
        try cap.put(self.alloc, "processId", .{ .integer = @intCast(std.os.linux.getpid()) });
        try cap.put(self.alloc, "rootUri", .{ .string = "file:///" });
        try cap.put(self.alloc, "capabilities", .{ .object = inner });
        return .{ .object = cap };
    }
};

/// Read one JSON-RPC frame (Content-Length header + body) from a pipe/file.
/// Returns null on a clean EOF at a message boundary. `json_rpc.readFrame`
/// targets in-memory readers; pipes need explicit streaming reads.
fn readFrameFromFile(alloc: std.mem.Allocator, file: std.Io.File, io: std.Io) !?[]u8 {
    var hdr: [8192]u8 = undefined;
    var hdr_len: usize = 0;
    while (true) {
        const n = try file.readStreaming(io, &.{hdr[hdr_len..]});
        if (n == 0) return if (hdr_len == 0) null else error.UnexpectedEof;
        hdr_len += n;
        if (std.mem.indexOf(u8, hdr[0..hdr_len], "\r\n\r\n")) |sep| {
            const header = hdr[0..sep];
            var cl: ?usize = null;
            var it = std.mem.splitScalar(u8, header, '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                    if (cl != null) return error.InvalidHeader;
                    cl = std.fmt.parseInt(usize, val, 10) catch return error.InvalidContentLength;
                }
            }
            const clen = cl orelse return error.MissingContentLength;
            const body = try alloc.alloc(u8, clen);
            errdefer alloc.free(body);
            const have = hdr_len - (sep + 4);
            const take = @min(have, clen);
            @memcpy(body[0..take], hdr[sep + 4 .. sep + 4 + take]);
            var got = take;
            while (got < clen) {
                const m = try file.readStreaming(io, &.{body[got..]});
                if (m == 0) return error.UnexpectedEof;
                got += m;
            }
            return body;
        }
        if (hdr_len >= hdr.len) return error.InvalidHeader;
    }
}

test "queue: push/pop/popTimeout round-trip" {
    const alloc = std.testing.allocator;
    var q = Queue{ .io = std.testing.io };
    defer q.deinit(alloc);
    try q.push(alloc, "hello");
    try q.push(alloc, "world");
    const a = q.pop().?;
    defer alloc.free(a);
    try std.testing.expectEqualStrings("hello", a);
    const b = q.pop().?;
    defer alloc.free(b);
    try std.testing.expectEqualStrings("world", b);
    try std.testing.expect(q.pop() == null);
}

test "queue: popTimeout returns null on timeout" {
    const alloc = std.testing.allocator;
    var q = Queue{ .io = std.testing.io };
    defer q.deinit(alloc);
    const start = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    const item = q.popTimeout(20 * std.time.ns_per_ms);
    try std.testing.expect(item == null);
    try std.testing.expect(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - start < std.time.ns_per_s);
}
