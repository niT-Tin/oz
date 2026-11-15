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
const lsp_types = @import("types.zig");

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
    /// Mixed-severity, multiline/CJK diagnostics plus an unrelated URI push.
    diagnostic_ui,
    diagnostic_underlines,
    /// First edit gets no reply; later edits publish current then stale data.
    diagnostic_versions,
    /// Phantom-'j' detector: after EVERY didChange, inspect the latest
    /// recorded document text — if it starts with 'j' push an error
    /// diagnostic at line 0 ("phantom j"), else push an empty list.
    /// Regression coverage for the jk exit LSP-sync bug: 'i' + 'j' + 'k'
    /// must send a didChange for BOTH the 'j' insertion and its removal,
    /// or the server keeps analyzing "jconst …" forever (stale
    /// diagnostics / inlay hints computed against text that never existed).
    jk_sync,
    /// Range-respecting inlay hints that echo the server's RECORDED text:
    /// textDocument/inlayHint returns one hint per line of the REQUESTED
    /// range (clamped to the recorded document), label = ": <line content
    /// minus its first word>", anchored at character 0. Because the label
    /// derives from the recorded copy of the REQUESTED uri, a test can
    /// verify (a) which lines the editor asked for — coverage of the whole
    /// viewport — and (b) whether didChange edits reached the right
    /// document (a stale copy yields stale labels). Script `hello` keeps
    /// its fixed line-0 ": i32" hint for the older tests.
    inlay_range,
    /// End-of-line inlay hints, zls-shaped: one hint per requested line,
    /// anchored at the line's TEXT end (after the last content byte, before
    /// a CRLF/ LF terminator) with label ": eol". zls emits a variable type
    /// hint at the end of the declared name token, which is at EOL for a
    /// legal multiline declaration (`const foo\n    = 1;`) — the case that
    /// exposed the stale-hint shift on `o`. Also models a slow response:
    /// only the FIRST inlayHint request is answered, so the hints cannot be
    /// repaired from a fresh document between `o` and the assertions.
    inlay_eol,
    /// Rich popup fixture: hover markdown with a heading, an arrow glyph
    /// ("→", 3 bytes / 1 cell), a fenced zig block and CJK text; completion
    /// items with detail + markdown documentation and a wide label. Used by
    /// the popup-geometry/markdown e2e tests.
    rich,
    /// Capability-aware hover fixture: returns MarkupContent kind "markdown"
    /// with a zig fenced block ONLY when the client advertised
    /// textDocument.hover.contentFormat containing "markdown"; otherwise it
    /// returns kind "plaintext" with no fence (like ZLS). This prevents a
    /// canned-markdown mock from hiding a missing capability negotiation.
    hover_cap,
    /// Completion ranking fixture: the server returns the reported bad order
    /// count_lines, read_lines, line, inline; every item has a distinct
    /// insertText so the accepted bytes prove insertText was used and the
    /// label/filterText were not. The client must rank exact `line` first.
    completion_order,
    /// Inlay/undo fixture: one hint anchored at line 0, character 2 (the
    /// start of the identifier) plus a completion item that replaces the
    /// 20-character identifier with another 20-character insertText. Used by
    /// the undo replacement-start regression (the old transform underflowed
    /// when removed > offset).
    inlay_param,
    /// Progressive completion fixture: `lines` (sortText "a") and `line`
    /// (sortText "b"), docs tagged with the response generation. Typing "l"
    /// ranks lines first; typing the full "line" makes exact line best. Used
    /// to separate default-best selection from an explicit Ctrl+n selection
    /// across refreshes.
    completion_progressive,
    /// Performance fixture: one item with a large Markdown body containing a
    /// 160-line zig fenced block. Used to profile/document the per-frame
    /// documentation layout cost while the completion menu is open.
    completion_bulk_docs,
    completion_fenced_edges,
    /// Rich completion-only fixture: labelDetails (detail + description),
    /// display label != insertText, markdown/plaintext docs, a long
    /// scrollable body, duplicate labels and detail-only/no-docs items.
    completion_rich,
    /// Initial items without docs; completionProvider.resolveProvider=true.
    /// Resolve refines detail/documentation for the selected item.
    completion_resolve,
    /// Like completion_resolve, but A's response is held until B is
    /// requested, then emitted first (out-of-order/obsolete response).
    completion_resolve_hold,
    /// Resolve returns a JSON-RPC error; the menu must remain usable.
    completion_resolve_error,
    /// Hold formatting until another URI is didOpen'd. Rename returns two
    /// URI-keyed changes with b.zig first, deliberately unlike request order.
    edit_safety,
    /// The same rename fixture in documentChanges form (nullable versions).
    edit_safety_documents,
    /// Rename returns real b.zig while hover observes the opened symlink.
    edit_safety_alias,
    /// Controlled signature/completion lifecycle fixture. The first
    /// signatureHelp request can be held until another message arrives;
    /// markers (OZ_SIG_BARRIER_DIR/request-N, response-N) give tests a
    /// protocol barrier instead of sleeping.
    signature_lifecycle,

    pub fn parse(name: []const u8) ?Script {
        if (std.mem.eql(u8, name, "hello")) return .hello;
        if (std.mem.eql(u8, name, "silent")) return .silent;
        if (std.mem.eql(u8, name, "clear_on_change")) return .clear_on_change;
        if (std.mem.eql(u8, name, "diagnostic_ui")) return .diagnostic_ui;
        if (std.mem.eql(u8, name, "diagnostic_underlines")) return .diagnostic_underlines;
        if (std.mem.eql(u8, name, "diagnostic_versions")) return .diagnostic_versions;
        if (std.mem.eql(u8, name, "jk_sync")) return .jk_sync;
        if (std.mem.eql(u8, name, "inlay_range")) return .inlay_range;
        if (std.mem.eql(u8, name, "inlay_eol")) return .inlay_eol;
        if (std.mem.eql(u8, name, "rich")) return .rich;
        if (std.mem.eql(u8, name, "hover_cap")) return .hover_cap;
        if (std.mem.eql(u8, name, "completion_order")) return .completion_order;
        if (std.mem.eql(u8, name, "inlay_param")) return .inlay_param;
        if (std.mem.eql(u8, name, "completion_progressive")) return .completion_progressive;
        if (std.mem.eql(u8, name, "completion_bulk_docs")) return .completion_bulk_docs;
        if (std.mem.eql(u8, name, "completion_fenced_edges")) return .completion_fenced_edges;
        if (std.mem.eql(u8, name, "completion_rich")) return .completion_rich;
        if (std.mem.eql(u8, name, "completion_resolve")) return .completion_resolve;
        if (std.mem.eql(u8, name, "completion_resolve_hold")) return .completion_resolve_hold;
        if (std.mem.eql(u8, name, "completion_resolve_error")) return .completion_resolve_error;
        if (std.mem.eql(u8, name, "edit_safety")) return .edit_safety;
        if (std.mem.eql(u8, name, "edit_safety_documents")) return .edit_safety_documents;
        if (std.mem.eql(u8, name, "edit_safety_alias")) return .edit_safety_alias;
        if (std.mem.eql(u8, name, "signature_lifecycle")) return .signature_lifecycle;
        return null;
    }
};

pub const SignatureMode = enum { normal, null_result, error_result, ignore, timeout };

