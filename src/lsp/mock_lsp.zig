//! Programmable mock LSP server for L4 e2e tests (M2 integration base).
//!
//! Replaces real language servers (zls / gopls / ...) in end-to-end tests
//! with a deterministic, scripted peer that speaks LSP over the usual
//! Content-Length framed stdio transport:
//!
//!     zig-out/bin/mock_lsp [script] [--verbose]
//!
//! scripts (see `Script`):
//!   hello   (default) initialize handshake with canned capabilities; pushes
//!           one `textDocument/publishDiagnostics` (single error "mock
//!           error", range line 0 columns 0-5, uri `default_uri` or the
//!           first didOpen'd document) right after the `initialized`
//!           notification; answers completion / hover with canned results;
//!           every other request gets a `null` result.
//!   silent  handshake only (same request answers); never pushes
//!           diagnostics proactively.
//!
//! Design: everything except the stdio loop is a pure function
//! (`handleMessage`: one parsed Message in -> zero or more outgoing frame
//! bodies out), so the response logic is unit-tested without spawning a
//! process. The frame transport below follows the pattern in
//! src/lsp/client.zig (`readFrameFromFile` / `writeFrameToStdin`, which are
//! not exported from that file), but the reader is buffered (`FrameReader`)
//! so frames that coalesce into one OS read — or arrive in tiny chunks —
//! are still delivered one by one without losing bytes.
//!
//! The mock never writes to stdout except well-formed JSON-RPC frames, and
//! never uses `std.debug.print`; `--verbose` diagnostics go to stderr.

const std = @import("std");
const json_rpc = @import("../util/json_rpc.zig");

/// URI used for the proactive publishDiagnostics when no document has been
/// opened yet (which is the normal case: LSP sends `initialized` before any
/// `textDocument/didOpen`). Deterministic so e2e tests can open this exact
/// file and expect the diagnostic to surface.
pub const default_uri = "file:///mock.txt";

/// Built-in behaviors, selected by the first CLI argument (or the
/// OZ_MOCK_SCRIPT env var when no argument is given — oz's OZ_LSP_CMD hook
/// is a single argv element and cannot carry a script argument).
pub const Script = enum {
    hello,
    silent,
    /// Like `hello`, but the first didChange pushes an EMPTY
    /// publishDiagnostics (the error is gone). Regression coverage for
    /// "a diagnostics push must repaint without a keypress".
    clear_on_change,
    /// Phantom-'j' detector: after EVERY didChange, inspect the latest
    /// recorded document text — if it starts with 'j' push an error
    /// diagnostic at line 0 ("phantom j"), else push an empty list.
    /// Regression coverage for the jk exit LSP-sync bug: 'i' + 'j' + 'k'
    /// must send a didChange for BOTH the 'j' insertion and its removal,
    /// or the server keeps analyzing "jconst …" forever (stale
    /// diagnostics / inlay hints computed against text that never existed).
    jk_sync,

    pub fn parse(name: []const u8) ?Script {
        if (std.mem.eql(u8, name, "hello")) return .hello;
        if (std.mem.eql(u8, name, "silent")) return .silent;
        if (std.mem.eql(u8, name, "clear_on_change")) return .clear_on_change;
        if (std.mem.eql(u8, name, "jk_sync")) return .jk_sync;
        return null;
    }
};

/// Per-connection state carried across messages. Owns everything it records;
/// call `deinit` when the connection ends.
pub const State = struct {
    /// true once the client has sent the `initialized` notification.
    initialized: bool = false,
    /// true after an `exit` notification; the server loop stops.
    exit_requested: bool = false,
    /// URIs seen in textDocument/didOpen, in arrival order (owned).
    opened: std.ArrayList([]u8) = .empty,
    /// textDocument/didChange records: uri + the latest full text (owned).
    /// Seeded by didOpen, so the FIRST didChange lands at index 1.
    changed: std.ArrayList(ChangeRecord) = .empty,
    /// clear_on_change script: the empty publishDiagnostics went out.
    clear_pushed: bool = false,

    pub const ChangeRecord = struct {
        uri: []u8,
        text: []u8,
    };

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (self.opened.items) |uri| alloc.free(uri);
        self.opened.deinit(alloc);
        for (self.changed.items) |rec| {
            alloc.free(rec.uri);
            alloc.free(rec.text);
        }
        self.changed.deinit(alloc);
    }
};

/// Result of handling one incoming message: zero or more outgoing frame
/// *bodies* (allocator-owned JSON content, no headers). Call `deinit`.
pub const Outcome = struct {
    frames: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Outcome, alloc: std.mem.Allocator) void {
        for (self.frames.items) |f| alloc.free(f);
        self.frames.deinit(alloc);
    }
};

