//! search — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const indent = @import("../editor/indent.zig");
const autil = @import("util.zig");

const InlayHint = app_mod.InlayHint;

// ---- buffer search (/ ? n N) ----

/// Last confirmed query is never changed by a preview. Each buffer owns its
/// revision-keyed index, so splits/workspaces cannot borrow another file's hits.
pub fn activeSearchQuery(self: *App) ?[]const u8 {
    if (self.state.mode == .command and self.cmdline_kind != .ex)
        return if (self.cmdline.items.len > 0) self.cmdline.items else null;
    return if (self.search_hl_active) self.last_search else null;
}

pub fn beginSearch(self: *App) void {
    const w = &self.windows.items[self.current_win];
    self.cmd_register_pending = false;
    self.search_origin = .{
        .workspace = self.current_ws,
        .win_id = w.id,
        .buf = w.buf,
        .view = .{ .cursor = w.cursor, .view_top = w.view_top, .view_wrap = w.view_wrap, .view_pinned = w.view_pinned },
    };
}

pub fn restoreSearchOrigin(self: *App) void {
    const origin = self.search_origin orelse return;
    const w = &self.windows.items[self.current_win];
    if (self.current_ws != origin.workspace or w.id != origin.win_id or w.buf != origin.buf) return;
    const snap = @import("view_state.zig").clamp(&self.cur().pt, origin.view);
    w.cursor = snap.cursor;
    w.view_top = snap.view_top;
    w.view_wrap = snap.view_wrap;
    w.view_pinned = snap.view_pinned;
}

pub fn previewSearch(self: *App) !void {
    if (self.state.mode != .command or self.cmdline_kind == .ex) return;
    self.restoreSearchOrigin();
    const query = self.activeSearchQuery() orelse return;
    const buf = self.cur();
    try buf.search_index.ensure(self.alloc, &buf.pt, buf.history.revision, query);
    if (buf.search_index.next(self.curCursor().*, self.cmdline_kind == .search_bwd)) |hit| {
        self.curCursor().* = hit;
        self.clearHover();
    }
}

/// Enter confirms from the original anchor, not the preview cursor; otherwise
/// it would skip the match already shown. Empty Enter repeats the last query.
pub fn execSearch(self: *App, input: []const u8, backward: bool) !void {
    const query = if (input.len > 0) input else self.last_search orelse {
        try self.setMsg(try self.alloc.dupe(u8, "no previous search"));
        return;
    };
    const owned = try self.alloc.dupe(u8, query); // input may alias last_search
    if (self.last_search) |old| self.alloc.free(old);
    self.last_search = owned;
    self.last_search_bwd = backward;
    try self.searchOnce(owned, backward);
}

pub fn repeatSearch(self: *App, flip: bool) !void {
    const q = self.last_search orelse {
        try self.setMsg(try self.alloc.dupe(u8, "no previous search"));
        return;
    };
    try self.searchOnce(q, self.last_search_bwd != flip);
}

pub fn searchOnce(self: *App, query: []const u8, backward: bool) !void {
    const buf = self.cur();
    try buf.search_index.ensure(self.alloc, &buf.pt, buf.history.revision, query);
    self.search_hl_active = true;
    if (buf.search_index.next(self.curCursor().*, backward)) |hit| {
        self.curCursor().* = hit;
        self.clearHover();
        try self.setMsg(try self.alloc.dupe(u8, ""));
    } else {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "pattern not found: {s}", .{query}));
    }
}

pub fn searchCountText(self: *App, a: std.mem.Allocator) !?[]const u8 {
    const query = self.activeSearchQuery() orelse return null;
    const buf = self.cur();
    try buf.search_index.ensure(self.alloc, &buf.pt, buf.history.revision, query);
    return try std.fmt.allocPrint(a, "[{d}/{d}]", .{ buf.search_index.ordinal(self.curCursor().*), buf.search_index.starts.items.len });
}

/// Leading spaces/tabs of `line` (owned copy) — used to auto-indent new
/// lines opened with o/O.
pub fn leadingIndent(self: *App, line: u32) ![]u8 {
    const pt = &self.cur().pt;
    const start = pt.lineStart(line);
    const len = pt.lineLen(line);
    var n: usize = 0;
    while (n < len) : (n += 1) {
        const c = pt.byteAt(start + @as(u32, @intCast(n)));
        if (c != ' ' and c != '\t') break;
    }
    const out = try self.alloc.alloc(u8, n);
    pt.copyRange(start, out);
    return out;
}

