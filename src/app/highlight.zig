//! highlight — App method group split out of src/main.zig (physical move).

const std = @import("std");
const editor = @import("../editor/root.zig");
const syntax = @import("../syntax.zig");
const term = @import("../term.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");

const Buffer = App.Buffer;

// ---- tree-sitter syntax highlighting ----

/// Merged non-overlapping spans for the visible byte range of `buf`
/// (later spans win overlaps), arena-allocated. Empty when highlighting
/// is inactive (no grammar for the filetype / over the size limit).
///
/// Every buffer owns its highlighter (`Buffer.hl`), so ANY window —
/// focused or not, showing the current buffer or another — gets real
/// tree-sitter highlighting for what it displays. Reparse policy: a
/// single recorded edit since the last parse takes the incremental path
/// (tree.edit + parse); everything else (undo/redo, multi-edit ops, first
/// parse, forced full reparses) falls back to a full reparse — the
/// incremental bookkeeping must never guess.
pub fn visibleSpansFor(self: *App, buf: *Buffer, arena: std.mem.Allocator, view_top: u32, content_rows: u32) ![]syntax.Span {
    if (buf.hl == null) {
        const ft = autil.filetypeOf(buf.path);
        const lang = syntax.languageFor(ft) orelse return &.{};
        if (buf.pt.len() > syntax.SIZE_LIMIT) return &.{};
        buf.hl = syntax.Highlighter.init(self.alloc, lang) catch null;
    }
    const hl = &buf.hl.?;
    const hist = &buf.history;
    const rev = hist.revision;
    const parsed = hl.tree != null;
    if (!(parsed and rev == buf.syntax_revision)) {
        const len = buf.pt.len();
        const text = try self.alloc.alloc(u8, len);
        defer self.alloc.free(text);
        buf.pt.copyRange(0, text);
        const incremental = parsed and
            rev > buf.syntax_revision and
            rev - buf.syntax_revision == 1 and
            hist.last_record != null;
        if (incremental) {
            const e = hist.last_record.?;
            try hl.reparseEdit(e.pos, e.pos + @as(u32, @intCast(e.before.len)), e.pos + @as(u32, @intCast(e.after.len)), text);
        } else {
            try hl.reparse(text);
        }
        buf.syntax_revision = rev;
    }
    const line_count = buf.pt.lineCount();
    // view_top comes from a (possibly unfocused) window and can exceed
    // this buffer's line count after edits elsewhere shrank it — clamp
    // to the last line: lineStart asserts line < lineCount.
    const start = buf.pt.lineStart(@min(view_top, line_count -| 1));
    const vbottom = @min(view_top + content_rows, line_count);
    // lineStart has no EOF sentinel: the last visible line's end is pt.len()
    const end: u32 = if (vbottom >= line_count) buf.pt.len() else buf.pt.lineStart(vbottom);
    // Cache hit: no edit since the last query (revision unchanged) and
    // the same visible byte range — the query+merge below is the
    // dominant frame cost and would be pure waste (every non-scrolling
    // key, every cursor move inside the viewport, every repaint).
    if (buf.spans_cache_valid and buf.spans_cache_rev == rev and
        buf.spans_cache_start == start and buf.spans_cache_end == end)
    {
        return buf.spans_cache;
    }
    var raw = std.ArrayList(syntax.Span).empty;
    try hl.spansInRange(@intCast(start), @intCast(end), arena, &raw);
    var out = std.ArrayList(syntax.Span).empty;
    for (raw.items) |sp| {
        while (out.items.len > 0) {
            var last = &out.items[out.items.len - 1];
            if (sp.start >= last.end) break; // disjoint
            if (sp.start <= last.start) {
                _ = out.pop(); // covers the previous span wholly
                continue;
            }
            last.end = sp.start; // later span wins the overlap
            break;
        }
        try out.append(arena, sp);
    }
    // own a copy so future cache hits return a stable slice (the arena
    // is per-frame; the buffer outlives any frame)
    const cached = try self.alloc.dupe(syntax.Span, out.items);
    if (buf.spans_cache.len > 0) self.alloc.free(buf.spans_cache);
    buf.spans_cache = cached;
    buf.spans_cache_valid = true;
    buf.spans_cache_start = start;
    buf.spans_cache_end = end;
    buf.spans_cache_rev = rev;
    return buf.spans_cache;
}

