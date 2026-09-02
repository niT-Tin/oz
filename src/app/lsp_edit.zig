//! lsp_edit — App method group split out of src/main.zig (physical move).

const std = @import("std");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const isWordByte = App.isWordByte;

// ---- LSP editing (<leader>rn / <leader>lf / <leader>ti / <leader>o) ----

/// <leader>rn: open the command line prefilled with the word under the
/// cursor; Enter sends textDocument/rename with the edited name.
pub fn requestRename(self: *App) !void {
    if (self.lsp_client == null) {
        try self.setMsg(try self.alloc.dupe(u8, "no language server"));
        return;
    }
    const cursor = self.curCursor().*;
    if (cursor == 0 or !isWordByte(self.cur().pt.byteAt(cursor - 1))) {
        try self.setMsg(try self.alloc.dupe(u8, "no symbol under cursor"));
        return;
    }
    var start = cursor;
    while (start > 0 and isWordByte(self.cur().pt.byteAt(start - 1))) start -= 1;
    var end = cursor;
    while (end < self.cur().pt.len() and isWordByte(self.cur().pt.byteAt(end))) end += 1;
    self.cmdline.clearRetainingCapacity();
    const wlen = end - start;
    const wbuf = self.alloc.alloc(u8, wlen) catch return;
    defer self.alloc.free(wbuf);
    self.cur().pt.copyRange(start, wbuf);
    try self.cmdline.appendSlice(self.alloc, wbuf);
    self.cmd_hist_idx = null;
    self.cmd_complete_idx = 0;
    self.clearCmdCompleteNames();
    try self.setMsg(try self.alloc.dupe(u8, ""));
    self.state.mode = .command;
    self.pending_rename = true;
}

/// Execute the pending rename with the command line's text.
pub fn execRename(self: *App) !void {
    self.pending_rename = false;
    const client = self.lsp_client orelse return;
    const new_name = self.cmdline.items;
    if (new_name.len == 0) return;
    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    const line = self.cur().pt.lineOf(self.curCursor().*);
    const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
    var params = lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
    defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
    const name_copy = try self.alloc.dupe(u8, new_name);
    // Always freed exactly once, on every exit path (put failure, request
    // failure, success): params never frees it, so defer is safe and no
    // path leaks it.
    defer self.alloc.free(name_copy);
    try params.object.put(self.alloc, "newName", .{ .string = name_copy });
    client.request("textDocument/rename", params, &self.format_slot) catch return;
    self.format_req_seq = self.edit_seq;
}

/// Free a manually-built {textDocument:{uri(dupe)}, ...} params object
/// (used by format/inlay/outline; json_rpc.encodeRequest only
/// serializes — it does not free the params).
pub fn freeSimpleDocParams(self: *App, v: *std.json.Value) void {
    if (v.object.getPtr("textDocument")) |td| {
        if (td.object.getPtr("uri")) |u| {
            if (u.* == .string) self.alloc.free(u.string);
        }
        td.object.deinit(self.alloc);
    }
    if (v.object.getPtr("options")) |o| o.object.deinit(self.alloc);
    if (v.object.getPtr("range")) |r| {
        if (r.object.getPtr("start")) |st| st.object.deinit(self.alloc);
        if (r.object.getPtr("end")) |en| en.object.deinit(self.alloc);
        r.object.deinit(self.alloc);
    }
    v.object.deinit(self.alloc);
}

/// <leader>lf: request textDocument/formatting; the TextEdit[] response
/// is applied in processFormat.
pub fn requestFormat(self: *App) !void {
    const client = self.lsp_client orelse return;
    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer td.deinit(self.alloc);
    const uri_copy = try self.alloc.dupe(u8, uri);
    errdefer self.alloc.free(uri_copy);
    try td.put(self.alloc, "uri", .{ .string = uri_copy });
    var options = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer options.deinit(self.alloc);
    try options.put(self.alloc, "tabSize", .{ .integer = 4 });
    try options.put(self.alloc, "insertSpaces", .{ .bool = true });
    var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer params.deinit(self.alloc);
    try params.put(self.alloc, "textDocument", .{ .object = td });
    try params.put(self.alloc, "options", .{ .object = options });
    var params_value = std.json.Value{ .object = params };
    defer self.freeSimpleDocParams(&params_value);
    client.request("textDocument/formatting", params_value, &self.format_slot) catch return;
    self.format_req_seq = self.edit_seq;
}

