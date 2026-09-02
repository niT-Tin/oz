//! completion — App method group split out of src/main.zig (physical move).

const std = @import("std");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const json_rpc = @import("../util/json_rpc.zig");

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
    if (self.edit_seq != self.completion_req_seq or self.state.mode != .insert) {
        self.completion_waiting_enter = false;
        return true;
    }
    for (self.completion_words.items) |it| self.alloc.free(it.text);
    self.completion_words.clearRetainingCapacity();
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
                if (containsIgnoreCase(it.text, typed)) {
                    self.completion_words.items[write] = it.*;
                    write += 1;
                } else {
                    self.alloc.free(it.text);
                }
            }
            self.completion_words.shrinkRetainingCapacity(write);
        }
    }
    if (self.completion_words.items.len > 0) {
        self.completion_active = true;
        // keep the user's selection when the list refreshed while typing
        if (self.completion_sel >= self.completion_words.items.len) self.completion_sel = 0;
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