/// Load recent files from ~/.cache/oz/recent (one path per line).
pub fn loadRecent(self: *App) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = self.env_map.get("HOME") orelse return;
    const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch return;
    defer dir.close(self.io);
    const file = dir.openFile(self.io, "recent", .{ .mode = .read_only }) catch return;
    defer file.close(self.io);
    const size = (try file.stat(self.io)).size;
    if (size == 0) return;
    const content = try self.alloc.alloc(u8, @intCast(size));
    defer self.alloc.free(content);
    _ = try file.readPositionalAll(self.io, content, 0);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const copy = try self.alloc.dupe(u8, line);
        errdefer self.alloc.free(copy);
        self.recent_files.append(self.alloc, copy) catch {};
    }
}

/// Persist recent files to ~/.cache/oz/recent.
pub fn saveRecent(self: *App) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = self.env_map.get("HOME") orelse return;
    const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch blk: {
        try std.Io.Dir.cwd().createDirPath(self.io, dir_path);
        break :blk try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
    };
    defer dir.close(self.io);
    const file = try dir.createFile(self.io, "recent", .{ .truncate = true });
    defer file.close(self.io);
    for (self.recent_files.items) |f| {
        try file.writeStreamingAll(self.io, f);
        try file.writeStreamingAll(self.io, "\n");
    }
}

/// Execute an operator + motion combo over the current buffer/cursor.
/// Shared by normal-mode dispatch and the '.' repeat (which replays the
/// same motion from wherever the cursor now sits).
pub fn execOpMotion(self: *App, m: editor.OpMotion) !void {
    // dd / cc / yy: motion == .line_start + exclusive_end == false is
    // the whole-line sentinel (see mode.zig Result docs; d^ is
    // .line_start with exclusive_end == true, so unambiguous). Must
    // delete/change/yank `count` whole lines, not [cursor, line start).
    if (m.motion == .line_start and !m.exclusive_end) {
        const line = self.cur().pt.lineOf(self.curCursor().*);
        const n = @max(m.count, 1);
        const start_line = @min(line, self.cur().pt.lineCount() - 1);
        const end_line = @min(start_line + n - 1, self.cur().pt.lineCount() - 1);
        const start = self.cur().pt.lineStart(start_line);
        var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
        // dd/yy take the trailing newline (the line is gone from the
        // buffer); cc keeps it — vim's change clears the line's TEXT and
        // puts the cursor on the (now empty) line, not on the next one
        if (m.op != .change and end_line + 1 < self.cur().pt.lineCount()) end += 1;
        try self.applyOpRange(m.op, start, end, false, true); // whole-line → linewise register
        return;
    }
    // text object (diw / ci( / yaw …): resolve at the cursor; the count
    // follows vim (2ciw = two words, 2i( = second nesting level)
    if (m.text_object) |kind| {
        const rng = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, m.count);
        try self.applyOpRange(m.op, rng.start, rng.end, false, false);
        return;
    }
    // visual mode: the operator acts on the selection
    if (self.isVisual()) {
        if (self.visual_anchor) |anchor| {
            if (self.state.mode == .visual_block) {
                try self.applyBlockOp(m.op);
            } else {
                try self.applyOpRangeEx(m.op, anchor, self.curCursor().*, false, .inclusive_cursor, self.state.mode == .visual_line);
            }
        }
        self.exitVisualAfterOp(m.op);
        return;
    }
    // linewise motions (j/k/G/gg/{/}) with an operator from
    // mid-line: the range covers WHOLE lines from the cursor
    // line through the target line (the dd sentinel above already
    // handled the pure line_start case). Deleting a partial
    // byte range across lines would shred the text.
    if (!m.exclusive_end) {
        const from_line = self.cur().pt.lineOf(self.curCursor().*);
        // H/M/L are linewise viewport motions: Motion.target can't
        // resolve them (no viewport), so take the line from the window.
        const to_line = if (self.viewMotionTargetLine(m.motion)) |l|
            l
        else
            self.cur().pt.lineOf(editor.Motion.target(&self.cur().pt, m.motion, m.args, self.curCursor().*, m.count));
        const lo = @min(from_line, to_line);
        const hi = @max(from_line, to_line);
        const start = self.cur().pt.lineStart(lo);
        var end = self.cur().pt.lineStart(hi) + self.cur().pt.lineLen(hi);
        if (hi + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
        try self.applyOpRange(m.op, start, end, false, true); // linewise motion → linewise register
        return;
    }
    // normal mode: d/c/y over [cursor, target). vim semantics:
    // naturally-exclusive motions (w/b/h/l/t/^) yield a half-open
    // range [cursor, target) as-is; inclusive motions ($/e/f/%)
    // include the character at the target (add one). We therefore
    // pass exclusive=false and pre-adjust the target, instead of
    // the old unconditional end-=1 that broke dl/dh/d$/de/dw.
    var target_pos = editor.Motion.target(&self.cur().pt, m.motion, m.args, self.curCursor().*, m.count);
    if (m.inclusive and target_pos < self.cur().pt.len()) target_pos += 1;
    try self.applyOpRange(m.op, self.curCursor().*, target_pos, false, false);
}