/// Per-connection state carried across messages. Owns everything it records;
/// call `deinit` when the connection ends.
pub const State = struct {
    /// true once the client has sent the `initialized` notification.
    initialized: bool = false,
    /// true after an `exit` notification; the server loop stops.
    exit_requested: bool = false,
    /// Held completionItem/resolve request id (completion_resolve_hold).
    held_resolve_id: ?u64 = null,
    /// URIs seen in textDocument/didOpen, in arrival order (owned).
    opened: std.ArrayList([]u8) = .empty,
    /// textDocument/didChange records: uri + the latest full text (owned).
    /// Seeded by didOpen, so the FIRST didChange lands at index 1.
    changed: std.ArrayList(ChangeRecord) = .empty,
    /// clear_on_change script: the empty publishDiagnostics went out.
    clear_pushed: bool = false,
    /// inlay_eol script: the single inlayHint response has been sent.
    /// Later requests are deliberately left unanswered to model a slow
    /// server (the editor must not rely on a refresh to fix stale hints).
    inlay_answered: bool = false,
    /// Complete owned response held until didOpen of another document.
    pending_format: ?struct { body: []u8, uri: []u8 } = null,
    signature_mode: SignatureMode = .normal,
    signature_requests: u32 = 0,
    signature_responses: u32 = 0,
    /// hover_cap script: client declared hover.contentFormat with markdown.
    /// Recorded from initialize so the SAME fixture answers in the format the
    /// client asked for, exactly like a real server.
    hover_markdown_cap: bool = false,
    /// hover_cap script test seam: a server may still answer plaintext even
    /// when the client advertises markdown. The renderer must then keep
    /// literal backticks/fences as prose. Set by OZ_HOVER_FORCE_PLAINTEXT=1.
    hover_force_plaintext: bool = false,
    /// completion_progressive: number of completion responses sent. Docs carry
    /// this generation so a test can prove it is reading a REFRESHED frame
    /// rather than a stale one.
    progressive_requests: u32 = 0,

    pub const ChangeRecord = struct {
        uri: []u8,
        text: []u8,
    };

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        if (self.pending_format) |pending| {
            alloc.free(pending.body);
            alloc.free(pending.uri);
        }
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
            state.hover_markdown_cap = initializeHoverMarkdownCap(msg.params);
            try pushResponse(alloc, &out, id, try buildInitializeResult(a, script));
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
            const result = if (script == .completion_fenced_edges)
                try buildFencedEdgeCompletionResult(a)
            else if (script == .completion_bulk_docs)
                try buildBulkDocsCompletionResult(a)
            else if (script == .completion_order)
                try buildOrderCompletionResult(a)
            else if (script == .inlay_param)
                try buildInlayParamCompletionResult(a)
            else if (script == .completion_progressive) blk: {
                state.progressive_requests += 1;
                break :blk try buildProgressiveCompletionResult(a, state.progressive_requests);
            } else if (script == .completion_rich)
                try buildRichCompletionResult(a, prefix)
            else if (script == .signature_lifecycle)
                try buildLifecycleCompletionResult(a)
            else if (script == .completion_resolve or script == .completion_resolve_hold or script == .completion_resolve_error)
                try buildResolveCompletionResult(a, prefix, script)
            else
                try buildCompletionResult(a, prefix, script);
            try pushResponse(alloc, &out, id, result);
        } else if (std.mem.eql(u8, method, "completionItem/resolve")) {
            if (script == .completion_resolve_error) {
                const body = try json_rpc.encodeError(alloc, id, -32603, "resolve failed");
                errdefer alloc.free(body);
                try out.frames.append(alloc, body);
            } else if (script == .completion_resolve_hold) {
                const label = if (msg.params) |p|
                    if (p == .object) if (p.object.get("label")) |l| if (l == .string) l.string else "" else "" else ""
                else
                    "";
                // A is held; B flushes A first, then answers B. The client
                // must discard A (its slot was replaced) and keep B.
                if (std.mem.indexOf(u8, label, "resolveA") != null) {
                    state.held_resolve_id = id;
                } else {
                    if (state.held_resolve_id) |held| {
                        try pushResponse(alloc, &out, held, try buildResolvedItem(a, "resolveA", "LATE_A"));
                        state.held_resolve_id = null;
                    }
                    try pushResponse(alloc, &out, id, try buildResolvedItem(a, label, "DOC_B"));
                }
            } else {
                const label = if (msg.params) |p|
                    if (p == .object) if (p.object.get("label")) |l| if (l == .string) l.string else "" else "" else ""
                else
                    "";
                try pushResponse(alloc, &out, id, try buildResolvedItem(a, label, label));
            }
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            const result = if (script == .edit_safety or script == .edit_safety_documents or script == .edit_safety_alias)
                try buildSafetyHover(a, state, msg.params, if (script == .edit_safety_alias) "linked-b.zig" else "b.zig")
            else
                try buildHoverResult(a, script, state);
            try pushResponse(alloc, &out, id, result);
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
            if (script == .signature_lifecycle) {
                state.signature_requests += 1;
                switch (state.signature_mode) {
                    .ignore, .timeout => {},
                    .null_result => {
                        try pushResponse(alloc, &out, id, .null);
                        state.signature_responses += 1;
                    },
                    .error_result => {
                        const body = try json_rpc.encodeError(alloc, id, -32603, "signature failed SIG_ERROR");
                        errdefer alloc.free(body);
                        try out.frames.append(alloc, body);
                        state.signature_responses += 1;
                    },
                    .normal => {
                        const label = if (state.signature_requests == 1) "SIG_A" else "SIG_B";
                        try pushResponse(alloc, &out, id, try buildSignatureLabel(a, label));
                        state.signature_responses += 1;
                    },
                }
            } else {
                try pushResponse(alloc, &out, id, try buildSignatureResult(a));
            }
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            if (script == .edit_safety or script == .edit_safety_documents or script == .edit_safety_alias) {
                const uri = requestDocumentUri(msg.params) orelse return error.MissingDocumentUri;
                const body = try json_rpc.encodeResponse(alloc, id, try buildSafetyEdits(a, "FORMATTED_A"));
                errdefer alloc.free(body);
                const owned_uri = try alloc.dupe(u8, uri);
                errdefer alloc.free(owned_uri);
                if (state.pending_format) |old| {
                    alloc.free(old.body);
                    alloc.free(old.uri);
                }
                state.pending_format = .{ .body = body, .uri = owned_uri };
            } else {
                // Default fixture is a no-op edit over the whole document.
                try pushResponse(alloc, &out, id, try buildFormatResult(a, state));
            }
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (script == .edit_safety or script == .edit_safety_documents or script == .edit_safety_alias) {
                try pushResponse(alloc, &out, id, try buildSafetyRename(a, msg.params, script == .edit_safety_documents));
            } else {
                try pushResponse(alloc, &out, id, try buildRenameResult(a, state));
            }
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            if (script == .inlay_range) {
                // Echo the recorded text of the REQUESTED uri, one hint per
                // line of the requested range (see Script.inlay_range).
                try pushResponse(alloc, &out, id, try buildRangeInlayResult(a, state, msg.params));
            } else if (script == .inlay_eol) {
                // Exactly one response, then silence (slow zls): hints the
                // editor shifted must stay where it put them until the next
                // insert-exit request, so a stale EOL hint is observable.
                if (!state.inlay_answered) {
                    state.inlay_answered = true;
                    try pushResponse(alloc, &out, id, try buildEolInlayResult(a, state, msg.params));
                }
            } else if (script == .inlay_param) {
                try pushResponse(alloc, &out, id, try buildInlayParamHintResult(a));
            } else {
                try pushResponse(alloc, &out, id, try buildInlayResult(a));
            }
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
        if (state.pending_format) |pending| {
            if (requestDocumentUri(msg.params)) |opened_uri| {
                if (!std.mem.eql(u8, pending.uri, opened_uri)) {
                    try out.frames.append(alloc, pending.body);
                    alloc.free(pending.uri);
                    state.pending_format = null;
                }
            }
        }
        // Push diagnostics for the JUST-opened document (uri matches what the
        // client filters on) — pushing at `initialized` races didOpen and the
        // client would drop the diagnostics as belonging to another file.
        if (script == .hello or script == .clear_on_change or script == .diagnostic_ui or script == .diagnostic_underlines or script == .diagnostic_versions) {
            const uri = if (state.opened.items.len > 0) state.opened.items[state.opened.items.len - 1] else default_uri;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            var params = if (script == .diagnostic_underlines) try buildUnderlineDiagnostics(a, uri) else if (script == .diagnostic_ui) try buildDetailedDiagnostics(a, uri) else try buildDiagnosticsParams(a, uri, "mock error");
            if (script == .diagnostic_versions) try params.object.put(a, "version", msg.params.?.object.get("textDocument").?.object.get("version").?);
            const body = try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", params);
            errdefer alloc.free(body);
            try out.frames.append(alloc, body);
            if (script == .diagnostic_ui) {
                const other = try buildDiagnosticsParams(a, "file:///tmp/oz-unrelated-diagnostic.zig", "FOREIGN_DIAG");
                try out.frames.append(alloc, try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", other));
            }
        }
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try recordDidChange(alloc, state, msg.params);
        if (script == .diagnostic_versions and state.changed.items.len >= 3) {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const td = msg.params.?.object.get("textDocument").?;
            const uri = td.object.get("uri").?.string;
            const v = td.object.get("version").?;
            const version: i64 = switch (v) {
                .integer => |n| n,
                .number_string => |s| try std.fmt.parseInt(i64, s, 10),
                else => return error.InvalidVersion,
            };
            // After the second edit publish a valid result, then a late old
            // result and a late old clear. Neither may replace the valid one.
            // After later edits publish only an invalid future version.
            if (state.changed.items.len == 3) {
                var current = try buildDiagnosticsParams(a, uri, "CURRENT_VERSION");
                try current.object.put(a, "version", .{ .integer = version });
                try out.frames.append(alloc, try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", current));
                var stale = try buildDiagnosticsParams(a, uri, "STALE_VERSION");
                try stale.object.put(a, "version", .{ .integer = version - 1 });
                try out.frames.append(alloc, try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", stale));
                var empty = try buildEmptyDiagnosticsParams(a, uri);
                try empty.object.put(a, "version", .{ .integer = version - 1 });
                try out.frames.append(alloc, try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", empty));
            } else {
                var future = try buildDiagnosticsParams(a, uri, "FUTURE_VERSION");
                try future.object.put(a, "version", .{ .integer = version + 1 });
                try out.frames.append(alloc, try json_rpc.encodeNotification(alloc, "textDocument/publishDiagnostics", future));
            }
        }
        // clear_on_change: the edit fixed the document — push an empty
        // diagnostics list so the client must clear the gutter mark (and
        // repaint without waiting for another keypress).
        if ((script == .clear_on_change or script == .diagnostic_ui or script == .diagnostic_underlines) and !state.clear_pushed) {
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

fn buildInitializeResult(a: std.mem.Allocator, script: Script) !std.json.Value {
    var caps = try std.json.ObjectMap.init(a, &.{}, &.{});
    // 2 == Incremental text sync.
    try caps.put(a, "textDocumentSync", .{ .integer = 2 });

    var comp = try std.json.ObjectMap.init(a, &.{}, &.{});
    var triggers = std.json.Array.init(a);
    try triggers.append(.{ .string = "." });
    try comp.put(a, "triggerCharacters", .{ .array = triggers });
    const resolve_script = script == .completion_resolve or
        script == .completion_resolve_hold or script == .completion_resolve_error;
    try comp.put(a, "resolveProvider", .{ .bool = resolve_script });
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

fn richCompletionItem(
    a: std.mem.Allocator,
    label: []const u8,
    kind: i64,
    insert_text: ?[]const u8,
    ld_detail: ?[]const u8,
    ld_desc: ?[]const u8,
    detail: ?[]const u8,
    doc_kind: ?[]const u8,
    doc_value: ?[]const u8,
) !std.json.Value {
    var item = try std.json.ObjectMap.init(a, &.{}, &.{});
    try item.put(a, "label", .{ .string = label });
    try item.put(a, "kind", .{ .integer = kind });
    if (insert_text) |t| try item.put(a, "insertText", .{ .string = t });
    if (ld_detail != null or ld_desc != null) {
        var ld = try std.json.ObjectMap.init(a, &.{}, &.{});
        if (ld_detail) |t| try ld.put(a, "detail", .{ .string = t });
        if (ld_desc) |t| try ld.put(a, "description", .{ .string = t });
        try item.put(a, "labelDetails", .{ .object = ld });
    }
    if (detail) |t| try item.put(a, "detail", .{ .string = t });
    if (doc_value) |v| {
        if (doc_kind) |k| {
            var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
            try doc.put(a, "kind", .{ .string = k });
            try doc.put(a, "value", .{ .string = v });
            try item.put(a, "documentation", .{ .object = doc });
        } else {
            try item.put(a, "documentation", .{ .string = v });
        }
    }
    return .{ .object = item };
}

/// inlay_param: one 20-char item whose label/filterText matches the typed
/// lowercase identifier while insertText is a distinct 20-char uppercase run.
fn buildInlayParamCompletionResult(a: std.mem.Allocator) !std.json.Value {
    var items = std.json.Array.init(a);
    var it = try std.json.ObjectMap.init(a, &.{}, &.{});
    try it.put(a, "label", .{ .string = "abcdefghijklmnopqrstXYZ" });
    try it.put(a, "filterText", .{ .string = "abcdefghijklmnopqrstXYZ" });
    try it.put(a, "insertText", .{ .string = "ABCDEFGHIJKLMNOPQRST" });
    try it.put(a, "kind", .{ .integer = 6 });
    try it.put(a, "documentation", .{ .object = blk: {
        var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
        try doc.put(a, "kind", .{ .string = "plaintext" });
        try doc.put(a, "value", .{ .string = "INLAY_PARAM_DOC" });
        break :blk doc;
    } });
    try items.append(.{ .object = it });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

/// inlay_param: hint exactly at the replacement start (line 0, char 2).
fn buildInlayParamHintResult(a: std.mem.Allocator) !std.json.Value {
    var pos = try std.json.ObjectMap.init(a, &.{}, &.{});
    try pos.put(a, "line", .{ .integer = 0 });
    try pos.put(a, "character", .{ .integer = 2 });
    var hint = try std.json.ObjectMap.init(a, &.{}, &.{});
    try hint.put(a, "position", .{ .object = pos });
    try hint.put(a, "label", .{ .string = ": usize" });
    var items = std.json.Array.init(a);
    try items.append(.{ .object = hint });
    return .{ .array = items };
}

/// completion_progressive: two prefix-related items where the best match
/// changes with the typed prefix, while both identities stay selectable.
/// Initial order (typed "l") is `lines` (sortText a) then `line` (b); typing
/// "line" makes exact `line` best. Docs carry the response generation so a
/// test can prove it observed a refreshed frame.
fn buildProgressiveCompletionResult(a: std.mem.Allocator, generation: u32) !std.json.Value {
    const Spec = struct { label: []const u8, insert: []const u8, doc: []const u8, sort: []const u8 };
    const specs = [_]Spec{
        .{ .label = "lines", .insert = "lines_insert", .doc = "LINES", .sort = "a" },
        .{ .label = "line", .insert = "line_insert", .doc = "LINE", .sort = "b" },
    };
    var items = std.json.Array.init(a);
    for (specs) |spec| {
        var it = try std.json.ObjectMap.init(a, &.{}, &.{});
        try it.put(a, "label", .{ .string = spec.label });
        try it.put(a, "filterText", .{ .string = spec.label });
        try it.put(a, "insertText", .{ .string = spec.insert });
        try it.put(a, "sortText", .{ .string = spec.sort });
        try it.put(a, "kind", .{ .integer = 6 });
        const doc_value = try std.fmt.allocPrint(a, "{s}_DOC_{d}", .{ spec.doc, generation });
        var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
        try doc.put(a, "kind", .{ .string = "plaintext" });
        try doc.put(a, "value", .{ .string = doc_value });
        try it.put(a, "documentation", .{ .object = doc });
        try items.append(.{ .object = it });
    }
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

/// completion_bulk_docs: one item whose documentation has a 160-line fenced
/// code block (bounded by the editor's 64 KiB / 256-row doc cap).
fn buildBulkDocsCompletionResult(a: std.mem.Allocator) !std.json.Value {
    var items = std.json.Array.init(a);
    var it = try std.json.ObjectMap.init(a, &.{}, &.{});
    try it.put(a, "label", .{ .string = "std_bulk" });
    try it.put(a, "filterText", .{ .string = "std_bulk" });
    try it.put(a, "insertText", .{ .string = "std_bulk" });
    try it.put(a, "kind", .{ .integer = 6 });
    try it.put(a, "detail", .{ .string = "fn std_bulk() void" });
    var doc_text = std.ArrayList(u8).empty;
    // No deinit here: the result's `value` slice is encoded after this
    // builder returns, and the handler's arena is the owner until then.
    try doc_text.appendSlice(a, "BULK_DOC_START\n```zig\n");
    var i: usize = 0;
    while (i < 160) : (i += 1) {
        var line_buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "const value_{d}: usize = {d};\n", .{ i, i });
        try doc_text.appendSlice(a, line);
    }
    try doc_text.appendSlice(a, "```\nBULK_DOC_END");
    var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
    try doc.put(a, "kind", .{ .string = "markdown" });
    try doc.put(a, "value", .{ .string = doc_text.items });
    try it.put(a, "documentation", .{ .object = doc });
    try items.append(.{ .object = it });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

/// Adversarial block slicing: CRLF, multiple blocks, UTF-8 and an unclosed
/// final fence must retain their own source offsets after batch highlighting.
fn buildFencedEdgeCompletionResult(a: std.mem.Allocator) !std.json.Value {
    var it = try std.json.ObjectMap.init(a, &.{}, &.{});
    try it.put(a, "label", .{ .string = "std_fenced" });
    try it.put(a, "kind", .{ .integer = 3 });
    try it.put(a, "detail", .{ .string = "fn std_fenced() void" });
    var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
    try doc.put(a, "kind", .{ .string = "markdown" });
    try doc.put(a, "value", .{ .string = "FENCE_EDGE_START\r\n```zig\r\nconst first = \"中😀\";\r\n```\r\nAFTER_FIRST\r\n```zig\r\nconst second = 2;\r\n```\r\nAFTER_SECOND\r\n```zig\r\nconst last = \"EDGE_UNCLOSED_LAST\";" });
    try it.put(a, "documentation", .{ .object = doc });
    var items = std.json.Array.init(a);
    try items.append(.{ .object = it });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

/// Completion ordering fixture: the exact server order from the report, each
/// item accepting a distinct insertText.
fn buildOrderCompletionResult(a: std.mem.Allocator) !std.json.Value {
    const labels = [_][]const u8{ "count_lines", "read_lines", "line", "inline" };
    var items = std.json.Array.init(a);
    for (labels) |label| {
        var it = try std.json.ObjectMap.init(a, &.{}, &.{});
        try it.put(a, "label", .{ .string = label });
        try it.put(a, "kind", .{ .integer = 3 });
        const insert = try std.fmt.allocPrint(a, "{s}_accepted", .{label});
        try it.put(a, "insertText", .{ .string = insert });
        try it.put(a, "filterText", .{ .string = label });
        try items.append(.{ .object = it });
    }
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

fn buildRichCompletionResult(a: std.mem.Allocator, prefix: []const u8) !std.json.Value {
    _ = prefix;
    var items = std.json.Array.init(a);
    try items.append(try richCompletionItem(a, "ArrayList", 22, "ArrayList", "(comptime T: type)", "type", "fn (comptime T: type) type", "markdown", "A contiguous, growable list of items in memory.\n\n**Bold prose** and `inline code`.\n\n```zig\nvar list = std.ArrayList(u8).init(alloc);\n```\nShort doc end."));
    try items.append(try richCompletionItem(a, "HashMap", 22, "HashMap", "(comptime K: type, comptime V: type)", "type", "fn (comptime K: type, comptime V: type) type", "markdown", "Duplicates ArrayList's line but not its documentation.\n```zig\nconst map = std.AutoHashMap(u32, []const u8).init(alloc);\n```"));
    try items.append(try richCompletionItem(a, "makeThing", 3, "makeThing", "(count: usize)", "fn", "fn makeThing(count: usize) Thing", "plaintext", "PLAIN_DOC *stars stay literal* and `ticks stay literal`."));
    // Long, scrollable docs with CJK/emoji and a fenced block.
    var long = std.ArrayList(u8).empty;
    try long.appendSlice(a, "LONG_DOC_FIRST\n");
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try long.appendSlice(a, try std.fmt.allocPrint(a, "line {d}: 文档内容 🙂 keeps wrapping and scrolling until the end.\n", .{i}));
    }
    try long.appendSlice(a, "```zig\nconst sentinel = 42;\n```\nLONG_DOC_LAST");
    try items.append(try richCompletionItem(a, "LONG_DOC", 9, "LONG_DOC", null, "std", "pub const LONG_DOC", "markdown", long.items));
    // Same display label, different identity/documentation.
    try items.append(try richCompletionItem(a, "dup", 6, "dup_alpha", "(alpha)", "A", "detail alpha", "markdown", "DUP_ALPHA_DOC"));
    try items.append(try richCompletionItem(a, "dup", 6, "dup_beta", "(beta)", "B", "detail beta", "markdown", "DUP_BETA_DOC"));
    try items.append(try richCompletionItem(a, "detail_only", 6, "detail_only", null, null, "DETAIL_ONLY_SIGNATURE", null, null));
    try items.append(try richCompletionItem(a, "bare", 6, "bare", null, null, null, null, null));
    try items.append(try richCompletionItem(a, "array_list", 9, "array_list", null, null, "pub const array_list", null, null));
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

fn buildResolveCompletionResult(a: std.mem.Allocator, prefix: []const u8, script: Script) !std.json.Value {
    _ = prefix;
    _ = script;
    var items = std.json.Array.init(a);
    const specs = [_]struct { label: []const u8, kind: i64, doc: ?[]const u8 }{
        .{ .label = "resolveA", .kind = 3, .doc = null },
        .{ .label = "resolveB", .kind = 3, .doc = null },
        .{ .label = "resolveC_has_docs", .kind = 6, .doc = "INITIAL_DOC_C" },
        .{ .label = "resolveD_detail", .kind = 6, .doc = null },
    };
    for (specs) |sp| {
        var item = try std.json.ObjectMap.init(a, &.{}, &.{});
        try item.put(a, "label", .{ .string = sp.label });
        try item.put(a, "kind", .{ .integer = sp.kind });
        try item.put(a, "insertText", .{ .string = sp.label });
        if (std.mem.eql(u8, sp.label, "resolveD_detail")) {
            try item.put(a, "detail", .{ .string = "DETAIL_D" });
        }
        if (sp.doc) |d| try item.put(a, "documentation", .{ .string = d });
        var data = try std.json.ObjectMap.init(a, &.{}, &.{});
        try data.put(a, "slot", .{ .string = sp.label });
        try item.put(a, "data", .{ .object = data });
        try items.append(.{ .object = item });
    }
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

fn buildResolvedItem(a: std.mem.Allocator, label: []const u8, sentinel: []const u8) !std.json.Value {
    const detail = try std.fmt.allocPrint(a, "resolved signature for {s}", .{label});
    const doc = try std.fmt.allocPrint(a, "RESOLVED_BODY_{s}", .{sentinel});
    return richCompletionItem(a, label, 3, label, "(resolved: usize)", "resolved", detail, "markdown", doc);
}

fn buildCompletionResult(a: std.mem.Allocator, prefix: []const u8, script: Script) !std.json.Value {
    var item = try std.json.ObjectMap.init(a, &.{}, &.{});
    const item_label = try std.fmt.allocPrint(a, "mockItem{s}", .{prefix});
    try item.put(a, "label", .{ .string = item_label });
    try item.put(a, "kind", .{ .integer = 6 }); // CompletionItemKind.Function
    if (script == .rich) {
        // Renderable documentation: bold prose + a fenced zig block whose
        // body must get real syntax colors in the completion docs pane.
        try item.put(a, "detail", .{ .string = "fn(e: i32) void" });
        var docs = try std.json.ObjectMap.init(a, &.{}, &.{});
        try docs.put(a, "kind", .{ .string = "markdown" });
        try docs.put(a, "value", .{ .string = "**mock docs**\n```zig\nconst q = 7;\n```" });
        try item.put(a, "documentation", .{ .object = docs });
    }
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
    if (script == .rich) {
        // A label whose UTF-8 bytes (9) exceed its terminal cells (6):
        // byte-counted row widths shifted the menu's right border.
        var wide = try std.json.ObjectMap.init(a, &.{}, &.{});
        const wide_label = try std.fmt.allocPrint(a, "日本語{s}", .{prefix});
        try wide.put(a, "label", .{ .string = wide_label });
        try wide.put(a, "kind", .{ .integer = 6 });
        try items.append(.{ .object = wide });
    }
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
}

/// True when initialize.params.capabilities.textDocument.hover.contentFormat
/// contains "markdown". Defensive about absent/mistyped fields: a missing
/// capability must mean plaintext, not a panic.
pub fn initializeHoverMarkdownCap(params: ?std.json.Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const caps = p.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const td = caps.object.get("textDocument") orelse return false;
    if (td != .object) return false;
    const hover = td.object.get("hover") orelse return false;
    if (hover != .object) return false;
    const formats = hover.object.get("contentFormat") orelse return false;
    if (formats != .array) return false;
    for (formats.array.items) |f| {
        if (f == .string and std.mem.eql(u8, f.string, "markdown")) return true;
    }
    return false;
}

fn buildHoverResult(a: std.mem.Allocator, script: Script, state: *State) !std.json.Value {
    var contents = try std.json.ObjectMap.init(a, &.{}, &.{});
    try contents.put(a, "kind", .{ .string = "markdown" });
    if (script == .hover_cap) {
        // The negotiated format decides the payload: markdown gets a fenced
        // zig block (real syntax colors); plaintext stays literal prose with
        // no fences, so the renderer must not interpret it as Markdown.
        const md = state.hover_markdown_cap and !state.hover_force_plaintext;
        const value: []const u8 = if (md)
            "```zig\nconst hover_sentinel: usize = 99;\n```\n(usize = 99)"
        else
            "const hover_sentinel: usize = 99;\n```not a fence\n(usize = 99)";
        try contents.put(a, "kind", .{ .string = if (md) "markdown" else "plaintext" });
        try contents.put(a, "value", .{ .string = value });
        var result = try std.json.ObjectMap.init(a, &.{}, &.{});
        try result.put(a, "contents", .{ .object = contents });
        return .{ .object = result };
    }
    if (script == .rich) {
        // Six lines (the hover cap): heading (markers concealed), an arrow
        // (byte/cell mismatch), a fenced zig block (syntax colors), and CJK
        // at EOL (3 bytes / 2 cells). Any byte-counted row pad misaligns
        // the right border of exactly these rows.
        try contents.put(a, "value", .{ .string = "## mock hover\n→ `second line`\n```zig\nconst b = 2;\n```\nhttp://example.com third line 第三行" });
        var result = try std.json.ObjectMap.init(a, &.{}, &.{});
        try result.put(a, "contents", .{ .object = contents });
        return .{ .object = result };
    }
    // Multi-line hover: exercises the floating window's row wrapping and
    // its token styling — markdown inline tokens (bold, code span, URL) on
    // the prose lines and a ```zig fenced block whose content must get real
    // tree-sitter colors ("const" keyword, "2" number).
    try contents.put(a, "value", .{ .string = "**mock hover**\n`second line`\n```zig\nconst b = 2;\n```\nhttp://example.com third line" });
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

fn requestDocumentUri(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const td = p.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri = td.object.get("uri") orelse return null;
    return if (uri == .string) uri.string else null;
}

/// Both safety fixtures replace exactly the three ASCII characters on line
/// zero, keeping the newline. The response therefore has a real valid range.
fn buildSafetyEdits(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    var start = try std.json.ObjectMap.init(a, &.{}, &.{});
    try start.put(a, "line", .{ .integer = 0 });
    try start.put(a, "character", .{ .integer = 0 });
    var end = try std.json.ObjectMap.init(a, &.{}, &.{});
    try end.put(a, "line", .{ .integer = 0 });
    try end.put(a, "character", .{ .integer = 3 });
    var range = try std.json.ObjectMap.init(a, &.{}, &.{});
    try range.put(a, "start", .{ .object = start });
    try range.put(a, "end", .{ .object = end });
    var edit = try std.json.ObjectMap.init(a, &.{}, &.{});
    try edit.put(a, "range", .{ .object = range });
    try edit.put(a, "newText", .{ .string = text });
    var edits = std.json.Array.init(a);
    try edits.append(.{ .object = edit });
    return .{ .array = edits };
}

fn buildSafetyRename(a: std.mem.Allocator, params: ?std.json.Value, document_changes: bool) !std.json.Value {
    const uri_a = requestDocumentUri(params) orelse return error.MissingDocumentUri;
    const slash = std.mem.lastIndexOfScalar(u8, uri_a, '/') orelse return error.MissingDocumentUri;
    const uri_b = try std.fmt.allocPrint(a, "{s}/b.zig", .{uri_a[0..slash]});
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    const uris = [_][]const u8{ uri_b, uri_a };
    const replacements = [_][]const u8{ "RENAMED_B", "RENAMED_A" };
    if (document_changes) {
        var documents = std.json.Array.init(a);
        for (uris, replacements) |uri, replacement| {
            var td = try std.json.ObjectMap.init(a, &.{}, &.{});
            try td.put(a, "uri", .{ .string = uri });
            try td.put(a, "version", .null);
            var doc = try std.json.ObjectMap.init(a, &.{}, &.{});
            try doc.put(a, "textDocument", .{ .object = td });
            try doc.put(a, "edits", try buildSafetyEdits(a, replacement));
            try documents.append(.{ .object = doc });
        }
        try result.put(a, "documentChanges", .{ .array = documents });
    } else {
        var changes = try std.json.ObjectMap.init(a, &.{}, &.{});
        for (uris, replacements) |uri, replacement| try changes.put(a, uri, try buildSafetyEdits(a, replacement));
        try result.put(a, "changes", .{ .object = changes });
    }
    return .{ .object = result };
}

/// Hover requested from A reports B's last didOpen/didChange text. Rename
/// responses do not update this copy themselves, so a stale hidden document
/// is observable without selecting B (which could otherwise repair it).
fn buildSafetyHover(a: std.mem.Allocator, state: *State, params: ?std.json.Value, peer: []const u8) !std.json.Value {
    const uri_a = requestDocumentUri(params) orelse return error.MissingDocumentUri;
    const slash = std.mem.lastIndexOfScalar(u8, uri_a, '/') orelse return error.MissingDocumentUri;
    const uri_b = try std.fmt.allocPrint(a, "{s}/{s}", .{ uri_a[0..slash], peer });
    const text = recordedTextOf(state, uri_b) orelse "<not opened>";
    const label = try std.fmt.allocPrint(a, "server {s}: {s}", .{ peer, std.mem.trimEnd(u8, text, "\r\n") });
    var contents = try std.json.ObjectMap.init(a, &.{}, &.{});
    try contents.put(a, "kind", .{ .string = "plaintext" });
    try contents.put(a, "value", .{ .string = label });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "contents", .{ .object = contents });
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

/// The server's latest recorded full text for `uri` (borrowed from state;
/// seeded by didOpen, updated by every didChange).
fn recordedTextOf(state: *State, uri: []const u8) ?[]const u8 {
    var i = state.changed.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, state.changed.items[i].uri, uri)) return state.changed.items[i].text;
    }
    return null;
}

/// Parse the `line` member of an LSP position object (tolerates both
/// `.integer` and the codebase's `.number_string`).
fn posLineOf(v: std.json.Value, out: *u32) bool {
    if (v != .object) return false;
    const line_v = v.object.get("line") orelse return false;
    const n = jsonInt(line_v) orelse return false;
    if (n < 0) return false;
    out.* = @intCast(n);
    return true;
}

/// One inlay hint anchored at character 0 of `line`, whose label echoes
/// `content` minus its first word (": v105 = 105;" for a recorded line
/// "const v105 = 105;"). Returns false when the line carries nothing to
/// annotate (blank, single-token, or whitespace-only tail).
fn appendEchoHint(a: std.mem.Allocator, hints: *std.json.Array, line: u32, content: []const u8) !bool {
    var i: usize = 0;
    while (i < content.len and content[i] != ' ' and content[i] != '\t') i += 1; // first word
    if (i == content.len) return false; // single-token line (brace, etc.)
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1; // gap
    if (i == content.len) return false; // whitespace-only tail
    const label = try std.fmt.allocPrint(a, ": {s}", .{content[i..]});
    var hint = try std.json.ObjectMap.init(a, &.{}, &.{});
    var pos = try std.json.ObjectMap.init(a, &.{}, &.{});
    try pos.put(a, "line", .{ .integer = @intCast(line) });
    try pos.put(a, "character", .{ .integer = 0 });
    try hint.put(a, "position", .{ .object = pos });
    try hint.put(a, "label", .{ .string = label });
    try hints.append(.{ .object = hint });
    return true;
}

/// `inlay_range` script: answer textDocument/inlayHint with one echo hint
/// per line of the REQUESTED range, computed from the server's recorded
/// copy of the REQUESTED uri. Empty result for a never-opened document or
/// an unparsable request.
fn buildRangeInlayResult(a: std.mem.Allocator, state: *State, params: ?std.json.Value) !std.json.Value {
    var hints = std.json.Array.init(a);
    errdefer hints.deinit();
    const p = params orelse return .{ .array = hints };
    if (p != .object) return .{ .array = hints };
    const td = p.object.get("textDocument") orelse return .{ .array = hints };
    if (td != .object) return .{ .array = hints };
    const uri_v = td.object.get("uri") orelse return .{ .array = hints };
    if (uri_v != .string) return .{ .array = hints };
    const range = p.object.get("range") orelse return .{ .array = hints };
    if (range != .object) return .{ .array = hints };
    var start_line: u32 = 0;
    var end_line: u32 = 0;
    if (!posLineOf(range.object.get("start") orelse return .{ .array = hints }, &start_line)) return .{ .array = hints };
    if (!posLineOf(range.object.get("end") orelse return .{ .array = hints }, &end_line)) return .{ .array = hints };
    if (end_line <= start_line) return .{ .array = hints }; // empty range
    const text = recordedTextOf(state, uri_v.string) orelse return .{ .array = hints };
    var line: u32 = 0;
    var line_start: usize = 0;
    while (line < end_line and line_start <= text.len) : (line += 1) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        if (line >= start_line) {
            _ = try appendEchoHint(a, &hints, line, text[line_start..line_end]);
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return .{ .array = hints };
}

/// `inlay_eol` script: one hint per non-empty line of the requested range,
/// anchored at the line's TEXT end (excluding a trailing CR). Label ": eol".
/// Mirrors zls's variable-type hint position for a multiline declaration
/// whose name token ends the line (`const foo\n    = 1;`). The requested
/// range is always ASCII in the fixture, so UTF-16 vs byte columns coincide.
fn buildEolInlayResult(a: std.mem.Allocator, state: *State, params: ?std.json.Value) !std.json.Value {
    var hints = std.json.Array.init(a);
    errdefer hints.deinit();
    const p = params orelse return .{ .array = hints };
    if (p != .object) return .{ .array = hints };
    const td = p.object.get("textDocument") orelse return .{ .array = hints };
    if (td != .object) return .{ .array = hints };
    const uri_v = td.object.get("uri") orelse return .{ .array = hints };
    if (uri_v != .string) return .{ .array = hints };
    const range = p.object.get("range") orelse return .{ .array = hints };
    if (range != .object) return .{ .array = hints };
    var start_line: u32 = 0;
    var end_line: u32 = 0;
    if (!posLineOf(range.object.get("start") orelse return .{ .array = hints }, &start_line)) return .{ .array = hints };
    if (!posLineOf(range.object.get("end") orelse return .{ .array = hints }, &end_line)) return .{ .array = hints };
    if (end_line <= start_line) return .{ .array = hints };
    const text = recordedTextOf(state, uri_v.string) orelse return .{ .array = hints };
    var line: u32 = 0;
    var line_start: usize = 0;
    while (line < end_line and line_start <= text.len) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl orelse text.len;
        var content_end = line_end;
        if (content_end > line_start and text[content_end - 1] == '\r') content_end -= 1;
        if (line >= start_line and content_end > line_start) {
            var hint = try std.json.ObjectMap.init(a, &.{}, &.{});
            var pos = try std.json.ObjectMap.init(a, &.{}, &.{});
            try pos.put(a, "line", .{ .integer = @intCast(line) });
            try pos.put(a, "character", .{ .integer = @intCast(content_end - line_start) });
            try hint.put(a, "position", .{ .object = pos });
            try hint.put(a, "label", .{ .string = ": eol" });
            try hints.append(.{ .object = hint });
        }
        if (nl == null) break;
        line_start = line_end + 1;
    }
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

fn buildUnderlineDiagnostics(a: std.mem.Allocator, uri: []const u8) !std.json.Value {
    var params = try buildEmptyDiagnosticsParams(a, uri);
    const ds = &params.object.getPtr("diagnostics").?.array;
    const ranges = [_]struct { sl: i64, sc: i64, el: i64, ec: i64, severity: i64, message: []const u8 }{
        .{ .sl = 0, .sc = 6, .el = 0, .ec = 7, .severity = 2, .message = "CJK_WARNING" },
        .{ .sl = 0, .sc = 28, .el = 0, .ec = 35, .severity = 1, .message = "RANGE_ERROR" },
        .{ .sl = 1, .sc = 10, .el = 1, .ec = 17, .severity = 2, .message = "RANGE_WARNING" },
        .{ .sl = 2, .sc = 16, .el = 2, .ec = 17, .severity = 3, .message = "COMBINING_INFO" },
        .{ .sl = 2, .sc = 0, .el = 2, .ec = 1, .severity = 2, .message = "TAB_WARNING" },
        .{ .sl = 3, .sc = 10, .el = 5, .ec = 0, .severity = 3, .message = "MULTILINE_INFO" },
        .{ .sl = 3, .sc = 10, .el = 3, .ec = 14, .severity = 4, .message = "RANGE_HINT" },
        .{ .sl = 3, .sc = 17, .el = 3, .ec = 17, .severity = 1, .message = "POINT_ERROR" },
        .{ .sl = 6, .sc = 20, .el = 6, .ec = 110, .severity = 2, .message = "WRAPPED_WARNING" },
        .{ .sl = 7, .sc = 10, .el = 7, .ec = 14, .severity = 4, .message = "ISOLATED_HINT" },
    };
    for (ranges) |r| {
        const wrapper = try buildDiagnosticsParams(a, uri, r.message);
        var d = wrapper.object.get("diagnostics").?.array.items[0];
        try d.object.put(a, "severity", .{ .integer = r.severity });
        const range = d.object.getPtr("range").?;
        const start = &range.object.getPtr("start").?.object;
        const end = &range.object.getPtr("end").?.object;
        try start.put(a, "line", .{ .integer = r.sl });
        try start.put(a, "character", .{ .integer = r.sc });
        try end.put(a, "line", .{ .integer = r.el });
        try end.put(a, "character", .{ .integer = r.ec });
        try ds.append(d);
    }
    return params;
}

fn buildDetailedDiagnostics(a: std.mem.Allocator, uri: []const u8) !std.json.Value {
    var params = try buildDiagnosticsParams(a, uri, "WARNING_FIRST");
    const ds = &params.object.getPtr("diagnostics").?.array;
    try ds.items[0].object.put(a, "severity", .{ .integer = 2 });
    var message: std.ArrayList(u8) = .empty;
    try message.appendSlice(a, "unused function parameter\n");
    for (0..24) |i| try message.appendSlice(a, try std.fmt.allocPrint(a, "细节 {d}: 参数没有被使用，请移除参数或显式忽略它。\n", .{i}));
    try message.appendSlice(a, "DIAG_DETAIL_LAST");
    const second = try buildDiagnosticsParams(a, uri, try message.toOwnedSlice(a));
    try ds.append(second.object.get("diagnostics").?.array.items[0]);
    const third = try buildDiagnosticsParams(a, uri, "SPANNING_NOTE");
    var info = third.object.get("diagnostics").?.array.items[0];
    try info.object.put(a, "severity", .{ .integer = 3 });
    const range = info.object.getPtr("range").?;
    try range.object.getPtr("start").?.object.put(a, "line", .{ .integer = 1 });
    try range.object.getPtr("end").?.object.put(a, "line", .{ .integer = 3 });
    try range.object.getPtr("end").?.object.put(a, "character", .{ .integer = 0 });
    try ds.append(info);
    return params;
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

/// Byte offset in `text` of LSP position `pos` (line + UTF-16 character).
/// Clamps to the end of the line/document; null when the line does not exist.
fn byteOffsetAt(text: []const u8, pos: lsp_types.Position) ?usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null;
        i = nl + 1;
        line += 1;
    }
    var units: u32 = 0;
    while (units < pos.character) {
        if (i >= text.len or text[i] == '\n') break; // clamp to line end
        const b = text[i];
        const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
        units += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }
    return i;
}

/// Apply one incremental change {range, text} to `base` (the pre-change
/// document) and return the new full text (owned). A change whose range is
/// out of bounds is dropped (LSP clients must not send those, but a stray
/// fake range in a test should not corrupt the recorded document).
fn applyChange(alloc: std.mem.Allocator, base: []const u8, range: lsp_types.Range, text: []const u8) ![]u8 {
    const start = (byteOffsetAt(base, range.start) orelse return alloc.dupe(u8, base));
    const end = (byteOffsetAt(base, range.end) orelse return alloc.dupe(u8, base));
    if (start > end) return alloc.dupe(u8, base);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base[0..start]);
    try out.appendSlice(alloc, text);
    try out.appendSlice(alloc, base[end..]);
    return out.toOwnedSlice(alloc);
}

/// JSON numbers arrive as `.number_string` (raw text) through this codebase's
/// parser (see util/json_rpc.zig takeValue); tolerate plain `.integer` too.
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn recordDidChange(alloc: std.mem.Allocator, state: *State, params: ?std.json.Value) !void {
    const uri = extractUri(alloc, params) catch return;
    errdefer alloc.free(uri);
    // The pre-change document is the last recorded state for this uri (the
    // didOpen seed, or the previous didChange). Incremental changes splice
    // into it; range-less changes replace it wholesale (full-text sync).
    var base: []const u8 = "";
    var i = state.changed.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, state.changed.items[i].uri, uri)) {
            base = state.changed.items[i].text;
            break;
        }
    }
    var text: []const u8 = "";
    var range: ?lsp_types.Range = null;
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("contentChanges")) |cc| {
                if (cc == .array and cc.array.items.len > 0) {
                    const first = cc.array.items[0];
                    if (first == .object) {
                        if (first.object.get("text")) |t| {
                            if (t == .string) text = t.string;
                        }
                        if (first.object.get("range")) |r| {
                            if (r == .object) {
                                var rg: lsp_types.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
                                var got_start = false;
                                var got_end = false;
                                if (r.object.get("start")) |s| {
                                    if (s == .object) {
                                        if (s.object.get("line")) |ln| {
                                            if (s.object.get("character")) |ch| {
                                                const line = jsonInt(ln);
                                                const character = jsonInt(ch);
                                                if (line != null and character != null) {
                                                    rg.start = .{ .line = @intCast(line.?), .character = @intCast(character.?) };
                                                    got_start = true;
                                                }
                                            }
                                        }
                                    }
                                }
                                if (r.object.get("end")) |e| {
                                    if (e == .object) {
                                        if (e.object.get("line")) |ln| {
                                            if (e.object.get("character")) |ch| {
                                                const line = jsonInt(ln);
                                                const character = jsonInt(ch);
                                                if (line != null and character != null) {
                                                    rg.end = .{ .line = @intCast(line.?), .character = @intCast(character.?) };
                                                    got_end = true;
                                                }
                                            }
                                        }
                                    }
                                }
                                if (got_start and got_end) range = rg;
                            }
                        }
                    }
                }
            }
        }
    }
    const text_copy = if (range) |rg|
        try applyChange(alloc, base, rg, text)
    else
        try alloc.dupe(u8, text);
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
        \\  inlay_eol  one ": eol" type hint at each requested line's TEXT end
        \\           (zls multiline-declaration shape); only the first request
        \\           is answered, modelling a slow server.
        \\  rich    hover/completion fixture for popup geometry: markdown
        \\           heading + arrow + fenced code + CJK hover; completion
        \\           items with detail/docs and a wide label.
        \\  edit_safety  formatting waits for another didOpen; rename edits
        \\           b.zig then the requesting URI through changes.
        \\  edit_safety_documents  same rename through documentChanges.
        \\  edit_safety_alias  rename real b.zig, hover its opened symlink URI.
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

fn writeBarrier(io: anytype, dir: []const u8, name: []const u8) void {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, "1") catch {};
}

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
    if (script == .signature_lifecycle) {
        if (init.environ_map.get("OZ_SIG_MODE")) |mode| {
            if (std.mem.eql(u8, mode, "null")) state.signature_mode = .null_result else if (std.mem.eql(u8, mode, "error")) state.signature_mode = .error_result else if (std.mem.eql(u8, mode, "ignore")) state.signature_mode = .ignore else if (std.mem.eql(u8, mode, "timeout")) state.signature_mode = .timeout;
        }
    }
    if (init.environ_map.get("OZ_HOVER_FORCE_PLAINTEXT")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) state.hover_force_plaintext = true;
    }
    const barrier_dir = init.environ_map.get("OZ_SIG_BARRIER_DIR");
    var seen_requests: u32 = 0;
    var seen_responses: u32 = 0;

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
        if (script == .signature_lifecycle) {
            if (state.signature_requests != seen_requests) {
                seen_requests = state.signature_requests;
                if (barrier_dir) |dir| {
                    var name_buf: [64]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "request-{d}", .{seen_requests}) catch "";
                    if (name.len > 0) writeBarrier(io, dir, name);
                }
            }
        }
        for (outcome.frames.items) |frame| {
            writeFrameToFile(stdout, io, frame) catch |e| {
                logVerbose(io, verbose, "mock_lsp: stdout write failed: {s}\n", .{@errorName(e)});
                running = false;
                break;
            };
            logVerbose(io, verbose, "mock_lsp: sent frame ({d} bytes)\n", .{frame.len});
        }
        outcome.deinit(gpa); // frees every frame (no per-frame free above)
        if (script == .signature_lifecycle and state.signature_responses != seen_responses) {
            seen_responses = state.signature_responses;
            if (barrier_dir) |dir| {
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "response-{d}", .{seen_responses}) catch "";
                if (name.len > 0) writeBarrier(io, dir, name);
            }
        }

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

