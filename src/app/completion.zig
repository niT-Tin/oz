//! completion — App method group split out of src/main.zig (physical move).

const std = @import("std");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const json_rpc = @import("../util/json_rpc.zig");
const theme = @import("../theme.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- insert-mode keyword completion (Ctrl+n) ----

/// Word characters for keyword completion: [a-zA-Z0-9_] plus any
/// non-ASCII byte (mirrors editor/multicursor.zig's classification).
pub fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80;
}

/// Case-insensitive substring match (completion filtering — loose, like
/// blink's fuzzy matching).
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Nerd Font glyph for an LSP CompletionItemKind (1-25); " " for unknown.
/// Mirrors the user's nvim icons (AstroNvim style) so the completion menu
/// looks like blink.cmp.
pub fn kindGlyph(kind: u8) []const u8 {
    return switch (kind) {
        2, 3, 4 => "", // Method / Function / Constructor
        5, 10, 20 => "", // Field / Property / EnumMember
        6 => "", // Variable
        7 => "", // Class
        8 => "", // Interface
        9, 19 => "", // Module / Folder
        11 => "", // Unit
        12, 1, 18 => "", // Value / Text / Reference
        13 => "", // Enum
        14 => "", // Keyword
        15 => "", // Snippet
        16 => "", // Color
        17 => "", // File
        21 => "", // Constant
        22 => "", // Struct
        23 => "", // Event
        24 => "", // Operator
        25 => "", // TypeParameter
        else => " ",
    };
}

/// Category color for a completion kind. Kept separate from the label row
/// color so the selected row never paints every icon the same; unknown kinds
/// get the neutral muted role (never a fabricated type color).
pub fn kindColor(t: theme.Theme, kind: u8) theme.Rgb {
    return switch (kind) {
        2, 3, 4 => t.function, // Method / Function / Constructor
        7, 8, 13, 22, 25 => t.type, // Class / Interface / Enum / Struct / TypeParameter
        5, 10, 20 => t.property, // Field / Property / EnumMember
        6, 12, 18 => t.variable, // Variable / Value / Reference
        9, 19 => t.namespace, // Module / Folder
        21 => t.constant,
        14, 15 => t.keyword, // Keyword / Snippet
        16 => t.number, // Color
        17 => t.type, // File
        23 => t.diag_warn, // Event
        24 => t.operator,
        else => t.fg_dim,
    };
}

/// Ctrl+n in insert mode with the cursor inside a word: collect keyword
/// candidates from the whole buffer and open the completion menu. Without
/// a word prefix the key is swallowed (no candidates, no side effect).
pub fn startCompletion(self: *App) !void {
    if (self.completion_active) return;
    if (self.curCursor().* == 0) return;
    if (!isWordByte(self.cur().pt.byteAt(self.curCursor().* - 1))) return;
    // LSP completion first: ask the language server for candidates at the
    // cursor; the response lands in completion_slot and processCompletion
    // opens the menu. Without a client we fall back to buffer words.
    if (self.lsp_client) |c| {
        self.completion_manual = true;
        self.completion_waiting_enter = true;
        try self.requestLspCompletion(c, false);
        return;
    }
    try self.collectCompletionWords(false);
    if (self.completion_words.items.len > 0) {
        self.invalidatePassiveHints();
        self.completion_active = true;
    }
}

/// Send a textDocument/completion request at the cursor (the menu opens
/// when the response lands in processCompletion). Shared by Ctrl+n and
/// the insert-mode auto-suggest. `no_prefix` is true after a trigger
/// character ("b."): there is no word prefix — completion_pos is the
/// cursor and accept inserts at it (the server resolves members etc.).
pub fn requestLspCompletion(self: *App, c: anytype, no_prefix: bool) !void {
    // remember the start of the word being typed so acceptCompletion
    // replaces just [completion_pos, cursor) with the chosen item
    var pos = self.curCursor().*;
    if (!no_prefix) {
        while (pos > 0 and isWordByte(self.cur().pt.byteAt(pos - 1))) pos -= 1;
        if (pos == self.curCursor().*) return;
    }
    self.completion_pos = pos;
    // A request issued while no menu is open belongs to a fresh session;
    // resolve results from a previous menu must never revive it.
    if (!self.completion_active and self.completion_slot == null) self.completion_session +%= 1;
    self.completion_req_buf = self.current;
    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    const line = self.cur().pt.lineOf(self.curCursor().*);
    const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
    var params = lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
    defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
    c.request("textDocument/completion", params, &self.completion_slot) catch return;
    self.completion_req_seq = self.edit_seq;
}