/// Pure message dispatch: turn one parsed JSON-RPC message into the frames
/// the server should send back (responses to requests, plus scripted
/// notifications). Does no I/O and only reads `msg`; all allocations come
/// from `alloc` and are owned by the returned `Outcome` / `state`.
///
/// Request handling (both scripts):
///   initialize                        -> capabilities (see `buildInitializeResult`)
///   textDocument/completion           -> {items:[{label:"mockItem", kind:6}]}
///   textDocument/hover                -> {contents:{kind:"markdown",value:"mock hover"}}
///   anything else (definition, ...)   -> null result
///
/// Notification handling:
///   initialized -> record + (hello only) push publishDiagnostics
///   textDocument/didOpen / didChange  -> record into `state`
///   exit                              -> set `state.exit_requested`
///   anything else                     -> ignored
pub fn handleMessage(
    alloc: std.mem.Allocator,
    script: Script,
    state: *State,
    msg: *const json_rpc.Message,
) !Outcome {
    var out = Outcome{};
    errdefer out.deinit(alloc);

    if (msg.id) |id| {
        // A request from the client: answer it. (A response from the client
        // would have a null method; nothing to do with it.)
        const method = msg.method orelse return out;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        if (std.mem.eql(u8, method, "initialize")) {
            try pushResponse(alloc, &out, id, try buildInitializeResult(a));
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            // echo the typed prefix in the labels ("mockItemmo") so tests can
            // verify the client filters suggestions as the user types
            var col: u32 = 0;
            var line: u32 = 0;
            var uri: ?[]const u8 = null;
            if (msg.params) |params| {
                if (params == .object) {
                    if (params.object.get("position")) |pos| {
                        if (pos == .object) {
                            if (pos.object.get("line")) |ln| {
                                const lval: ?i64 = switch (ln) {
                                    .integer => |n| n,
                                    .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                                    else => null,
                                };
                                if (lval) |lv| {
                                    if (lv >= 0) line = @intCast(lv);
                                }
                            }
                            if (pos.object.get("character")) |ch| {
                                const cval: ?i64 = switch (ch) {
                                    .integer => |n| n,
                                    .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                                    else => null,
                                };
                                if (cval) |cv| {
                                    if (cv >= 0) col = @intCast(cv);
                                }
                            }
                        }
                    }
                    if (params.object.get("textDocument")) |td| {
                        if (td == .object) {
                            if (td.object.get("uri")) |u| {
                                if (u == .string) uri = u.string;
                            }
                        }
                    }
                }
            }
            const prefix = completionPrefix(a, state, uri, line, col);
            try pushResponse(alloc, &out, id, try buildCompletionResult(a, prefix));
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try pushResponse(alloc, &out, id, try buildHoverResult(a));
        } else if (std.mem.eql(u8, method, "textDocument/definition") or
            std.mem.eql(u8, method, "textDocument/declaration"))
        {
            // a fixed location in the FIRST opened document (line 1, col 6 —
            // col 6 is the identifier in "const a = 1;", so gd lands on the
            // definition token, not the line start)
            try pushResponse(alloc, &out, id, try buildLocationResult(a, state, 1, 6));
        } else if (std.mem.eql(u8, method, "textDocument/references") or
            std.mem.eql(u8, method, "textDocument/implementation"))
        {
            // two locations: line 1 and line 2 of the first opened document
            var locs = std.json.Array.init(a);
            const l1 = try buildLocationValue(a, state, 1, 6);
            const l2 = try buildLocationValue(a, state, 2, 0);
            try locs.append(l1);
            try locs.append(l2);
            try pushResponse(alloc, &out, id, .{ .array = locs });
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try pushResponse(alloc, &out, id, try buildSignatureResult(a));
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            // Format the whole doc: replace everything with a canonical form
            try pushResponse(alloc, &out, id, try buildFormatResult(a, state));
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            // Rename: replace the symbol at the cursor (line 0) everywhere.
            // The mock replaces the whole document with a fixed rename edit.
            try pushResponse(alloc, &out, id, try buildRenameResult(a, state));
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            try pushResponse(alloc, &out, id, try buildInlayResult(a));
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try pushResponse(alloc, &out, id, try buildSymbolResult(a));
        } else {
            // Any other request (shutdown, ...) gets a null result.
            try pushResponse(alloc, &out, id, .null);
        }
        return out;
    }

    const method = msg.method orelse return out;
    if (std.mem.eql(u8, method, "initialized")) {
        state.initialized = true;
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try recordDidOpen(alloc, state, msg.params);
        // Push diagnostics for the JUST-opened document (uri matches what the
        // client filters on) — pushing at `initialized` races didOpen and the
        // client would drop the diagnostics as belonging to another file.
        if (script == .hello or script == .clear_on_change) {
            const uri = if (state.opened.items.len > 0) state.opened.items[state.opened.items.len - 1] else default_uri;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const params = try buildDiagnosticsParams(a, uri, "mock error");
            const body = try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", params);
            errdefer alloc.free(body);
            try out.frames.append(alloc, body);
        }
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try recordDidChange(alloc, state, msg.params);
        // clear_on_change: the edit fixed the document — push an empty
        // diagnostics list so the client must clear the gutter mark (and
        // repaint without waiting for another keypress).
        if (script == .clear_on_change and !state.clear_pushed) {
            state.clear_pushed = true;
            const uri = if (state.opened.items.len > 0) state.opened.items[state.opened.items.len - 1] else default_uri;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const params = try buildEmptyDiagnosticsParams(a, uri);
            const body = try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", params);
            errdefer alloc.free(body);
            try out.frames.append(alloc, body);
        }
        // jk_sync: the server's document is whatever the LATEST didChange
        // said. A 'j' insertion followed by a jk-exit deletion must produce
        // two didChanges; if the deletion is never synced the text still
        // starts with 'j' and the phantom diagnostic stays published.
        if (script == .jk_sync) {
            const uri = if (state.opened.items.len > 0) state.opened.items[state.opened.items.len - 1] else default_uri;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const phantom = state.changed.items.len > 0 and
                state.changed.items[state.changed.items.len - 1].text.len > 0 and
                state.changed.items[state.changed.items.len - 1].text[0] == 'j';
            const params = if (phantom)
                try buildDiagnosticsParams(a, uri, "phantom j")
            else
                try buildEmptyDiagnosticsParams(a, uri);
            const body = try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", params);
            errdefer alloc.free(body);
            try out.frames.append(alloc, body);
        }
    } else if (std.mem.eql(u8, method, "exit")) {
        state.exit_requested = true;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Frame transport (pattern adapted from src/lsp/client.zig)
// ---------------------------------------------------------------------------

/// Streaming reader for Content-Length framed messages with an internal
/// buffer. A single OS read may deliver several frames (or a partial frame);
/// a stateless reader that copies only `Content-Length` bytes out of one
/// read loses the excess. (The stateless reader in src/lsp/client.zig does
/// exactly that — see its `readFrameFromFile` — which is fine there until
/// frames coalesce; this one keeps every excess byte for the next `next()`.)
///
/// EOF surfaces as `null` at a clean frame boundary and
/// `error.UnexpectedEof` when a frame is cut short. Each returned body is
/// allocated with `alloc` and owned by the caller.
pub const FrameReader = struct {
    alloc: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    /// Bytes read from `file` but not yet consumed by a frame (owned).
    pending: std.ArrayList(u8) = .empty,

    /// A header block bigger than this (without finding "\r\n\r\n") is
    /// garbage, not a frame; guards against unbounded buffering.
    const max_header_len = 1 << 20;

    pub fn init(alloc: std.mem.Allocator, file: std.Io.File, io: std.Io) FrameReader {
        return .{ .alloc = alloc, .file = file, .io = io };
    }

    pub fn deinit(self: *FrameReader) void {
        self.pending.deinit(self.alloc);
    }

    pub fn next(self: *FrameReader) !?[]u8 {
        // 1. Fill until a complete header block ("...\r\n\r\n") is buffered.
        while (std.mem.indexOf(u8, self.pending.items, "\r\n\r\n") == null) {
            if (self.pending.items.len >= max_header_len) return error.InvalidHeader;
            const got = try self.fillMore();
            if (got == 0) {
                if (self.pending.items.len == 0) return null; // clean EOF
                return error.UnexpectedEof; // EOF inside a header
            }
        }

        // 2. Skip blank-line padding between frames (an empty header block).
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

        // 3. Parse Content-Length from the header.
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

        // 4. Fill until the whole body is buffered.
        const body_start = sep + 4;
        while (self.pending.items.len < body_start + clen) {
            const got = try self.fillMore();
            if (got == 0) return error.UnexpectedEof; // EOF inside a body
        }

        // 5. Copy the frame out and drop header + body from the buffer.
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

    /// Read up to 8192 more bytes into `pending`; returns the number of
    /// bytes added, or 0 on EOF (mapped from both `error.EndOfStream` and a
    /// zero-length read, depending on the io implementation).
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

/// Write `Content-Length: N\r\n\r\n` followed by `content` to `file`
/// (blocking). Same framing as src/lsp/client.zig `writeFrameToStdin`.
pub fn writeFrameToFile(file: std.Io.File, io: std.Io, content: []const u8) !void {
    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{content.len});
    try std.Io.File.writeStreamingAll(file, io, hdr);
    try std.Io.File.writeStreamingAll(file, io, content);
}

// ---------------------------------------------------------------------------
// JSON builders (arena-backed; values only need to live through encoding)
// ---------------------------------------------------------------------------

fn pushResponse(alloc: std.mem.Allocator, out: *Outcome, id: u64, result: std.json.Value) !void {
    const body = try json_rpc.encodeResponse(alloc, id, result);
    errdefer alloc.free(body);
    try out.frames.append(alloc, body);
}

fn buildInitializeResult(a: std.mem.Allocator) !std.json.Value {
    var caps = try std.json.ObjectMap.init(a, &.{}, &.{});
    // 2 == Incremental text sync.
    try caps.put(a, "textDocumentSync", .{ .integer = 2 });

    var comp = try std.json.ObjectMap.init(a, &.{}, &.{});
    var triggers = std.json.Array.init(a);
    try triggers.append(.{ .string = "." });
    try comp.put(a, "triggerCharacters", .{ .array = triggers });
    try caps.put(a, "completionProvider", .{ .object = comp });

    try caps.put(a, "hoverProvider", .{ .bool = true });
    try caps.put(a, "definitionProvider", .{ .bool = true });
    try caps.put(a, "inlayHintProvider", .{ .bool = true });

    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "capabilities", .{ .object = caps });
    return .{ .object = result };
}

/// Word chars in the document at the request position, walked back from the
/// cursor column (what the client will filter by). Owned copy.
fn completionPrefix(a: std.mem.Allocator, state: *State, uri: ?[]const u8, line: u32, col: u32) []const u8 {
    const u = uri orelse return a.dupe(u8, "") catch return "";
    var i: usize = state.changed.items.len;
    while (i > 0) {
        i -= 1;
        const rec = &state.changed.items[i];
        if (!std.mem.eql(u8, rec.uri, u)) continue;
        const text = rec.text;
        // advance to the requested line
        var line_i: u32 = 0;
        var pos: usize = 0;
        while (line_i < line and pos < text.len) : (line_i += 1) {
            const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
            pos = @min(nl + 1, text.len);
        }
        const line_len = blk: {
            const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
            break :blk nl - pos;
        };
        var end = pos + @min(col, @as(u32, @intCast(line_len)));
        while (end > pos) {
            const b = text[end - 1];
            const is_word = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
                (b >= '0' and b <= '9') or b == '_' or b >= 0x80;
            if (!is_word) break;
            end -= 1;
        }
        return a.dupe(u8, text[end .. pos + @min(col, @as(u32, @intCast(line_len)))]) catch "";
    }
    return a.dupe(u8, "") catch return "";
}

fn buildCompletionResult(a: std.mem.Allocator, prefix: []const u8) !std.json.Value {
    var item = try std.json.ObjectMap.init(a, &.{}, &.{});
    const item_label = try std.fmt.allocPrint(a, "mockItem{s}", .{prefix});
    try item.put(a, "label", .{ .string = item_label });
    try item.put(a, "kind", .{ .integer = 6 }); // CompletionItemKind.Function
    var item2 = try std.json.ObjectMap.init(a, &.{}, &.{});
    const item2_label = try std.fmt.allocPrint(a, "mockAlpha{s}", .{prefix});
    try item2.put(a, "label", .{ .string = item2_label });
    try item2.put(a, "kind", .{ .integer = 5 }); // CompletionItemKind.Field
    // a snippet candidate: insertTextFormat=2 with ${n:...} placeholder text.
    // The client must degrade to the plain label on accept.
    var item3 = try std.json.ObjectMap.init(a, &.{}, &.{});
    try item3.put(a, "label", .{ .string = "mockSnippet" });
    try item3.put(a, "kind", .{ .integer = 15 }); // CompletionItemKind.Snippet
    try item3.put(a, "insertTextFormat", .{ .integer = 2 });
    var edit = try std.json.ObjectMap.init(a, &.{}, &.{});
    try edit.put(a, "newText", .{ .string = "mockSnippet(${1:args})" });
    try item3.put(a, "textEdit", .{ .object = edit });
    var items = std.json.Array.init(a);
    try items.append(.{ .object = item });
    try items.append(.{ .object = item2 });
    try items.append(.{ .object = item3 });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

fn buildHoverResult(a: std.mem.Allocator) !std.json.Value {
    var contents = try std.json.ObjectMap.init(a, &.{}, &.{});
    try contents.put(a, "kind", .{ .string = "markdown" });
    // Multi-line hover: exercises the floating window's row wrapping.
    try contents.put(a, "value", .{ .string = "mock hover\nsecond line\nthird line" });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "contents", .{ .object = contents });
    return .{ .object = result };
}

fn buildFormatResult(a: std.mem.Allocator, state: *State) !std.json.Value {
    // Replace the whole document with its current text (a no-op format), so
    // the editor exercises the TextEdit apply path without changing content.
    const doc: []const u8 = if (state.changed.items.len > 0) state.changed.items[state.changed.items.len - 1].text else "";
    // The end position must be a REAL position (line after the last '\n',
    // column 0 / last line's length): the client drops edits whose range is
    // out of range, so a fake end like line 999 would silently discard the
    // whole edit and never exercise the apply path.
    var end_line: u32 = 0;
    var end_col: u32 = 0;
    for (doc) |c| {
        if (c == '\n') {
            end_line += 1;
            end_col = 0;
        } else {
            end_col += 1;
        }
    }
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = 0 });
    try start.put(a, "character", .{ .integer = 0 });
    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = end_line });
    try end.put(a, "character", .{ .integer = end_col });
    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });
    var edit = try std.json.ObjectMap.init(a, &.{}, &.{});
    try edit.put(a, "range", .{ .object = range });
    try edit.put(a, "newText", .{ .string = doc });
    var edits = std.json.Array.init(a);
    try edits.append(.{ .object = edit });
    return .{ .array = edits };
}