fn buildSignatureLabel(a: std.mem.Allocator, label: []const u8) !std.json.Value {
    var sig = try std.json.ObjectMap.init(a, &.{}, &.{});
    try sig.put(a, "label", .{ .string = label });
    var sigs = std.json.Array.init(a);
    try sigs.append(.{ .object = sig });
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "signatures", .{ .array = sigs });
    return .{ .object = result };
}

fn buildLifecycleCompletionResult(a: std.mem.Allocator) !std.json.Value {
    const specs = [_]struct { label: []const u8, detail: []const u8, doc: []const u8, kind: i64 }{
        .{ .label = "stat", .detail = "fn stat() void", .doc = "STAT_DOC", .kind = 3 },
        .{ .label = "close", .detail = "fn close() void", .doc = "CLOSE_DOC", .kind = 3 },
        .{ .label = "sync", .detail = "fn sync() void", .doc = "SYNC_DOC", .kind = 3 },
        .{ .label = "isTty", .detail = "fn isTty() bool", .doc = "ISTTY_DOC", .kind = 3 },
    };
    var items = std.json.Array.init(a);
    for (specs) |spec| {
        try items.append(try richCompletionItem(a, spec.label, spec.kind, null, null, null, spec.detail, "markdown", spec.doc));
    }
    var result = try std.json.ObjectMap.init(a, &.{}, &.{});
    try result.put(a, "items", .{ .array = items });
    return .{ .object = result };
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
    try testing.expect(Script.parse("edit_safety") == .edit_safety);
    try testing.expect(Script.parse("edit_safety_documents") == .edit_safety_documents);
    try testing.expect(Script.parse("edit_safety_alias") == .edit_safety_alias);
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
    try testing.expectEqualStrings("**mock hover**\n`second line`\n```zig\nconst b = 2;\n```\nhttp://example.com third line", contents.object.get("value").?.string);
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

test "didChange: incremental range edits are applied to the recorded document" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":1,\"text\":\"const a = 1;\\n\"}}}";
    var out_open = try handleContent(alloc, .hello, &state, open);
    defer out_open.deinit(alloc);

    // insert "X" at line 0 col 0 (the per-keystroke didChange the client sends)
    const ins = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":2},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"text\":\"X\"}]}}";
    var out_ins = try handleContent(alloc, .hello, &state, ins);
    defer out_ins.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), state.changed.items.len);
    try testing.expectEqualStrings("Xconst a = 1;\n", state.changed.items[1].text);

    // delete "X" again: [0,1) → "" (jk-exit removal style)
    const del = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":3},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"text\":\"\"}]}}";
    var out_del = try handleContent(alloc, .hello, &state, del);
    defer out_del.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), state.changed.items.len);
    try testing.expectEqualStrings("const a = 1;\n", state.changed.items[2].text);

    // multi-line edit: replace "a = 1" (col 6..11 on line 0) with "b = 2"
    const rep = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":4},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}},\"text\":\"b = 2\"}]}}";
    var out_rep = try handleContent(alloc, .hello, &state, rep);
    defer out_rep.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), state.changed.items.len);
    try testing.expectEqualStrings("const b = 2;\n", state.changed.items[3].text);
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