/// True when the just-typed `text` is one of the server's completion
/// trigger characters (e.g. "." after "b" → "b." member access), or the
/// tail of a multi-char trigger ("-" + ">" → "->"). No LSP → false.
pub fn isCompletionTriggerText(self: *App, text: []const u8) bool {
    const c = self.lsp_client orelse return false;
    if (c.isCompletionTrigger(text)) return true;
    if (text.len == 1 and self.curCursor().* >= 2) {
        var two: [2]u8 = undefined;
        self.cur().pt.copyRange(self.curCursor().* - 2, two[0..2]);
        if (c.isCompletionTrigger(two[0..2])) return true;
    }
    return false;
}

/// Insert-mode auto-suggest: after typing a word character or a trigger
/// character (".", "::", …), ask the LSP for candidates at the cursor
/// (the response opens/updates the menu; stale responses are discarded in
/// processCompletion). Without an LSP, buffer-word completion is triggered
/// only for word prefixes on small documents — a full-buffer scan per
/// keystroke on a huge file would jitter.
pub fn maybeAutoComplete(self: *App, text: []const u8) !void {
    if (self.curCursor().* == 0) return;
    self.completion_manual = false; // auto-suggest: silent on empty
    const trigger = !isWordByte(text[0]) and self.isCompletionTriggerText(text);
    if (self.lsp_client) |c| {
        if (trigger) {
            // no word prefix: the server resolves the trigger context
            self.completion_pos = self.curCursor().*;
            try self.requestLspCompletion(c, true);
            return;
        }
        if (!isWordByte(self.cur().pt.byteAt(self.curCursor().* - 1))) return;
        try self.requestLspCompletion(c, false);
        return;
    }
    if (trigger) return; // buffer words need a prefix
    if (self.cur().pt.len() > 16 * 1024) return;
    const was_active = self.completion_active;
    try self.collectCompletionWords(was_active);
    if (self.completion_words.items.len > 0) {
        self.invalidatePassiveHints();
        self.completion_active = true;
    }
}

/// Consume a completed LSP completion response (called after drain each
/// frame): fill completion_words and open the menu. Returns true when a
/// response was consumed (caller renders immediately).
pub fn processCompletion(self: *App) bool {
    var result = self.completion_slot orelse return false;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.completion_slot = null;
    }
    // Stale: the text changed after the request (fast typing) or the
    // user left insert mode (e.g. Esc before the response landed). Keep
    // the current items — the next keystroke sends a fresh request.
    // The manual request's response is still consumed, so Enter must be
    // unblocked (otherwise it would stay stuck on "completion pending…"
    // forever with no menu to open).
    if (self.edit_seq != self.completion_req_seq or self.state.mode != .insert or
        self.completion_req_buf != self.current)
    {
        self.completion_waiting_enter = false;
        return true;
    }
    // Preserve the SELECTED ITEM, not its old index: a refresh may reorder
    // the list, and keeping the index silently swaps the documentation.
    const prev_id: ?u64 = if (self.completion_sel < self.completion_words.items.len)
        self.completion_words.items[self.completion_sel].item_id
    else
        null;
    const prev_key: ?u64 = if (self.completion_sel < self.completion_words.items.len)
        self.completion_words.items[self.completion_sel].selection_key
    else
        null;
    for (self.completion_words.items) |*it| it.deinit(self.alloc);
    self.completion_words.clearRetainingCapacity();
    self.completion_generation +%= 1;
    lsp_nav.parseCompletionItems(self.alloc, result, &self.completion_words) catch {};
    // Client-side filter: servers like zls return the FULL candidate set
    // and leave matching to the client (blink/nvim do the same via
    // filterText/label). Substring match, case-insensitive — loose like
    // fuzzy matching; without this the menu would show the same
    // unfiltered list no matter what you type.
    if (self.completion_words.items.len > 0 and self.completion_pos < self.curCursor().*) {
        const typed_len = self.curCursor().* - self.completion_pos;
        var typed_buf: [256]u8 = undefined;
        if (typed_len <= 256) {
            self.cur().pt.copyRange(self.completion_pos, typed_buf[0..typed_len]);
            const typed = typed_buf[0..typed_len];
            var write: usize = 0;
            for (self.completion_words.items) |*it| {
                if (containsIgnoreCase(it.filterText(), typed)) {
                    self.completion_words.items[write] = it.*;
                    write += 1;
                } else {
                    it.deinit(self.alloc);
                }
            }
            self.completion_words.shrinkRetainingCapacity(write);
        }
    }
    if (self.completion_words.items.len > 0) {
        self.invalidatePassiveHints();
        self.completion_active = true;
        var next_sel: usize = 0;
        var same_selection = false;
        if (prev_id) |want| {
            if (lsp_nav.completionSelection(self.completion_words.items, want, prev_key.?)) |i| {
                next_sel = i;
                same_selection = true;
            }
        }
        const selection_changed = !same_selection;
        self.completion_sel = next_sel;
        if (selection_changed) {
            self.completion_doc_scroll = 0;
        }
        // Fresh items do not own the previous array's resolved fields. Check
        // the selected object after EVERY refresh, even at the same index.
        self.maybeResolveCompletion();
    } else {
        // nothing matches the typed prefix: keep typing clean. A manual
        // Ctrl+n with zero matches gets a status hint — otherwise the
        // user can't tell the accept never happened and Enter quietly
        // inserts a newline (the classic "cursor is not after the
        // semicolon" confusion).
        self.completion_active = false;
        self.completion_sel = 0;
        if (self.completion_manual) {
            self.setMsg(self.alloc.dupe(u8, "no candidates") catch return true) catch {};
        }
    }
    // the manual request's response has been consumed: Enter is free
    // again (accept if the menu opened, newline otherwise)
    self.completion_waiting_enter = false;
    return true;
}

