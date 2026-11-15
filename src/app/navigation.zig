//! navigation — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const NavAction = app_mod.NavAction;
const term = @import("../term.zig");

// ---- LSP navigation (K / gd / gD / gr / gI / gs) ----

/// Current identity of the passive-hint context. The epoch is part of the
/// identity, so a response captured before any invalidation can never match
/// the current context even if the cursor/mode later return to the same
/// values.
pub fn passiveContext(self: *App) app_mod.PassiveNavContext {
    const path = self.cur().path;
    return .{
        .epoch = self.passive_epoch,
        .buffer_hash = if (path) |p| std.hash.Wyhash.hash(0, p) else 0,
        .has_path = path != null,
        .window = self.current_win,
        .cursor = self.curCursor().*,
        .edit_seq = self.edit_seq,
        .insert_session = self.insert_session,
        .mode = @backingInt(self.state.mode),
        .focus = @backingInt(self.focus),
        .ai_focus = @backingInt(self.ai.focus),
        .agent_focus = self.ai.agent_focus,
        .terminal_focus = if (term.supported)
            (self.term_pane != null and self.term_pane.?.focused)
        else
            false,
    };
}

/// Convert every focus transition (keyboard, mouse, terminal, AI rail) into
/// the same invalidation. Observe each event boundary before later events
/// can create a request in the new focus. Request creation and rendering
/// also synchronize as safeguards for non-event callers.
pub fn syncPassiveFocus(self: *App) void {
    const now: app_mod.PassiveFocus = .{
        .focus = @backingInt(self.focus),
        .ai_focus = @backingInt(self.ai.focus),
        .agent_focus = self.ai.agent_focus,
        .terminal_focus = if (term.supported)
            (self.term_pane != null and self.term_pane.?.focused)
        else
            false,
    };
    if (self.passive_focus_seen) |prev| {
        if (prev.focus != now.focus or prev.ai_focus != now.ai_focus or
            prev.agent_focus != now.agent_focus or prev.terminal_focus != now.terminal_focus)
        {
            self.invalidatePassiveHints();
            // A completion list requested under the old focus must never
            // reopen after a mouse/keyboard focus switch.
            self.invalidateCompletionContext();
        }
    }
    self.passive_focus_seen = now;
}

/// End the old passive context: free displayed content and make any
/// in-flight/complete response uninstallable. This is the single primitive
/// used by edits, cursor movement, insert-session boundaries, buffer/window
/// focus changes, completion display, and explicit navigation.
pub fn invalidatePassiveHints(self: *App) void {
    self.passive_epoch +%= 1;
    self.passive_ctx = null;
    self.passive_action = .none;
    self.nav_hover_ctx = null;
    if (self.passive_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.passive_slot = null;
    if (self.nav_hover_text) |t| self.alloc.free(t);
    self.nav_hover_text = null;
    self.nav_hover_markdown = false;
}

/// Renderer-side final defence: the displayed text is tied to the context
/// that produced it. A mismatch hides it; normal paths also free it via
/// `invalidatePassiveHints`.
pub fn navHoverAlive(self: *App) bool {
    const ctx = self.nav_hover_ctx orelse return false;
    return ctx.matches(self.passiveContext());
}

/// Send a textDocument request for the cursor position. Hover/signature use
/// the dedicated passive slot; definition/reference lists keep `nav_slot`
/// and are never invalidated by a floating-hint lifetime change.
pub fn requestNav(self: *App, method: []const u8, action: NavAction) !void {
    const client = self.lsp_client orelse return;
    const passive = action == .hover or action == .signature;
    if (!passive and self.nav_slot != null) return;
    // Completion owns the popup space and has its own signature/docs. A
    // signature requested while that menu is open (ZLS lists '(' as a
    // completion trigger) must not become a second independent float over
    // the menu. The completion state was already invalidated when it opened.
    if (passive and self.completion_active) return;

    // A single action can focus the editor and request a hint. Record that
    // transition before capturing the new request, so the event/render
    // guards cannot later mistake this request for the old focus's hint.
    if (passive) self.syncPassiveFocus();

    // A new float request always ends the old float/list context. For a
    // passive request this also replaces an in-flight same-slot request
    // (the client drops its pending id and best-effort cancels it).
    self.clearNavOverlays();
    if (passive) self.invalidatePassiveHints();

    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    const line = self.cur().pt.lineOf(self.curCursor().*);
    const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
    // references needs ReferenceParams (mandatory `context`) — a bare
    // position params is a ParseError for strict servers (zls exits!)
    var params = if (action == .references)
        lsp_nav.buildReferencesParams(self.alloc, uri, line, col) catch return
    else
        lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
    defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
    if (passive) {
        client.request(method, params, &self.passive_slot) catch return;
        // Capture the FINAL context after auto-pair/insert completed; this
        // is what makes a new '(' survive the invalidation caused by its
        // own text insertion.
        self.passive_ctx = self.passiveContext();
        self.passive_action = action;
        self.passive_request_serial +%= 1;
    } else {
        client.request(method, params, &self.nav_slot) catch return;
        self.nav_action = action;
    }
}

/// Consume a completed passive response. Validation happens before parsing:
/// a response from an older epoch/context is freed and never installed.
pub fn processPassiveNav(self: *App) bool {
    var result = self.passive_slot orelse return false;
    const ctx = self.passive_ctx;
    const action = self.passive_action;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.passive_slot = null;
        self.passive_ctx = null;
        self.passive_action = .none;
    }
    const captured = ctx orelse return true;
    if (!captured.matches(self.passiveContext())) return true;
    switch (action) {
        .hover => {
            // Hover keeps the server's markup kind: Markdown (fenced code,
            // headings) takes the rich popup renderer, plaintext stays
            // literal — never the other way round.
            const hover: ?lsp_nav.HoverContent = lsp_nav.parseHover(self.alloc, result) catch null;
            if (self.nav_hover_text) |t| self.alloc.free(t);
            self.nav_hover_text = null;
            self.nav_hover_markdown = false;
            if (hover) |h| {
                self.nav_hover_text = h.text;
                self.nav_hover_markdown = h.kind == .markdown;
            }
            const text = self.nav_hover_text;
            self.nav_hover_ctx = if (text != null and text.?.len > 0) captured else null;
        },
        .signature => {
            const text = lsp_nav.parseSignature(self.alloc, result) catch null;
            if (self.nav_hover_text) |t| self.alloc.free(t);
            self.nav_hover_text = text;
            self.nav_hover_markdown = false;
            self.nav_hover_ctx = if (text != null and text.?.len > 0) captured else null;
        },
        else => {},
    }
    return true;
}