/// Consume a formatting/rename response (TextEdit[]) and apply the edits
/// right-to-left so earlier offsets stay valid. Returns true when a
/// response was consumed.
pub fn processFormat(self: *App) bool {
    var result = self.format_slot orelse return false;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.format_slot = null;
    }
    // Stale response: the document changed after this request was sent
    // (edits typed between <leader>lf and the reply). The TextEdits were
    // computed against the old text; applying them would corrupt the
    // buffer, so drop them like the inlay-hint path does.
    if (self.edit_seq != self.format_req_seq) return true;
    var edits = std.ArrayList(lsp_nav.TextEdit).empty;
    defer {
        for (edits.items) |*e| self.alloc.free(e.new_text);
        edits.deinit(self.alloc);
    }
    // formatting → TextEdit[]; rename → WorkspaceEdit {changes:{uri:[edits]}}
    const edits_value: ?std.json.Value = if (result == .array)
        result
    else if (result == .object) blk: {
        const changes = result.object.get("changes") orelse break :blk null;
        if (changes != .object) break :blk null;
        var it = changes.object.iterator();
        break :blk if (it.next()) |e| e.value_ptr.* else null;
    } else null;
    if (edits_value) |ev| {
        lsp_nav.parseTextEdits(self.alloc, ev, &self.cur().pt, &edits) catch return true;
    }
    if (edits.items.len == 0) return true;
    self.cur().history.beginGroup();
    var i = edits.items.len;
    while (i > 0) {
        i -= 1;
        const e = edits.items[i];
        if (e.end < e.start) continue;
        self.cur().history.record(&self.cur().pt, e.start, e.end - e.start, e.new_text) catch {};
    }
    self.cur().history.endGroup();
    self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
    self.markDirty();
    self.cur().syntax_revision = std.math.maxInt(u64);
    return true;
}

/// <leader>ti: request inlay hints for the current line.
pub fn requestInlayHints(self: *App) !void {
    const client = self.lsp_client orelse return;
    if (!client.caps_inlay) return; // server doesn't support inlay hints
    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    // request the visible line range; clamp the end to a real line so
    // strict servers (zls) don't stall on an out-of-range end line
    const top = self.curViewTop().*;
    const line_count = self.cur().pt.lineCount();
    const bottom = if (line_count == 0) 0 else @min(top + 24, line_count) - 1;
    var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer td.deinit(self.alloc);
    const uri_copy = try self.alloc.dupe(u8, uri);
    errdefer self.alloc.free(uri_copy);
    try td.put(self.alloc, "uri", .{ .string = uri_copy });
    var range = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer range.deinit(self.alloc);
    var start = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer start.deinit(self.alloc);
    try start.put(self.alloc, "line", .{ .integer = top });
    try start.put(self.alloc, "character", .{ .integer = 0 });
    var end = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer end.deinit(self.alloc);
    try end.put(self.alloc, "line", .{ .integer = bottom });
    try end.put(self.alloc, "character", .{ .integer = 0 });
    try range.put(self.alloc, "start", .{ .object = start });
    try range.put(self.alloc, "end", .{ .object = end });
    var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer params.deinit(self.alloc);
    try params.put(self.alloc, "textDocument", .{ .object = td });
    try params.put(self.alloc, "range", .{ .object = range });
    var params_value = std.json.Value{ .object = params };
    defer self.freeSimpleDocParams(&params_value);
    client.request("textDocument/inlayHint", params_value, &self.inlay_slot) catch return;
    self.inlay_req_seq = self.edit_seq;
}