/// Drop stale inlay hints after any edit: their line/column offsets refer
/// to the pre-edit text, so a leftover hint would render at the wrong spot
/// (an inserted line pushes every hint down by one). The auto-refresh in
/// the run loop re-requests hints for the new viewport.
///
/// Also runs on every buffer/window switch (switchTo, switchWindowTo,
/// closeBufferAt, teardownLsp): the list then holds the PREVIOUS buffer's
/// hints, which must never render over the newly focused buffer — the
/// switch's inlay_buf tag is cleared here so renderers stop drawing them,
/// and the band fields are reset so the run loop re-requests for the new
/// buffer. adjustInlayHintsInsert/Delete keep operating on whatever list
/// is present — by construction it can only hold the CURRENT buffer's
/// hints (an accepted response is tagged with the buffer it was fetched
/// for, and any switch that would change that clears the list first).
pub fn invalidateInlayHints(self: *App) void {
    for (self.inlay_hints.items) |*h| self.alloc.free(h.label);
    self.inlay_hints.clearRetainingCapacity();
    self.inlay_buf = null;
    self.inlay_view_top = null;
    self.inlay_stale = true;
}

/// Re-anchor inlay hints for a WHOLE-LINE open (`o` / `O`).
///
/// Unlike a text insertion, no bytes are inserted inside the edited line:
/// a hint anchored at its end (zls emits the type hint at the end of the
/// declared name, which can be the last token on a line) belongs to that
/// line, not to character 0 of the new empty row. Moving it there made the
/// insert cursor count the stale label's width and ride in the middle of
/// the new line (the "insert mode looks garbled" report). Hints move only
/// by LINE: lines below the insertion shift down one; for O the edited
/// line shifts too. Columns are untouched (CRLF offsets included).
pub fn adjustInlayHintsLineOpen(self: *App, line: u32, above: bool) void {
    for (self.inlay_hints.items) |*h| {
        if (h.line > line or (above and h.line == line)) h.line += 1;
    }
}

/// Shift inlay hints after inserting `text` at the pre-edit position
/// (line, col). Same-line inserts shift later hints right; newline
/// inserts push hints below down a line (and re-anchor those past the
/// split point onto the new line). Kept hints stay aligned while typing,
/// which is what keeps the insert-mode view from flickering.
pub fn adjustInlayHintsInsert(self: *App, line: u32, col: u32, text: []const u8) void {
    if (self.inlay_hints.items.len == 0) return;
    const nl = std.mem.count(u8, text, "\n");
    if (nl == 0) {
        for (self.inlay_hints.items) |*h| {
            if (h.line == line and h.character >= col) {
                h.character += @intCast(text.len);
            }
        }
        return;
    }
    // text contains newline(s): the tail after the last '\n' stays on the
    // current line past the split point
    const tail = text.len - (std.mem.lastIndexOfScalar(u8, text, '\n') orelse return) - 1;
    const tail_u32: u32 = @intCast(tail);
    for (self.inlay_hints.items) |*h| {
        if (h.line > line) {
            h.line += @intCast(nl);
        } else if (h.line == line and h.character >= col) {
            h.line += @intCast(nl);
            h.character = h.character - col + tail_u32;
        }
    }
}

/// Shift inlay hints after deleting `deleted` (the pre-edit bytes) from
/// (line, col). Hints inside the deleted span are dropped; same-line
/// deletes shift later hints left; multi-line deletes pull hints below up.
pub fn adjustInlayHintsDelete(self: *App, line: u32, col: u32, deleted: []const u8) void {
    if (self.inlay_hints.items.len == 0) return;
    const nl = std.mem.count(u8, deleted, "\n");
    if (nl == 0) {
        // same-line delete: drop hints inside [col, col+len), shift the
        // rest left
        var write: usize = 0;
        for (self.inlay_hints.items) |*h| {
            if (h.line != line or h.character < col or h.character >= col + deleted.len) {
                if (h.line == line and h.character >= col) h.character -= @intCast(deleted.len);
                self.inlay_hints.items[write] = h.*;
                write += 1;
            } else {
                self.alloc.free(h.label); // inside the deleted span
            }
        }
        self.inlay_hints.shrinkRetainingCapacity(write);
        return;
    }
    // multi-line delete: the span covers the tail of `line` from `col`,
    // all of lines (line, line+nl), and the head of line (line+nl) up to
    // its end column E. Middle lines are dropped entirely; the last
    // line's surviving tail re-anchors onto `line` at col + offset.
    const last_nl = std.mem.lastIndexOfScalar(u8, deleted, '\n') orelse return;
    const end_col: u32 = @intCast(deleted.len - last_nl - 1);
    const last_line = line + nl;
    var write: usize = 0;
    for (self.inlay_hints.items) |*h| {
        if (h.line < line or (h.line == line and h.character < col)) {
            self.inlay_hints.items[write] = h.*;
            write += 1;
            continue;
        }
        if (h.line == last_line and h.character >= end_col) {
            h.line = line;
            h.character = col + (h.character - end_col);
            self.inlay_hints.items[write] = h.*;
            write += 1;
            continue;
        }
        if (h.line > last_line) {
            h.line -= @intCast(nl);
            self.inlay_hints.items[write] = h.*;
            write += 1;
            continue;
        }
        self.alloc.free(h.label); // inside the deleted span
    }
    self.inlay_hints.shrinkRetainingCapacity(write);
}