test "inlay_eol: hints anchor at the line text end; only the first request answers" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///e.zig\",\"version\":1,\"text\":\"const foo\\n    = 1;\\r\\n\"}}}";
    var out_open = try handleContent(alloc, .inlay_eol, &state, open);
    defer out_open.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), out_open.frames.items.len);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///e.zig\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":2,\"character\":0}}}}";
    var out = try handleContent(alloc, .inlay_eol, &state, req);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), out.frames.items.len);
    var resp = try json_rpc.parseMessage(alloc, out.frames.items[0]);
    defer resp.deinit(alloc);
    const hints = resp.result.?.array;
    try testing.expectEqual(@as(usize, 2), hints.items.len);
    // line 0: "const foo" ends at byte 9; line 1: "    = 1;\r" -> text end 8
    const pos0 = hints.items[0].object.get("position").?.object;
    const pos1 = hints.items[1].object.get("position").?.object;
    try testing.expectEqualStrings("9", pos0.get("character").?.number_string);
    try testing.expectEqualStrings("8", pos1.get("character").?.number_string);
    try testing.expectEqualStrings(": eol", hints.items[0].object.get("label").?.string);

    // Slow server: a second request gets no response at all, so the editor
    // cannot repair a shifted hint from a fresh document.
    var out2 = try handleContent(alloc, .inlay_eol, &state, req);
    defer out2.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), out2.frames.items.len);
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