fn buildRenameResult(a: std.mem.Allocator, state: *State) !std.json.Value {
    // WorkspaceEdit {changes: {uri: [TextEdit]}} — replace the first word of
    // the first line with "renamedSymbol" (deterministic for the e2e test).
    const uri = if (state.changed.items.len > 0) state.changed.items[0].uri else "file:///mock.zig";
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = 0 });
    try start.put(a, "character", .{ .integer = 0 });
    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = 0 });
    try end.put(a, "character", .{ .integer = 4 });
    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });
    var edit = try std.json.ObjectMap.init(a, &.{}, &.{});
    try edit.put(a, "range", .{ .object = range });
    try edit.put(a, "newText", .{ .string = "renamedSymbol" });
    var edits = std.json.Array.init(a);
    try edits.append(.{ .object = edit });
    var changes = try std.json.ObjectMap.init(a, &.{}, &.{});
    try changes.put(a, uri, .{ .array = edits });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "changes", .{ .object = changes });
    return .{ .object = result };
}

fn buildInlayResult(a: std.mem.Allocator) !std.json.Value {
    var hint = try std.json.ObjectMap.init(a, &.{}, &.{});
    var pos = try std.json.ObjectMap.init(a, &.{}, &.{});
    try pos.put(a, "line", .{ .integer = 0 });
    try pos.put(a, "character", .{ .integer = 0 });
    try hint.put(a, "position", .{ .object = pos });
    try hint.put(a, "label", .{ .string = ": i32" });
    var hints = std.json.Array.init(a);
    try hints.append(.{ .object = hint });
    return .{ .array = hints };
}

