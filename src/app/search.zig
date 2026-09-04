//! search — App method group split out of src/main.zig (physical move).

const std = @import("std");
const buffer = @import("../buffer/root.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const InlayHint = app_mod.InlayHint;

// ---- buffer search (/ ? n N) ----

/// Execute a '/' / '?' search: plain substring (no regex, like :s), from
/// just after (forward) or before (backward) the cursor, wrapping around
/// the buffer edges like vim. The query is remembered for n/N.
pub fn execSearch(self: *App, query: []const u8, backward: bool) !void {
    if (query.len == 0) return;
    // remember for n/N (dupes — `query` borrows the cmdline buffer)
    if (self.last_search) |q| self.alloc.free(q);
    self.last_search = try self.alloc.dupe(u8, query);
    self.last_search_bwd = backward;
    try self.searchOnce(query, backward);
}

/// n / N: repeat the remembered search; `flip` inverts the direction.
pub fn repeatSearch(self: *App, flip: bool) !void {
    const q = self.last_search orelse {
        try self.setMsg(try self.alloc.dupe(u8, "no previous search"));
        return;
    };
    try self.searchOnce(q, self.last_search_bwd != flip);
}

/// Search `query` in the document byte range [start, end) of `pt`,
/// iterating pieces in document order with NO full-document copy. Returns
/// the absolute offset of the first (want_last = false) or last
/// (want_last = true) match STARTING inside the range, or null.
///
/// A match may straddle a piece boundary, so a window of the last
/// (query.len - 1) stream bytes is carried between pieces (stack buffer)
/// and searched together with the next piece's head. Null when the query
/// is empty or longer than the window cap (caller falls back to the
/// full-text path for absurdly long patterns).
pub fn findInPieces(
    pt: *const buffer.PieceTable,
    start: u32,
    end: u32,
    query: []const u8,
    want_last: bool,
) ?u32 {
    const qlen = query.len;
    if (qlen == 0 or end <= start or end - start < qlen) return null;
    const need: usize = qlen - 1;
    const max_win = 255;
    if (need > max_win) return null; // absurd pattern; caller falls back
    var tail: [max_win]u8 = undefined;
    var tail_len: usize = 0;
    var concat: [2 * max_win]u8 = undefined;
    var result: ?u32 = null;
    var doc_off: u32 = 0;
    for (pt.pieces.items) |p| {
        const piece_end = doc_off + p.len;
        if (piece_end <= start) {
            doc_off = piece_end;
            continue;
        }
        if (doc_off >= end) break;
        const src: []const u8 = if (p.source == .origin) pt.origin else pt.add.items;
        const skip: u32 = if (start > doc_off) start - doc_off else 0;
        const take: u32 = @min(p.len - skip, end - doc_off);
        const bytes = src[@as(usize, p.start) + skip .. @as(usize, p.start) + skip + take];
        if (bytes.len == 0) {
            doc_off = piece_end;
            continue;
        }
        // Boundary window: a match can start in the carried tail and
        // extend into this piece — search tail ++ head together.
        if (tail_len > 0) {
            const head: usize = @min(bytes.len, need);
            @memcpy(concat[0..tail_len], tail[0..tail_len]);
            @memcpy(concat[tail_len .. tail_len + head], bytes[0..head]);
            if (std.mem.indexOf(u8, concat[0 .. tail_len + head], query)) |k| {
                const abs = doc_off - @as(u32, @intCast(tail_len)) + @as(u32, @intCast(k));
                if (!want_last) return abs;
                if (result == null or abs > result.?) result = abs;
            }
        }
        if (std.mem.indexOf(u8, bytes, query)) |k| {
            const abs = doc_off + skip + @as(u32, @intCast(k));
            if (!want_last) return abs;
            if (result == null or abs > result.?) result = abs;
        }
        // Carry the last `need` stream bytes for the next boundary.
        if (bytes.len >= need) {
            @memcpy(tail[0..need], bytes[bytes.len - need ..]);
            tail_len = need;
        } else if (need > 0) {
            if (tail_len + bytes.len > need) {
                const drop = tail_len + bytes.len - need;
                std.mem.copyForwards(u8, tail[0 .. tail_len - drop], tail[drop..tail_len]);
                tail_len -= drop;
            }
            @memcpy(tail[tail_len .. tail_len + bytes.len], bytes);
            tail_len += bytes.len;
        }
        doc_off = piece_end;
    }
    return result;
}

pub fn searchOnce(self: *App, query: []const u8, backward: bool) !void {
    const len = self.cur().pt.len();
    if (len == 0) return;
    const cursor = self.curCursor().*;
    var hit: ?u32 = null;
    if (query.len - 1 > 255) {
        // Pathological pattern length: the piece-walker's boundary window
        // caps at 255 bytes, so fall back to the (rare) full-text path.
        const text = try self.curText();
        defer self.alloc.free(text);
        if (backward) {
            if (std.mem.lastIndexOf(u8, text[0..@min(cursor, len)], query)) |i| {
                hit = @intCast(i);
            } else {
                const from = @min(cursor + 1, len);
                if (std.mem.lastIndexOf(u8, text[from..], query)) |i| hit = @intCast(from + i);
            }
        } else {
            const from = @min(cursor + 1, len);
            if (std.mem.indexOf(u8, text[from..], query)) |i| {
                hit = @intCast(from + i);
            } else {
                if (std.mem.indexOf(u8, text[0..from], query)) |i| hit = @intCast(i);
            }
        }
    } else {
        const pt = &self.cur().pt;
        if (backward) {
            // last match starting before the cursor, else wrap to the end
            hit = findInPieces(pt, 0, @min(cursor, len), query, true);
            if (hit == null) {
                const from = @min(cursor + 1, len);
                hit = findInPieces(pt, from, len, query, true);
            }
        } else {
            // first match starting after the cursor, else wrap to the top
            const from = @min(cursor + 1, len);
            hit = findInPieces(pt, from, len, query, false);
            if (hit == null) {
                hit = findInPieces(pt, 0, from, query, false);
            }
        }
    }
    if (hit) |h| {
        self.curCursor().* = h;
        self.clearHover();
    } else {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "pattern not found: {s}", .{query}));
    }
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
    if (path.len > 0 and path[0] == '/') return self.alloc.dupe(u8, path);
    var cwd_buf: [4096:0]u8 = undefined;
    // libc getcwd — portable (the binary links libc). A raw
    // std.os.linux.getcwd issues the LINUX syscall number: on macOS that
    // number maps to an unrelated syscall, so the buffer stays garbage
    // with no NUL and the resolved path is thousands of bogus bytes
    // (createFile then failed with NameTooLong on :w).
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) return self.alloc.dupe(u8, path);
    // getcwd NUL-terminates on success; trim to the C-string length
    // before joining so no \0 lands inside the path (an embedded NUL
    // later fails as BadPathName on createFile/write — openat just
    // truncates at the NUL, so opening still works while the saved path
    // is silently corrupt).
    var n: usize = 0;
    while (n < cwd_buf.len and cwd_buf[n] != 0) : (n += 1) {}
    return std.Io.Dir.path.resolve(self.alloc, &.{ cwd_buf[0..n], path }) catch
        self.alloc.dupe(u8, path);
}