test "edit safety fixture: formatting responds only after another document opens" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const open_a = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"text\":\"aaa\\n\"}}}";
    var opened = try handleContent(alloc, .edit_safety, &state, open_a);
    defer opened.deinit(alloc);
    var requested = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\"}}}");
    defer requested.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), requested.frames.items.len);
    try testing.expect(state.pending_format != null);
    var same = try handleContent(alloc, .edit_safety, &state, open_a);
    defer same.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), same.frames.items.len);
    var switched = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///b.zig\",\"text\":\"bbb\\n\"}}}");
    defer switched.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), switched.frames.items.len);
    try testing.expect(state.pending_format == null);
    var response = try json_rpc.parseMessage(alloc, switched.frames.items[0]);
    defer response.deinit(alloc);
    try testing.expectEqual(@as(?u64, 7), response.id);
    try testing.expectEqualStrings("FORMATTED_A", response.result.?.array.items[0].object.get("newText").?.string);
}

test "edit safety fixture: both rename encodings put two URI targets in B A order" {
    const alloc = testing.allocator;
    for ([_]Script{ .edit_safety, .edit_safety_documents }) |script| {
        var state = State{};
        defer state.deinit(alloc);
        var out = try handleContent(alloc, script, &state, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/a.zig\"},\"newName\":\"renamed\"}}");
        defer out.deinit(alloc);
        var response = try json_rpc.parseMessage(alloc, out.frames.items[0]);
        defer response.deinit(alloc);
        const result = response.result.?.object;
        const uris = [_][]const u8{ "file:///fixture/b.zig", "file:///fixture/a.zig" };
        const replacements = [_][]const u8{ "RENAMED_B", "RENAMED_A" };
        if (script == .edit_safety) {
            const changes = result.get("changes").?.object;
            try testing.expectEqual(@as(usize, 2), changes.count());
            for (uris, replacements, 0..) |uri, replacement, i| {
                try testing.expectEqualStrings(uri, changes.keys()[i]);
                try testing.expectEqualStrings(replacement, changes.values()[i].array.items[0].object.get("newText").?.string);
            }
        } else {
            const docs = result.get("documentChanges").?.array.items;
            try testing.expectEqual(@as(usize, 2), docs.len);
            for (uris, replacements, docs) |uri, replacement, doc| {
                const td = doc.object.get("textDocument").?.object;
                try testing.expectEqualStrings(uri, td.get("uri").?.string);
                try testing.expect(td.get("version").? == .null);
                try testing.expectEqualStrings(replacement, doc.object.get("edits").?.array.items[0].object.get("newText").?.string);
            }
        }
    }
}

