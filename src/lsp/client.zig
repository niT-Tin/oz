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
const types = @import("types.zig");

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
    /// Whether the server advertised inlayHintProvider (from initialize).
    /// When false the editor skips inlayHint requests entirely.
    caps_inlay: bool = false,
    /// Completion trigger characters declared by the server (e.g. "." for
    /// member access) — auto-suggest fires on these too, like blink.cmp's
    /// show_on_trigger_character. Owned strings; empty when undeclared.
    completion_triggers: std.ArrayList([]u8) = .empty,

    proc: std.process.Child,
    stdin: std.Io.File,
    next_id: u64 = 1,
    /// Heap-held argv when the server command came from OZ_LSP_CMD (freed on
    /// deinit); null when argv points at the static server_config table.
    argv_override: ?[]const []const u8 = null,
    /// Whether argv_override[0] is a heap-owned copy (resolveServerBinary's
    /// dupe) that deinit must free; OZ_LSP_CMD's entry is a borrowed env slice.
    argv_override_first_owned: bool = false,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the reader thread when the server's stdout hit EOF or a read
    /// error — i.e. the server EXITED (or crashed) on its own. The editor
    /// checks this after each drain: a dead server leaves pending requests
    /// hanging forever, so it must be torn down and reported.
    server_died: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue: Queue,

    /// Optional wake callback invoked from the reader thread whenever a
    /// message arrives. The editor uses it to post an event to its event
    /// loop, so asynchronous responses (diagnostics, navigation) are drained
    /// without waiting for a keypress. Thread-safe: the callback must only
    /// touch thread-safe state (e.g. vaxis postEvent).
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (ctx: *anyopaque) void = null,

    /// Pending request result slots, keyed by id (main-thread only).
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        id: u64,
        slot: *?std.json.Value, // filled on the matching response
    };

    /// Resolve a language server binary that is not on PATH by checking common
    /// install directories (nvim-mason, standalone mason, user local bin). The
    /// returned path is owned by the caller. null when nothing is found — spawn
    /// then falls back to execvp's PATH search (and may fail, which the App
    /// reports in the status bar).
    fn resolveServerBinary(
        alloc: std.mem.Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
        name: []const u8,
    ) ?[]u8 {
        const home = env_map.get("HOME") orelse return null;
        const dirs = [_][]const u8{
            ".local/share/nvim/mason/bin",
            ".local/share/mason/bin",
            ".local/bin",
            ".cargo/bin",
        };
        for (dirs) |dir| {
            const path = std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ home, dir, name }) catch continue;
            defer alloc.free(path);
            const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch continue;
            f.close(io);
            return alloc.dupe(u8, path) catch null;
        }
        return null;
    }

    /// Open the server's stderr log file (/tmp/oz-lsp-<lang>.log) for
    /// appending, so a server that fails to start leaves a diagnosable
    /// trace. null when it cannot be opened — spawn then discards stderr.
    /// Uses posix openat directly because std.Io.File exposes no
    /// seek-to-end; O_APPEND makes the child's writes land at the end of
    /// the existing log regardless of the shared file offset.
    fn openServerLog(lang: []const u8) ?std.Io.File {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/oz-lsp-{s}.log", .{lang}) catch return null;
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        ) catch return null;
        return .{ .handle = fd, .flags = .{ .nonblocking = false } };
    }

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
        var argv_first_owned = false;
        if (env_map.get("OZ_LSP_CMD")) |cmd| {
            const arr = try alloc.alloc([]const u8, 1);
            errdefer alloc.free(arr);
            arr[0] = cmd;
            argv = arr;
            argv_override = arr;
        } else if (resolveServerBinary(alloc, io, env_map, argv[0])) |path| {
            // The server name is not on PATH (e.g. nvim-mason installs under
            // ~/.local/share/nvim/mason/bin): point spawn at the resolved
            // absolute path instead of relying on execvp's PATH search.
            const arr = try alloc.alloc([]const u8, 1);
            errdefer alloc.free(arr);
            arr[0] = path;
            argv = arr;
            argv_override = arr;
            argv_first_owned = true;
        }
        // Server stderr must NOT leak onto the editor's terminal (clangd
        // logs its indexing there, which would interleave with the TUI
        // frames): route it to a per-language log file instead; fall back to
        // discarding it when the log cannot be opened.
        const stderr_log: ?std.Io.File = openServerLog(lang);
        defer if (stderr_log) |f| f.close(io);
        // Spawn failure: free the heap-held argv (including the resolved
        // binary path). `proc` is only valid after a successful spawn, so the
        // cleanup cannot live in an errdefer that also touches proc.
        var proc = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (stderr_log) |f| .{ .file = f } else .ignore,
        }) catch |e| {
            if (argv_override) |arr| {
                if (argv_first_owned) alloc.free(arr[0]);
                alloc.free(arr);
            }
            return e;
        };
        // From here on the heap-held argv (if any) is owned by this cleanup
        // chain — covering failures of alloc.create/dupe before `self` fully
        // exists, which the self-based errdefers below cannot see.
        errdefer {
            if (argv_override) |arr| {
                if (argv_first_owned) alloc.free(arr[0]);
                alloc.free(arr);
            }
        }
        // Failures after a successful spawn must terminate the child.
        // kill() reaps it (id → null — a wait() after kill() would assert).
        // This covers failures before the reader thread exists; once the
        // thread is spawned its own errdefer (declared last, so it runs
        // FIRST) kills the server and joins the thread before `self` is
        // destroyed, flipping cleanup_proc so the child is never killed twice.
        var cleanup_proc = true;
        errdefer if (cleanup_proc) proc.kill(io);

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
            .argv_override_first_owned = argv_first_owned,
        };
        errdefer self.alloc.free(self.uri);

        // Reader thread first: the initialize response arrives through it.
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
        // Declared last so it runs FIRST on handshake failure (errdefers are
        // LIFO): the reader thread touches `self` (`stop.store` on exit), so
        // it must be joined before `self` is destroyed. kill FIRST — the
        // child's death EOFs the thread's blocking read — then join; joining
        // a live server would deadlock.
        errdefer {
            self.proc.kill(self.io);
            cleanup_proc = false;
            self.thread.?.join();
        }

        // initialize request (synchronous handshake, 30s cap — rust-analyzer
        // may need tens of seconds to load a large workspace before it can
        // answer). The response (capabilities) is consumed below.
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
        // Record server capabilities the editor feature gates on
        // (e.g. inlayHintProvider=false ⇒ don't send inlayHint requests).
        if (init_msg.result) |res| {
            if (res == .object) {
                if (res.object.get("capabilities")) |caps| {
                    if (caps == .object) {
                        if (caps.object.get("inlayHintProvider")) |p| {
                            // servers declare it as `true` or as an object
                            // {resolveProvider: bool}
                            self.caps_inlay = switch (p) {
                                .bool => |b| b,
                                .object => true,
                                else => false,
                            };
                        }
                        // completion trigger characters: auto-suggest fires
                        // on these too ("b." member access, "::", …)
                        if (caps.object.get("completionProvider")) |cp| {
                            if (cp == .object) {
                                if (cp.object.get("triggerCharacters")) |tc| {
                                    if (tc == .array) {
                                        for (tc.array.items) |ch| {
                                            if (ch != .string) continue;
                                            if (ch.string.len == 0) continue;
                                            const copy = alloc.dupe(u8, ch.string) catch continue;
                                            self.completion_triggers.append(alloc, copy) catch {
                                                alloc.free(copy);
                                            };
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

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
        // Leftover queue frames are freed here; unreceived response VALUES
        // live in the caller's slots (the App frees nav_slot etc. in its own
        // deinit), so the pending array itself is all we own.
        self.queue.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        for (self.completion_triggers.items) |t| self.alloc.free(t);
        self.completion_triggers.deinit(self.alloc);
        if (self.argv_override) |arr| {
            if (self.argv_override_first_owned) self.alloc.free(arr[0]);
            self.alloc.free(arr);
        }
        self.alloc.free(self.uri);
        self.alloc.destroy(self);
    }

    /// True when `text` is one of the server's completion trigger characters.
    /// Servers that support completion but declared no triggerCharacters get
    /// the lenient "." default (member access) so `b.` still auto-suggests.
    pub fn isCompletionTrigger(self: *const Client, text: []const u8) bool {
        for (self.completion_triggers.items) |t| {
            if (std.mem.eql(u8, t, text)) return true;
        }
        if (self.completion_triggers.items.len == 0 and std.mem.eql(u8, text, ".")) return true;
        return false;
    }

    // ---- params lifetime ----
    // json_rpc.freeValue frees every key/string it finds, but this module's
    // manually built params use comptime literal keys — freeing those crashes.
    // These per-shape helpers free the dupe'd strings and deinit the maps.

    fn freeDidOpenParams(self: *Client, v: *std.json.Value) void {
        const params = &v.object;
        var td = params.get("textDocument").?;
        self.alloc.free(td.object.get("uri").?.string);
        self.alloc.free(td.object.get("languageId").?.string);
        self.alloc.free(td.object.get("text").?.string);
        td.object.deinit(self.alloc);
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
        var folders = cap.get("workspaceFolders").?;
        const folder = &folders.array.items[0].object;
        self.alloc.free(folder.get("uri").?.string);
        self.alloc.free(folder.get("name").?.string);
        folder.deinit(self.alloc);
        folders.array.deinit();
        var inner = cap.get("capabilities").?;
        if (inner.object.getPtr("textDocument")) |td| {
            if (td.object.getPtr("inlayHint")) |ih| ih.object.deinit(self.alloc);
            if (td.object.getPtr("publishDiagnostics")) |pd| pd.object.deinit(self.alloc);
            td.object.deinit(self.alloc);
        }
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
        // The version counter covers didOpen too: versions must strictly
        // increase across the document's whole lifetime (1, 2, 3, ...).
        self.version += 1;
        try td.put(self.alloc, "version", .{ .integer = self.version });
        // languageId is required by the LSP textDocumentItem schema; servers
        // (clangd) refuse to add a document without it. Use the server's
        // declared id when it differs from the filetype — rust-analyzer
        // rejects the bare extension "rs" and only accepts "rust".
        const lang_copy = try self.alloc.dupe(u8, server_config.languageIdFor(self.lang));
        errdefer self.alloc.free(lang_copy);
        try td.put(self.alloc, "languageId", .{ .string = lang_copy });
        // text lives INSIDE textDocument (TextDocumentItem); putting it at the
        // top level makes strict servers (zls) fail to parse the notification.
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        try td.put(self.alloc, "text", .{ .string = text_copy });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
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

    /// Switch the client to a new document of the same filetype (the editor
    /// switched buffers): close the old document, retarget `uri`, open the
    /// new one. Versions keep increasing across the client's lifetime, which
    /// LSP requires.
    pub fn switchDocument(self: *Client, new_uri: []const u8, text: []const u8) !void {
        try self.didClose();
        const copy = try self.alloc.dupe(u8, new_uri);
        self.alloc.free(self.uri);
        self.uri = copy;
        try self.didOpen(text);
    }

    // ---- requests / notifications ----

    /// Send a request; the response result lands in `slot` when `drain`
    /// matches it (main thread). Caller frees `slot` once set.
    ///
    /// At most one in-flight request per slot: a new request for a slot that
    /// already has a pending entry REPLACES it (the old entry is dropped, so
    /// its late response — a slot's responses may arrive out of order — finds
    /// no pending id and is discarded instead of overwriting the newer
    /// result). Without this, two requests sharing a slot (formatting +
    /// rename, nav requests) could be consumed in arrival order, letting a
    /// stale response clobber the current one.
    pub fn request(self: *Client, method: []const u8, params: std.json.Value, slot: *?std.json.Value) !void {
        const id = self.next_id;
        self.next_id += 1;
        // encode first so a failure leaves no dangling pending entry
        const content = try json_rpc.encodeRequest(self.alloc, id, method, params);
        defer self.alloc.free(content);
        // drop any older in-flight request for the same slot (see above)
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].slot == slot) {
                _ = self.pending.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.pending.append(self.alloc, .{ .id = id, .slot = slot });
        self.writeFrameToStdin(content) catch |e| {
            // roll the pending entry back: a response for it will never come
            self.pending.items.len -= 1;
            return e;
        };
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
            if (msg.method != null) {
                if (msg.id) |id| {
                    // Server→client REQUEST (id + method), not a response:
                    // server id counters collide with ours (both count from
                    // small integers), so routing it to `pending` would
                    // silently consume a client request's slot. Answer with
                    // MethodNotFound instead, or servers that await a reply
                    // (rust-analyzer's workspace/configuration) stall.
                    self.answerServerRequest(id) catch {};
                } else {
                    handler(ctx, self, &msg);
                }
            } else if (msg.id) |id| {
                // response → pending slot. A slot may already hold an
                // un-consumed response if two requests shared it (e.g. the
                // App's single nav_slot): free the stale value first so the
                // earlier result is not leaked by the overwrite.
                var i: usize = 0;
                while (i < self.pending.items.len) : (i += 1) {
                    if (self.pending.items[i].id == id) {
                        if (self.pending.items[i].slot.*) |*old| {
                            json_rpc.freeValue(self.alloc, old);
                        }
                        self.pending.items[i].slot.* = msg.result;
                        msg.result = null; // ownership moved
                        _ = self.pending.orderedRemove(i);
                        break;
                    }
                }
            }
            msg.deinit(self.alloc);
        }
    }

    /// Synchronous wait for the response with `want_id` (handshake). Used
    /// only for initialize; every other response arrives asynchronously via
    /// `drain`, so the generous 30s cap applies to the handshake alone.
    fn waitResponse(self: *Client, want_id: u64) !json_rpc.Message {
        const deadline = std.Io.Timestamp.now(self.io, .real).nanoseconds + 30 * std.time.ns_per_s;
        while (std.Io.Timestamp.now(self.io, .real).nanoseconds < deadline) {
            // A server that died before answering (bad binary, crash on
            // startup — e.g. a rustup proxy with no default toolchain) will
            // never respond: bail out instead of freezing the UI for the
            // full 30s.
            if (self.server_died.load(.acquire)) return error.LspServerDied;
            const content = self.queue.popTimeout(100 * std.time.ns_per_ms) orelse continue;
            defer self.alloc.free(content);
            var msg = json_rpc.parseMessage(self.alloc, content) catch continue;
            // Only a bare response (id, no method) matches: a server→client
            // request may reuse the same id value (separate id space).
            if (msg.id) |id| {
                if (id == want_id and msg.method == null) return msg;
            }
            // A server→client request during the handshake must be answered
            // (MethodNotFound), or a server that blocks on its reply — e.g.
            // rust-analyzer's workspace/configuration — stalls until our
            // timeout expires and the whole start fails.
            if (msg.method != null and msg.id != null) {
                self.answerServerRequest(msg.id.?) catch {};
            }
            msg.deinit(self.alloc);
        }
        return error.LspHandshakeTimeout;
    }

    /// Answer a server→client request we don't implement with a
    /// MethodNotFound error response (the spec-sanctioned "unsupported").
    fn answerServerRequest(self: *Client, id: u64) !void {
        const content = try json_rpc.encodeError(self.alloc, id, -32601, "method not found");
        defer self.alloc.free(content);
        try self.writeFrameToStdin(content);
    }

    // ---- reader thread ----

    fn readerMain(self: *Client) void {
        const stdout = self.proc.stdout orelse return;
        var reader = FrameReader.init(self.alloc, stdout, self.io);
        defer reader.deinit();
        while (!self.stop.load(.acquire)) {
            const content = reader.next() catch {
                // read error — treat the server as gone
                self.server_died.store(true, .release);
                break;
            };
            if (content) |c| {
                // push dupes again into the queue; the frame body itself is
                // ours to free here
                self.queue.push(self.alloc, c) catch {
                    self.alloc.free(c);
                    break;
                };
                self.alloc.free(c);
                // Wake the editor's event loop so it drains this message
                // promptly (async responses don't wait for a keypress).
                if (self.wake_fn) |w| {
                    if (self.wake_ctx) |ctx| w(ctx);
                }
            } else {
                // clean EOF: the server closed its stdout (exit/crash) — it
                // is not coming back; flag it so the editor can report it.
                self.server_died.store(true, .release);
                break;
            }
        }
        self.stop.store(true, .release);
    }

    // ---- params builders ----

    /// Derive the workspace root directory from the open document's URI:
    /// the nearest ancestor containing a Cargo.toml (or rust-project.json —
    /// rust-analyzer's non-cargo project format), falling back to the
    /// document's own directory. rust-analyzer discovers the crate graph
    /// relative to this root; the old hardcoded "file:///" root left it
    /// without a manifest, so nothing ever resolved. Owned result.
    fn rootDir(self: *Client) ![]u8 {
        const path = types.fileUriToPath(self.alloc, self.uri) catch
            return self.alloc.dupe(u8, "/");
        defer self.alloc.free(path);
        const doc_dir = std.fs.path.dirname(path) orelse "/";
        var dir: []const u8 = doc_dir;
        while (true) {
            for ([_][]const u8{ "Cargo.toml", "rust-project.json" }) |marker| {
                const candidate = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir, marker });
                const exists = if (std.Io.Dir.cwd().openFile(self.io, candidate, .{ .mode = .read_only })) |f| blk: {
                    f.close(self.io);
                    break :blk true;
                } else |_| false;
                self.alloc.free(candidate);
                if (exists) return self.alloc.dupe(u8, dir);
            }
            dir = std.fs.path.dirname(dir) orelse break;
        }
        return self.alloc.dupe(u8, doc_dir);
    }

    fn initParams(self: *Client) !std.json.Value {
        // client capabilities: advertise the features the editor consumes so
        // strict servers (clangd/zls/rust-analyzer) provide them instead of
        // staying silent — inlayHint, publishDiagnostics (gutter markers),
        // hover, definition/references (navigation).
        var hint_cap = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer hint_cap.deinit(self.alloc);
        try hint_cap.put(self.alloc, "dynamicRegistration", .{ .bool = false });
        var diag_cap = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer diag_cap.deinit(self.alloc);
        try diag_cap.put(self.alloc, "relatedInformation", .{ .bool = true });
        var td_cap = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td_cap.deinit(self.alloc);
        try td_cap.put(self.alloc, "inlayHint", .{ .object = hint_cap });
        try td_cap.put(self.alloc, "publishDiagnostics", .{ .object = diag_cap });
        var inner = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer inner.deinit(self.alloc);
        try inner.put(self.alloc, "textDocument", .{ .object = td_cap });
        var cap = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer cap.deinit(self.alloc);
        try cap.put(self.alloc, "processId", .{ .integer = @intCast(std.os.linux.getpid()) });
        const root_dir = try self.rootDir();
        defer self.alloc.free(root_dir);
        const root_uri = try types.pathToFileUri(self.alloc, root_dir);
        errdefer self.alloc.free(root_uri);
        try cap.put(self.alloc, "rootUri", .{ .string = root_uri });
        // workspaceFolders mirrors rootUri (rust-analyzer's project
        // discovery reads the folders list); name is the root's basename.
        var folder = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer folder.deinit(self.alloc);
        const folder_uri = try self.alloc.dupe(u8, root_uri);
        errdefer self.alloc.free(folder_uri);
        try folder.put(self.alloc, "uri", .{ .string = folder_uri });
        const base = std.fs.path.basename(root_dir);
        const folder_name = try self.alloc.dupe(u8, if (base.len == 0) root_dir else base);
        errdefer self.alloc.free(folder_name);
        try folder.put(self.alloc, "name", .{ .string = folder_name });
        var folders = std.json.Array.init(self.alloc);
        errdefer folders.deinit();
        try folders.append(.{ .object = folder });
        try cap.put(self.alloc, "workspaceFolders", .{ .array = folders });
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
    /// Cap on a single JSON-RPC frame body. A malicious/broken server could
    /// claim a giant Content-Length and make us buffer forever; LSP payloads
    /// (diagnostics dumps) are large but far below this.
    const max_body_len = 1 << 26; // 64 MiB

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
        if (clen > max_body_len) return error.InvalidContentLength;
        const body_start = sep + 4;
        // guard against overflow of the size math when the server lies
        const need = std.math.add(usize, body_start, clen) catch return error.InvalidContentLength;
        while (self.pending.items.len < need) {
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

// ---------------------------------------------------------------------------
// Client state-machine tests (hand-built Client over pipes, no subprocess)
// ---------------------------------------------------------------------------

/// A Client whose stdin is a pipe's write end, with no spawned process and
/// no reader thread; tests drive the queue by hand. Call cleanupClient (not
/// deinit — there is no proc to kill and no thread to join).
fn testClient(alloc: std.mem.Allocator, io: std.Io, stdin: std.Io.File) !Client {
    return .{
        .alloc = alloc,
        .io = io,
        .lang = "mock",
        .uri = try alloc.dupe(u8, "file:///t.zig"),
        .proc = undefined,
        .stdin = stdin,
        .queue = .{ .io = io },
    };
}

fn cleanupClient(alloc: std.mem.Allocator, c: *Client) void {
    c.queue.deinit(alloc);
    c.pending.deinit(alloc);
    alloc.free(c.uri);
}

test "didOpen/didChange: document version is monotonic (1, 2, 3, ...)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    var client = try testClient(alloc, io, write_end);
    defer cleanupClient(alloc, &client);

    try client.didOpen("hello");
    try client.didChange("hello!");
    try client.didChange("hello!!");

    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();
    const versions = [_][]const u8{ "1", "2", "3" };
    for (versions) |want| {
        const body = (try reader.next()).?;
        defer alloc.free(body);
        var msg = try json_rpc.parseMessage(alloc, body);
        defer msg.deinit(alloc);
        const td = msg.params.?.object.get("textDocument").?;
        try std.testing.expectEqualStrings(want, td.object.get("version").?.number_string);
    }
}

test "waitResponse: a server request with the same id is not the response" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    var client = try testClient(alloc, io, write_end);
    defer cleanupClient(alloc, &client);

    // A server→client request (id + method) whose id collides with the
    // handshake id, followed by the actual initialize response.
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/configuration\",\"params\":{\"items\":[]}}");
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");

    var msg = try client.waitResponse(1);
    defer msg.deinit(alloc);
    try std.testing.expect(msg.method == null);
    try std.testing.expect(msg.result != null);

    // The server→client request was answered (MethodNotFound), so a server
    // that blocks on its reply doesn't stall the handshake.
    var pfd = [_]std.posix.pollfd{.{ .fd = read_end.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try std.posix.poll(&pfd, 1000) == 1);
    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();
    const body = (try reader.next()).?;
    defer alloc.free(body);
    var reply = try json_rpc.parseMessage(alloc, body);
    defer reply.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), reply.id);
    try std.testing.expectEqual(@as(i64, -32601), reply.err.?.code);
}

test "drain: server requests are answered, never fill pending slots" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    var client = try testClient(alloc, io, write_end);
    defer cleanupClient(alloc, &client);

    var slot: ?std.json.Value = null;
    defer if (slot) |*v| json_rpc.freeValue(alloc, v);
    try client.pending.append(alloc, .{ .id = 1, .slot = &slot });

    // A server→client request with an id that COLLIDES with the pending
    // client request id (both sides count from small integers).
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/configuration\",\"params\":{\"items\":[]}}");
    // A notification for the handler.
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const Recorder = struct {
        methods: std.ArrayList([]u8) = .empty,
    };
    var rec = Recorder{};
    defer {
        for (rec.methods.items) |m| alloc.free(m);
        rec.methods.deinit(alloc);
    }
    const handler = struct {
        fn handle(ctx: *Recorder, c: *Client, msg: *json_rpc.Message) void {
            const m = msg.method orelse return;
            const copy = c.alloc.dupe(u8, m) catch return;
            ctx.methods.append(c.alloc, copy) catch c.alloc.free(copy);
        }
    }.handle;
    client.drain(&rec, handler);

    // The pending request must survive; the slot must stay empty.
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(slot == null);
    // The notification reached the handler.
    try std.testing.expectEqual(@as(usize, 1), rec.methods.items.len);
    try std.testing.expectEqualStrings("initialized", rec.methods.items[0]);
    // The server request got an error response (so the server doesn't stall).
    var pfd = [_]std.posix.pollfd{.{ .fd = read_end.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try std.posix.poll(&pfd, 1000) == 1);
    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();
    const body = (try reader.next()).?;
    defer alloc.free(body);
    var reply = try json_rpc.parseMessage(alloc, body);
    defer reply.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), reply.id);
    try std.testing.expect(reply.method == null);
    try std.testing.expectEqual(@as(i64, -32601), reply.err.?.code);

    // The real response still resolves the pending request.
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}");
    client.drain(&rec, handler);
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(true, slot.?.object.get("ok").?.bool);
}