fn buildSymbolResult(a: std.mem.Allocator) !std.json.Value {
    var sym = try std.json.ObjectMap.init(a, &.{}, &.{});
    try sym.put(a, "name", .{ .string = "mockFn" });
    try sym.put(a, "kind", .{ .integer = 12 }); // Function
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = 0 });
    try start.put(a, "character", .{ .integer = 0 });
    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = 0 });
    try end.put(a, "character", .{ .integer = 4 });
    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });
    try sym.put(a, "range", .{ .object = range });
    var selection = try std.json.ObjectMap.init(a, &.{}, &.{});
    try selection.put(a, "start", .{ .object = start });
    try selection.put(a, "end", .{ .object = end });
    try sym.put(a, "selectionRange", .{ .object = selection });
    var syms = std.json.Array.init(a);
    try syms.append(.{ .object = sym });
    return .{ .array = syms };
}

fn buildDiagnosticsParams(a: std.mem.Allocator, uri: []const u8, message: []const u8) !std.json.Value {
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = 0 });
    try start.put(a, "character", .{ .integer = 0 });

    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = 0 });
    try end.put(a, "character", .{ .integer = 5 });

    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });

    var diag = try std.json.ObjectMap.init(a, &.{}, &.{});
    try diag.put(a, "range", .{ .object = range });
    try diag.put(a, "severity", .{ .integer = 1 }); // DiagnosticSeverity.Error
    try diag.put(a, "message", .{ .string = message });

    var diags = std.json.Array.init(a);
    try diags.append(.{ .object = diag });

    var params = try std.json.ObjectMap.init(a, &.{}, &.{});
    try params.put(a, "uri", .{ .string = uri });
    try params.put(a, "diagnostics", .{ .array = diags });
    return .{ .object = params };
}

