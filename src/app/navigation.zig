//! navigation — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const NavAction = app_mod.NavAction;

// ---- LSP navigation (K / gd / gD / gr / gI / gs) ----

/// Send a textDocument request for the cursor position. The response
/// lands in `nav_slot`; `processNav` (called every frame after drain)
/// consumes it. No-op when the client is absent.
pub fn requestNav(self: *App, method: []const u8, action: NavAction) !void {
    const client = self.lsp_client orelse {
        return;
    };
    if (self.nav_slot != null) {
        return;
    }
    // A new navigation request replaces any stale overlay (hover window,
    // location list) from a previous request. Concurrent requests share
    // nav_slot; the client's drain frees a stale slot value on overwrite.
    self.clearNavOverlays();
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
    client.request(method, params, &self.nav_slot) catch return;
    self.nav_action = action;
}

/// Consume a completed navigation response (called after drain each
/// frame). Frees the slot either way. Returns true when a response was
/// consumed (caller renders immediately — the event loop may otherwise
/// block in pollEvent before the new hover/list can be drawn).
pub fn processNav(self: *App) bool {
    var result = self.nav_slot orelse return false;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.nav_slot = null;
        self.nav_action = .none;
    }
    switch (self.nav_action) {
        .hover, .signature => {
            const text = if (self.nav_action == .hover)
                lsp_nav.parseHoverText(self.alloc, result) catch null
            else
                lsp_nav.parseSignature(self.alloc, result) catch null;
            if (self.nav_hover_text) |t| self.alloc.free(t);
            self.nav_hover_text = text;
        },
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

/// Drop only the hover/signature floating window — used when the cursor
/// moves (nvim hides the hover window as soon as the cursor leaves the
/// annotated token).
pub fn clearHover(self: *App) void {
    if (self.nav_hover_text) |t| self.alloc.free(t);
    self.nav_hover_text = null;
}

/// Move to a nav location: jump within the current buffer, or open the
/// file (new buffer) when the URI points elsewhere. Lands on the exact
/// definition column (clamped to the line length), like nvim's gd —
/// not the line start.
pub fn jumpToLocation(self: *App, loc: lsp_nav.NavLocation) void {
    const path = lsp_types.fileUriToPath(self.alloc, loc.uri) catch {
        // URI unparseable: fall back to a clamped position in the
        // current buffer
        const pt = &self.cur().pt;
        const line = @min(loc.line, pt.lineCount() -| 1);
        self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineLen(line));
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
    self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineLen(line));
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
