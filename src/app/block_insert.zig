//! block_insert — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const editor = @import("../editor/root.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- visual-block multi-cursor insert (<C-v> block then I/A) ----

/// The vim visual-block rectangle: the lines between the anchor and
/// cursor rows and the columns between their columns (both ends
/// inclusive). Columns are byte columns within a line.
pub const BlockRect = struct {
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,
};

/// Align `pos` (a byte offset within [line_start, line_end)) forward to a
/// UTF-8 character boundary, so a visual-block column landing on a
/// continuation byte doesn't slice a multibyte char mid-sequence.
pub fn charBoundaryForward(self: *App, pt: *const buffer.PieceTable, pos: u32, line_end: u32) u32 {
    _ = self;
    var p = pos;
    while (p < line_end and (pt.byteAt(p) & 0xC0) == 0x80) : (p += 1) {}
    return p;
}

/// Byte length of the UTF-8 character starting at `pos` (1 for ASCII,
/// 2-4 for sequences; malformed bytes — stray continuation bytes and
/// invalid leads 0xF8..0xFF — count as 1, matching motion.zig).
pub fn charLenAt(self: *App, pt: *const buffer.PieceTable, pos: u32) u32 {
    _ = self;
    if (pos >= pt.len()) return 0;
    const b = pt.byteAt(pos);
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1; // stray continuation byte: its own char
    const n: u32 = if (b < 0xE0) 2 else if (b < 0xF0) 3 else if (b < 0xF8) 4 else 1;
    return @min(n, pt.len() - pos);
}

pub fn blockRect(self: *App) ?BlockRect {
    const anchor = self.visual_anchor orelse return null;
    const pt = &self.cur().pt;
    const a_line = pt.lineOf(anchor);
    const c_line = pt.lineOf(self.curCursor().*);
    const a_col = anchor - pt.lineStart(a_line);
    const c_col = self.curCursor().* - pt.lineStart(c_line);
    return .{
        .top = @min(a_line, c_line),
        .bottom = @max(a_line, c_line),
        .left = @min(a_col, c_col),
        .right = @max(a_col, c_col),
    };
}

/// d/c/y over a visual-block rectangle: operate on every covered line's
/// [left, min(right+1, lineLen)) slice — bottom-up for edits so earlier
/// positions stay valid; blank slices on short lines are skipped.
pub fn applyBlockOp(self: *App, op: editor.KeyEvent.ActionId) !void {
    const rect = self.blockRect() orelse return;
    const pt = &self.cur().pt;
    switch (op) {
        .delete, .change => {
            self.cur().history.beginGroup();
            var line = rect.bottom + 1;
            while (line > rect.top) {
                line -= 1;
                const ls = pt.lineStart(line);
                const len = pt.lineLen(line);
                if (rect.left >= len) continue;
                const line_end = ls + len;
                const start = self.charBoundaryForward(pt, ls + rect.left, line_end);
                const end = @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end);
                if (end <= start) continue;
                try self.cur().history.record(pt, start, end - start, "");
            }
            self.cur().history.endGroup();
            self.markDirty();
            if (op == .change) {
                // vim blockwise change: after deleting the rectangle, one
                // insert cursor per covered line at the block's left edge
                // — the typed text lands in EVERY line of the block, not
                // just at the cursor. placeBlockCursors opens the insert
                // session undo group (typing joins it).
                try self.placeBlockCursors(rect, false);
            } else {
                self.curCursor().* = pt.lineStart(rect.top) + @min(rect.left, pt.lineLen(rect.top));
            }
        },
        .yank => {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.alloc);
            var line = rect.top;
            while (line <= rect.bottom) : (line += 1) {
                const ls = pt.lineStart(line);
                const len = pt.lineLen(line);
                if (rect.left < len) {
                    const line_end = ls + len;
                    const start = self.charBoundaryForward(pt, ls + rect.left, line_end);
                    const end = @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end);
                    if (end <= start) continue;
                    const seg = try self.alloc.alloc(u8, end - start);
                    defer self.alloc.free(seg);
                    pt.copyRange(start, seg);
                    try buf.appendSlice(self.alloc, seg);
                }
                if (line < rect.bottom) try buf.append(self.alloc, '\n');
            }
            if (self.yank_buffer) |b| self.alloc.free(b);
            self.yank_buffer = try buf.toOwnedSlice(self.alloc);
            self.yank_linewise = false; // blockwise yank pastes inline (no blockwise put yet)
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked block {d} bytes", .{self.yank_buffer.?.len}));
        },
        else => {},
    }
}