/// :w — write the current buffer. Returns false (with a status message)
/// when there is no file name or the write fails, so callers like :wq
/// must NOT proceed to quit on failure.
pub fn writeBuffer(self: *App) !bool {
    const path = self.cur().path orelse {
        try self.setMsg(try self.alloc.dupe(u8, "E32: No file name"));
        return false;
    };
    self.saveFile(path) catch |e| {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "write failed: {s}", .{@errorName(e)}));
        return false;
    };
    self.cur().dirty = false;
    // the file on disk changed: refresh git marks/branch (async)
    self.scheduleGitStatus();
    try self.setMsg(try std.fmt.allocPrint(self.alloc, "written: {s}", .{path}));
    return true;
}

pub fn saveFile(self: *App, path: []const u8) !void {
    const len = self.cur().pt.len();
    const buf = try self.alloc.alloc(u8, len);
    defer self.alloc.free(buf);
    self.cur().pt.copyRange(0, buf);
    // Write to a sibling temp file and rename it over `path` — NEVER
    // truncate the open file in place: the buffer's origin may be an
    // mmap of it, and truncating a mapped file SIGBUSes every later read
    // of the mapping (the file no longer backs those pages). Temp+rename
    // also makes saves atomic for other readers (they never see a
    // half-written file) and keeps the old inode alive for the mapping.
    const tmp = try std.fmt.allocPrint(self.alloc, "{s}.oztmp{d}", .{ path, std.c.getpid() });
    defer self.alloc.free(tmp);
    var flags: std.Io.Dir.CreateFileOptions = .{ .truncate = true };
    // Preserve the original file's mode (executable bit etc.) on the
    // replacement file.
    if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |st| {
        flags.permissions = st.permissions;
    } else |_| {}
    var f = try std.Io.Dir.cwd().createFile(self.io, tmp, flags);
    defer f.close(self.io);
    try f.writeStreamingAll(self.io, buf);
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, self.io);
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
    try self.cur().history.record(&self.cur().pt, pos, 0, text);
    self.curCursor().* += @intCast(text.len);
    // keep inlay hints aligned instead of clearing them (insert mode:
    // clearing + re-requesting on every keystroke makes the view flicker)
    self.adjustInlayHintsInsert(line, col, text);
    self.markDirtyRange(at, at, text);
}