/// publishDiagnostics params with an empty list: "all problems fixed".
fn buildEmptyDiagnosticsParams(a: std.mem.Allocator, uri: []const u8) !std.json.Value {
    const diags = std.json.Array.init(a);
    var params = try std.json.ObjectMap.init(a, &.{}, &.{});
    try params.put(a, "uri", .{ .string = uri });
    try params.put(a, "diagnostics", .{ .array = diags });
    return .{ .object = params };
}

// ---------------------------------------------------------------------------
// didOpen / didChange recording
// ---------------------------------------------------------------------------

fn extractUri(alloc: std.mem.Allocator, params: ?std.json.Value) ![]u8 {
    const p = params orelse return error.MissingParams;
    if (p != .object) return error.BadParams;
    const td = p.object.get("textDocument") orelse return error.MissingTextDocument;
    if (td != .object) return error.BadParams;
    const uri = td.object.get("uri") orelse return error.MissingUri;
    if (uri != .string) return error.BadParams;
    return alloc.dupe(u8, uri.string);
}

fn recordDidOpen(alloc: std.mem.Allocator, state: *State, params: ?std.json.Value) !void {
    const uri = extractUri(alloc, params) catch return;
    errdefer alloc.free(uri);
    try state.opened.append(alloc, uri);
    // The didOpen text is the document state until the first didChange;
    // completion/format handlers read `changed`, so seed it here too.
    var text: []const u8 = "";
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("textDocument")) |td| {
                if (td == .object) {
                    if (td.object.get("text")) |t| {
                        if (t == .string) text = t.string;
                    }
                }
            }
        }
    }
    const text_copy = try alloc.dupe(u8, text);
    errdefer alloc.free(text_copy);
    const uri_copy = try alloc.dupe(u8, uri);
    errdefer alloc.free(uri_copy);
    try state.changed.append(alloc, .{ .uri = uri_copy, .text = text_copy });
}

fn recordDidChange(alloc: std.mem.Allocator, state: *State, params: ?std.json.Value) !void {
    const uri = extractUri(alloc, params) catch return;
    errdefer alloc.free(uri);
    var text: []const u8 = "";
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("contentChanges")) |cc| {
                if (cc == .array and cc.array.items.len > 0) {
                    const first = cc.array.items[0];
                    if (first == .object) {
                        if (first.object.get("text")) |t| {
                            if (t == .string) text = t.string;
                        }
                    }
                }
            }
        }
    }
    const text_copy = try alloc.dupe(u8, text);
    errdefer alloc.free(text_copy);
    try state.changed.append(alloc, .{ .uri = uri, .text = text_copy });
}

// ---------------------------------------------------------------------------
// stderr diagnostics (never stdout, never std.debug.print)
// ---------------------------------------------------------------------------

fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, line) catch {};
}

fn logVerbose(io: std.Io, verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (!verbose) return;
    writeStderr(io, fmt, args);
}

