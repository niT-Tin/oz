//! highlight — App method group split out of src/main.zig (physical move).

const std = @import("std");
const replace_plan = @import("../editor/replace_plan.zig");
const text_object_edit = @import("../editor/text_object_edit.zig");
const edit_range = @import("../editor/edit_range.zig");
const indent_mod = @import("../editor/indent.zig");
const editor = @import("../editor/root.zig");
const syntax = @import("../syntax.zig");
const term = @import("../term.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");
const markdown = @import("markdown.zig");
const inlay_history = @import("inlay_history.zig");
const history_mod = @import("../buffer/history.zig");

const Buffer = App.Buffer;

// ---- tree-sitter syntax highlighting ----

/// Each view parses its own text; only compiled language queries are shared.
pub fn newHighlighter(self: *App, lang: []const u8) !syntax.Highlighter {
    for (self.buffers.items) |*other| {
        if (other.hl) |*existing| {
            if (std.mem.eql(u8, existing.lang_name, lang)) return existing.forAnotherBuffer();
        }
    }
    return syntax.Highlighter.init(self.alloc, lang);
}

/// Merged non-overlapping spans for the visible byte range of `buf`
/// (later spans win overlaps), arena-allocated. Empty when highlighting
/// is inactive (no grammar for the filetype / over the size limit).
///
/// Every buffer owns its highlighter (`Buffer.hl`), so ANY window —
/// focused or not, showing the current buffer or another — gets real
/// tree-sitter highlighting for what it displays. Reparse policy: a
/// single recorded edit supplies exact offsets. A batch or undo uses the
/// actual before/after text. First parses and explicit resets start fresh.
pub fn visibleSpansFor(self: *App, buf: *Buffer, arena: std.mem.Allocator, view_top: u32, content_rows: u32) ![]syntax.Span {
    const lang = if (buf.hl) |*h| h.lang_name else syntax.languageFor(autil.filetypeOf(buf.path)) orelse return &.{};
    if (buf.pt.len() > syntax.bufferSizeLimit(lang)) {
        if (buf.hl) |*h| {
            h.deinit();
            buf.hl = null;
            buf.spans_cache_valid = false;
            buf.decors_cache_valid = false;
            if (buf.markdown_arena) |*md| md.deinit();
            buf.markdown_arena = null;
            buf.markdown_layout = null;
        }
        return &.{};
    }
    if (buf.hl == null) {
        buf.hl = self.newHighlighter(lang) catch return &.{};
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
        } else if (parsed and rev > buf.syntax_revision) {
            try hl.reparseChanges(text);
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
    // "Later wins" overlap merge with SPLITTING: a nested span takes its
    // subrange while the covered container keeps its head and tail (the
    // tail is re-appended after the nested span so still-later spans can
    // beat it). The old merge truncated or popped the container, which was
    // invisible for dense code captures but dropped whole prose styles once
    // markdown injections nested emphasis/links inside headings.
    var out = std.ArrayList(syntax.Span).empty;
    raw_loop: for (raw.items) |sp| {
        const s = sp;
        while (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.end <= s.start) break; // disjoint
            if (last.start < s.start) {
                if (last.end > s.end) {
                    // s punches a hole in last: head keeps last's style
                    const tail = syntax.Span{ .start = s.end, .end = last.end, .style = last.style };
                    last.end = s.start;
                    try out.append(arena, s);
                    try out.append(arena, tail);
                    continue :raw_loop;
                }
                last.end = s.start; // s covers last's tail
                break;
            }
            // last.start == s.start (raw is sorted by start): s wins the head
            if (s.end >= last.end) {
                _ = out.pop(); // s covers last wholly
                continue;
            }
            // same start, s shorter: s takes the head, last keeps its tail
            const tail = syntax.Span{ .start = s.end, .end = last.end, .style = last.style };
            last.* = s;
            try out.append(arena, tail);
            continue :raw_loop;
        }
        try out.append(arena, s);
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

/// Markdown decorations (conceal / checkbox replace / heading & fence
/// bands) for the visible byte range of `buf` — same (revision, byte
/// range) caching as visibleSpansFor. Empty for non-markdown buffers (only
/// markdown highlighters carry a decor query) and before the first parse.
/// Call AFTER visibleSpansFor so the tree is fresh.
pub fn visibleDecorsFor(self: *App, buf: *Buffer, arena: std.mem.Allocator, view_top: u32, content_rows: u32) ![]syntax.Decor {
    const hl = if (buf.hl) |*h| h else return &.{};
    if (hl.queries.decorations == null or hl.tree == null) return &.{};
    const rev = buf.history.revision;
    const line_count = buf.pt.lineCount();
    const start = buf.pt.lineStart(@min(view_top, line_count -| 1));
    const vbottom = @min(view_top + content_rows, line_count);
    // lineStart has no EOF sentinel: the last visible line's end is pt.len()
    const end: u32 = if (vbottom >= line_count) buf.pt.len() else buf.pt.lineStart(vbottom);
    if (buf.decors_cache_valid and buf.decors_cache_rev == rev and
        buf.decors_cache_start == start and buf.decors_cache_end == end)
    {
        return buf.decors_cache;
    }
    var out = std.ArrayList(syntax.Decor).empty;
    try hl.decorInRange(@intCast(start), @intCast(end), arena, &out);
    // own a copy so future cache hits return a stable slice (the arena is
    // per-frame; the buffer outlives any frame)
    const cached = try self.alloc.dupe(syntax.Decor, out.items);
    if (buf.decors_cache.len > 0) self.alloc.free(buf.decors_cache);
    buf.decors_cache = cached;
    buf.decors_cache_valid = true;
    buf.decors_cache_start = start;
    buf.decors_cache_end = end;
    buf.decors_cache_rev = rev;
    return buf.decors_cache;
}

pub fn visibleMarkdownFor(
    self: *App,
    buf: *Buffer,
    win: @import("vaxis").Window,
    decors: []const syntax.Decor,
    view_top: u32,
    content_rows: u32,
    content_width: u32,
) !?*markdown.Layout {
    const hl = if (buf.hl) |*h| h else return null;
    if (hl.queries.decorations == null) return null;
    const rev = buf.history.revision;
    if (buf.markdown_layout != null and buf.markdown_cache_rev == rev and
        buf.markdown_cache_top == view_top and buf.markdown_cache_rows == content_rows and
        buf.markdown_cache_width == content_width) return buf.markdown_layout;

    if (buf.markdown_arena) |*old| old.deinit();
    buf.markdown_arena = std.heap.ArenaAllocator.init(self.alloc);
    buf.markdown_layout = null;
    const a = buf.markdown_arena.?.allocator();
    const layout = try markdownForRange(buf, a, win, decors, view_top, content_rows, content_width, null);
    buf.markdown_layout = layout;
    buf.markdown_cache_rev = rev;
    buf.markdown_cache_top = view_top;
    buf.markdown_cache_rows = content_rows;
    buf.markdown_cache_width = content_width;
    return layout;
}

pub fn markdownForRange(
    buf: *Buffer,
    a: std.mem.Allocator,
    win: @import("vaxis").Window,
    decors: []const syntax.Decor,
    view_top: u32,
    content_rows: u32,
    content_width: u32,
    draft: ?@import("table_cell.zig").Preview,
) !*markdown.Layout {
    const start = buf.pt.lineStart(view_top);
    const bottom = view_top + content_rows;
    const end = if (bottom >= buf.pt.lineCount()) buf.pt.len() else buf.pt.lineStart(bottom);
    const visible: markdown.LineRange = .{ .start = view_top, .end = bottom };
    var table_start = start;
    var table_end = end;
    for (decors) |d| {
        if (d.kind != .table or d.end <= start or d.start >= end) continue;
        table_start = @min(table_start, d.start);
        table_end = @max(table_end, d.end);
    }
    if (table_start == start and table_end == end)
        return markdown.build(a, &buf.pt, decors, win, content_width, buf.path, visible, draft);

    // A table entering or leaving the viewport must keep the same widths.
    // Query its full set of cells and inline decorations before layout.
    var full = std.ArrayList(syntax.Decor).empty;
    try buf.hl.?.decorInRange(table_start, table_end, a, &full);
    return markdown.build(a, &buf.pt, full.items, win, content_width, buf.path, visible, draft);
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
        const end_line = @min(start_line +| (n - 1), self.cur().pt.lineCount() - 1);
        const start = self.cur().pt.lineStart(start_line);
        var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
        // dd/yy take the trailing newline (the line is gone from the
        // buffer); cc keeps it — vim's change clears the line's TEXT and
        // puts the cursor on the (now empty) line, not on the next one.
        // For cc the TEXT end is before a CRLF terminator's '\r', so the
        // kept terminator is the full "\r\n", not a lone "\r".
        if (m.op == .change) {
            end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineTextLen(end_line);
        } else if (end_line + 1 < self.cur().pt.lineCount()) {
            end += 1;
        }
        try self.applyOpRange(m.op, start, end, false, true); // whole-line → linewise register
        return;
    }
    // text object (diw / ci( / yaw …): resolve at the cursor; the count
    // follows vim (2ciw = two words, 2i( = second nesting level)
    if (m.text_object) |kind| {
        const rng = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, m.count);
        const block_plan = if (m.op == .delete or m.op == .change or m.op == .yank)
            try text_object_edit.plan(self.alloc, &self.cur().pt, kind, rng, m.op == .change)
        else
            null;
        if (block_plan) |plan| {
            defer plan.deinit(self.alloc);
            // Empty multiline interiors keep their delimiter newline; c enters
            // Insert at the empty body instead of joining both delimiter lines.
            if (plan.register.start == plan.register.end) {
                if (m.op == .change) {
                    self.curCursor().* = plan.register.start;
                    try self.applyOpRange(m.op, plan.register.start, plan.register.end, false, false);
                }
                return;
            }
            try self.setRegister(plan.register.start, plan.register.end, plan.linewise);
            if (m.op == .yank) {
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked {d} bytes", .{plan.register.end - plan.register.start}));
                return;
            }
            const start_pos = self.lspPositionAt(&self.cur().pt, plan.edit.start);
            const end_pos = self.lspPositionAt(&self.cur().pt, plan.edit.end);
            const offsets = captureInlayOffsetsForReplace(self, plan.edit.start, plan.edit.end - plan.edit.start, @intCast(plan.replacement.len));
            defer if (offsets) |value| self.alloc.free(value);
            self.cur().history.beginGroup();
            try self.recordEdit(plan.edit.start, plan.edit.end - plan.edit.start, plan.replacement);
            self.curCursor().* = @min(plan.cursor, self.cur().pt.len());
            if (m.op == .change) {
                self.state.mode = .insert;
                self.in_insert = true;
            } else self.cur().history.endGroup();
            self.markDirtyRange(start_pos, end_pos, plan.replacement);
            if (offsets) |value| applyInlayOffsetsAfterHistory(self, value);
            return;
        }
        try self.applyOpRange(m.op, rng.start, rng.end, false, false);
        return;
    }
    // visual mode: the operator acts on the selection
    if (self.isVisual()) {
        if (self.visual_anchor) |anchor| {
            if (self.state.mode == .visual_block) {
                try self.applyBlockOp(m.op);
            } else if (self.state.mode == .visual_line) {
                const range = edit_range.linewise(&self.cur().pt, anchor, self.curCursor().*);
                try self.applyOpRangeEx(m.op, range.start, range.end, false, .exclusive_cursor, true);
            } else {
                try self.applyOpRangeEx(m.op, anchor, self.curCursor().*, false, .inclusive_cursor, false);
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
    // naturally-exclusive motions (w/b/h/l/^) yield a half-open
    // range [cursor, target) as-is; inclusive motions ($/e/f/t/%)
    // include the full character at the sorted right endpoint, including
    // multibyte characters and backward inclusive find motions.
    //
    // Find/till operators require the count-th match. A miss aborts the
    // entire edit; using the cursor as a fallback would delete a character
    // for an inclusive motion, or enter Insert for a change with no target.
    const pt = &self.cur().pt;
    const from = self.curCursor().*;
    const target_pos = switch (m.motion) {
        .find, .find_back => editor.Motion.findTarget(pt, from, m.args.ch, if (m.motion == .find) 1 else -1, m.count) orelse return,
        .till, .till_back => editor.Motion.tillTarget(pt, from, m.args.ch, if (m.motion == .till) 1 else -1, m.count) orelse return,
        else => editor.Motion.target(pt, m.motion, m.args, from, m.count),
    };
    const range = edit_range.characterwise(pt, from, target_pos, m.inclusive);
    try self.applyOpRange(m.op, range.start, range.end, false, false);
}

/// Public transaction result for `u` / Ctrl-r. The handler is the only
/// caller today; this explicit shape keeps cursor/range/revision in one
/// place so e2e and future callers do not re-derive them.
pub const HistoryOutcome = struct {
    applied: bool = false,
    kind: history_mod.UndoKind = .undo,
    before_cursor: u32 = 0,
    after_cursor: u32 = 0,
    change_start: u32 = 0,
    change_end: u32 = 0,
    revision: u64 = 0,
};

/// Clamp a post-undo/redo anchor to a real Insert/Normal position: inside
/// the document, on a UTF-8 scalar boundary, and never between the \r and \n
/// of a CRLF terminator.
fn clampHistoryCursor(self: *App, pos: u32) u32 {
    const pt = &self.cur().pt;
    var p: u32 = @min(pos, pt.len());
    if (p > 0 and p < pt.len()) {
        while (p > 0 and (pt.byteAt(p) & 0xC0) == 0x80) p -= 1;
    }
    const line = pt.lineOf(p);
    const line_start = pt.lineStart(line);
    const text_end = line_start + pt.lineTextLen(line);
    if (p > text_end) p = text_end;
    return p;
}

/// Capture anchors BEFORE a single replacement. The returned transformed
/// offsets must be applied only AFTER the document edit succeeds; converting
/// them against the old document would clamp a shifted EOL hint into text.
pub fn captureInlayOffsetsForReplace(self: *App, pos: u32, removed: u32, inserted: u32) ?[]?u32 {
    if (self.inlay_hints.items.len == 0 or self.inlay_buf != self.current) return null;
    const pt = &self.cur().pt;
    const offsets = self.alloc.alloc(?u32, self.inlay_hints.items.len) catch {
        self.invalidateInlayHints();
        return null;
    };
    const span = inlay_history.Span{ .pos = pos, .removed = removed, .inserted = inserted };
    for (self.inlay_hints.items, offsets) |h, *off| {
        const abs = pt.lineStart(h.line) + h.character;
        off.* = if (abs <= pt.len()) inlay_history.transformOffset(abs, span) else null;
    }
    return offsets;
}

/// Capture the displayed hint anchors as absolute byte offsets in the
/// CURRENT (pre-operation) document and transform them through the edit
/// group. The conversion back to line/column MUST happen after the history
/// transaction, against the new piece table: an undo that inserts/deletes
/// lines changes line starts and length, so converting before the operation
/// re-anchors to stale coordinates. Returns null when there is nothing to
/// transform (or on allocation failure, after the safe invalidate fallback).
fn captureInlayOffsetsForHistory(
    self: *App,
    edits: []const history_mod.Edit,
    kind: history_mod.UndoKind,
) ?[]?u32 {
    if (self.inlay_hints.items.len == 0) return null;
    if (self.inlay_buf != self.current) return null;
    if (edits.len == 0) return null;
    const pt = &self.cur().pt;
    const spans = self.alloc.alloc(inlay_history.Span, edits.len) catch {
        self.invalidateInlayHints();
        return null;
    };
    defer self.alloc.free(spans);
    const lens = self.alloc.alloc(inlay_history.EditLen, edits.len) catch {
        self.invalidateInlayHints();
        return null;
    };
    defer self.alloc.free(lens);
    for (edits, lens) |e, *l| {
        l.* = .{
            .pos = e.pos,
            .before_len = @intCast(e.before.len),
            .after_len = @intCast(e.after.len),
        };
    }
    switch (kind) {
        .undo => inlay_history.undoSpans(spans, lens),
        .redo => inlay_history.redoSpans(spans, lens),
    }
    const offsets = self.alloc.alloc(?u32, self.inlay_hints.items.len) catch {
        self.invalidateInlayHints();
        return null;
    };
    for (self.inlay_hints.items, offsets) |h, *off| {
        const ls = pt.lineStart(h.line);
        const abs = ls + h.character;
        off.* = if (abs <= pt.len()) abs else null;
    }
    inlay_history.transformOffsets(offsets, spans);
    return offsets;
}

/// Re-anchor transformed absolute offsets in the POST-operation document:
/// validate UTF-8/line bounds, drop dead hints (freeing only their labels),
/// then compute the new line/byte column. `offsets` maps 1:1 to the hint list
/// captured before the operation.
pub fn applyInlayOffsetsAfterHistory(self: *App, offsets: []const ?u32) void {
    if (self.inlay_hints.items.len != offsets.len) return;
    const pt = &self.cur().pt;
    var write: usize = 0;
    for (self.inlay_hints.items, offsets) |h, off_opt| {
        const off = off_opt orelse {
            self.alloc.free(h.label);
            continue;
        };
        if (off > pt.len()) {
            self.alloc.free(h.label);
            continue;
        }
        // A transformed anchor must still be a UTF-8 boundary and inside the
        // line's text (not the CRLF terminator). Otherwise it no longer
        // describes a drawable position; drop it rather than paint garbage.
        if (off < pt.len() and (pt.byteAt(off) & 0xC0) == 0x80) {
            self.alloc.free(h.label);
            continue;
        }
        const line = pt.lineOf(off);
        const ls = pt.lineStart(line);
        const character = off -| ls;
        if (character > pt.lineTextLen(line)) {
            self.alloc.free(h.label);
            continue;
        }
        self.inlay_hints.items[write] = .{ .line = line, .character = character, .label = h.label };
        write += 1;
    }
    self.inlay_hints.shrinkRetainingCapacity(write);
}

/// One `u` / Ctrl-r transaction. Empty stacks and refused Agent-set undos do
/// not touch the dirty flag, LSP sync, inlay hints or cursor.
pub fn performHistoryStep(self: *App, kind: history_mod.UndoKind) HistoryOutcome {
    const before_cursor = self.curCursor().*;
    if (self.in_insert) {
        self.cur().history.endGroup();
        self.in_insert = false;
    }
    // M3b2 multi-file apply: one cross-file undo unit. `u` in any buffer of
    // the set restores every file (buffers + disk) instead of undoing just
    // the current buffer. From an unrelated buffer this returns false.
    const agent_consumed = switch (kind) {
        .undo => self.agentPatchUndo(),
        .redo => self.agentPatchRedo(),
    };
    if (agent_consumed) {
        return .{
            .applied = true,
            .kind = kind,
            .before_cursor = before_cursor,
            .after_cursor = self.curCursor().*,
            .revision = self.cur().history.revision,
        };
    }
    const group = switch (kind) {
        .undo => self.cur().history.topUndoGroup(),
        .redo => self.cur().history.topRedoGroup(),
    } orelse return .{ .applied = false, .kind = kind, .before_cursor = before_cursor, .after_cursor = before_cursor, .revision = self.cur().history.revision };
    // Transform offsets in the pre-edit document, apply the history
    // transaction, then convert to line/column in the NEW document.
    const inlay_offsets = captureInlayOffsetsForHistory(self, group.edits.items, kind);
    defer if (inlay_offsets) |o| self.alloc.free(o);
    // historyApply carries this buffer's closed folds through the same edit
    // sequence (against a scratch copy) before running the transaction, so
    // undo/redo never unfold blocks whose content survives.
    const res = self.historyApply(self.cur(), kind);
    if (!res.changed) {
        return .{ .applied = false, .kind = kind, .before_cursor = before_cursor, .after_cursor = before_cursor, .revision = res.revision };
    }
    if (inlay_offsets) |o| applyInlayOffsetsAfterHistory(self, o);
    // A secondary insert cursor is a per-session position; an undo is a
    // single deterministic transaction, so collapse to the main cursor.
    if (self.mc_active or self.mc.cursors.items.len > 0) {
        self.mc.clear();
        self.mc_active = false;
    }
    self.curCursor().* = clampHistoryCursor(self, res.anchor);
    // Keep the transformed inlay hints rendered; the run loop re-requests
    // the post-undo band and processInlay atomically replaces the list.
    self.markDirtyHistory();
    return .{
        .applied = true,
        .kind = kind,
        .before_cursor = before_cursor,
        .after_cursor = self.curCursor().*,
        .change_start = res.change_start,
        .change_end = res.change_end,
        .revision = res.revision,
    };
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
            _ = self.performHistoryStep(.undo);
        },
        .redo => {
            _ = self.performHistoryStep(.redo);
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
            // a: insert after the character under the cursor. The EOL is
            // the end of the line TEXT — never the CR of a CRLF terminator
            // (typing there would insert between \r and \n and corrupt the
            // file's line endings).
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const ls = self.cur().pt.lineStart(line);
            const end = ls + self.cur().pt.lineTextLen(line);
            if (self.curCursor().* < end) {
                var i = self.curCursor().* + 1;
                while (i < end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                self.curCursor().* = i;
            } else if (self.curCursor().* > end) {
                self.curCursor().* = end;
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
            const end = ls + self.cur().pt.lineTextLen(line);
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
            // A: end of the line TEXT (before a CRLF terminator's '\r').
            const line = self.cur().pt.lineOf(self.curCursor().*);
            self.curCursor().* = self.cur().pt.lineStart(line) + self.cur().pt.lineTextLen(line);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            self.in_insert = true;
            self.state.mode = .insert;
        },
        .insert_line_after => {
            const pt = &self.cur().pt;
            const line = pt.lineOf(self.curCursor().*);
            const ls = pt.lineStart(line);
            const text_len = pt.lineTextLen(line);
            const leading = try self.leadingIndent(line);
            defer self.alloc.free(leading);
            var insert_pos = ls + text_len;
            var plan: indent_mod.NewlinePlan = undefined;
            if (pt.len() <= indent_mod.max_insert_bytes) {
                const doc = try self.curText();
                defer self.alloc.free(doc);
                const open = try indent_mod.planOpenBelow(self.alloc, doc, self.curCursor().*, autil.filetypeOf(self.cur().path), .{
                    .indent_width = @intCast(app_mod.tab_width),
                    .use_tabs = std.mem.indexOfScalar(u8, leading, '\t') != null,
                });
                insert_pos = open.pos;
                plan = open.newline;
            } else {
                const ending = editor.line_open.preferredEnding(pt, line);
                const open = try editor.line_open.plan(self.alloc, ending, leading, false);
                plan = .{ .text = open.text, .cursor_after = open.cursor_off };
            }
            defer self.alloc.free(plan.text);
            const at = self.lspPositionAt(pt, insert_pos);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            try self.recordEdit(insert_pos, 0, plan.text);
            self.curCursor().* = insert_pos + plan.cursor_after;
            self.in_insert = true;
            self.state.mode = .insert;
            if (insert_pos == ls + text_len and std.mem.count(u8, plan.text, "\n") == 1) {
                // End-of-line hints stay attached to their original source;
                // only rows below an ordinary open-below move down.
                self.adjustInlayHintsLineOpen(line, false);
            } else {
                self.adjustInlayHintsInsert(line, insert_pos - ls, plan.text);
            }
            self.cur().syntax_revision = std.math.maxInt(u64);
            self.markDirtyRange(at, at, plan.text);
        },
        .insert_line_before => {
            // O: new line above, cursor on it (same open-group semantics).
            // The new row is `indent ++ ending`; the edited line keeps its
            // own terminator, so a CRLF buffer stays CRLF.
            const pt = &self.cur().pt;
            const line = pt.lineOf(self.curCursor().*);
            const ls = pt.lineStart(line);
            const indent = try self.leadingIndent(line);
            defer self.alloc.free(indent);
            const ending = editor.line_open.preferredEnding(pt, line);
            const open = try editor.line_open.plan(self.alloc, ending, indent, true);
            defer open.deinit(self.alloc);
            self.beginInsertSession();
            self.cur().history.beginGroup();
            try self.recordEdit(ls, 0, open.text);
            self.curCursor().* = ls + open.cursor_off;
            self.in_insert = true;
            self.state.mode = .insert;
            // Hints on the edited line move with it (column unchanged);
            // nothing is re-anchored onto the new empty row.
            self.adjustInlayHintsLineOpen(line, true);
            // keep the git gutter marks glued to their lines (O pushes the
            // whole edited line down)
            self.gitShiftInsertAt(line, 0, 1);
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
                    try self.recordEdit(w.start, w.end - w.start, "");
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
                        // earlier endpoint's line start to the later line's end
                        // (including the trailing newline when present),
                        // not just anchor..cursor bytes — otherwise the
                        // last selected line survives a d/c.
                        const range = edit_range.linewise(&self.cur().pt, anchor, self.curCursor().*);
                        // exclusive_cursor: the range already ends exactly
                        // after the last selected line's newline.
                        try self.applyOpRangeEx(action, range.start, range.end, false, .exclusive_cursor, true);
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
        .search_clear => try self.execCommand(.noh),
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
        // M1 AI chat
        .ai_toggle => try self.toggleAiPanel(),
        // M2b2 inline assistant (<leader>i)
        .inline_edit => try self.startInlineEdit(),
        // M2.6a keyboard hints (DESIGN.md §19)
        .hint_mode => self.beginHintMode(),
        .paste => try self.pasteBuffer(false, count),
        .paste_before => try self.pasteBuffer(true, count),
        .delete_char => {
            // x deletes whole graphemes in one edit. Capture the same byte
            // range in the unnamed register before changing the piece table.
            const c0 = self.curCursor().*;
            var reg_end = c0;
            var clusters = edit_range.graphemes(&self.cur().pt, c0, self.cur().pt.len());
            for (0..@max(count, 1)) |_| {
                const cluster = clusters.nextGrapheme() orelse break;
                reg_end = @intCast(cluster.end);
            }
            if (reg_end == c0) return;
            try self.setRegister(c0, reg_end, false);
            // LSP range in the PRE-EDIT document: [c0, reg_end).
            const start_pos = self.lspPositionAt(&self.cur().pt, c0);
            const end_pos = self.lspPositionAt(&self.cur().pt, reg_end);
            try self.recordEdit(c0, reg_end - c0, "");
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
                try self.recordEdit(start, c - start, "");
                self.curCursor().* = start;
            }
            self.cur().history.endGroup();
            self.markDirtyRange(start_pos, end_pos, "");
        },
        .delete_to_eol => {
            // D: delete to end of line (d$), keeping the terminator so the
            // line is emptied, not removed. vim count: `count` lines from
            // the cursor (3D = delete to EOL on three lines). The deleted
            // text fills the unnamed register (charwise). The TEXT end is
            // before a CRLF terminator's '\r' (deleting the '\r' would
            // corrupt the file's line endings).
            const c = self.curCursor().*;
            const pt = &self.cur().pt;
            const line = pt.lineOf(c);
            const end_line = @min(line + @max(count, 1) - 1, pt.lineCount() - 1);
            const end = pt.lineStart(end_line) + pt.lineTextLen(end_line);
            if (end > c) {
                try self.setRegister(c, end, false);
                // LSP range in the PRE-EDIT document: [c, end).
                const start_pos = self.lspPositionAt(&self.cur().pt, c);
                const end_pos = self.lspPositionAt(&self.cur().pt, end);
                self.cur().history.beginGroup();
                try self.recordEdit(c, end - c, "");
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
            const end = pt.lineStart(end_line) + pt.lineTextLen(end_line);
            // LSP range in the PRE-EDIT document: [c, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, c);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            self.cur().history.beginGroup();
            if (end > c) {
                try self.recordEdit(c, end - c, "");
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
            // (the terminator stays, like vim cc) and enter insert with the
            // cursor on the emptied line. The content ends before a CRLF
            // '\r', so the full "\r\n" survives.
            const pt = &self.cur().pt;
            const line = pt.lineOf(self.curCursor().*);
            const start = pt.lineStart(line);
            const end = start + pt.lineTextLen(line);
            self.curCursor().* = start;
            // LSP range in the PRE-EDIT document: [start, end).
            const start_pos = self.lspPositionAt(&self.cur().pt, start);
            const end_pos = self.lspPositionAt(&self.cur().pt, end);
            self.cur().history.beginGroup();
            try self.recordEdit(start, end - start, "");
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
                    try self.recordEdit(c, 1, &.{ch});
                    self.curCursor().* = c + seq;
                } else {
                    self.curCursor().* = c + seq;
                }
            }
            self.cur().history.endGroup();
            self.markDirty();
        },
        .join_lines => try joinLines(self, count),
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
                    try self.recordEdit(ls, 0, indent);
                } else {
                    // remove up to 4 leading spaces/tabs
                    var removed: u32 = 0;
                    while (removed < 4) : (removed += 1) {
                        if (ls >= pt.len()) break;
                        const b = pt.byteAt(ls);
                        if (b == ' ' or b == '\t') {
                            try self.recordEdit(ls, 1, "");
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
        // SPC TAB workspace family (M5)
        .workspace_new => try self.wsNew(),
        .workspace_pick => try self.wsOpenPicker(),
        .workspace_rename => try self.wsRenameStart(),
        .workspace_delete => self.wsDelete(),
        .workspace_kill_session => try self.wsKillSession(),
        .workspace_prev => self.wsSwitchDelta(-1),
        .workspace_next => self.wsSwitchDelta(1),
        // za/zo/zc/zR/zM — buffer fold state (not edits; no markDirty)
        .fold_toggle, .fold_open, .fold_close, .fold_open_all, .fold_close_all => try self.execFold(action),
        else => {},
    }
}

fn joinNeedsSpace(left: ?u8, right: u8) bool {
    const prev = left orelse return false;
    return prev != ' ' and prev != '\t' and right != ')';
}

/// Normal [count]J counts the current line. A final LF terminates the
/// last file line; the empty display row after it is not another join target.
fn joinLines(self: *App, count: u32) !void {
    const pt = &self.cur().pt;
    if (pt.len() == 0) return;
    const first = pt.lineOf(self.curCursor().*);
    const last = @min(first +| (@max(count, 2) - 1), pt.lineOf(pt.len() - 1));
    if (last <= first) return;

    const first_start = pt.lineStart(first);
    const start = first_start + pt.lineTextLen(first);
    const last_start = pt.lineStart(last);
    const last_end = last_start + pt.lineTextLen(last);
    var end = last_start;
    while (end < last_end and (pt.byteAt(end) == ' ' or pt.byteAt(end) == '\t')) end += 1;

    // Copy only the span being replaced. Strip intermediate indentation in
    // place: each inserted space fits in the preceding removed terminator.
    const span = try self.alloc.alloc(u8, end - start);
    defer self.alloc.free(span);
    pt.copyRange(start, span);
    var middle = span[pt.lineStart(first + 1) - start .. last_start - start];
    var left: ?u8 = if (start > first_start) pt.byteAt(start - 1) else null;
    var used: usize = 0;
    while (std.mem.indexOfScalar(u8, middle, '\n')) |lf| {
        const raw = middle[0..lf];
        middle = middle[lf + 1 ..];
        const body = std.mem.trimStart(u8, std.mem.cutSuffix(u8, raw, "\r") orelse raw, " \t");
        if (body.len == 0) continue;
        if (joinNeedsSpace(left, body[0])) {
            span[used] = ' ';
            used += 1;
        }
        @memmove(span[used..][0..body.len], body);
        used += body.len;
        left = span[used - 1];
    }
    const seam = start + @as(u32, @intCast(used));
    if (end < last_end and joinNeedsSpace(left, pt.byteAt(end))) {
        span[used] = ' ';
        used += 1;
    }
    const from = self.lspPositionAt(pt, start);
    const to = self.lspPositionAt(pt, end);
    const offsets = captureInlayOffsetsForReplace(self, start, end - start, @intCast(used));
    defer if (offsets) |value| self.alloc.free(value);
    try self.recordEdit(start, end - start, span[0..used]);
    var cursor = seam;
    if (end == last_end and seam > first_start) {
        var clusters = edit_range.graphemes(pt, first_start, seam);
        while (clusters.nextGrapheme()) |cluster| cursor = @intCast(cluster.start);
    }
    self.curCursor().* = cursor;
    self.markDirtyRange(from, to, span[0..used]);
    if (offsets) |value| applyInlayOffsetsAfterHistory(self, value);
}

/// r{char}: replace a complete typed grapheme, atomically, within this line.
/// A count past EOL is a no-op; the cursor stays on the final replacement.
pub fn replaceCharsAtCursor(self: *App, text: []const u8, count: u32) !void {
    const pt = &self.cur().pt;
    const start = edit_range.charStart(pt, self.curCursor().*);
    const line = pt.lineOf(start);
    const end = pt.lineStart(line) + pt.lineTextLen(line);
    if (start >= end) return;
    const source = try self.alloc.alloc(u8, end - start);
    defer self.alloc.free(source);
    pt.copyRange(start, source);
    const plan = (try replace_plan.plan(self.alloc, source, text, count)) orelse return;
    defer plan.deinit(self.alloc);
    if (std.mem.eql(u8, source[0..plan.before_len], plan.text)) {
        self.curCursor().* = start + plan.cursor_off;
        return;
    }
    const from = self.lspPositionAt(pt, start);
    const to = self.lspPositionAt(pt, start + plan.before_len);
    const offsets = captureInlayOffsetsForReplace(self, start, plan.before_len, @intCast(plan.text.len));
    defer if (offsets) |value| self.alloc.free(value);
    self.cur().history.beginGroup();
    try self.recordEdit(start, plan.before_len, plan.text);
    self.cur().history.endGroup();
    self.curCursor().* = start + plan.cursor_off;
    self.markDirtyRange(from, to, plan.text);
    if (offsets) |value| applyInlayOffsetsAfterHistory(self, value);
}