/// Consume a completed explicit navigation response (called after drain
/// each frame). Frees the slot either way. Returns true when a response was
/// consumed (caller renders immediately — the event loop may otherwise
/// block in pollEvent before the new list/jump can be drawn).
pub fn processNav(self: *App) bool {
    var result = self.nav_slot orelse return false;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.nav_slot = null;
        self.nav_action = .none;
    }
    switch (self.nav_action) {
        .hover, .signature => {},
        .definition, .declaration => {
            self.clearNavOverlays();
            var locs = std.ArrayList(lsp_nav.NavLocation).empty;
            defer {
                for (locs.items) |*l| self.alloc.free(l.uri);
                locs.deinit(self.alloc);
            }
            lsp_nav.parseLocations(self.alloc, result, &locs) catch {};
            if (locs.items.len > 0) self.jumpToLocation(locs.items[0]);
        },
        .references, .implementation => {
            self.clearNavOverlays();
            for (self.nav_locations.items) |*l| self.alloc.free(l.uri);
            self.nav_locations.clearRetainingCapacity();
            lsp_nav.parseLocations(self.alloc, result, &self.nav_locations) catch {};
            self.nav_list_sel = 0;
            self.nav_loc_top = 0;
            self.nav_list_active = self.nav_locations.items.len > 0;
            self.nav_list_title = if (self.nav_action == .implementation) " Implementations " else " References ";
            self.refreshNavPreview();
        },
        .none => {},
    }
    return true;
}

/// Drop the hover window and location-list overlay (used when starting a
/// new navigation request or jumping).
pub fn clearNavOverlays(self: *App) void {
    self.clearHover();
    self.nav_list_active = false;
}

/// Drop the passive hover/signature window and invalidate its pending
/// response. `diag_float_active` is an explicit diagnostic overlay, not a
/// passive hint; movement closes it for the historical `clearHover`
/// behavior, but passive invalidation alone does not.
pub fn clearHover(self: *App) void {
    self.diag_float_active = false;
    self.invalidatePassiveHints();
}

/// Move to a nav location: jump within the current buffer, or open the
/// file (new buffer) when the URI points elsewhere. Lands on the exact
/// definition column (clamped to the line length), like nvim's gd —
/// not the line start.
pub fn jumpToLocation(self: *App, loc: lsp_nav.NavLocation) void {
    self.invalidatePassiveHints();
    const path = lsp_types.fileUriToPath(self.alloc, loc.uri) catch {
        // URI unparseable: fall back to a clamped position in the
        // current buffer
        const pt = &self.cur().pt;
        const line = @min(loc.line, pt.lineCount() -| 1);
        self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineTextLen(line));
        return;
    };
    defer self.alloc.free(path);
    const current = self.cur().path;
    if (current == null or !std.mem.eql(u8, current.?, path)) {
        // switching buffers: the target must be computed on the NEW
        // buffer, whose lengths differ (a stale offset from the old
        // buffer could exceed it and crash the next render)
        self.openInBuffer(path) catch return;
    }
    const pt = &self.cur().pt;
    const line = @min(loc.line, pt.lineCount() -| 1);
    self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineTextLen(line));
}

/// Keys while the gr/gI location list is open. Returns true when consumed.
pub fn navListKey(self: *App, key: vaxis.Key) bool {
    switch (key.codepoint) {
        vaxis.Key.escape => {
            self.nav_list_active = false;
            self.freeGrepPreview();
            return true;
        },
        'j', vaxis.Key.down => {
            if (self.nav_list_sel + 1 < self.nav_locations.items.len) {
                self.nav_list_sel += 1;
                self.refreshNavPreview();
            }
            return true;
        },
        'k', vaxis.Key.up => {
            if (self.nav_list_sel > 0) {
                self.nav_list_sel -= 1;
                self.refreshNavPreview();
            }
            return true;
        },
        vaxis.Key.enter => {
            if (self.nav_list_sel < self.nav_locations.items.len) {
                const loc = self.nav_locations.items[self.nav_list_sel];
                self.jumpToLocation(loc);
                self.nav_list_active = false;
                self.freeGrepPreview();
            }
            return true;
        },
        else => return false,
    }
}