fn printUsage(io: std.Io) void {
    writeStderr(io,
        \\usage: mock_lsp [script] [--verbose]
        \\
        \\Programmable mock LSP server for oz e2e tests. Speaks JSON-RPC 2.0
        \\over Content-Length framed stdio (LSP transport).
        \\
        \\scripts:
        \\  hello   (default) initialize handshake with canned capabilities;
        \\           pushes one textDocument/publishDiagnostics ("mock error",
        \\           line 0, columns 0-5) after the `initialized` notification;
        \\           answers completion/hover with canned results; all other
        \\           requests get a null result.
        \\  silent  handshake only; never pushes diagnostics proactively.
        \\  jk_sync pushes an error diagnostic ("phantom j") whenever its
        \\           document starts with 'j', else an empty list — detects
        \\           a didChange for a 'j' insertion whose jk-exit removal
        \\           was never synced.
        \\
        \\options:
        \\  --verbose  log received/sent messages to stderr
        \\  --help     show this help
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var script: Script = .hello;
    var script_set = false;
    var verbose = false;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]: program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(io);
            return;
        } else if (!script_set) {
            script = Script.parse(arg) orelse {
                writeStderr(io, "mock_lsp: unknown script '{s}'\n", .{arg});
                printUsage(io);
                std.process.exit(2);
            };
            script_set = true;
        } else {
            writeStderr(io, "mock_lsp: unexpected argument '{s}'\n", .{arg});
            printUsage(io);
            std.process.exit(2);
        }
    }
    // env fallback: OZ_LSP_CMD injects the mock as a single argv element, so
    // e2e passes the script via OZ_MOCK_SCRIPT instead.
    if (!script_set) {
        if (init.environ_map.get("OZ_MOCK_SCRIPT")) |name| {
            script = Script.parse(name) orelse {
                writeStderr(io, "mock_lsp: unknown OZ_MOCK_SCRIPT '{s}'\n", .{name});
                std.process.exit(2);
            };
        }
    }

    var state = State{};
    defer state.deinit(gpa);

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var reader = FrameReader.init(gpa, stdin, io);
    defer reader.deinit();

    logVerbose(io, verbose, "mock_lsp: script={s} ready\n", .{@tagName(script)});

    var running = true;
    while (running) {
        const body = reader.next() catch |e| {
            logVerbose(io, verbose, "mock_lsp: stdin closed or read error: {s}\n", .{@errorName(e)});
            break;
        } orelse break; // clean EOF at a frame boundary
        defer gpa.free(body);

        var msg = json_rpc.parseMessage(gpa, body) catch |e| {
            logVerbose(io, verbose, "mock_lsp: malformed frame, ignoring: {s}\n", .{@errorName(e)});
            continue;
        };
        defer msg.deinit(gpa);

        if (msg.id) |id| {
            logVerbose(io, verbose, "mock_lsp: recv request id={d} method={s}\n", .{ id, msg.method orelse "(no method)" });
        } else if (msg.method) |m| {
            logVerbose(io, verbose, "mock_lsp: recv notification method={s}\n", .{m});
        }

        var outcome = try handleMessage(gpa, script, &state, &msg);
        for (outcome.frames.items) |frame| {
            writeFrameToFile(stdout, io, frame) catch |e| {
                logVerbose(io, verbose, "mock_lsp: stdout write failed: {s}\n", .{@errorName(e)});
                running = false;
                break;
            };
            logVerbose(io, verbose, "mock_lsp: sent frame ({d} bytes)\n", .{frame.len});
        }
        outcome.deinit(gpa); // frees every frame (no per-frame free above)

        if (!running or state.exit_requested) break;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn handleContent(alloc: std.mem.Allocator, script: Script, state: *State, content: []const u8) !Outcome {
    var msg = try json_rpc.parseMessage(alloc, content);
    defer msg.deinit(alloc);
    return handleMessage(alloc, script, state, &msg);
}

/// A Location for line `line`/col `col` in the first didOpen'd document
/// (default_uri when none opened yet).
fn buildLocationValue(a: std.mem.Allocator, state: *State, line: u32, col: u32) !std.json.Value {
    const uri = if (state.opened.items.len > 0) state.opened.items[0] else default_uri;
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = line });
    try start.put(a, "character", .{ .integer = col });
    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = line });
    try end.put(a, "character", .{ .integer = col + 4 });
    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });
    var loc = try std.json.ObjectMap.init(a, &.{}, &.{});
    try loc.put(a, "uri", .{ .string = uri });
    try loc.put(a, "range", .{ .object = range });
    return .{ .object = loc };
}

fn buildLocationResult(a: std.mem.Allocator, state: *State, line: u32, col: u32) !std.json.Value {
    return buildLocationValue(a, state, line, col);
}

fn buildSignatureResult(a: std.mem.Allocator) !std.json.Value {
    var sig = try std.json.ObjectMap.init(a, &.{}, &.{});
    try sig.put(a, "label", .{ .string = "mockSig(x: i32)" });
    var sigs = std.json.Array.init(a);
    try sigs.append(.{ .object = sig });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "signatures", .{ .array = sigs });
    return .{ .object = result };
}

test "Script.parse" {
    try testing.expect(Script.parse("hello") == .hello);
    try testing.expect(Script.parse("silent") == .silent);
    try testing.expect(Script.parse("bogus") == null);
}

test "frame read/write round-trip over a pipe" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    var write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer if (write_end.handle != -1) std.Io.File.close(write_end, io);

    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();

    const c1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const c2 = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    try writeFrameToFile(write_end, io, c1);
    try writeFrameToFile(write_end, io, c2);
    std.Io.File.close(write_end, io); // reader now sees clean EOF after c2
    write_end.handle = -1; // mark closed so the defer no-ops

    const r1 = (try reader.next()).?;
    defer alloc.free(r1);
    try testing.expectEqualStrings(c1, r1);

    const r2 = (try reader.next()).?;
    defer alloc.free(r2);
    try testing.expectEqualStrings(c2, r2);

    try testing.expectEqual(@as(?[]u8, null), try reader.next());
}