/// True when the selected candidate still lacks information that a server
/// may provide through completionItem/resolve.
fn needsResolve(item: *const lsp_nav.CompletionItem) bool {
    return item.doc == null;
}

/// Ask the server for the selected item's details/docs. Called on selection
/// changes and list refreshes; existing initial documentation is used as-is
/// (no pointless resolve request). The request is tagged with the session and
/// item identity so a late answer cannot attach to another candidate.
pub fn maybeResolveCompletion(self: *App) void {
    if (!self.completion_active) return;
    if (self.completion_sel >= self.completion_words.items.len) return;
    const c = self.lsp_client orelse return;
    if (!c.caps_completion_resolve) return;
    var item = &self.completion_words.items[self.completion_sel];
    if (!needsResolve(item) or item.resolve_requested) return;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var params = std.json.ObjectMap.init(a, &.{}, &.{}) catch return;
    params.put(a, "label", .{ .string = item.label }) catch return;
    if (item.kind != 0) params.put(a, "kind", .{ .integer = item.kind }) catch return;
    if (item.detail) |d| params.put(a, "detail", .{ .string = d }) catch return;
    if (item.label_detail != null or item.label_description != null) {
        var ld = std.json.ObjectMap.init(a, &.{}, &.{}) catch return;
        if (item.label_detail) |d| ld.put(a, "detail", .{ .string = d }) catch return;
        if (item.label_description) |d| ld.put(a, "description", .{ .string = d }) catch return;
        params.put(a, "labelDetails", .{ .object = ld }) catch return;
    }
    if (item.data_json) |raw| {
        var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch null;
        if (parsed) |*p| {
            params.put(a, "data", p.value) catch return;
            // The arena owns both copies until the request has been encoded.
        }
    }
    // drain may have filled the old resolve slot in the same batch as a
    // completion refresh. Never relabel that completed payload with the new
    // request's generation/index before processCompletionResolve consumes it.
    if (self.completion_resolve_slot) |*old| json_rpc.freeValue(self.alloc, old);
    self.completion_resolve_slot = null;
    item.resolve_requested = true;
    item.resolve_state = .loading;
    // A new request replaces the pending slot. The old item must be allowed
    // to retry if the user comes back; its canceled reply will never arrive.
    if (self.completion_resolve_generation == self.completion_generation and
        self.completion_resolve_index != self.completion_sel and
        self.completion_resolve_index < self.completion_words.items.len)
    {
        const previous = &self.completion_words.items[self.completion_resolve_index];
        if (previous.resolve_state == .loading) {
            previous.resolve_state = .none;
            previous.resolve_requested = false;
        }
    }
    self.completion_resolve_item_id = item.item_id;
    self.completion_resolve_session = self.completion_session;
    self.completion_resolve_generation = self.completion_generation;
    self.completion_resolve_index = self.completion_sel;
    self.completion_resolve_seq = self.edit_seq;
    self.completion_resolve_buf = self.current;
    self.completion_resolve_started_ms = self.nowMs();
    c.request("completionItem/resolve", .{ .object = params }, &self.completion_resolve_slot) catch {
        item.resolve_state = .failed;
        self.completion_resolve_item_id = 0;
    };
}