/// Inlay hints for one line, sorted by insertion column (ascending), as
/// arena slices so they live for the frame. Hints with a character inside
/// the line's text are kept at that column — the renderer splices them in.
pub fn lineHints(self: *App, a: std.mem.Allocator, line: u32) ![]InlayHint {
    // common fast path: no hints in the buffer at all — skip the
    // ArrayList dance entirely (this is called once per rendered row)
    if (self.inlay_hints.items.len == 0) return &.{};
    var out = std.ArrayList(InlayHint).empty;
    for (self.inlay_hints.items) |hint| {
        if (hint.line != line) continue;
        try out.append(a, hint);
    }
    std.mem.sort(InlayHint, out.items, {}, struct {
        fn lt(_: void, x: InlayHint, y: InlayHint) bool {
            return x.character < y.character;
        }
    }.lt);
    return out.toOwnedSlice(a);
}

/// Resolve `path` (possibly relative to the process cwd) into an absolute
/// path. Returns a heap copy; the caller owns it. Falls back to a plain
/// dupe on failure so file opening never breaks on a resolution error.
pub fn absolutePath(self: *App, path: []const u8) ![]u8 {
    const expanded = try @import("path_completion.zig").homeExpansion(self.alloc, path, self.env_map.get("HOME"));
    defer if (expanded) |p| self.alloc.free(p);
    const input = expanded orelse path;
    if (input.len > 0 and input[0] == '/') return self.alloc.dupe(u8, input);
    var cwd_buf: [4096:0]u8 = undefined;
    // libc getcwd — portable (the binary links libc). A raw
    // std.os.linux.getcwd issues the LINUX syscall number: on macOS that
    // number maps to an unrelated syscall, so the buffer stays garbage
    // with no NUL and the resolved path is thousands of bogus bytes
    // (createFile then failed with NameTooLong on :w).
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) return self.alloc.dupe(u8, input);
    // getcwd NUL-terminates on success; trim to the C-string length
    // before joining so no \0 lands inside the path (an embedded NUL
    // later fails as BadPathName on createFile/write — openat just
    // truncates at the NUL, so opening still works while the saved path
    // is silently corrupt).
    var n: usize = 0;
    while (n < cwd_buf.len and cwd_buf[n] != 0) : (n += 1) {}
    return std.Io.Dir.path.resolve(self.alloc, &.{ cwd_buf[0..n], input }) catch
        self.alloc.dupe(u8, input);
}

/// :w — write the current buffer. Returns false (with a status message)
/// when there is no file name or the write fails, so callers like :wq
/// must NOT proceed to quit on failure.
pub fn writeBuffer(self: *App) !bool {
    return writeBufferForce(self, false);
}

pub fn writeBufferForce(self: *App, force: bool) !bool {
    const path = self.cur().path orelse {
        try self.setMsg(try self.alloc.dupe(u8, "E32: No file name"));
        return false;
    };
    saveFileForce(self, path, force) catch |e| {
        if (e == error.FileChanged) {
            try self.setMsg(try self.alloc.dupe(u8, "E13: file changed on disk; :w! to overwrite"));
            return false;
        }
        if (e == error.PathChanged) {
            try self.setMsg(try self.alloc.dupe(u8, "write refused: file target changed; reopen the file"));
            return false;
        }
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "write failed: {s}", .{@errorName(e)}));
        return false;
    };
    self.cur().dirty = false;
    // A saved note changed the list's title/snippet/mtime: refresh the
    // navigator cache now (only for paths under the notes dir).
    self.notesDidSave(path);
    self.navigator_git.refresh(self.io);
    // the file on disk changed: refresh git marks/branch (async)
    self.scheduleGitStatus();
    try self.setMsg(try std.fmt.allocPrint(self.alloc, "written: {s}", .{path}));
    return true;
}

pub fn saveFile(self: *App, path: []const u8) !void {
    return saveFileForce(self, path, false);
}