test "frame reader survives coalesced and chunked delivery" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    var write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer if (write_end.handle != -1) std.Io.File.close(write_end, io);

    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();

    const c1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const c2 = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";

    // Coalescing: both complete frames written in one shot, so a single OS
    // read delivers them together; the reader must not drop the second.
    var both_buf: [512]u8 = undefined;
    const both = try std.fmt.bufPrint(&both_buf, "Content-Length: {d}\r\n\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ c1.len, c1, c2.len, c2 });
    try std.Io.File.writeStreamingAll(write_end, io, both);

    // Chunked: dribble the bytes of a third frame in 3-byte pieces so header
    // and body arrive across many reads.
    const c3 = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/hover\",\"params\":{}}";
    var framed: [512]u8 = undefined;
    const all3 = try std.fmt.bufPrint(&framed, "Content-Length: {d}\r\n\r\n{s}", .{ c3.len, c3 });
    var i: usize = 0;
    while (i < all3.len) : (i += 3) {
        const chunk = all3[@min(i, all3.len)..@min(i + 3, all3.len)];
        try std.Io.File.writeStreamingAll(write_end, io, chunk);
    }
    std.Io.File.close(write_end, io);
    write_end.handle = -1; // mark closed so the defer no-ops

    const r1 = (try reader.next()).?;
    defer alloc.free(r1);
    try testing.expectEqualStrings(c1, r1);

    const r2 = (try reader.next()).?;
    defer alloc.free(r2);
    try testing.expectEqualStrings(c2, r2);

    const r3 = (try reader.next()).?;
    defer alloc.free(r3);
    try testing.expectEqualStrings(c3, r3);

    try testing.expectEqual(@as(?[]u8, null), try reader.next());
}

test "hello: initialize responds with capabilities" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    var out = try handleContent(alloc, .hello, &state, req);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out.frames.items.len);

    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(?u64, 1), resp.id);
    const caps = resp.result.?.object.get("capabilities").?;
    try testing.expectEqualStrings("2", caps.object.get("textDocumentSync").?.number_string);
    const comp = caps.object.get("completionProvider").?;
    try testing.expectEqualStrings(".", comp.object.get("triggerCharacters").?.array.items[0].string);
    try testing.expectEqual(true, caps.object.get("hoverProvider").?.bool);
    try testing.expectEqual(true, caps.object.get("definitionProvider").?.bool);
}

test "hello: completion returns the canned item" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{}}";
    var out = try handleContent(alloc, .hello, &state, req);
    defer out.deinit(alloc);

    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(?u64, 2), resp.id);
    const item = resp.result.?.object.get("items").?.array.items[0];
    try testing.expectEqualStrings("mockItem", item.object.get("label").?.string);
    try testing.expectEqualStrings("6", item.object.get("kind").?.number_string);
}

test "hello: hover returns the canned markdown" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{}}";
    var out = try handleContent(alloc, .hello, &state, req);
    defer out.deinit(alloc);

    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(?u64, 3), resp.id);
    const contents = resp.result.?.object.get("contents").?;
    try testing.expectEqualStrings("markdown", contents.object.get("kind").?.string);
    try testing.expectEqualStrings("mock hover\nsecond line\nthird line", contents.object.get("value").?.string);
}

test "hello: definition returns a location, unknown methods still null" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    // a didOpen so the location references the opened document
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":1},\"text\":\"x\"}}";
    var out_open = try handleContent(alloc, .hello, &state, open);
    defer out_open.deinit(alloc);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/definition\",\"params\":{}}";
    var out = try handleContent(alloc, .hello, &state, req);
    defer out.deinit(alloc);
    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(?u64, 4), resp.id);
    const uri = resp.result.?.object.get("uri").?;
    try testing.expectEqualStrings("file:///a.zig", uri.string);

    // shutdown is still null
    const req2 = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shutdown\",\"params\":{}}";
    var out2 = try handleContent(alloc, .hello, &state, req2);
    defer out2.deinit(alloc);
    var resp2 = try json_rpc.parseMessage(alloc, out2.frames.items[0]);
    defer resp2.deinit(alloc);
    try testing.expect(resp2.result.? == .null);
}

test "hello: didOpen pushes one publishDiagnostics (mock error)" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/a.zig\",\"version\":1},\"text\":\"const a = 1;\\n\"}}";
    var out = try handleContent(alloc, .hello, &state, open);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out.frames.items.len);

    var m = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer m.deinit(alloc);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", m.method.?);
    const params = m.params.?;
    // the diagnostics reference the just-opened document
    try testing.expectEqualStrings("file:///tmp/a.zig", params.object.get("uri").?.string);
    const diags = params.object.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try testing.expectEqualStrings("mock error", d.object.get("message").?.string);
    try testing.expectEqualStrings("1", d.object.get("severity").?.number_string);
    const range = d.object.get("range").?;
    const start = range.object.get("start").?;
    try testing.expectEqualStrings("0", start.object.get("line").?.number_string);
    try testing.expectEqualStrings("0", start.object.get("character").?.number_string);
}

test "hello: initialized alone pushes nothing; silent pushes nothing either" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    var out = try handleContent(alloc, .hello, &state, notif);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), out.frames.items.len);

    var state2 = State{};
    defer state2.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":1,\"text\":\"hello\"}}}";
    var out2 = try handleContent(alloc, .silent, &state2, open);
    defer out2.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), out2.frames.items.len);
}

test "silent: initialized sends no diagnostics" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    var out = try handleContent(alloc, .silent, &state, notif);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), out.frames.items.len);
    try testing.expect(state.initialized);
}

test "silent: still answers initialize and hover" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/hover\",\"params\":{}}";
    var out = try handleContent(alloc, .silent, &state, req);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out.frames.items.len);
    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(?u64, 5), resp.id);
    try testing.expect(resp.result != null);
}