/// Consume an inlayHint response: collect (line, character, label) hints
/// for inline rendering. Returns true when a response was consumed.
pub fn processInlay(self: *App) bool {
    var result = self.inlay_slot orelse {
        return false;
    };
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.inlay_slot = null;
    }
    // Stale response: the document changed after this request was sent
    // (fast typing in insert mode). Discard it — the in-place adjusted
    // hints stay rendered, and the next quiescent request replaces them.
    // Applying it would jump the hints to pre-edit positions (flicker).
    if (self.edit_seq != self.inlay_req_seq) return true;
    // The response matches the current document: the hints are no longer
    // stale, so renderers may draw them again.
    self.inlay_stale = false;
    for (self.inlay_hints.items) |*h| self.alloc.free(h.label);
    self.inlay_hints.clearRetainingCapacity();
    if (result != .array) {
        return true;
    }
    for (result.array.items) |hint| {
        if (hint != .object) continue;
        const label = hint.object.get("label") orelse continue;
        const text: ?[]const u8 = switch (label) {
            .string => |str| str,
            .array => blk: {
                // InlayHintPart[] — concatenate the `value` strings. Must
                // transfer ownership (toOwnedSlice) — returning out.items
                // and letting a defer deinit free the buffer would leave a
                // dangling slice (rendered as 0xAA garbage).
                var out = std.ArrayList(u8).empty;
                for (label.array.items) |part| {
                    if (part == .object) {
                        if (part.object.get("value")) |val| {
                            if (val == .string) out.appendSlice(self.alloc, val.string) catch {};
                        }
                    }
                }
                if (out.items.len == 0) {
                    out.deinit(self.alloc);
                    break :blk null;
                }
                break :blk out.toOwnedSlice(self.alloc) catch {
                    out.deinit(self.alloc);
                    break :blk null;
                };
            },
            else => null,
        };
        const t = text orelse continue;
        if (t.len == 0) continue;
        // The array branch owns its slice (toOwnedSlice); the string
        // branch borrows from `result` (freed below). A malformed hint
        // that fails the position parse below must release the owned
        // slice — otherwise every such response leaks the label.
        const position = hint.object.get("position") orelse {
            if (label == .array) self.alloc.free(t);
            continue;
        };
        const line = lsp_nav.posLine(position) orelse {
            if (label == .array) self.alloc.free(t);
            continue;
        };
        const character_utf16 = lsp_nav.posCharacter(position) orelse {
            if (label == .array) self.alloc.free(t);
            continue;
        };
        // LSP positions are UTF-16 code units; store the hint at the
        // byte column instead so adjustInlayHints* and the renderer's
        // byte-column comparisons stay consistent on non-ASCII lines.
        const character = self.byteColumnFromUtf16(line, character_utf16);
        const copy = switch (label) {
            .array => t,
            else => self.alloc.dupe(u8, t) catch continue,
        };
        self.inlay_hints.append(self.alloc, .{ .line = line, .character = character, .label = copy }) catch {
            self.alloc.free(copy);
            continue;
        };
    }
    return true;
}

/// <leader>o: request document symbols; the response fills the outline
/// list overlay (reuses the navigation location list UI).
pub fn requestOutline(self: *App) !void {
    const client = self.lsp_client orelse return;
    const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
    defer self.alloc.free(uri);
    var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer td.deinit(self.alloc);
    const uri_copy = try self.alloc.dupe(u8, uri);
    errdefer self.alloc.free(uri_copy);
    try td.put(self.alloc, "uri", .{ .string = uri_copy });
    var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
    errdefer params.deinit(self.alloc);
    try params.put(self.alloc, "textDocument", .{ .object = td });
    var params_value = std.json.Value{ .object = params };
    defer self.freeSimpleDocParams(&params_value);
    client.request("textDocument/documentSymbol", params_value, &self.outline_slot) catch return;
}

/// Consume a documentSymbol response: flatten into the outline list
/// (reuses nav_locations for the overlay; the label rides in a packed
/// "label\x00line" uri slot so the list shows it and Enter jumps).
pub fn processOutline(self: *App) bool {
    var result = self.outline_slot orelse return false;
    defer {
        json_rpc.freeValue(self.alloc, &result);
        self.outline_slot = null;
    }
    for (self.nav_locations.items) |*l| self.alloc.free(l.uri);
    self.nav_locations.clearRetainingCapacity();
    self.nav_list_sel = 0;
    self.nav_loc_top = 0;
    if (result == .array) {
        for (result.array.items) |item| {
            if (item != .object) continue;
            var name: ?[]const u8 = null;
            if (item.object.get("name")) |nm| {
                if (nm == .string) name = nm.string;
            }
            const rng = if (item.object.get("range")) |r| r else blk: {
                const loc = item.object.get("location") orelse continue;
                break :blk if (loc.object.get("range")) |rr| rr else continue;
            };
            if (rng != .object) continue;
            const start = rng.object.get("start") orelse continue;
            const line = lsp_nav.posLine(start) orelse continue;
            const nm = name orelse continue;
            const packed_uri = std.fmt.allocPrint(self.alloc, "{s}\x00{d}", .{ nm, line }) catch continue;
            self.nav_locations.append(self.alloc, .{ .uri = packed_uri, .line = line, .character = 0 }) catch {
                self.alloc.free(packed_uri);
                continue;
            };
        }
    }
    self.nav_list_active = self.nav_locations.items.len > 0;
    self.nav_list_title = " Outline ";
    self.refreshNavPreview();
    return true;
}