/// I/A after a Ctrl+v block (or blockwise c after the rectangle was
/// deleted): place one insert cursor per line of the block and enter
/// insert mode. I puts each cursor at the block's left edge; A (append)
/// puts them one column past the block's right edge (vim: the right edge
/// is the last selected column, so +1 inserts right after the selection's
/// rightmost character). Both clamp to the end of the line, so
/// short/empty lines get their cursor at end-of-line. The top line's
/// cursor is added first so it becomes the main one.
pub fn blockInsert(self: *App, append: bool) !void {
    const rect = self.blockRect() orelse return;
    try self.placeBlockCursors(rect, append);
}

pub fn placeBlockCursors(self: *App, rect: BlockRect, append: bool) !void {
    const pt = &self.cur().pt;
    self.mc.clear();
    const anchor_line = pt.lineStart(rect.top);
    const anchor_end = anchor_line + pt.lineLen(rect.top);
    const anchor_col: u32 = if (append)
        @min(self.charBoundaryForward(pt, anchor_line + rect.right + 1, anchor_end), anchor_end)
    else
        @min(self.charBoundaryForward(pt, anchor_line + rect.left, anchor_end), anchor_end);
    _ = try self.mc.add(anchor_col);
    var line = rect.top;
    while (line <= rect.bottom) : (line += 1) {
        if (line == rect.top) continue;
        const ls = pt.lineStart(line);
        const line_end = ls + pt.lineLen(line);
        const col: u32 = if (append)
            @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end)
        else
            @min(self.charBoundaryForward(pt, ls + rect.left, line_end), line_end);
        _ = try self.mc.add(col);
    }
    self.mc_active = true;
    self.visual_anchor = null; // the selection is consumed by I/A/c
    self.state.mode = .insert;
    // open the undo group immediately: the first key (backspace or
    // typing) must join the same session group
    self.cur().history.beginGroup();
    self.in_insert = true;
    self.prev_insert_key = null;
    self.mcSyncCursor();
}

/// Insert-mode keys with an active visual-block multi-cursor selection.
/// Mirrors the single-cursor insert path, but every edit applies at every
/// cursor (one history.record per cursor, right-to-left so the earlier
/// positions stay valid) and the whole session lives in one undo group.
pub fn handleMcInsertKey(self: *App, key: vaxis.Key) !void {
    // Arrow keys move the main cursor without leaving insert.
    if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.right or
        key.codepoint == vaxis.Key.up or key.codepoint == vaxis.Key.down)
    {
        var c = self.curCursor().*;
        editor.Motion.apply(&self.cur().pt, switch (key.codepoint) {
            vaxis.Key.left => .left,
            vaxis.Key.right => .right,
            vaxis.Key.up => .up,
            else => .down,
        }, .{}, &c, 1);
        self.curCursor().* = c;
        self.mcSyncCursor();
        return;
    }
    // Esc / Ctrl-c: exit, one main cursor remains
    if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
        self.exitMcInsert();
        return;
    }
    // jk → drop the just-typed 'j' at every cursor, then exit
    if (self.prev_insert_key) |p| {
        if (p.codepoint == 'j' and key.codepoint == 'k' and
            !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            var deleted_any = false;
            var i = self.mc.cursors.items.len;
            while (i > 0) {
                i -= 1;
                const pos = self.mc.cursors.items[i];
                if (pos > 0 and self.cur().pt.byteAt(pos - 1) == 'j') {
                    deleted_any = true;
                    try self.cur().history.record(&self.cur().pt, pos - 1, 1, "");
                    // the deletion shifts every cursor at/after it back
                    for (self.mc.cursors.items[i..]) |*c| c.* -= 1;
                }
            }
            // The 'j' insertions were synced via didChange (mcInsertText
            // → markDirty); re-sync the removals too, or the server
            // analyzes a document with phantom 'j's (stale diagnostics,
            // wrong inlay positions).
            if (deleted_any) self.markDirty();
            self.exitMcInsert();
            return;
        }
    }
    // Enter at every cursor: insert a newline at each one. (No
    // indentation carry-over — M1 keeps the multi-cursor path simple.
    // Ctrl+k / Alt+b / Alt+f are intentionally not handled here.)
    if (key.codepoint == vaxis.Key.enter) {
        try self.mcInsertText("\n");
        return;
    }
    if (key.codepoint == vaxis.Key.backspace) {
        try self.mcBackspace();
        return;
    }
    if (key.codepoint == 'w' and key.mods.ctrl) {
        try self.mcDeleteWordBefore();
        return;
    }
    self.prev_insert_key = key;
    if (key.text) |text| {
        try self.mcInsertText(text);
    }
}