test "request: a new request for a busy slot replaces the old pending one" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    var client = try testClient(alloc, io, write_end);
    defer cleanupClient(alloc, &client);

    var slot: ?std.json.Value = null;
    defer if (slot) |*v| json_rpc.freeValue(alloc, v);

    // Two requests share the slot (formatting + rename, or two nav
    // requests). The second replaces the first's pending entry, so the
    // first response arriving LATE must not overwrite the second's result.
    try client.request("textDocument/formatting", .{ .object = .{} }, &slot);
    try client.request("textDocument/rename", .{ .object = .{} }, &slot);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);

    // The second (newer) response arrives first, then the stale first one.
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"kind\":\"rename\"}}");
    try client.queue.push(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"kind\":\"format\"}}");

    const Recorder = struct {};
    var rec = Recorder{};
    const handler = struct {
        fn handle(ctx: *Recorder, c: *Client, msg: *json_rpc.Message) void {
            _ = ctx;
            _ = c;
            _ = msg;
        }
    }.handle;
    client.drain(&rec, handler);

    // The stale formatting response found no pending id 1 and was dropped;
    // the slot holds the rename result.
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expect(slot != null);
    try std.testing.expectEqualStrings("rename", slot.?.object.get("kind").?.string);
}

test "initParams: rootUri/workspaceFolders derive from the document" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    var client = try testClient(alloc, io, write_end);
    defer cleanupClient(alloc, &client);

    var params = try client.initParams();
    defer client.freeInitParams(&params);
    // No Cargo.toml above "/t.zig" ⇒ the root falls back to the document's
    // own directory (the filesystem root here).
    try std.testing.expectEqualStrings("file:///", params.object.get("rootUri").?.string);
    const folders = params.object.get("workspaceFolders").?;
    try std.testing.expectEqual(@as(usize, 1), folders.array.items.len);
    const folder = folders.array.items[0].object;
    try std.testing.expectEqualStrings("file:///", folder.get("uri").?.string);
}

