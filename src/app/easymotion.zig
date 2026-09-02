//! easymotion — App method group split out of src/main.zig (physical move).

const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const editor = @import("../editor/root.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- easymotion (s / <leader>f) ----

pub fn handleEasyMotionKey(self: *App, key: vaxis.Key) !void {
    if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
        self.endEasyMotion();
        return;
    }
    if (!self.em_labels) {
        // first key = the query character. Use the key's UTF-8 text so
        // non-ASCII queries (CJK etc.) work — codepoint-only matching
        // capped the query at 0xFF and swallowed multibyte keys.
        const text = key.text orelse {
            // keys without text (Enter etc.): take the codepoint as a
            // single byte when it is printable ASCII
            if (key.codepoint >= 0x20 and key.codepoint <= 0x7F and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super)
            {
                self.em_query[0] = @intCast(key.codepoint);
                self.em_query_len = 1;
                if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
                const q = self.em_query[0..self.em_query_len];
                self.em_matches = try editor.easymotion.find(self.alloc, &self.cur().pt, q);
                self.em_labels = true;
            }
            return;
        };
        if (text.len > 0 and text.len <= 2 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            @memcpy(self.em_query[0..text.len], text);
            self.em_query_len = @intCast(text.len);
            if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
            const q = self.em_query[0..self.em_query_len];
            self.em_matches = try editor.easymotion.find(self.alloc, &self.cur().pt, q);
            self.em_labels = true;
        }
        return;
    }
    // label key: jump to the match carrying this label
    const ch = key.codepoint;
    if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
        for (self.em_matches) |m| {
            if (m.label == ch) {
                self.curCursor().* = m.pos;
                break;
            }
        }
    }
    self.endEasyMotion();
}

pub fn endEasyMotion(self: *App) void {
    if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
    self.em_matches = &.{};
    self.em_active = false;
    self.em_labels = false;
    self.em_query = .{ 0, 0, 0, 0 };
    self.em_query_len = 0;
}

/// Delete the character before the cursor (backspace). The edit lands in
/// the open insert undo group so it stays part of the insert session.
pub fn deleteBeforeCursor(self: *App) !void {
    if (self.curCursor().* == 0) return;
    // safety net: make sure the insert-session group is open even if a
    // future entry path forgets to open it (backspace is a deletion, and
    // history.record would otherwise auto-open/close its own group)
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const start = buffer.ops.prevCharStart(&self.cur().pt, self.curCursor().*);
    const cursor = self.curCursor().*;
    const line = self.cur().pt.lineOf(start);
    const col = start - self.cur().pt.lineStart(line);
    // LSP range in the PRE-EDIT document: [start, cursor).
    const start_pos = self.lspPositionAt(&self.cur().pt, start);
    const end_pos = self.lspPositionAt(&self.cur().pt, cursor);
    var deleted: [16]u8 = undefined;
    const del_len: usize = @intCast(cursor - start);
    self.cur().pt.copyRange(start, deleted[0..del_len]);
    try self.cur().history.record(&self.cur().pt, start, cursor - start, "");
    self.curCursor().* = start;
    self.adjustInlayHintsDelete(line, col, deleted[0..del_len]);
    self.markDirtyRange(start_pos, end_pos, "");
}

/// Delete the word before the cursor (Ctrl-w). Vim semantics: walk back
/// over whitespace then word characters; deletes [start, cursor).
pub fn deleteWordBefore(self: *App) !void {
    if (self.curCursor().* == 0) return;
    const start = buffer.ops.wordStartBefore(&self.cur().pt, self.curCursor().*);
    if (start == self.curCursor().*) return;
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const cursor = self.curCursor().*;
    const line = self.cur().pt.lineOf(start);
    const col = start - self.cur().pt.lineStart(line);
    // LSP range in the PRE-EDIT document: [start, cursor).
    const start_pos = self.lspPositionAt(&self.cur().pt, start);
    const end_pos = self.lspPositionAt(&self.cur().pt, cursor);
    const del_len: usize = @intCast(cursor - start);
    const deleted = try self.alloc.alloc(u8, del_len);
    defer self.alloc.free(deleted);
    self.cur().pt.copyRange(start, deleted);
    try self.cur().history.record(&self.cur().pt, start, cursor - start, "");
    self.curCursor().* = start;
    self.adjustInlayHintsDelete(line, col, deleted);
    self.markDirtyRange(start_pos, end_pos, "");
}