/// Insert `text` at every visual-block cursor. One history.record per
/// cursor, applied right-to-left so earlier positions stay valid; every
/// cursor at or after an insertion point moves forward by `text.len`
/// (mirrors MultiCursor.applyInsert, but each edit lands in history).
pub fn mcInsertText(self: *App, text: []const u8) !void {
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const tlen: u32 = @intCast(text.len);
    var i = self.mc.cursors.items.len;
    while (i > 0) {
        i -= 1;
        const pos = self.mc.cursors.items[i];
        try self.cur().history.record(&self.cur().pt, pos, 0, text);
        for (self.mc.cursors.items[i..]) |*c| c.* += tlen;
    }
    self.mcSyncCursor();
    self.markDirty();
}

/// Backspace at every visual-block cursor: delete one character before
/// each cursor (right-to-left); cursors at/after a deletion shift back,
/// ones inside its range clamp to its start.
pub fn mcBackspace(self: *App) !void {
    // safety net: the deletion must join the insert-session group
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    var i = self.mc.cursors.items.len;
    while (i > 0) {
        i -= 1;
        const pos = self.mc.cursors.items[i];
        if (pos == 0) continue;
        const start = buffer.ops.prevCharStart(&self.cur().pt, pos);
        const del = pos - start;
        try self.cur().history.record(&self.cur().pt, start, del, "");
        var j: usize = 0;
        while (j < self.mc.cursors.items.len) : (j += 1) {
            const c = self.mc.cursors.items[j];
            if (c < start) continue;
            self.mc.cursors.items[j] = if (c >= pos) c - del else start;
        }
    }
    self.mcSyncCursor();
    // LSP sync: the deletions changed the buffer — the server's copy
    // must follow or diagnostics/hints are computed against stale text.
    self.markDirty();
}

/// Ctrl-w at every visual-block cursor: delete the word before each
/// cursor (right-to-left); cursors shift like backspace.
pub fn mcDeleteWordBefore(self: *App) !void {
    // safety net: the deletion must join the insert-session group
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    var i = self.mc.cursors.items.len;
    while (i > 0) {
        i -= 1;
        const pos = self.mc.cursors.items[i];
        if (pos == 0) continue;
        const start = buffer.ops.wordStartBefore(&self.cur().pt, pos);
        if (start == pos) continue;
        const del = pos - start;
        try self.cur().history.record(&self.cur().pt, start, del, "");
        var j: usize = 0;
        while (j < self.mc.cursors.items.len) : (j += 1) {
            const c = self.mc.cursors.items[j];
            if (c < start) continue;
            self.mc.cursors.items[j] = if (c >= pos) c - del else start;
        }
    }
    self.mcSyncCursor();
    // LSP sync: the deletions changed the buffer — the server's copy
    // must follow or diagnostics/hints are computed against stale text.
    self.markDirty();
}

/// Exit a visual-block multi-cursor insert session: close the undo group,
/// drop the extra cursors and leave a single main cursor (the block's
/// anchor-line cursor) in normal mode.
pub fn exitMcInsert(self: *App) void {
    self.mcSyncCursor();
    self.mc.clear();
    self.mc_active = false;
    self.state.mode = .normal;
    self.cur().history.endGroup();
    self.in_insert = false;
    self.prev_insert_key = null;
    self.endInsertSession();
    // Force a full reparse on the next render: incremental edits during
    // the insert session may have drifted the highlight tree.
    self.cur().syntax_revision = std.math.maxInt(u64);
    // the mc edits were not position-adjusted (unlike single-cursor
    // insert); fetch fresh hints for the new text
    self.invalidateInlayHints();
    // typing done: refresh the git gutter marks right away (mc edits do
    // not go through the per-edit shift hooks — a full re-diff is the
    // exact fix)
    self.gitRefreshSoon();
}

/// Keep the visible (main) cursor on the main multi-cursor's position.
pub fn mcSyncCursor(self: *App) void {
    if (self.mc.len() > 0) self.curCursor().* = self.mc.cursors.items[self.mc.main];
}