fn saveFileForce(self: *App, path: []const u8, force: bool) !void {
    const len = self.cur().pt.len();
    const buf = try self.alloc.alloc(u8, len);
    defer self.alloc.free(buf);
    self.cur().pt.copyRange(0, buf);
    const disk = if (self.cur().disk) |*d| d else return error.MissingDiskBaseline;
    try disk.write(self.alloc, self.io, path, buf, force);
}

pub fn openFile(self: *App, path: []const u8) !void {
    // Multi-buffer semantics: open in a new buffer (or switch if open).
    try self.openInBuffer(path);
}

pub fn insertText(self: *App, text: []const u8) !void {
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const pos = self.curCursor().*;
    const line = self.cur().pt.lineOf(pos);
    const col = pos - self.cur().pt.lineStart(line);
    // LSP range for a pure insert: [pos, pos) in the pre-edit document
    // (an insert changes nothing before `pos`, so the position is the
    // same before and after the edit).
    const at = self.lspPositionAt(&self.cur().pt, pos);
    // record() snapshots the pre-edit state and applies the edit itself
    try self.recordEdit(pos, 0, text);
    self.curCursor().* += @intCast(text.len);
    // keep inlay hints aligned instead of clearing them (insert mode:
    // clearing + re-requesting on every keystroke makes the view flicker)
    self.adjustInlayHintsInsert(line, col, text);
    self.markDirtyRange(at, at, text);
}

/// Bounded materialization of the current buffer for the pure indentation
/// planner. Returns null above the planner limit; callers then keep the old
/// bounded insert path instead of copying a huge document per paste.
pub fn indentDocSlice(self: *App) !?[]u8 {
    const pt = &self.cur().pt;
    if (pt.len() > indent.max_insert_bytes) return null;
    const doc = try self.alloc.alloc(u8, pt.len());
    if (doc.len > 0) pt.copyRange(0, doc);
    return doc;
}

/// Indentation style detected around `line`: tabs win when the current line
/// (or a near, non-blank line above it) starts with a tab. The editor's tab
/// width is the space fallback.
pub fn indentConfigFor(self: *App, doc: []const u8, line: u32) indent.Config {
    var cfg = indent.Config{ .indent_width = @intCast(app_mod.tab_width), .use_tabs = false };
    const pt = &self.cur().pt;
    var l = line;
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const start: usize = pt.lineStart(l);
        const len: usize = pt.lineLen(l);
        var i = start;
        var non_blank = false;
        while (i < start + len) : (i += 1) {
            const c = doc[i];
            if (c == '\t') {
                cfg.use_tabs = true;
                return cfg;
            }
            if (c != ' ') {
                non_blank = true;
                break;
            }
        }
        if (non_blank or l == 0) break;
        l -= 1;
    }
    return cfg;
}

/// Plan one language-aware paste at `at`. The caller owns `text`.
pub fn planPasteAt(
    self: *App,
    doc: []const u8,
    at: u32,
    text: []const u8,
    ft: []const u8,
    linewise: bool,
) !indent.PastePlan {
    const cfg = indentConfigFor(self, doc, self.cur().pt.lineOf(at));
    return indent.planPaste(self.alloc, doc, at, text, ft, cfg, linewise);
}

/// Apply one paste edit as a SINGLE history record (one undo step, one LSP
/// pre-edit range). `delete_len` replaces the all-blank prefix of a
/// whitespace-only line (0 for ordinary inserts); the caller sets the cursor
/// according to the paste kind afterwards.
pub fn recordPasteEditNoCursor(self: *App, at: u32, delete_len: u32, text: []const u8) !void {
    const pt = &self.cur().pt;
    const line = pt.lineOf(at);
    const line_start = pt.lineStart(line);
    const col = at - line_start;
    // LSP coordinates in the PRE-EDIT document: [at, at+delete_len) -> text.
    const start_pos = self.lspPositionAt(pt, at);
    const end_pos = self.lspPositionAt(pt, at + delete_len);
    if (delete_len > 0) {
        const deleted = try self.alloc.alloc(u8, delete_len);
        defer self.alloc.free(deleted);
        pt.copyRange(at, deleted);
        try self.recordEdit(at, delete_len, text);
        self.adjustInlayHintsDelete(line, col, deleted);
    } else {
        try self.recordEdit(at, 0, text);
    }
    self.adjustInlayHintsInsert(line, col, text);
    self.markDirtyRange(start_pos, end_pos, text);
}