test "reader: server stdout EOF sets server_died (crash detection)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // /bin/true exits immediately: the reader sees clean EOF on the pipe
    // and must flag the server as gone (the editor then tears it down and
    // tells the user instead of hanging on pending requests).
    const proc = try std.process.spawn(io, .{
        .argv = &.{"/bin/true"},
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var client = try testClient(alloc, io, undefined);
    defer cleanupClient(alloc, &client);
    client.proc = proc;

    client.readerMain(); // runs synchronously here; no reader thread

    try std.testing.expect(client.server_died.load(.acquire));
    _ = client.proc.kill(io);
}

test "start: every failure point after spawn cleans up (no hang, no crash)" {
    const base = std.testing.allocator;
    const io = std.testing.io;

    // OZ_LSP_CMD=/bin/cat: cat echoes our initialize request back, but with
    // method set it is never mistaken for the response — a run that reaches
    // the handshake wait ends in LspHandshakeTimeout (the 30s cap) or
    // LspServerDied (failing index hit the reader thread), so the loop stops
    // there: all earlier failure indices were already tested.
    var env_map = std.process.Environ.Map.init(base);
    defer env_map.deinit();
    try env_map.put("OZ_LSP_CMD", "/bin/cat");

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const result = Client.start(failing.allocator(), io, &env_map, "zig", "file:///t.zig", "hello");
        if (result) |client| {
            // /bin/cat never answers a valid initialize response, so a
            // successful start would itself be a bug.
            client.deinit();
            return error.TestUnexpectedResult;
        } else |e| {
            // Reaching the handshake wait ends the loop: LspHandshakeTimeout
            // (/bin/cat never answers) or LspServerDied (the failing index
            // landed in the reader thread's own allocation) — both mean
            // every earlier alloc-failure path was already exercised.
            if (e == error.LspHandshakeTimeout or e == error.LspServerDied) break;
            try std.testing.expect(e == error.OutOfMemory);
        }
    }
    try std.testing.expect(fail_index > 0);
}