pub fn execAction(self: *App, action: editor.KeyEvent.ActionId, count: u32) !void {
    switch (action) {
        .repeat_last => {
            // '.' — replay the last repeatable edit from the current
            // cursor. An operator+motion re-resolves its range; a plain
            // action re-runs with its stored count. Nothing to replay
            // (or the last edit was undo/redo) → no-op, like vim.
            const rep = self.state.last_repeat orelse return;
            switch (rep) {
                .action => |a| try self.execAction(a.action, a.count),
                .op => |o| try self.execOpMotion(o),
            }
        },
        .undo => {
            if (self.in_insert) {
                self.cur().history.endGroup();
                self.in_insert = false;
            }
            _ = self.cur().history.undo(&self.cur().pt);
            self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
            // the document changed: keep LSP/inlay in sync (markDirty
            // also touches the dirty flag — acceptable for undo, vim
            // marks the buffer modified after an undo too)
            self.markDirty();
        },
        .redo => {
            _ = self.cur().history.redo(&self.cur().pt);
            self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
            self.markDirty();
        },
        .insert_mode => {
            // open the undo group immediately so the whole insert session
            // (deletes first or not) is one undo step
            self.beginInsertSession();
            self.cur().history.beginGroup();
            self.in_insert = true;
            self.state.mode = .insert;
        },
        .append => {
            // a: insert after the character under the cursor
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const end = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
            if (self.curCursor().* < end) {
                var i = self.curCursor().* + 1;
                while (i < end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                self.curCursor().* = i;
            }
            self.beginInsertSession();
            self.cur().history.beginGroup();
            self.in_insert = true;
            self.state.mode = .insert;
        },
        .insert_before => {
            // I: first non-blank of the line
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const ls = self.cur().pt.lineStart(line);
            const end = ls + self.cur().pt.lineLen(line);
            var pos = ls;
            while (pos < end) {
                const c = self.cur().pt.byteAt(pos);
                if (c != ' ' and c != '\t') break;
                pos += 1;
            }
            self.curCursor().* = pos;
            self.beginInsertSession();
            self.cur().history.beginGroup();
            self.in_insert = true;
            self.state.mode = .insert;
        },
        .append_end => {
            // A: end of the line
            const line = self.cur().pt.lineOf(self.curCursor().*);
            self.curCursor().* = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            self.in_insert = true;
            self.state.mode = .insert;
        },
        .insert_line_after => {
            // o: new line below, cursor on it. The inserted '\n' joins the
            // insert-session undo group (left open until exitInsert), so
            // one undo reverts the whole o+typing session.
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const pos = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
            const col = pos - self.cur().pt.lineStart(line);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
            // Auto-indent: copy the current line's leading whitespace onto
            // the new line so typing continues at the same indent level.
            const indent = try self.leadingIndent(line);
            defer self.alloc.free(indent);
            try self.cur().history.record(&self.cur().pt, pos + 1, 0, indent);
            self.curCursor().* = pos + 1 + @as(u32, @intCast(indent.len));
            self.in_insert = true;
            self.state.mode = .insert;
            // keep inlay hints aligned (the newline + indent shift lines)
            self.adjustInlayHintsInsert(line, col, "\n");
            self.adjustInlayHintsInsert(line + 1, 0, indent);
            // structural edit (newline): force a full reparse next frame —
            // incremental parsing of a newline is where highlight drift
            // shows up ("o then type then jk leaves gray chars")
            self.cur().syntax_revision = std.math.maxInt(u64);
            // Notify LSP (the new line + indent changed the document).
            self.markDirty();
        },
        .insert_line_before => {
            // O: new line above, cursor on it (same open-group semantics)
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const pos = self.cur().pt.lineStart(line);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
            const indent = try self.leadingIndent(line);
            defer self.alloc.free(indent);
            try self.cur().history.record(&self.cur().pt, pos, 0, indent);
            self.curCursor().* = pos + @as(u32, @intCast(indent.len));
            self.in_insert = true;
            self.state.mode = .insert;
            // keep inlay hints aligned (a line was inserted above)
            self.adjustInlayHintsInsert(line, 0, "\n");
            self.adjustInlayHintsInsert(line, 0, indent);
            // structural edit (newline): force a full reparse next frame
            self.cur().syntax_revision = std.math.maxInt(u64);
            self.markDirty();
        },
        .visual_char => {
            // mode.zig already set state.mode, so isVisual() can't tell a
            // fresh entry from a sub-mode switch; the anchor can: it is
            // null on entry and non-null while a selection exists. Keep
            // the selection when switching v -> V / Ctrl+v.
            if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
            self.state.mode = .visual_char;
        },
        .visual_line => {
            if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
            self.state.mode = .visual_line;
        },
        .visual_block => {
            if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
            self.state.mode = .visual_block;
        },
        // visual 'o': swap the anchor and the cursor (flip the selection
        // end) — handled by mode.handleVisual and dispatched here
        .flip_visual => {
            if (self.visual_anchor) |a| {
                const c = self.curCursor().*;
                self.visual_anchor = c;
                self.curCursor().* = a;
            }
        },
        .delete, .change, .yank => {
            // multi-cursor: d deletes the selected word at every cursor
            if (self.mc_active and action == .delete and self.state.mode == .normal) {
                // delete the WORD at each cursor (cursors sit on word
                // starts): [pos, word_end), not the bytes before the
                // cursor — and through history so it is undoable
                const pt = &self.cur().pt;
                self.cur().history.beginGroup();
                var i = self.mc.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const pos = self.mc.cursors.items[i];
                    const w = self.mc.wordRange(pt, pos);
                    if (w.end <= w.start) continue;
                    try self.cur().history.record(pt, w.start, w.end - w.start, "");
                    for (self.mc.cursors.items, 0..) |*c, j| {
                        if (j == i) continue;
                        if (c.* >= w.end) c.* -= w.end - w.start;
                    }
                }
                self.cur().history.endGroup();
                self.mc.clear();
                self.mc_active = false;
                self.markDirty();
                return;
            }
            // visual mode: the operator acts on the selection directly.
            // A visual-block selection is a rectangle — d/c/y apply to
            // every covered line's column slice, not one byte range.
            if (self.isVisual()) {
                if (self.visual_anchor) |anchor| {
                    if (self.state.mode == .visual_block) {
                        try self.applyBlockOp(action);
                    } else if (self.state.mode == .visual_line) {
                        // V selects whole lines: the range spans from the
                        // anchor line's start to the cursor line's end
                        // (including the trailing newline when present),
                        // not just anchor..cursor bytes — otherwise the
                        // last selected line survives a d/c.
                        const pt = &self.cur().pt;
                        const al = pt.lineOf(anchor);
                        const cl = pt.lineOf(self.curCursor().*);
                        const start = pt.lineStart(al);
                        var end = pt.lineStart(cl) + pt.lineLen(cl);
                        if (end < pt.len()) end += 1; // include the newline
                        // exclusive_cursor: the range already ends exactly
                        // after the last selected line's newline.
                        try self.applyOpRangeEx(action, start, end, false, .exclusive_cursor, true);
                    } else {
                        try self.applyOpRangeEx(action, anchor, self.curCursor().*, false, .inclusive_cursor, false);
                    }
                }
                self.exitVisualAfterOp(action);
            }
        },
        .mc_add => try self.mcSelectNext(),
        .increment, .decrement => {
            // Ctrl+a / Ctrl+x: a visual selection increments every number
            // in every selected line; otherwise the number at/after the
            // cursor. `count` is the delta (vim: 5<C-a> adds 5).
            const delta: i64 = if (action == .increment) @as(i64, count) else -@as(i64, count);
            if (self.isVisual()) {
                try self.execSelectionNumberDelta(delta);
                self.exitVisual();
            } else {
                try self.execNumberDeltaAtCursor(delta);
            }
        },
        .increment_visual, .decrement_visual => {
            // g Ctrl+a / g Ctrl+x: visual column increment — each line's
            // first number gets ±(count + line offset, 1-based). Normal
            // mode g Ctrl+a is plain Ctrl+a (vim).
            const delta: i64 = if (action == .increment_visual) @as(i64, count) else -@as(i64, count);
            if (self.isVisual()) {
                try self.execSelectionNumberColumn(delta);
                self.exitVisual();
            } else {
                try self.execNumberDeltaAtCursor(delta);
            }
        },
        .next_buffer => try self.switchBuffer(1),
        .prev_buffer => try self.switchBuffer(-1),
        .picker_file => try self.openPicker(),
        .picker_grep => try self.openGrepPicker(),
        .picker_buffers => try self.openBufferPicker(),
        .picker_recent => try self.openRecentPicker(),
        .picker_keymaps => try self.openKeymapPicker(),
        .picker_themes => try self.openThemePicker(),
        .diagnostic_next => self.gotoDiagnostic(true),
        .diagnostic_prev => self.gotoDiagnostic(false),
        .search_next => try self.repeatSearch(false),
        .search_prev => try self.repeatSearch(true),
        .diagnostic_line => self.showLineDiagnostics(),
        .diagnostics_list => self.toggleDiagnosticsList(),
        .hover => try self.requestNav("textDocument/hover", .hover),
        .definition => try self.requestNav("textDocument/definition", .definition),
        .declaration => try self.requestNav("textDocument/declaration", .declaration),
        .references => try self.requestNav("textDocument/references", .references),
        .implementation => try self.requestNav("textDocument/implementation", .implementation),
        .signature_help => try self.requestNav("textDocument/signatureHelp", .signature),
        .rename_symbol => try self.requestRename(),
        .format_document => try self.requestFormat(),
        .inlay_hints => try self.requestInlayHints(),
        .document_outline => try self.requestOutline(),
        .close_buffer => self.closeCurrentBuffer(),
        .buffer_to_left_win => self.moveBufferToWindow(.left),
        .buffer_to_right_win => self.moveBufferToWindow(.right),
        .filetree_toggle => try self.toggleFiletree(),
        .filetree_locate => try self.locateInFiletree(),
        // M3 git
        .hunk_next => self.gotoHunk(true),
        .hunk_prev => self.gotoHunk(false),
        .hunk_stage => self.applyHunk(.stage),
        .hunk_reset => self.applyHunk(.reset),
        .hunk_preview => self.previewHunk(),
        .blame_toggle => self.toggleBlame(),
        .git_lazygit => self.launchLazygit(),
        // M3b embedded terminal
        .term_float => if (term.supported) try self.toggleTerm(.floating) else {},
        .term_bottom => if (term.supported) try self.toggleTerm(.bottom) else {},
        .term_right => if (term.supported) try self.toggleTerm(.right) else {},
        .paste => try self.pasteBuffer(false, count),
        .paste_before => try self.pasteBuffer(true, count),
        .delete_char => {
            // x: vim dl — delete `count` characters under the cursor. At
            // the end of a line the newline is deleted (joining the next
            // line), like vim; at EOF nothing happens. One undo group.
            // The deleted text fills the unnamed register (charwise) —
            // vim's xp char-swap depends on it. Capture BEFORE deleting:
            // setRegister reads the live piece table.
            const c0 = self.curCursor().*;
            var reg_end = c0;
            var i: u32 = 0;
            while (i < @max(count, 1)) : (i += 1) {
                if (reg_end >= self.cur().pt.len()) break;
                const seq = self.charLenAt(&self.cur().pt, reg_end);
                reg_end = @min(reg_end + seq, self.cur().pt.len());
            }
            if (reg_end > c0) try self.setRegister(c0, reg_end, false);
            // LSP range in the PRE-EDIT document: [c0, reg_end).
            const start_pos = self.lspPositionAt(&self.cur().pt, c0);
            const end_pos = self.lspPositionAt(&self.cur().pt, reg_end);
            self.cur().history.beginGroup();
            i = 0;
            while (i < @max(count, 1)) : (i += 1) {
                const c = self.curCursor().*;
                if (c >= self.cur().pt.len()) break;
                const pt = &self.cur().pt;
                const seq = self.charLenAt(pt, c);
                const end = @min(c + seq, pt.len());
                if (end <= c) break;
                try self.cur().history.record(pt, c, end - c, "");
            }
            self.cur().history.endGroup();
            self.markDirtyRange(start_pos, end_pos, "");
        },
        .delete_char_before => {
            // X: vim dh — delete `count` chars before the cursor (the
            // deleted text fills the unnamed register, charwise; capture
            // BEFORE deleting — setRegister reads the live piece table)
            const c0 = self.curCursor().*;
            var reg_start = c0;
            var i: u32 = 0;
            while (i < @max(count, 1)) : (i += 1) {
                if (reg_start == 0) break;
                reg_start -= 1;
                while (reg_start > 0 and (self.cur().pt.byteAt(reg_start) & 0xC0) == 0x80) reg_start -= 1;
            }
            if (reg_start < c0) try self.setRegister(reg_start, c0, false);
            // LSP range in the PRE-EDIT document: [reg_start, c0).
            const start_pos = self.lspPositionAt(&self.cur().pt, reg_start);
            const end_pos = self.lspPositionAt(&self.cur().pt, c0);
            self.cur().history.beginGroup();
            i = 0;
            while (i < @max(count, 1)) : (i += 1) {
                const c = self.curCursor().*;
                if (c == 0) break;
                const pt = &self.cur().pt;
                // walk back to the start of the previous UTF-8 character
                var start = c - 1;
                while (start > 0 and (pt.byteAt(start) & 0xC0) == 0x80) start -= 1;
                try self.cur().history.record(pt, start, c - start, "");
                self.curCursor().* = start;
            }
            self.cur().history.endGroup();
            self.markDirtyRange(start_pos, end_pos, "");
        },
        .delete_to_eol => {
            // D: delete to end of line (d$), keeping the newline so the
            // line is emptied, not removed. vim count: `count` lines
            // from the cursor (3D = delete to EOL on three lines). The
            // deleted text fills the unnamed register (charwise).
            const c = self.curCursor().*;
            const pt = &self.cur().pt;
            const line = pt.lineOf(c);
            const end_line = @min(line + @max(count, 1) - 1, pt.lineCount() - 1);
            const end = pt.lineStart(end_line) + pt.lineLen(end_line);
            if (end > c) {
                try self.setRegister(c, end, false);
                // LSP range in the PRE-EDIT document: [c, end).
                const start_pos = self.lspPositionAt(&self.cur().pt, c);
                const end_pos = self.lspPositionAt(&self.cur().pt, end);
                self.cur().history.beginGroup();
                try self.cur().history.record(pt, c, end - c, "");
                self.cur().history.endGroup();
                self.curCursor().* = c;
                self.markDirtyRange(start_pos, end_pos, "");
            }
        },
        .change_to_eol => {
            // C: change to end of line (c$) — vim count: `count` lines
            // (3C = change to EOL on three lines). Delete the tail and
            // enter insert with the undo group open, like applyOpRangeEx.
            const c = self.curCursor().*;
            const pt = &self.cur().pt;
            const line = pt.lineOf(c);
            const end_line = @min(line + @max(count, 1) - 1, pt.lineCount() - 1);
            const end = pt.lineStart(end_line) + pt.lineLen(end_line);
            // LSP range in the PRE-EDIT document: [c, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, c);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            self.cur().history.beginGroup();
            if (end > c) {
                try self.cur().history.record(pt, c, end - c, "");
            }
            self.state.mode = .insert;
            self.in_insert = true; // group stays open until exitInsert
            // markDirty (via markDirtyBase) skips inlay invalidation
            // while in_insert, matching the pre-edit behavior of C.
            if (end > c) {
                self.markDirtyRange(start_pos, end_pos, "");
            } else {
                self.markDirtyBase(); // no edit; just the bookkeeping
            }
            self.cur().syntax_revision = std.math.maxInt(u64);
        },
        .change_line => {
            // S: change the whole line (cc) — delete the line's CONTENT
            // (the newline stays, like vim cc) and enter insert with the
            // cursor on the emptied line.
            const pt = &self.cur().pt;
            const line = pt.lineOf(self.curCursor().*);
            const start = pt.lineStart(line);
            const end = start + pt.lineLen(line);
            self.curCursor().* = start;
            // LSP range in the PRE-EDIT document: [start, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, start);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            self.cur().history.beginGroup();
            try self.cur().history.record(pt, start, end - start, "");
            self.state.mode = .insert;
            self.in_insert = true;
            self.markDirtyRange(start_pos, end_pos, "");
            self.cur().syntax_revision = std.math.maxInt(u64);
        },
        .replace_char => {
            // r{char}: arm the pending-replace capture; the next plain
            // key (handled before the mode dispatch) replaces the char
            // under the cursor via replaceCharsAtCursor. `count` chars
            // are replaced (vim 3rx).
            self.pending_replace = .{ .count = count };
        },
        .toggle_case => {
            // ~: swap the case of `count` chars under the cursor,
            // advancing (vim ~). One undo group.
            self.cur().history.beginGroup();
            var i: u32 = 0;
            while (i < @max(count, 1)) : (i += 1) {
                const c = self.curCursor().*;
                const pt = &self.cur().pt;
                if (c >= pt.len()) break;
                const seq = self.charLenAt(pt, c);
                if (seq != 1) break; // multi-byte: not ASCII, leave alone
                var buf: [1]u8 = undefined;
                pt.copyRange(c, buf[0..1]);
                var swapped: ?u8 = null;
                if (buf[0] >= 'a' and buf[0] <= 'z') {
                    swapped = buf[0] - 32;
                } else if (buf[0] >= 'A' and buf[0] <= 'Z') {
                    swapped = buf[0] + 32;
                }
                if (swapped) |ch| {
                    try self.cur().history.record(pt, c, 1, &.{ch});
                    self.curCursor().* = c + seq;
                } else {
                    self.curCursor().* = c + seq;
                }
            }
            self.cur().history.endGroup();
            self.markDirty();
        },
        .join_lines => {
            // J: join the current line with the next: remove the newline,
            // trim the next line's leading whitespace to one space (vim
            // joins with a single space when the first line is non-empty).
            const pt = &self.cur().pt;
            const line = pt.lineOf(self.curCursor().*);
            if (line + 1 >= pt.lineCount()) return;
            const cur_end = pt.lineStart(line) + pt.lineLen(line);
            const next_start = pt.lineStart(line + 1);
            const next_len = pt.lineLen(line + 1);
            var next_indent: u32 = 0;
            while (next_indent < next_len) : (next_indent += 1) {
                const b = pt.byteAt(next_start + next_indent);
                if (b != ' ' and b != '\t') break;
            }
            self.cur().history.beginGroup();
            // remove the newline (cur_end, one byte)
            try self.cur().history.record(pt, cur_end, 1, "");
            // collapse leading whitespace of the next line
            if (next_indent > 0) {
                try self.cur().history.record(pt, next_start - 1, next_indent, "");
            }
            // join with a single space unless the first line is empty.
            // The next line's first char now sits at next_start - 1 (the
            // newline is gone); inserting BEFORE it glues the lines.
            if (cur_end > pt.lineStart(line)) {
                try self.cur().history.record(pt, next_start - 1, 0, " ");
            }
            self.cur().history.endGroup();
            self.curCursor().* = @min(self.curCursor().*, pt.len());
            self.markDirty();
        },
        .indent_line, .dedent_line => {
            // >> / <<: add / remove one indent unit (4 spaces, matching
            // the insert-mode tab) at the start of each line the count
            // covers, starting at the cursor line.
            const pt = &self.cur().pt;
            const start_line = pt.lineOf(self.curCursor().*);
            const n = @max(count, 1);
            const end_line = @min(start_line + n - 1, pt.lineCount() - 1);
            const indent = if (action == .indent_line) "    " else "";
            self.cur().history.beginGroup();
            var l = start_line;
            while (l <= end_line) : (l += 1) {
                const ls = pt.lineStart(l);
                if (action == .indent_line) {
                    try self.cur().history.record(pt, ls, 0, indent);
                } else {
                    // remove up to 4 leading spaces/tabs
                    var removed: u32 = 0;
                    while (removed < 4) : (removed += 1) {
                        if (ls >= pt.len()) break;
                        const b = pt.byteAt(ls);
                        if (b == ' ' or b == '\t') {
                            try self.cur().history.record(pt, ls, 1, "");
                        } else break;
                    }
                }
            }
            self.cur().history.endGroup();
            self.curCursor().* = @min(self.curCursor().*, pt.len());
            self.markDirty();
        },
        .toggle_comment_line => try self.toggleCommentLine(),
        .easymotion, .leader_find => {
            // start the EasyMotion capture flow
            self.em_active = true;
            self.em_labels = false;
            self.em_query = .{ 0, 0, 0, 0 };
            self.em_query_len = 0;
        },
        .enter_command_mode => {},
        // zz/zt/zb — view-only scrolls of the focused window
        .scroll_cursor_center => self.scrollCursorTo(.center),
        .scroll_cursor_top => self.scrollCursorTo(.top),
        .scroll_cursor_bottom => self.scrollCursorTo(.bottom),
        // za/zo/zc/zR/zM — buffer fold state (not edits; no markDirty)
        .fold_toggle, .fold_open, .fold_close, .fold_open_all, .fold_close_all => try self.execFold(action),
        else => {},
    }
}

/// r{char}: replace the character under the cursor with `ch` (a single
/// byte; multi-byte replacements keep the original sequence length).
/// Like vim, the cursor stays on the replaced char (it does not move).
/// r{char} with a vim count (3rx): replace `count` characters under the
/// cursor with `ch`, one undo group. The cursor stays on the LAST
/// replaced character (vim r: 3rx leaves it on the third replacement).
pub fn replaceCharsAtCursor(self: *App, ch: u8, count: u32) !void {
    const pt = &self.cur().pt;
    self.cur().history.beginGroup();
    var c = self.curCursor().*;
    var i: u32 = 0;
    while (i < @max(count, 1)) : (i += 1) {
        if (c >= pt.len()) break;
        const seq = self.charLenAt(pt, c);
        if (seq != 1) break; // only replace single-byte chars
        if (pt.byteAt(c) != ch) {
            try self.cur().history.record(pt, c, 1, &.{ch});
        }
        c += 1;
    }
    self.cur().history.endGroup();
    self.curCursor().* = c -| 1;
    self.markDirty();
}