/// Scan the whole buffer for words and fill completion_words with the
/// most frequent ones (ties broken alphabetically), capped at 20. The
/// word currently being typed (from completion_pos to the cursor) is
/// excluded from the candidates.
pub fn collectCompletionWords(self: *App, keep_sel: bool) !void {
    const pt = &self.cur().pt;
    const cursor = self.curCursor().*;
    // start of the word under/behind the cursor — the replacement anchor
    var pos = cursor;
    while (pos > 0 and isWordByte(pt.byteAt(pos - 1))) pos -= 1;
    if (pos == cursor) return; // cursor not inside a word
    self.completion_pos = pos;
    const typed_len = cursor - pos;
    const typed = try self.alloc.alloc(u8, typed_len);
    defer self.alloc.free(typed);
    if (typed_len > 0) pt.copyRange(pos, typed);

    var counts = std.StringHashMap(u32).init(self.alloc);
    defer {
        var it = counts.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        counts.deinit();
    }

    // Scan the document in chunks, stitching words that straddle a chunk
    // boundary: the word bytes are accumulated in `pending` until a
    // non-word byte ends them. `pending_start` tracks the absolute start
    // of the word being assembled so the word currently being typed (the
    // one starting at completion_pos — it spans the cursor and continues
    // past it, e.g. "HELLObase" while typing HELLO into "base") is
    // excluded, exactly like blink.cmp skips the word under the cursor.
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(self.alloc);
    var pending_start: u32 = 0;
    var chunk: [4096]u8 = undefined;
    var off: u32 = 0;
    const doc_len = pt.len();
    while (off < doc_len) {
        const n: usize = @intCast(@min(chunk.len, doc_len - off));
        pt.copyRange(off, chunk[0..n]);
        var i: usize = 0;
        while (i < n) {
            if (isWordByte(chunk[i])) {
                var j = i;
                while (j < n and isWordByte(chunk[j])) j += 1;
                if (pending.items.len == 0) pending_start = off + @as(u32, @intCast(i));
                try pending.appendSlice(self.alloc, chunk[i..j]);
                if (j == n) break; // may continue on the next chunk
                try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
                pending.clearRetainingCapacity();
                i = j;
            } else {
                if (pending.items.len > 0) {
                    try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
                    pending.clearRetainingCapacity();
                }
                i += 1;
            }
        }
        off += @intCast(n);
    }
    // a word running to the end of the document
    if (pending.items.len > 0) {
        try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
        pending.clearRetainingCapacity();
    }

    // (word, count) pairs, sorted by count desc then word asc
    const Pair = struct { word: []const u8, count: u32 };
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(self.alloc);
    {
        var it = counts.iterator();
        while (it.next()) |e| {
            try pairs.append(self.alloc, .{ .word = e.key_ptr.*, .count = e.value_ptr.* });
        }
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lt);

    const max_words: usize = 20;
    const limit = @min(max_words, pairs.items.len);
    try self.completion_words.ensureTotalCapacity(self.alloc, limit);
    errdefer {
        for (self.completion_words.items) |it| self.alloc.free(it.text);
        self.completion_words.clearRetainingCapacity();
    }
    var k: usize = 0;
    while (k < limit) : (k += 1) {
        const w = try self.alloc.dupe(u8, pairs.items[k].word);
        try self.completion_words.append(self.alloc, .{ .text = w, .kind = 0 });
    }
    if (!keep_sel) self.completion_sel = 0;
}

/// Count one occurrence of `word` (skipping the word currently being
/// typed). StringHashMap does not copy keys, and the scan buffers are
/// reused, so keys are duplicated — the pending buffer can be overwritten
/// by the very next word.
pub fn countCompletionWord(self: *App, counts: *std.StringHashMap(u32), word: []const u8, typed: []const u8, is_current: bool) !void {
    // the word currently being typed (spans the cursor) is not a
    // candidate — blink skips it too
    if (is_current) return;
    // prefix filter: only words starting with the typed prefix are
    // candidates (vim C-n keyword completion); the exact typed word is
    // excluded
    if (word.len < typed.len or !std.mem.startsWith(u8, word, typed)) return;
    if (word.len == typed.len and std.mem.eql(u8, word, typed)) return;
    // fast path: word already counted — no allocation
    if (counts.getPtr(word)) |p| {
        p.* += 1;
        return;
    }
    const key = try self.alloc.dupe(u8, word);
    errdefer self.alloc.free(key);
    const gop = try counts.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
    } else {
        self.alloc.free(key); // duplicate of an existing key — drop ours
        gop.value_ptr.* += 1;
    }
}

