//! editing — App method group split out of src/main.zig (physical move).

const std = @import("std");
const editor = @import("../editor/root.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");

const isWordByte = App.isWordByte;

// ---- auto-pairs (insert mode): 括号/引号自动闭合与跳过 ----

/// Matching closer for an opener; the quote chars pair with themselves.
pub fn pairCloser(ch: u8) ?u8 {
    return switch (ch) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"', '\'', '`' => ch,
        else => null,
    };
}

/// Auto-pair handling for one typed character (insert mode, single
/// cursor — multi-cursor edits go through handleMcInsertKey and stay
/// literal). Returns true when the key was handled here:
/// - opener: insert the pair, cursor ends up between the two
/// - quote: same, but not right after a word char ("don't"), and typing
///   the quote again over an identical quote skips over it
/// - closer: when the cursor sits on that same closer, skip over it
///   instead of inserting a duplicate
pub fn autoPairInsert(self: *App, text: []const u8) !bool {
    if (text.len != 1) return false;
    const ch = text[0];
    const pos = self.curCursor().*;
    const len = self.cur().pt.len();
    switch (ch) {
        '(', '[', '{' => {
            try self.insertText(&[_]u8{ ch, pairCloser(ch).? });
            self.curCursor().* = pos + 1;
            return true;
        },
        '"', '\'', '`' => {
            if (pos < len and self.cur().pt.byteAt(pos) == ch) {
                self.curCursor().* = pos + 1; // skip over
                return true;
            }
            if (pos > 0 and isWordByte(self.cur().pt.byteAt(pos - 1))) return false;
            try self.insertText(&[_]u8{ ch, ch });
            self.curCursor().* = pos + 1;
            return true;
        },
        ')', ']', '}' => {
            if (pos < len and self.cur().pt.byteAt(pos) == ch) {
                self.curCursor().* = pos + 1; // skip over
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Backspace between an empty pair (`(|)`, `"|"`, …) deletes both sides
/// as one undo record. Returns true when it handled the keypress.
pub fn autoPairBackspace(self: *App) !bool {
    const pos = self.curCursor().*;
    if (pos == 0 or pos >= self.cur().pt.len()) return false;
    const open = self.cur().pt.byteAt(pos - 1);
    const closer = pairCloser(open) orelse return false;
    if (self.cur().pt.byteAt(pos) != closer) return false;
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const start = pos - 1;
    const line = self.cur().pt.lineOf(start);
    const col = start - self.cur().pt.lineStart(line);
    const start_pos = self.lspPositionAt(&self.cur().pt, start);
    const end_pos = self.lspPositionAt(&self.cur().pt, start + 2);
    try self.cur().history.record(&self.cur().pt, start, 2, "");
    self.curCursor().* = start;
    self.adjustInlayHintsDelete(line, col, &[_]u8{ open, closer });
    self.markDirtyRange(start_pos, end_pos, "");
    return true;
}

/// Visual-selection end semantics: vim's character-wise selection includes
/// the character under the cursor.
pub const SelEnd = enum { exclusive_cursor, inclusive_cursor };

/// Write [start, end) into the unnamed register (vim: y AND d/c all fill
/// it — dd p is cut-paste). `linewise` is the register's type and decides
/// how p/P puts the text (whole lines below/above vs inline).
pub fn setRegister(self: *App, start: u32, end: u32, linewise: bool) !void {
    if (self.yank_buffer) |b| self.alloc.free(b);
    const buf = try self.alloc.alloc(u8, end - start);
    self.cur().pt.copyRange(start, buf);
    self.yank_buffer = buf;
    self.yank_linewise = linewise;
}

/// Apply an operator (d/c/y) over a range. `exclusive` trims the end char
/// (vim exclusive motions); text objects and selections pass false with an
/// already-exact range. `linewise` marks the register type (vim regtype).
pub fn applyOpRange(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool, linewise: bool) !void {
    try self.applyOpRangeEx(op, from, to, exclusive, .exclusive_cursor, linewise);
}

pub fn applyOpRangeEx(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool, sel: SelEnd, linewise: bool) !void {
    const start = @min(from, to);
    var end = @max(from, to);
    if (exclusive and end > start) end -= 1;
    if (sel == .inclusive_cursor and end < self.cur().pt.len()) end += 1;
    if (end <= start) {
        if (op == .change) {
            // empty range (e.g. cc on an empty line): enter insert with
            // the undo group already open so typing joins one session
            self.cur().history.beginGroup();
            self.state.mode = .insert;
            self.in_insert = true;
        }
        // yy on an empty line (incl. the phantom EOF line a trailing
        // newline creates): yanks an empty LINE, so p/P still put an
        // empty line instead of erroring E353
        if (op == .yank and linewise) try self.setRegister(start, start, true);
        return;
    }
    switch (op) {
        .delete => {
            // LSP range in the PRE-EDIT document: [start, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, start);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            try self.setRegister(start, end, linewise);
            self.cur().history.beginGroup();
            try self.cur().history.record(&self.cur().pt, start, end - start, "");
            self.cur().history.endGroup();
            self.curCursor().* = start;
            // deleting the last real line lands on the phantom empty
            // line a trailing '\n' creates; nvim clamps the cursor to
            // the last REAL line (dd at EOF, then p/P pastes relative
            // to it)
            if (self.cur().pt.len() > 0 and self.curCursor().* >= self.cur().pt.len()) {
                const lc = self.cur().pt.lineCount();
                self.curCursor().* = self.cur().pt.lineStart(lc -| 2);
            }
            self.markDirtyRange(start_pos, end_pos, "");
        },
        .change => {
            // LSP range in the PRE-EDIT document: [start, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, start);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            try self.setRegister(start, end, linewise);
            self.curCursor().* = start;
            self.cur().history.beginGroup();
            try self.cur().history.record(&self.cur().pt, start, end - start, "");
            self.state.mode = .insert;
            self.in_insert = true; // keep the group open; exitInsert closes it
            self.markDirtyRange(start_pos, end_pos, "");
            self.cur().syntax_revision = std.math.maxInt(u64);
        },
        .yank => {
            try self.setRegister(start, end, linewise);
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked {d} bytes", .{self.yank_buffer.?.len}));
        },
        else => {},
    }
}

// ---- surround (ys / ds / cs) ----

pub fn execSurround(self: *App, s: anytype) !void {
    switch (s.op) {
        .add => {
            const rng = self.surroundRange(s.motion, s.args, s.count, s.text_object) orelse return;
            const res = try editor.surround.add(self.alloc, &self.cur().pt, .{ .start = rng.start, .end = rng.end }, s.ch);
            defer self.alloc.free(res.text);
            try self.applyEdit(res.start, res.end, res.text);
        },
        .delete => {
            const res = (try editor.surround.delete(self.alloc, &self.cur().pt, self.curCursor().*)) orelse {
                try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                return;
            };
            defer self.alloc.free(res.text);
            try self.applyEdit(res.start, res.end, res.text);
            self.curCursor().* = res.start;
        },
        .change => {
            const res = (try editor.surround.change(self.alloc, &self.cur().pt, self.curCursor().*, s.ch)) orelse {
                try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                return;
            };
            defer self.alloc.free(res.text);
            try self.applyEdit(res.start, res.end, res.text);
            self.curCursor().* = res.start;
        },
    }
}

/// Range covered by a surround-add motion/text object; trailing whitespace
/// is trimmed so ysw wraps the word, not "word " (vim-surround behavior).
pub fn surroundRange(self: *App, motion: ?editor.Motion.Motion, args: editor.Motion.Args, count: u32, text_object: ?editor.TextObject.Kind) ?editor.TextObject.Range {
    var rng: editor.TextObject.Range = undefined;
    if (text_object) |kind| {
        const r = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, count);
        rng = .{ .start = r.start, .end = r.end };
    } else if (motion) |m| {
        const target = editor.Motion.target(&self.cur().pt, m, args, self.curCursor().*, count);
        rng = .{ .start = @min(self.curCursor().*, target), .end = @max(self.curCursor().*, target) };
    } else return null;
    // trim trailing spaces/tabs (not newlines)
    while (rng.end > rng.start) {
        const c = self.cur().pt.byteAt(rng.end - 1);
        if (c != ' ' and c != '\t') break;
        rng.end -= 1;
    }
    return rng;
}

/// ga: align lines [start_line, end_line] on the first `char`.
pub fn execAlign(self: *App, a: anytype) !void {
    var start_line: u32 = undefined;
    var end_line: u32 = undefined;
    if (a.selection) {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.curCursor().*);
        const e = @max(anchor, self.curCursor().*);
        start_line = self.cur().pt.lineOf(s);
        end_line = self.cur().pt.lineOf(e);
        self.exitVisual();
    } else {
        var rng: editor.TextObject.Range = undefined;
        if (a.text_object) |kind| {
            const r = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, a.count);
            rng = .{ .start = r.start, .end = r.end };
        } else if (a.motion) |m| {
            const target = editor.Motion.target(&self.cur().pt, m, a.args, self.curCursor().*, a.count);
            rng = .{ .start = @min(self.curCursor().*, target), .end = @max(self.curCursor().*, target) };
        } else return;
        start_line = self.cur().pt.lineOf(rng.start);
        end_line = self.cur().pt.lineOf(rng.end);
        if (rng.end > rng.start and rng.end == self.cur().pt.lineStart(rng.end)) end_line -|= 1;
    }
    const text = try editor.align_text.alignLines(self.alloc, &self.cur().pt, start_line, end_line, a.char);
    defer self.alloc.free(text);
    const start = self.cur().pt.lineStart(start_line);
    var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
    if (end_line + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
    try self.applyEdit(start, end, text);
    self.curCursor().* = start;
}

pub fn applyEdit(self: *App, start: u32, end: u32, text: []const u8) !void {
    // LSP range in the PRE-EDIT document: [start, end).
    const start_pos = self.lspPositionAt(&self.cur().pt, start);
    const end_pos = self.lspPositionAt(&self.cur().pt, end);
    self.cur().history.beginGroup();
    try self.cur().history.record(&self.cur().pt, start, end - start, text);
    self.cur().history.endGroup();
    self.markDirtyRange(start_pos, end_pos, text);
}

pub fn isVisual(self: *const App) bool {
    return switch (self.state.mode) {
        .visual_char, .visual_line, .visual_block => true,
        else => false,
    };
}

/// gcc: comment/uncomment the current line (vim semantics: fully commented
/// lines get uncommented, otherwise everything is commented).
pub fn toggleCommentLine(self: *App) !void {
    const ft = autil.filetypeOf(self.cur().path);
    const style = editor.comment.styleForFiletype(ft) orelse {
        try self.setMsg(try self.alloc.dupe(u8, "E505: No comment style for filetype"));
        return;
    };
    // in visual mode the whole selection's lines are toggled; otherwise
    // just the cursor line
    const from_line: u32 = if (self.visual_anchor) |anchor|
        @min(self.cur().pt.lineOf(anchor), self.cur().pt.lineOf(self.curCursor().*))
    else
        self.cur().pt.lineOf(self.curCursor().*);
    const to_line: u32 = if (self.visual_anchor) |anchor|
        @max(self.cur().pt.lineOf(anchor), self.cur().pt.lineOf(self.curCursor().*))
    else
        from_line;
    const toggle = try editor.comment.toggleLines(self.alloc, &self.cur().pt, from_line, to_line, style);
    defer self.alloc.free(toggle.text);
    const start = self.cur().pt.lineStart(from_line);
    const end = self.cur().pt.lineStart(to_line) + self.cur().pt.lineLen(to_line); // toggleLines text excludes the trailing '\n'
    try self.applyEdit(start, end, toggle.text);
    self.curCursor().* = start;
}

pub fn exitVisual(self: *App) void {
    self.state.mode = .normal;
    self.visual_anchor = null;
}

/// Visual-mode d/c/y teardown: `.change` keeps the insert mode that
/// applyOpRangeEx/applyBlockOp entered (vim: c on a selection types in
/// insert); only the stale anchor is cleared. Other operators exit to
/// normal.
pub fn exitVisualAfterOp(self: *App, op: editor.KeyEvent.ActionId) void {
    if (op == .change) {
        self.visual_anchor = null;
    } else {
        self.exitVisual();
    }
}

/// Ctrl+n: first press selects the word under the cursor, later presses
/// add the next matching word as another cursor.
pub fn mcSelectNext(self: *App) !void {
    if (!self.mc_active) {
        self.mc.clear();
        _ = try self.mc.add(self.curCursor().*);
        self.mc_active = true;
    } else {
        const added = try self.mc.addNextMatch(&self.cur().pt);
        if (added) {
            // The main cursor follows the newest match (vim's multi-cursor
            // moves the cursor to each new selection as you press n); the
            // render pass keeps the cursor line on screen. `main` stays at
            // the FIRST cursor (the original word), so the newest match is
            // always the last slot.
            self.curCursor().* = self.mc.cursors.items[self.mc.cursors.items.len - 1];
        }
    }
}

/// 'c' with an active multi-cursor selection: delete the word under every
/// cursor (right-to-left, so earlier positions stay valid) and enter
/// insert mode with the cursors still on their word-start slots. Cursors
/// at/after each deleted range shift back so every position stays valid
/// (unlike the 'd' path — 'd' clears the cursors, 'c' keeps them for the
/// synchronized insert session via handleMcInsertKey). The deletion is
/// one undo group; typing opens the next one.
pub fn mcChangeWords(self: *App) !void {
    const pt = &self.cur().pt;
    self.cur().history.beginGroup();
    var i = self.mc.cursors.items.len;
    while (i > 0) {
        i -= 1;
        const pos = self.mc.cursors.items[i];
        const w = self.mc.wordRange(pt, pos);
        if (w.end <= w.start) continue; // no word at this cursor → skip it
        const wlen = w.end - w.start;
        try self.cur().history.record(pt, pos, wlen, "");
        // shift every other cursor at/after the deleted range back; the
        // cursor at `pos` (a word start) stays put
        for (self.mc.cursors.items, 0..) |*c, j| {
            if (j == i) continue;
            if (c.* >= pos + wlen) {
                c.* -= wlen;
            } else if (c.* > pos) {
                c.* = pos; // inside the deleted word — clamp (never happens)
            }
        }
    }
    self.cur().history.endGroup();
    self.mc_active = true; // stays active: the insert session is synchronized
    self.state.mode = .insert;
    // open the insert-session group immediately (deletes or typing first);
    // the word deletions above are their own group (undo reverts typing
    // first, then the deletions — same as before)
    self.cur().history.beginGroup();
    self.in_insert = true;
    self.prev_insert_key = null;
    self.mcSyncCursor();
    self.markDirty();
}