test "edit safety fixture: hover from A observes hidden B only after didChange" {
    const alloc = testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    var open_a = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/a.zig\",\"text\":\"aaa\\n\"}}}");
    defer open_a.deinit(alloc);
    var open_b = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/b.zig\",\"text\":\"bbb\\n\"}}}");
    defer open_b.deinit(alloc);
    var rename = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/a.zig\"},\"newName\":\"renamed\"}}");
    defer rename.deinit(alloc);
    const hover = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/a.zig\"},\"position\":{\"line\":0,\"character\":1}}}";
    var stale = try handleContent(alloc, .edit_safety, &state, hover);
    defer stale.deinit(alloc);
    var stale_response = try json_rpc.parseMessage(alloc, stale.frames.items[0]);
    defer stale_response.deinit(alloc);
    try testing.expectEqualStrings("server b.zig: bbb", stale_response.result.?.object.get("contents").?.object.get("value").?.string);
    var changed = try handleContent(alloc, .edit_safety, &state, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///fixture/b.zig\",\"version\":2},\"contentChanges\":[{\"text\":\"RENAMED_B\\n\"}]}}");
    defer changed.deinit(alloc);
    var fresh = try handleContent(alloc, .edit_safety, &state, hover);
    defer fresh.deinit(alloc);
    var fresh_response = try json_rpc.parseMessage(alloc, fresh.frames.items[0]);
    defer fresh_response.deinit(alloc);
    try testing.expectEqualStrings("server b.zig: RENAMED_B", fresh_response.result.?.object.get("contents").?.object.get("value").?.string);
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
    try testing.expectEqualStrings("**mock hover**\n`second line`\n```zig\nconst b = 2;\n```\nhttp://example.com third line", contents.object.get("value").?.string);
}

