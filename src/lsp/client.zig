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
    /// Heap-held argv when the server command came from OZ_LSP_CMD (freed on
    /// deinit); null when argv points at the static server_config table.
    argv_override: ?[]const []const u8 = null,

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
        env_map: *std.process.Environ.Map,
        lang: []const u8,
        uri: []const u8,
        text: []const u8,
    ) !*Client {
        var argv = server_config.commandFor(lang) orelse return error.NoLspServer;
        // Test hook: OZ_LSP_CMD overrides the server command (e2e injects the
        // mock server this way). The env string is borrowed (env_map lives for
        // the whole process); only the argv array is heap-held (stored on the
        // Client once it exists).
        var argv_override: ?[]const []const u8 = null;
        if (env_map.get("OZ_LSP_CMD")) |cmd| {
            const arr = try alloc.alloc([]const u8, 1);
            errdefer alloc.free(arr);
            arr[0] = cmd;
            argv = arr;
            argv_override = arr;
        }
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
            .argv_override = argv_override,
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
            var init_params = initParams(self) catch |e| {
                return e;
            };
            defer self.freeInitParams(&init_params);
            const content = json_rpc.encodeRequest(self.alloc, init_id, "initialize", init_params) catch |e| {
                return e;
            };
            defer self.alloc.free(content);
            self.writeFrameToStdin(content) catch |e| {
                return e;
            };
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
        // Kill the server FIRST: the reader thread blocks in readStreaming
        // until stdout EOF, so joining before the kill would deadlock on a
        // server that never closes its pipe. NOTE: Child.kill already cleans
        // up (id → null), so no wait() afterwards — it would assert.
        _ = self.proc.kill(self.io);
        if (self.thread) |t| t.join();
        self.queue.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        if (self.argv_override) |a| self.alloc.free(a);
        self.alloc.free(self.uri);
        self.alloc.destroy(self);
    }

    // ---- params lifetime ----
    // json_rpc.freeValue frees every key/string it finds, but this module's
    // manually built params use comptime literal keys — freeing those crashes.
    // These per-shape helpers free the dupe'd strings and deinit the maps.

    fn freeDidOpenParams(self: *Client, v: *std.json.Value) void {
        const params = &v.object;
        var td = params.get("textDocument").?;
        self.alloc.free(td.object.get("uri").?.string);
        td.object.deinit(self.alloc);
        self.alloc.free(params.get("text").?.string);
        params.deinit(self.alloc);
    }

    fn freeDidChangeParams(self: *Client, v: *std.json.Value) void {
        const params = &v.object;
        var td = params.get("textDocument").?;
        self.alloc.free(td.object.get("uri").?.string);
        td.object.deinit(self.alloc);
        var changes = params.get("contentChanges").?;
        const change = &changes.array.items[0].object;
        self.alloc.free(change.get("text").?.string);
        change.deinit(self.alloc);
        changes.array.deinit();
        params.deinit(self.alloc);
    }

    fn freeDidCloseParams(self: *Client, v: *std.json.Value) void {
        const params = &v.object;
        var td = params.get("textDocument").?;
        self.alloc.free(td.object.get("uri").?.string);
        td.object.deinit(self.alloc);
        params.deinit(self.alloc);
    }

    fn freeInitParams(self: *Client, v: *std.json.Value) void {
        var cap = &v.object;
        self.alloc.free(cap.get("rootUri").?.string);
        var inner = cap.get("capabilities").?;
        inner.object.deinit(self.alloc);
        cap.deinit(self.alloc);
    }

    // ---- text sync ----

    fn didOpen(self: *Client, text: []const u8) !void {
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        // freeValue frees every .string it finds, so every string must be a
        // heap copy (dupe) — borrowed slices would be freed and crash.
        const uri_copy = try self.alloc.dupe(u8, self.uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        try td.put(self.alloc, "version", .{ .integer = 1 });
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "text", .{ .string = text_copy });
        var v = std.json.Value{ .object = params };
        defer self.freeDidOpenParams(&v);
        try self.notify("textDocument/didOpen", v);
    }

    pub fn didChange(self: *Client, text: []const u8) !void {
        self.version += 1;
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        const uri_copy = try self.alloc.dupe(u8, self.uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        try td.put(self.alloc, "version", .{ .integer = self.version });
        var change = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer change.deinit(self.alloc);
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        try change.put(self.alloc, "text", .{ .string = text_copy });
        var changes = std.json.Array.init(self.alloc);
        errdefer changes.deinit();
        try changes.append(.{ .object = change });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "contentChanges", .{ .array = changes });
        var v = std.json.Value{ .object = params };
        defer self.freeDidChangeParams(&v);
        try self.notify("textDocument/didChange", v);
    }

    pub fn didClose(self: *Client) !void {
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        const uri_copy = try self.alloc.dupe(u8, self.uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        var v = std.json.Value{ .object = params };
        defer self.freeDidCloseParams(&v);
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
        var reader = FrameReader.init(self.alloc, stdout, self.io);
        defer reader.deinit();
        while (!self.stop.load(.acquire)) {
            const content = reader.next() catch break;
            if (content) |c| {
                // push dupes again into the queue; the frame body itself is
                // ours to free here
                self.queue.push(self.alloc, c) catch {
                    self.alloc.free(c);
                    break;
                };
                self.alloc.free(c);
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
        const root_copy = try self.alloc.dupe(u8, "file:///");
        errdefer self.alloc.free(root_copy);
        try cap.put(self.alloc, "rootUri", .{ .string = root_copy });
        try cap.put(self.alloc, "capabilities", .{ .object = inner });
        return .{ .object = cap };
    }
};

/// Buffered JSON-RPC frame reader for pipes. A single OS read can coalesce
/// several frames (or split one); the buffer holds leftovers for the next
/// `next()`, so back-to-back messages (e.g. the initialize response followed
/// immediately by a publishDiagnostics) are never lost.
pub const FrameReader = struct {
    alloc: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    pending: std.ArrayList(u8) = .empty,

    const max_header_len = 1 << 20;

    pub fn init(alloc: std.mem.Allocator, file: std.Io.File, io: std.Io) FrameReader {
        return .{ .alloc = alloc, .file = file, .io = io };
    }

    pub fn deinit(self: *FrameReader) void {
        self.pending.deinit(self.alloc);
    }

    pub fn next(self: *FrameReader) !?[]u8 {
        while (std.mem.indexOf(u8, self.pending.items, "\r\n\r\n") == null) {
            if (self.pending.items.len >= max_header_len) return error.InvalidHeader;
            const got = try self.fillMore();
            if (got == 0) {
                if (self.pending.items.len == 0) return null;
                return error.UnexpectedEof;
            }
        }
        while (self.pending.items.len >= 4 and
            std.mem.eql(u8, self.pending.items[0..4], "\r\n\r\n"))
        {
            self.drop(4);
            while (std.mem.indexOf(u8, self.pending.items, "\r\n\r\n") == null) {
                if (self.pending.items.len >= max_header_len) return error.InvalidHeader;
                const got = try self.fillMore();
                if (got == 0) {
                    if (self.pending.items.len == 0) return null;
                    return error.UnexpectedEof;
                }
            }
        }
        const sep = std.mem.indexOf(u8, self.pending.items, "\r\n\r\n").?;
        const header = self.pending.items[0..sep];
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
        const body_start = sep + 4;
        while (self.pending.items.len < body_start + clen) {
            const got = try self.fillMore();
            if (got == 0) return error.UnexpectedEof;
        }
        const body = try self.alloc.dupe(u8, self.pending.items[body_start .. body_start + clen]);
        errdefer self.alloc.free(body);
        const consumed = body_start + clen;
        if (consumed == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
        } else {
            const rest = self.pending.items[consumed..];
            std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
        return body;
    }

    fn fillMore(self: *FrameReader) !usize {
        var buf: [8192]u8 = undefined;
        const n = self.file.readStreaming(self.io, &.{buf[0..]}) catch |e| switch (e) {
            error.EndOfStream => return 0,
            else => return e,
        };
        if (n == 0) return 0;
        try self.pending.appendSlice(self.alloc, buf[0..n]);
        return n;
    }

    fn drop(self: *FrameReader, n: usize) void {
        if (n == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            return;
        }
        const rest = self.pending.items[n..];
        std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
        self.pending.shrinkRetainingCapacity(rest.len);
    }
};

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