/// Consume a completed resolve response (run loop, each frame). Returns true
/// when a response was consumed so the caller repaints immediately.
pub fn processCompletionResolve(self: *App) bool {
    if (self.completion_resolve_slot) |result| {
        var owned = result;
        self.completion_resolve_slot = null;
        defer json_rpc.freeValue(self.alloc, &owned);

        if (!self.completion_active or self.completion_resolve_session != self.completion_session or
            self.completion_resolve_generation != self.completion_generation or
            self.completion_resolve_seq != self.edit_seq or self.completion_resolve_buf != self.current)
        {
            return true;
        }
        if (self.completion_resolve_index >= self.completion_words.items.len) return true;
        // A reply can populate its original (now unselected) item, never the
        // item at the current selection. Equal-looking candidates are distinct.
        var item = &self.completion_words.items[self.completion_resolve_index];
        if (item.item_id != self.completion_resolve_item_id) return true;

        var resolved = lsp_nav.parseCompletionResolve(self.alloc, owned) catch {
            item.resolve_state = .failed;
            return true;
        };
        defer resolved.deinit(self.alloc);
        var any = false;
        if (resolved.detail) |v| {
            if (item.detail) |old| self.alloc.free(old);
            item.detail = v;
            resolved.detail = null;
            any = true;
        }
        if (resolved.doc) |v| {
            if (item.doc) |old| self.alloc.free(old);
            item.doc = v;
            item.doc_kind = resolved.doc_kind;
            resolved.doc = null;
            any = true;
        }
        if (resolved.label_detail) |v| {
            if (item.label_detail) |old| self.alloc.free(old);
            item.label_detail = v;
            resolved.label_detail = null;
            any = true;
        }
        if (resolved.label_description) |v| {
            if (item.label_description) |old| self.alloc.free(old);
            item.label_description = v;
            resolved.label_description = null;
            any = true;
        }
        item.resolve_state = if (any) .ready else .empty;
        if (self.completion_sel == self.completion_resolve_index) self.completion_doc_scroll = 0;
        return true;
    }

    // A request that produced no response (error/null/timeout) must not keep
    // the pane in "loading" forever. It also must not block Enter.
    if (self.completion_active and self.completion_sel < self.completion_words.items.len) {
        const item = &self.completion_words.items[self.completion_sel];
        if (item.resolve_state == .loading and self.nowMs() - self.completion_resolve_started_ms > 3000) {
            item.resolve_state = .failed;
            return true;
        }
    }
    return false;
}

/// True while the selected item is waiting for an asynchronous resolve. The
/// run loop polls in short slices during this window so the timeout can fire
/// without a keypress; no LSP request is made just to advance it.
pub fn completionResolveWaiting(self: *App) bool {
    if (!self.completion_active or self.completion_sel >= self.completion_words.items.len) return false;
    return self.completion_words.items[self.completion_sel].resolve_state == .loading;
}

/// True when the selected candidate has any documentation content to scroll.
pub fn completionDocsVisible(self: *App) bool {
    if (self.completion_sel >= self.completion_words.items.len) return false;
    const it = &self.completion_words.items[self.completion_sel];
    return (it.doc != null and it.doc.?.len > 0) or (it.detail != null and it.detail.?.len > 0);
}

/// Move the selection by `delta` (Ctrl+n/Ctrl+p/Up/Down) and refresh the
/// documentation state. Selection never edits the buffer.
pub fn moveCompletion(self: *App, delta: isize) void {
    const n = self.completion_words.items.len;
    if (n == 0) return;
    const cur: isize = @intCast(self.completion_sel);
    self.completion_sel = @intCast(@mod(cur + delta, @as(isize, @intCast(n))));
    self.completion_doc_scroll = 0;
    self.maybeResolveCompletion();
}

/// Ctrl+f / Ctrl+b while the documentation pane is visible: scroll display
/// lines without touching the cursor, selection or buffer.
pub fn scrollCompletionDocs(self: *App, delta: i32) void {
    if (!self.completion_active) return;
    if (self.completion_sel >= self.completion_words.items.len) return;
    if (delta > 0) {
        self.completion_doc_scroll +|= @intCast(delta);
    } else {
        self.completion_doc_scroll -|= @intCast(-delta);
    }
}