/// One language-aware paste insertion inside the current insert-session
/// group (the caller opens/closes the group). No per-key simulation, no
/// auto-pair/shortcut effects.
fn pasteInsert(self: *App, text: []const u8) !void {
    if (!self.in_insert) {
        self.cur().history.beginGroup();
        self.in_insert = true;
    }
    const ft = autil.filetypeOf(self.cur().path);
    const doc_opt = try indentDocSlice(self);
    if (doc_opt) |doc| {
        defer self.alloc.free(doc);
        const plan = try planPasteAt(self, doc, self.curCursor().*, text, ft, false);
        defer self.alloc.free(plan.text);
        try recordPasteEditNoCursor(self, plan.at, plan.delete_len, plan.text);
        self.curCursor().* = plan.at + @as(u32, @intCast(plan.text.len));
        return;
    }
    // Oversized buffer: bounded fallback, identical to the old verbatim path.
    try self.insertText(text);
}

/// Bracketed paste: insert `text` with the current language's structural
/// reindent. None of the typed-input transforms apply (no auto-indent per
/// newline, no auto-pairs, no completion triggers). If the insertion point
/// is inside the leading whitespace of a whitespace-only line, that prefix
/// is replaced by the reindented first line (never doubled). Line endings
/// are normalized to the buffer's dominant style by the planner (CRLF
/// buffers stay CRLF; LF buffers keep LF). In insert mode the paste joins
/// the session's undo group; in normal mode it is one undo group of its own
/// and the mode stays normal.
pub fn pasteText(self: *App, text: []const u8) !void {
    if (text.len == 0) return;
    var norm: []const u8 = text;
    var norm_buf: ?[]u8 = null;
    defer if (norm_buf) |nb| self.alloc.free(nb);
    if (std.mem.indexOfScalar(u8, text, '\r') != null) {
        const nb = try self.alloc.alloc(u8, text.len);
        var len: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                if (i + 1 >= text.len or text[i + 1] != '\n') {
                    nb[len] = '\n';
                    len += 1;
                }
            } else {
                nb[len] = text[i];
                len += 1;
            }
        }
        norm = nb[0..len];
        norm_buf = nb;
    }
    if (self.in_insert) {
        try pasteInsert(self, norm);
        return;
    }
    self.cur().history.beginGroup();
    try pasteInsert(self, norm);
    self.cur().history.endGroup();
    self.in_insert = false; // pasteInsert opened an insert session; close it
}

/// Pending first half of a CRLF pasted as ordinary key events. The parser
/// maps a pasted 0x0D to Enter and the following 0x0A to Ctrl+j, so without
/// this flag every CRLF became TWO newlines (a pasted Zig block acquired a
/// blank line between every row before pasteText ever saw the bytes).
/// `pasteAccumulate` resets it when the paste buffer is empty (paste start);
/// any non-CR pasted key clears it, so a lone CR still becomes one '\n'.
var paste_prev_cr: bool = false;

/// Append one key event of a bracketed paste to `buf`. Pure enough to unit
/// test: `prev_cr` carries the CR half across the Enter/Ctrl+j pair.
pub fn pasteAppendKey(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key: vaxis.Key,
    prev_cr: *bool,
) !void {
    if (key.text) |t| {
        // Some parsers hand the LF half through `text` instead of Ctrl+j.
        if (prev_cr.* and std.mem.eql(u8, t, "\n")) {
            prev_cr.* = false;
            return;
        }
        try buf.appendSlice(alloc, t);
        prev_cr.* = t.len > 0 and t[t.len - 1] == '\r';
        return;
    }
    if (key.codepoint == vaxis.Key.enter) {
        try buf.append(alloc, '\n');
        prev_cr.* = true;
        return;
    }
    if (key.codepoint == 'j' and key.mods.ctrl) {
        if (!prev_cr.*) try buf.append(alloc, '\n');
        prev_cr.* = false;
        return;
    }
    if (key.codepoint == vaxis.Key.tab) {
        try buf.append(alloc, '\t');
        prev_cr.* = false;
        return;
    }
    // Escape sequences that were part of the pasted content are dropped
    // rather than executed as editor commands; they also end a CR pair.
    prev_cr.* = false;
}

/// One key event arriving between paste_start/paste_end: append the bytes
/// it stands for to paste_buf. The parser maps pasted C0 bytes to key
/// codes (0x0A -> Ctrl+j, 0x0D -> Enter, 0x09 -> Tab) — inside a paste
/// they are TEXT, so translate them back. CRLF is one newline, never two.
pub fn pasteAccumulate(self: *App, key: vaxis.Key) !void {
    if (self.paste_buf.items.len == 0) paste_prev_cr = false; // paste start
    try pasteAppendKey(&self.paste_buf, self.alloc, key, &paste_prev_cr);
}