test "hover_cap: initialize capability decides markdown vs plaintext payload" {
    const alloc = testing.allocator;
    const cases = [_]struct { init_params: []const u8, want_markdown: bool }{
        .{
            .init_params = "{\"capabilities\":{\"textDocument\":{\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]}}}}",
            .want_markdown = true,
        },
        // Missing hover capability (the pre-fix oz initialize params):
        // plaintext, no fenced block.
        .{ .init_params = "{\"capabilities\":{}}", .want_markdown = false },
        // Unknown format only: still plaintext.
        .{ .init_params = "{\"capabilities\":{\"textDocument\":{\"hover\":{\"contentFormat\":[\"html\"]}}}}", .want_markdown = false },
    };
    for (cases, 0..) |case, i| {
        var state = State{};
        defer state.deinit(alloc);
        const init_json = try std.fmt.allocPrint(
            alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{s}}}",
            .{case.init_params},
        );
        defer alloc.free(init_json);
        var init = try handleContent(alloc, .hover_cap, &state, init_json);
        defer init.deinit(alloc);
        try testing.expectEqual(case.want_markdown, state.hover_markdown_cap);

        var hover = try handleContent(alloc, .hover_cap, &state, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\"},\"position\":{\"line\":0,\"character\":1}}}");
        defer hover.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), hover.frames.items.len);
        var msg = try json_rpc.parseMessage(alloc, hover.frames.items[0]);
        defer msg.deinit(alloc);
        const contents = msg.result.?.object.get("contents").?.object;
        const want_kind = if (case.want_markdown) "markdown" else "plaintext";
        try testing.expectEqualStrings(want_kind, contents.get("kind").?.string);
        const value = contents.get("value").?.string;
        try testing.expectEqual(case.want_markdown, std.mem.indexOf(u8, value, "```zig") != null);
        try testing.expect(std.mem.indexOf(u8, value, "hover_sentinel: usize = 99") != null);
        if (i == 0) {
            try testing.expect(std.mem.indexOf(u8, value, "```") != null);
        }
    }
}