test "didOpen and didChange are recorded in state" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":1,\"text\":\"hello\"}}}";
    var out_open = try handleContent(alloc, .hello, &state, open);
    defer out_open.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), state.opened.items.len);
    try testing.expectEqualStrings("file:///a.txt", state.opened.items[0]);
    // didOpen also seeds the document text (the state until the first change)
    try testing.expectEqual(@as(usize, 1), state.changed.items.len);
    try testing.expectEqualStrings("hello", state.changed.items[0].text);

    const change = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":2},\"contentChanges\":[{\"text\":\"world\"}]}}";
    var out_change = try handleContent(alloc, .hello, &state, change);
    defer out_change.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), state.changed.items.len);
    try testing.expectEqualStrings("file:///a.txt", state.changed.items[1].uri);
    try testing.expectEqualStrings("world", state.changed.items[1].text);
}

test "exit notification sets exit_requested" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const ex = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}";
    var out = try handleContent(alloc, .hello, &state, ex);
    defer out.deinit(alloc);
    try testing.expect(state.exit_requested);
    try testing.expectEqual(@as(usize, 0), out.frames.items.len);
}

test "jk_sync: phantom 'j' in the doc pushes the error; corrected text pushes empty" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":1,\"text\":\"const a = 1;\\n\"}}}";
    var out_open = try handleContent(alloc, .jk_sync, &state, open);
    defer out_open.deinit(alloc);
    // didOpen: "const a = 1;" does not start with 'j' — no push at open.
    try testing.expectEqual(@as(usize, 0), out_open.frames.items.len);

    // 'j' typed in insert mode: didChange carries the phantom.
    const with_j = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":2},\"contentChanges\":[{\"text\":\"jconst a = 1;\\n\"}]}}";
    var out_j = try handleContent(alloc, .jk_sync, &state, with_j);
    defer out_j.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out_j.frames.items.len);
    var msg_j = try json_rpc.parseMessage(alloc, out_j.frames.items[0]);
    defer msg_j.deinit(alloc);
    const diags_j = msg_j.params.?.object.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), diags_j.items.len);
    try testing.expectEqualStrings("phantom j", diags_j.items[0].object.get("message").?.string);

    // jk exit deleted the 'j': a second didChange with the corrected text
    // must arrive and clear the phantom — the e2e regression asserts the
    // editor actually sends it.
    const fixed = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":3},\"contentChanges\":[{\"text\":\"const a = 1;\\n\"}]}}";
    var out_fixed = try handleContent(alloc, .jk_sync, &state, fixed);
    defer out_fixed.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out_fixed.frames.items.len);
    var msg_fixed = try json_rpc.parseMessage(alloc, out_fixed.frames.items[0]);
    defer msg_fixed.deinit(alloc);
    const diags_fixed = msg_fixed.params.?.object.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 0), diags_fixed.items.len);
}

test "format: whole-doc edit is in range and covers the real document" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    // didOpen only (no didChange): the initial text must still be known.
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":1,\"text\":\"const a = 1;\\nconst b = 2;\\n\"}}}";
    var out_open = try handleContent(alloc, .silent, &state, open);
    defer out_open.deinit(alloc);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/formatting\",\"params\":{}}";
    var out = try handleContent(alloc, .silent, &state, req);
    defer out.deinit(alloc);
    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);

    // The edits must map onto the actual document — an out-of-range end
    // (e.g. line 999) is dropped by the client and the edit never applies.
    const navigation = @import("navigation.zig");
    const buffer = @import("../buffer/root.zig");
    var pt = try buffer.PieceTable.init(alloc, "const a = 1;\nconst b = 2;\n");
    defer pt.deinit();
    var edits = std.ArrayList(navigation.TextEdit).empty;
    defer {
        for (edits.items) |*e| alloc.free(e.new_text);
        edits.deinit(alloc);
    }
    try navigation.parseTextEdits(alloc, resp.result.?, &pt, &edits);
    try testing.expectEqual(@as(usize, 1), edits.items.len);
    try testing.expectEqual(@as(u32, 0), edits.items[0].start);
    try testing.expectEqual(@as(u32, 26), edits.items[0].end);
    try testing.expectEqualStrings("const a = 1;\nconst b = 2;\n", edits.items[0].new_text);
}

test "full message cycle through frame functions and handleMessage" {
    const alloc = testing.allocator;
    const io = testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer std.Io.File.close(read_end, io);
    defer std.Io.File.close(write_end, io);

    const req_content = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/hover\",\"params\":{}}";
    try writeFrameToFile(write_end, io, req_content);
    var reader = FrameReader.init(alloc, read_end, io);
    defer reader.deinit();
    const got = (try reader.next()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings(req_content, got);

    var msg = try json_rpc.parseMessage(alloc, got);
    defer msg.deinit(alloc);
    var state = State{};
    defer state.deinit(alloc);
    var out = try handleMessage(alloc, .hello, &state, &msg);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out.frames.items.len);

    try writeFrameToFile(write_end, io, out.frames.items[0]);
    const resp = (try reader.next()).?;
    defer alloc.free(resp);
    var rmsg = try json_rpc.parseMessage(alloc, resp);
    defer rmsg.deinit(alloc);
    try testing.expectEqual(@as(?u64, 9), rmsg.id);
    const contents = rmsg.result.?.object.get("contents").?;
    try testing.expectEqualStrings("markdown", contents.object.get("kind").?.string);
    try testing.expectEqualStrings("mock hover\nsecond line\nthird line", contents.object.get("value").?.string);
}