/// Enter while the menu is open: replace the typed prefix
/// [completion_pos, cursor) with the selected word — one edit inside the
/// open insert-session undo group — then close the menu (insert stays
/// active, the session continues). Matches the user's nvim (blink.cmp):
/// Enter is the only accept key; Tab always inserts literal spaces.
pub fn acceptCompletion(self: *App) !void {
    if (self.completion_words.items.len == 0 or self.completion_sel >= self.completion_words.items.len) {
        self.closeCompletion();
        return;
    }
    const word = self.completion_words.items[self.completion_sel].text;
    const pt = &self.cur().pt;
    const cursor = self.curCursor().*;
    const pos = @min(self.completion_pos, cursor);
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    // LSP range in the PRE-EDIT document: [pos, cursor) → word.
    const start_pos = self.lspPositionAt(pt, pos);
    const end_pos = self.lspPositionAt(pt, cursor);
    try self.cur().history.record(pt, pos, cursor - pos, word);
    self.curCursor().* = pos + @as(u32, @intCast(word.len));
    self.markDirtyRange(start_pos, end_pos, word);
    self.closeCompletion();
}

/// Drop the completion menu and free its candidate words (the list keeps
/// its capacity for the next trigger).
pub fn closeCompletion(self: *App) void {
    if (!self.completion_active and self.completion_words.items.len == 0) return;
    for (self.completion_words.items) |it| self.alloc.free(it.text);
    self.completion_words.clearRetainingCapacity();
    self.completion_active = false;
    self.completion_sel = 0;
    self.completion_pos = 0;
}

/// Enter in insert mode (vim semantics): split the current line at the
/// cursor and carry the original line's leading indentation (the run of
/// spaces/tabs before the cursor) over to the new line. The cursor lands
/// right after the carried indentation (insertText advances it). Done as
/// one edit so it is a single undo step.
pub fn insertNewline(self: *App) !void {
    // safety net: the '\n' insertion must join the insert-session group
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const pt = &self.cur().pt;
    const cursor = self.curCursor().*;
    const line = pt.lineOf(cursor);
    const line_start = pt.lineStart(line);
    const col = cursor - line_start;
    // leading indentation of the original line, capped at the cursor
    var indent_end: u32 = 0;
    while (indent_end < col) : (indent_end += 1) {
        const b = pt.byteAt(line_start + indent_end);
        if (b != ' ' and b != '\t') break;
    }
    const indent = try self.alloc.alloc(u8, @intCast(indent_end));
    defer self.alloc.free(indent);
    pt.copyRange(line_start, indent);
    const text = try std.fmt.allocPrint(self.alloc, "\n{s}", .{indent});
    defer self.alloc.free(text);
    try self.insertText(text);
}

/// Ctrl+k in insert mode (emacs kill-line): delete from the cursor to the
/// end of the line. When the cursor is already at the end of the line,
/// delete the trailing newline instead, joining the next line (no-op on
/// the last line).
pub fn deleteToEol(self: *App) !void {
    // safety net: the kill must join the insert-session group
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const pt = &self.cur().pt;
    const cursor = self.curCursor().*;
    const line = pt.lineOf(cursor);
    const line_start = pt.lineStart(line);
    const line_end = line_start + pt.lineLen(line);
    const col = cursor - line_start;
    if (cursor < line_end) {
        // LSP range in the PRE-EDIT document: [cursor, line_end).
        const start_pos = self.lspPositionAt(pt, cursor);
        const end_pos = self.lspPositionAt(pt, line_end);
        const del_len: usize = @intCast(line_end - cursor);
        const deleted = try self.alloc.alloc(u8, del_len);
        defer self.alloc.free(deleted);
        pt.copyRange(cursor, deleted);
        try self.cur().history.record(pt, cursor, line_end - cursor, "");
        self.adjustInlayHintsDelete(line, col, deleted);
        self.markDirtyRange(start_pos, end_pos, "");
    } else if (line_end < pt.len()) {
        // at end of line: swallow the trailing newline (joins next line)
        const start_pos = self.lspPositionAt(pt, line_end);
        const end_pos = self.lspPositionAt(pt, line_end + 1);
        try self.cur().history.record(pt, line_end, 1, "");
        self.adjustInlayHintsDelete(line, col, "\n");
        self.markDirtyRange(start_pos, end_pos, "");
    } else {
        return; // last line, nothing to delete
    }
}
