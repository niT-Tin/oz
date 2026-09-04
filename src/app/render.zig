//! render — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const util = @import("../util/root.zig");
const syntax = @import("../syntax.zig");
const lsp_types = @import("../lsp/types.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const keymap_list = @import("../editor/keymap_list.zig");
const git = @import("../git.zig");
const term = @import("../term.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");
const git_job = @import("git_job.zig");

const tab_width = app_mod.tab_width;
const status_row_count = app_mod.status_row_count;
const blame_hold_ms = app_mod.blame_hold_ms;
const ScopeAnim = app_mod.ScopeAnim;
const formatHm = git_job.formatHm;
const gitPreviewLineCount = git_job.gitPreviewLineCount;
const Buffer = App.Buffer;
const LeafRect = App.LeafRect;
const foldAt = App.foldAt;
const foldCovering = App.foldCovering;
const foldNextLine = App.foldNextLine;
const foldPrevLine = App.foldPrevLine;
const foldSnapPos = App.foldSnapPos;
const kindGlyph = App.kindGlyph;

// ---- rendering ----

pub const filetree_width: u32 = 25;

/// Tab-bar rows: one per column-overlap layer of the pane layout.
/// Panes whose column spans overlap (horizontal splits stack
/// full-width panes) draw their tabs on separate rows so tabs never
/// overwrite each other; vertical splits share a row (their spans are
/// disjoint). Column spans don't depend on the split heights, so a
/// nominal content height is fine here.
pub fn tabBarRows(self: *App, a: std.mem.Allocator) u32 {
    if (self.windows.items.len <= 1) return 1;
    const height: u32 = self.vx.window().height;
    if (height <= status_row_count) return 1;
    const layout = self.layoutWindows(a, 1, height - status_row_count - 1, self.contentCol(), self.vx.window().width) catch return 1;
    const leaves = layout.leaves;
    // greedy interval coloring: assign each pane to the lowest layer
    // whose rightmost pane ends at or before this pane's column start
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(a);
    for (0..leaves.len) |i| order.append(a, i) catch return 1;
    std.mem.sort(usize, order.items, TabSort{ .leaves = leaves }, TabSort.lt);
    var layer_end: std.ArrayList(u32) = .empty;
    defer layer_end.deinit(a);
    var layers: u32 = 0;
    for (order.items) |oi| {
        const lr = leaves[oi];
        var li: usize = 0;
        while (li < layers and layer_end.items[li] > lr.col) li += 1;
        if (li == layers) {
            layer_end.append(a, lr.col + lr.width) catch return 1;
            layers += 1;
        } else {
            layer_end.items[li] = lr.col + lr.width;
        }
    }
    return layers;
}

/// Sort panes by column for tab streaming: left to right, wider first
/// when spans start at the same column (stable per pane index).
pub const TabSort = struct {
    leaves: []LeafRect,
    fn lt(ctx: TabSort, x: usize, y: usize) bool {
        const ax = ctx.leaves[x];
        const ay = ctx.leaves[y];
        if (ax.col != ay.col) return ax.col < ay.col;
        return ax.width > ay.width;
    }
};

/// Row where the editor content starts (below the tab bar).
pub fn contentTop(self: *App, a: std.mem.Allocator) u32 {
    return self.tabBarRows(a);
}

pub fn contentCol(self: *const App) u32 {
    return if (self.filetree_active) filetree_width else 0;
}

/// Width of the relative-line-number gutter in cells: digits of the
/// largest possible relative number (≤ the file's line count, since a
/// relative number is a line offset) + one trailing space. Adaptive —
/// narrow for small files (vim's relativenumber fits the digits).
pub fn gutterWidth(self: *const App, line_count: u32) u32 {
    _ = self;
    var digits: u32 = 1;
    var n: u32 = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits + 1;
}

/// Display column (in cells) of `byte_pos` within `line`. vaxis renders a
/// multi-byte grapheme as one or two cells, so anything positioned from a
/// byte offset (the text cursor, the completion menu, ghost text) must be
/// converted — otherwise the cursor appears stuck mid-text on lines that
/// contain non-ASCII characters (e.g. after accepting a suggestion that
/// inserted text before/after CJK characters).
pub fn lineCellCol(self: *App, win: vaxis.Window, line: u32, byte_pos: u32) u32 {
    const pt = &self.cur().pt;
    const line_start = pt.lineStart(line);
    var p = line_start;
    var col: u32 = 0;
    // Scan a chunked COPY of the line: per-byte byteAt is O(pieces), so
    // walking long lines byte by byte costs O(line_len × pieces) per
    // call, several times per frame.
    var chunk: [4096]u8 = undefined;
    var chunk_start: u32 = 0;
    var chunk_len: usize = 0;
    while (p < byte_pos) {
        if (p < chunk_start or p >= chunk_start + chunk_len) {
            chunk_start = p;
            chunk_len = @min(@as(usize, @intCast(byte_pos - p)), chunk.len);
            pt.copyRange(p, chunk[0..chunk_len]);
        }
        const b = chunk[p - chunk_start];
        // A tab occupies `tab_width` cells (the renderer expands it), not
        // the 0 vaxis reports — otherwise cursor/ghost/menu columns would
        // disagree with the drawn line on files containing tabs.
        if (b == '\t') {
            col += tab_width;
            p += 1;
            continue;
        }
        const seq_len: usize = if (b < 0x80)
            1
        else
            (std.unicode.utf8ByteSequenceLength(b) catch 1);
        const avail = @min(seq_len, @as(usize, @intCast(byte_pos - p)));
        var ch_buf: [4]u8 = undefined;
        pt.copyRange(p, ch_buf[0..avail]);
        col += win.gwidth(ch_buf[0..avail]);
        p += @intCast(avail);
    }
    return col;
}

/// Display width (cells) of `text` — the same per-grapheme gwidth the
/// renderer uses. Used to shift columns past inlay hints: they occupy
/// screen cells but no buffer bytes, so a plain text column understates
/// the on-screen position by their combined width.
pub fn textWidth(self: *App, win: vaxis.Window, text: []const u8) u32 {
    _ = self;
    var col: u32 = 0;
    var p: usize = 0;
    while (p < text.len) {
        const b = text[p];
        if (b == '\t') {
            col += tab_width;
            p += 1;
            continue;
        }
        const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
        const avail = @min(seq_len, text.len - p);
        col += win.gwidth(text[p .. p + avail]);
        p += avail;
    }
    return col;
}

/// LSP positions are in UTF-16 code units, not bytes. Convert a byte
/// column within `line` (BMP chars = 1 unit, supplementary = 2). Without
/// this, hover/gd/completion/rename land at the wrong column on any line
/// containing CJK/emoji before the cursor.
pub fn utf16Column(self: *App, line: u32, byte_col: u32) u32 {
    const pt = &self.cur().pt;
    const ls = pt.lineStart(line);
    var p = ls;
    var units: u32 = 0;
    while (p < ls + byte_col) {
        const b = pt.byteAt(p);
        const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
        units += if (seq_len >= 4) 2 else 1;
        p += @intCast(seq_len);
    }
    return units;
}

/// Inverse of utf16Column: the byte offset within `line` of the
/// character at UTF-16 column `utf16_col` (LSP positions are UTF-16
/// code units). Clamped to the line end when the column runs past the
/// text (some servers report a hint at the token end == line end).
pub fn byteColumnFromUtf16(self: *App, line: u32, utf16_col: u32) u32 {
    const pt = &self.cur().pt;
    const ls = pt.lineStart(line);
    const end = ls + pt.lineLen(line);
    var p = ls;
    var units: u32 = 0;
    while (p < end) {
        if (units >= utf16_col) break;
        const b = pt.byteAt(p);
        const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
        units += if (seq_len >= 4) 2 else 1;
        p += @intCast(seq_len);
    }
    return p - ls;
}

/// On-screen cell column of `byte_pos` within `line`: the text column
/// plus the width of every inlay hint spliced before it.
pub fn screenCellCol(self: *App, win: vaxis.Window, line: u32, byte_pos: u32) u32 {
    if (self.cell_col_memo.valid and self.cell_col_memo.line == line and self.cell_col_memo.pos == byte_pos) {
        return self.cell_col_memo.col;
    }
    const text_col = self.lineCellCol(win, line, byte_pos);
    var col = text_col;
    // hints anchored before the cursor widen the cursor's cell column.
    // hint.character is a byte column (see processInlay), so compare it
    // with the cursor's byte offset within the line — not a cell column.
    // screenCellCol is only ever queried for the FOCUSED window / current
    // buffer, so count hints only when they belong to that buffer (the
    // same inlay_buf filter the text renderer applies): a foreign
    // buffer's hints are not drawn here and must not shift the cursor.
    const ls = self.cur().pt.lineStart(line);
    const in_line = if (byte_pos >= ls) byte_pos - ls else 0;
    if (!self.inlay_stale and self.inlay_buf == self.current) {
        for (self.inlay_hints.items) |hint| {
            if (hint.line == line and hint.character <= in_line) {
                col += self.textWidth(win, hint.label);
            }
        }
    }
    self.cell_col_memo = .{ .line = line, .pos = byte_pos, .col = col, .valid = true };
    return col;
}

/// true when buffer line `l` has no non-whitespace content.
/// Reads the line with ONE copyRange into a stack buffer (chunked for
/// long lines) instead of per-char byteAt — byteAt is O(pieces) per byte,
/// so a per-char scan of a many-piece buffer is quadratic; a copyRange is
/// O(pieces + len) total.
pub fn isBlankLine(self: *App, buf: *Buffer, l: u32) bool {
    _ = self;
    const ls = buf.pt.lineStart(l);
    const ll = buf.pt.lineLen(l);
    var chunk: [128]u8 = undefined;
    var off: u32 = 0;
    while (off < ll) {
        const n = @min(ll - off, @as(u32, chunk.len));
        buf.pt.copyRange(ls + off, chunk[0..n]);
        for (chunk[0..n]) |b| {
            if (b != ' ' and b != '\t') return false;
        }
        off += n;
    }
    return true;
}

/// Expanded indent levels (columns / tab_width) of buffer line `l`.
/// Same single-copyRange read as isBlankLine (the indent region is at the
/// line start, so the first chunk almost always decides).
pub fn lineIndentLevels(self: *App, buf: *Buffer, l: u32) u32 {
    _ = self;
    const ls = buf.pt.lineStart(l);
    const ll = buf.pt.lineLen(l);
    var chunk: [128]u8 = undefined;
    var cols: u32 = 0;
    var off: u32 = 0;
    while (off < ll) {
        const n = @min(ll - off, @as(u32, chunk.len));
        buf.pt.copyRange(ls + off, chunk[0..n]);
        for (chunk[0..n]) |b| {
            if (b == ' ') {
                cols += 1;
            } else if (b == '\t') {
                cols += tab_width;
            } else return cols / tab_width;
        }
        off += n;
    }
    return cols / tab_width;
}

/// Indent levels of the nearest non-blank line around `line`, up to 500
/// lines out — the context for blank-line indent-guide continuation.
/// Scans upward first, then downward from `line + 1` (the original
/// per-row semantics). 0 when the 500-line window is all blank.
pub fn blankContextLevels(self: *App, buf: *Buffer, line: u32, line_count: u32) u32 {
    var ctx_levels: u32 = 0;
    var ctx: i64 = @as(i64, @intCast(line)) - 1;
    var dir: i64 = -1;
    var scanned: usize = 0;
    const lc: i64 = @as(i64, @intCast(line_count));
    while (scanned < 500) : (scanned += 1) {
        if (ctx < 0) {
            if (dir == -1) {
                ctx = @as(i64, @intCast(line)) + 1;
                dir = 1;
                continue;
            }
            break;
        }
        if (ctx >= lc) break;
        const cl: u32 = @intCast(ctx);
        if (!self.isBlankLine(buf, cl)) {
            ctx_levels = self.lineIndentLevels(buf, cl);
            break;
        }
        ctx += dir;
    }
    return ctx_levels;
}

/// Render one split window's lines into `rect` (content-area coordinates).
/// The highlighter is bound to the current buffer, so only the focused
/// window gets syntax highlighting and the (single) visual selection.
pub fn renderWindowLines(self: *App, a: std.mem.Allocator, rect: LeafRect, is_focused: bool) !void {
    const win = self.vx.window();
    const w = &self.windows.items[rect.win];
    const buf = &self.buffers.items[w.buf];

    // A buffer edited through ANOTHER window may have shrunk under this
    // window's cursor/viewport (e.g. delete at EOF while a split window's
    // cursor sat there) — clamp before any line math, which asserts on
    // out-of-range positions (lineOf / lineStart).
    if (w.cursor > buf.pt.len()) w.cursor = buf.pt.len();
    if (w.view_top > buf.pt.lineCount() -| 1) w.view_top = buf.pt.lineCount() -| 1;

    // Fold backstop: the cursor must never sit on a hidden line. Every
    // fold-aware motion snaps already; this catches the paths that don't
    // go through them (search jumps, LSP goto, :N, splits' stale cursors).
    w.cursor = foldSnapPos(buf, w.cursor);

    const cursor_line = buf.pt.lineOf(w.cursor);
    const line_count = buf.pt.lineCount();
    // relative-number gutter: computed once per frame per window
    const gutter = self.gutterWidth(line_count);
    const gutter_digits = gutter - 1;

    // keep cursor line visible (per-window viewport). Fold-aware: a
    // closed fold occupies ONE screen row, so screen distances are
    // counted by walking visible lines, not by line-number arithmetic.
    // view_top itself must be a visible line — snap it up out of any
    // closed fold it fell into.
    if (foldCovering(buf, w.view_top)) |f| w.view_top = f.start;
    if (cursor_line < w.view_top) {
        w.view_top = cursor_line;
    }
    // rows between view_top and the cursor line (cursor inclusive of
    // itself, view_top row counts as row 0)
    var rows_to_cursor: u32 = 0;
    {
        var l = w.view_top;
        while (l < cursor_line) : (rows_to_cursor += 1) l = foldNextLine(buf, l);
    }
    while (rows_to_cursor >= rect.height and w.view_top < cursor_line) {
        w.view_top = foldNextLine(buf, w.view_top);
        rows_to_cursor -= 1;
    }
    // don't scroll past the end leaving blank rows: pull view_top up
    // while fewer than `height` visible rows remain below it (without
    // pushing the cursor off-screen)
    {
        var below: u32 = rows_to_cursor + 1; // + the cursor row itself
        // Count the visible rows below the cursor, but only up to the
        // viewport height: the pull-up below only cares whether fewer
        // than `height` rows remain, and the walk to EOF is O(lines)
        // per frame (a 135k-line file would scan to the end on every
        // render). Early-exit keeps this O(height) in the common case.
        var l = cursor_line;
        while (l + 1 < line_count and below < rect.height) {
            l = foldNextLine(buf, l);
            below += 1;
        }
        while (below < rect.height and w.view_top > 0 and rows_to_cursor + 1 < rect.height) {
            w.view_top = foldPrevLine(buf, w.view_top);
            below += 1;
            rows_to_cursor += 1;
        }
    }

    // syntax spans covering the visible byte range — every window uses
    // its own buffer's highlighter, so splits showing different buffers
    // each get real tree-sitter highlighting. With closed folds the
    // visible rows span MORE document lines than rect.height (hidden
    // bodies are skipped), so walk the actual last visible line first.
    var last_visible = w.view_top;
    {
        var vr: u32 = 1;
        while (vr < rect.height and last_visible + 1 < line_count) : (vr += 1) {
            last_visible = foldNextLine(buf, last_visible);
        }
    }
    // Syntax spans covering the visible byte range. The tree-sitter
    // query is the single most expensive per-frame item (it runs per
    // visible range), and its result is a pure function of (tree
    // revision, byte range) — so cache it per buffer and reuse it while
    // both are unchanged. Cursor movement inside a window keeps the
    // range fixed, and the ~30 scope-animation frames repaint the same
    // viewport, so this turns the common case into a pointer fetch.
    // visibleSpansFor still owns the query + reparse logic (and lazily
    // initializes buf.hl on the first miss).
    const span_revision = buf.history.revision;
    const span_rows = last_visible - w.view_top + 1;
    const span_start = buf.pt.lineStart(@min(w.view_top, line_count -| 1));
    const span_vbottom = @min(w.view_top + span_rows, line_count);
    const span_end: u32 = if (span_vbottom >= line_count) buf.pt.len() else buf.pt.lineStart(span_vbottom);
    var merged: []syntax.Span = undefined;
    if (buf.span_cache) |*sc| {
        if (sc.revision == span_revision and sc.start == span_start and sc.end == span_end) {
            merged = sc.spans;
        } else {
            const fresh = try self.visibleSpansFor(buf, a, w.view_top, span_rows);
            if (sc.spans.len > 0) self.alloc.free(sc.spans);
            sc.* = .{
                .revision = span_revision,
                .start = span_start,
                .end = span_end,
                .spans = try self.alloc.dupe(syntax.Span, fresh),
            };
            merged = sc.spans;
        }
    } else {
        const fresh = try self.visibleSpansFor(buf, a, w.view_top, span_rows);
        buf.span_cache = .{
            .revision = span_revision,
            .start = span_start,
            .end = span_end,
            .spans = try self.alloc.dupe(syntax.Span, fresh),
        };
        merged = buf.span_cache.?.spans;
    }

    // scope highlight (nvim snacks.indent.scope): the byte range of the
    // block containing this window's cursor, converted to a line range.
    // Skipped when the buffer has no highlighter (no grammar for the
    // filetype / over the size limit) — scopeAt also returns null for
    // empty files, top-level code and before the first parse.
    var scope_start_line: u32 = 0;
    var scope_end_line: u32 = 0;
    var scope_indent_col: u32 = 0;
    var has_scope = false;
    if (buf.hl) |*hl| {
        // scopeAt walks the tree from the root each call — reuse the last
        // result while the tree (history revision) and the queried cursor
        // byte are unchanged (sound: scopeAt's result is a pure function
        // of the tree and the byte). This is the common case for the
        // scope-animation frames that repaint every 16ms without the
        // cursor moving, and for split windows showing the same buffer.
        const revision = buf.history.revision;
        var cached = false;
        if (self.scope_cache) |*c| {
            if (c.buf == w.buf and c.win == rect.win and
                c.revision == revision and c.cursor == w.cursor)
            {
                scope_start_line = c.start_line;
                scope_end_line = c.end_line;
                scope_indent_col = c.indent_col;
                has_scope = c.has;
                cached = true;
            }
        }
        if (!cached) {
            var sc_has = false;
            var sc_start: u32 = 0;
            var sc_end: u32 = 0;
            var sc_indent: u32 = 0;
            if (hl.scopeAt(w.cursor)) |sc| {
                sc_start = buf.pt.lineOf(sc.start_byte);
                // end_byte is exclusive — the last byte inside the scope
                // is end_byte - 1 (lineOf maps pos == len to the last
                // line, so either clamp would work; -| guards the empty
                // edge case)
                sc_end = buf.pt.lineOf(sc.end_byte -| 1);
                // the scope's own guide column: the expanded indent of
                // its starting line (snacks.indent renders the scope line
                // at `scope.indent`)
                sc_indent = sc.indent_col;
                sc_has = true;
            }
            self.scope_cache = .{
                .buf = w.buf,
                .win = rect.win,
                .revision = revision,
                .cursor = w.cursor,
                .start_line = sc_start,
                .end_line = sc_end,
                .indent_col = sc_indent,
                .has = sc_has,
            };
            scope_start_line = sc_start;
            scope_end_line = sc_end;
            scope_indent_col = sc_indent;
            has_scope = sc_has;
        }
    }
    // ---- scope highlight animation (snacks.indent.animate "out") ----
    // The focused window's guides spread from the cursor line to the
    // scope edges over ~500ms whenever the scope block changes; the run
    // loop polls while animating so the frame advances on its own.
    // Non-focused windows get the full scope immediately (no animation).
    var anim_from: u32 = 0;
    var anim_to: u32 = 0;
    var scope_animating = false;
    if (is_focused) {
        if (!has_scope) {
            self.scope_anim = null;
        } else {
            const now = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms);
            if (self.scope_anim) |*anim| {
                if (anim.start_line != scope_start_line or anim.end_line != scope_end_line) {
                    anim.* = .{ .start_line = scope_start_line, .end_line = scope_end_line, .cursor_line = cursor_line, .start_ms = now };
                }
            } else {
                self.scope_anim = .{ .start_line = scope_start_line, .end_line = scope_end_line, .cursor_line = cursor_line, .start_ms = now };
            }
            const anim = &self.scope_anim.?;
            const elapsed = now - anim.start_ms;
            if (elapsed >= ScopeAnim.duration_ms) {
                anim_from = scope_start_line;
                anim_to = scope_end_line;
            } else {
                scope_animating = true;
                const p: f64 = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ScopeAnim.duration_ms));
                const up: u32 = @intFromFloat(p * @as(f64, @floatFromInt(anim.cursor_line -| anim.start_line)));
                const down: u32 = @intFromFloat(p * @as(f64, @floatFromInt(anim.end_line -| anim.cursor_line)));
                anim_from = anim.cursor_line -| up;
                anim_to = anim.cursor_line + down;
            }
        }
    }

    var span_i: usize = 0;
    var row: u32 = rect.row;
    var line = w.view_top;
    // blank-run context cache: consecutive blank rows share the nearest
    // non-blank line's indent levels (see the scan below)
    var prev_blank: ?u32 = null;
    var blank_run_ctx: u32 = 0;
    // Per-row allocations are a per-frame cost, not a per-row one: one
    // text buffer (width × height), one gutter-number buffer and one
    // guide-row buffer for the whole window, and ONE segs ArrayList whose
    // capacity is reserved once per frame (clearRetainingCapacity per
    // row). The segments' text slices reference these frame buffers (and
    // the arena), both alive until vx.render().
    const text_buf = try a.alloc(u8, @as(usize, rect.width) * rect.height);
    const num_buf = try a.alloc(u8, @as(usize, gutter) * rect.height);
    const guide_buf = try a.alloc(u8, rect.width);
    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.ensureTotalCapacity(a, @as(usize, rect.width) * 2 + 64);
    // diagnostics are sorted by line (sortByLine): a moving pointer keeps
    // the mark lookup O(rows + diags) instead of O(rows × diags)
    var diag_i: usize = 0;
    const diags = self.lsp_diagnostics.items;
    // git hunks are sorted by construction (git diff output order): the
    // same moving-pointer trick for the gutter sign
    var hunk_i: usize = 0;
    const hunks = self.git_diff.hunks.items;
    while (row < rect.row + rect.height and line < line_count) : ({
        // skip a closed fold's body: it shares its header's screen row
        line = foldNextLine(buf, line);
        row += 1;
    }) {
        const rel: u32 = if (line == cursor_line)
            line + 1
        else if (line > cursor_line)
            line - cursor_line
        else
            cursor_line - line;
        // relative number, right-aligned in the numeric field plus one
        // trailing space. allocPrint's width is comptime-only, so pad by
        // hand; the digits go into a stack buffer, the padded field into
        // the per-frame num_buf slice for this row.
        var raw_digits: [32]u8 = undefined;
        const num_raw = std.fmt.bufPrint(&raw_digits, "{d}", .{rel}) catch unreachable;
        const row_i: usize = (row - rect.row);
        const num_str = num_buf[row_i * gutter ..][0..gutter];
        @memset(num_str[0..gutter], ' ');
        @memcpy(num_str[gutter_digits - num_raw.len .. gutter_digits], num_raw);
        num_str[gutter - 1] = ' ';

        // LSP diagnostic mark in the gutter's last column (this window
        // shows the current buffer → marks the current file's
        // diagnostics). Nerd Font icons (spec: 图标体系 = Nerd Font),
        // like nvim's diagnostic gutter: ✖ for errors, ⚠ warnings, ℹ
        // info. A bare letter (E/W/I) read as noise/errors to users.
        // Marks render in EVERY mode (nvim behavior): hiding them during
        // insert made a pre-existing mark "appear" on exit, which read as
        // a bug; the diag_dirty repaint keeps them live while typing.
        var diag_mark: []const u8 = " ";
        var diag_mark_fg: ?vaxis.Style = null;
        if (w.buf == self.current and diags.len > 0) {
            // advance to the first diagnostic at/after this row's line
            // (rows ascend, so diag_i only moves forward)
            while (diag_i < diags.len and diags[diag_i].range.start.line < line) diag_i += 1;
            if (diag_i < diags.len and diags[diag_i].range.start.line == line) {
                const d = diags[diag_i];
                diag_mark = switch (d.severity) {
                    .err => "\u{f467}", // nf-fa-times_circle ✖
                    .warning => "\u{f071}", // nf-fa-warning ⚠
                    else => "\u{f05a}", // nf-fa-info_circle ℹ
                };
                diag_mark_fg = switch (d.severity) {
                    .err => .{ .fg = .{ .rgb = self.theme.diag_error } },
                    .warning => .{ .fg = .{ .rgb = self.theme.diag_warn } },
                    else => .{ .fg = .{ .rgb = self.theme.diag_info } },
                };
            }
        }

        // Git sign (M3a) for the same last gutter cell, when the line
        // carries no diagnostic mark. Only for a CLEAN buffer: the diff
        // describes the file on disk, and while dirty the marks would
        // lie about the visible text (they return after :w refreshes).
        // Also only when the diff was computed for THIS buffer's path.
        var git_mark: ?git.LineKind = null;
        var git_mark_fg: ?vaxis.Style = null;
        if (w.buf == self.current and !buf.dirty) {
            if (self.git_diff_path) |dp| {
                if (buf.path) |cp| {
                    if (std.mem.eql(u8, dp, cp)) {
                        if (self.git_diff.untracked) {
                            // untracked file: every line reads as added
                            git_mark = .added;
                            git_mark_fg = .{ .fg = .{ .rgb = self.theme.git_add } };
                        } else {
                            // advance past hunks whose marked region ends
                            // before this row's line (hunks sorted; lines[]
                            // is indexed by absolute line number)
                            while (hunk_i < hunks.len and hunks[hunk_i].lines.len <= line) hunk_i += 1;
                            if (hunk_i < hunks.len) {
                                if (hunks[hunk_i].markAt(line)) |k| {
                                    git_mark = k;
                                    git_mark_fg = switch (k) {
                                        .added => .{ .fg = .{ .rgb = self.theme.git_add } },
                                        .modified => .{ .fg = .{ .rgb = self.theme.git_mod } },
                                        .removed_above, .removed_below => .{ .fg = .{ .rgb = self.theme.git_del } },
                                    };
                                }
                            }
                        }
                    }
                }
            }
        }

        const line_len = buf.pt.lineLen(line);
        const line_start = buf.pt.lineStart(line);
        // the row also carries the gutter (rect.col + gutter), so the
        // content width is rect.width minus the gutter — otherwise long
        // lines are clipped on the right by the gutter width
        var n: u32 = @min(line_len, rect.width -| gutter);
        // don't cut a multibyte char in half at the line end — a lone
        // UTF-8 continuation byte renders as U+FFFD ("box with ?")
        while (n > 0 and n < line_len and (buf.pt.byteAt(line_start + n) & 0xC0) == 0x80) {
            n -= 1;
        }
        // line text lives in the per-frame text_buf row slice (valid
        // until vx.render, like every other segment slice)
        const text = text_buf[row_i * rect.width ..][0..n];
        buf.pt.copyRange(line_start, text);

        // visual selection bounds as local columns (both = n if absent);
        // only the focused window carries the selection
        var sel_s: u32 = n;
        var sel_e: u32 = n;
        if (is_focused) {
            if (self.visual_anchor) |anchor| {
                var sel_start = @min(anchor, w.cursor);
                var sel_end = @max(anchor, w.cursor);
                // V (visual_line) selects whole lines
                if (self.state.mode == .visual_line) {
                    sel_start = buf.pt.lineStart(buf.pt.lineOf(sel_start));
                    sel_end = buf.pt.lineStart(buf.pt.lineOf(sel_end)) + buf.pt.lineLen(buf.pt.lineOf(sel_end));
                }
                // Ctrl+v (visual_block) selects a rectangle
                if (self.state.mode == .visual_block) {
                    if (self.blockRect()) |br| {
                        if (line >= br.top and line <= br.bottom) {
                            sel_s = @min(br.left, line_len);
                            sel_e = @min(br.right + 1, line_len);
                        }
                    }
                } else {
                    const line_end = line_start + line_len;
                    if (sel_start < line_end and sel_end > line_start) {
                        sel_s = @max(sel_start, line_start) - line_start;
                        sel_e = @min(sel_end, line_end) - line_start;
                    }
                }
            }
        }

        // split the line into styled runs: syntax fg from the merged
        // spans, cursorline bg on the cursor's row, selection bg wins
        const is_cur_line = line == cursor_line;
        segs.clearRetainingCapacity();
        // gutter: always painted (bg_alt), cursor line slightly brighter
        const cursorline_style: vaxis.Style = if (is_cur_line)
            .{ .bg = .{ .rgb = self.theme.bg_curline }, .fg = .{ .rgb = self.theme.fg } }
        else
            .{ .bg = .{ .rgb = self.theme.bg_alt }, .fg = .{ .rgb = self.theme.fg_faint } };
        try segs.append(a, .{ .text = num_str[0 .. gutter - 1], .style = cursorline_style });
        try segs.append(a, .{ .text = num_str[gutter - 1 .. gutter], .style = cursorline_style });
        // Inlay hints for this line, sorted by insertion column: each hint
        // is spliced into the text at its character offset (the token it
        // annotates ends there), so `const x = foo()` renders as
        // `const x: i32 = foo()` like nvim — not moved to end of line.
        // Hints render in insert mode too (vim shows them while typing);
        // the data is shift-maintained per edit so it stays at the right
        // column. `inlay_stale` only hides them for the brief window
        // after a buffer switch / invalidation until a fresh response
        // lands — NOT on insert exit (that caused the jk vanish flash).
        //
        // The stored hints are homogeneous — they all describe the buffer
        // `inlay_buf` names (the last accepted response's buffer, i.e.
        // whichever buffer was FOCUSED when its hints were fetched). THIS
        // window renders them only while it shows that buffer: a split
        // window displaying a DIFFERENT buffer must not splice hints whose
        // line numbers and byte columns were computed against another
        // document's text (inlay hints "misaligned" over the wrong text).
        // Hints for the unfocused window are simply not loaded — only the
        // focused window requests (single-document LSP client) — so that
        // window renders none, which is correct.
        const line_hints = if (self.inlay_stale or self.inlay_buf != w.buf)
            &.{}
        else
            try self.lineHints(a, line);
        var hint_i: usize = 0;
        // scope membership for this line: focused windows use the
        // animation spread range, others the full scope
        const in_scope = if (is_focused)
            has_scope and line >= anim_from and line <= anim_to
        else
            has_scope and line >= scope_start_line and line <= scope_end_line;

        // ---- indent guides (nvim snacks.indent) ----
        // The line's leading whitespace renders as one "│" (U+2502) per
        // 4-column indent level (tab_width). Guides outside the cursor's
        // scope block are dim gray (snacks links SnacksIndent to NonText);
        // inside the scope they take the rainbow indent[level % 8] ramp
        // (snacks' SnacksIndent1..8) — with the outwards spread animation
        // filling the scope from the cursor line. The scope's FIRST line
        // (its declaration/opening line) gets an underline in the text
        // (snacks.indent.scope underline). A "│" occupies exactly one
        // cell, so the region keeps the expanded width of the whitespace
        // it replaces (tab = tab_width cells) — byte columns, cursor
        // placement, selection bounds and every existing row/column
        // assertion stay unchanged. Empty lines and indent < 4 columns
        // ("不足 4 列的部分") draw nothing (the spaces still render).
        var indent_end: u32 = 0;
        while (indent_end < n and (text[indent_end] == ' ' or text[indent_end] == '\t')) indent_end += 1;
        // expanded column count of the indent region (space = 1 col,
        // tab = tab_width cols) — also needed by the blank-line
        // continuation below, so computed here for both paths
        var indent_cols: u32 = 0;
        var ib: u32 = 0;
        while (ib < indent_end) : (ib += 1) indent_cols += if (text[ib] == '\t') tab_width else 1;
        if (indent_end > 0) {
            const indent_levels: u32 = indent_cols / tab_width;
            // hints anchored at/inside the indent region render before it
            // (normally none: hints annotate tokens, which start past the
            // indent) — keeps the hint-before-text ordering of the main loop
            while (hint_i < line_hints.len and line_hints[hint_i].character <= indent_end) {
                const hint = line_hints[hint_i];
                if (hint.label.len > 0) {
                    try segs.append(a, .{
                        .text = hint.label,
                        .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                    });
                }
                hint_i += 1;
            }
            var gcol: u32 = 0; // expanded column of the current indent cell
            ib = 0;
            while (ib < indent_end) : (ib += 1) {
                const cell_w: u32 = if (text[ib] == '\t') tab_width else 1;
                var j: u32 = 0;
                while (j < cell_w) : (j += 1) {
                    const level: u32 = gcol / tab_width;
                    const is_guide = gcol % tab_width == 0 and gcol < indent_levels * tab_width;
                    var gstyle: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
                    if (is_cur_line) gstyle.bg = .{ .rgb = self.theme.bg_curline };
                    if (ib >= sel_s and ib < sel_e) gstyle.bg = .{ .rgb = self.theme.bg_sel };
                    if (is_guide) {
                        // Only the scope's OWN guide column (its starting
                        // line's indent, snacks: `i > indent` rows) is
                        // highlighted; every other level's guides stay dim
                        // gray — entering a nested scope must NOT keep the
                        // outer scopes' lines lit.
                        const is_scope_guide = in_scope and
                            gcol == scope_indent_col and
                            indent_cols > scope_indent_col;
                        gstyle.fg = .{ .rgb = if (is_scope_guide) self.theme.indent[level % 8] else self.theme.fg_dim };
                        try segs.append(a, .{ .text = "│", .style = gstyle });
                    } else {
                        try segs.append(a, .{ .text = " ", .style = gstyle });
                    }
                    gcol += 1;
                }
            }
        }
        // Blank / whitespace-only lines: the indent guides continue
        // through them (snacks.indent draws blank rows too), so the
        // guides never break across empty lines. The gray levels
        // come from the nearest non-blank line (above, else below);
        // inside the cursor's scope the scope's own guide column is
        // highlighted (rainbow). NOTE: only ACTUALLY blank lines
        // reach this — a content line at column 0 (fn header,
        // closing brace) has indent_end == 0 but indent_end != n, so
        // the scope's vertical never extends onto those rows.
        //
        // Consecutive blank rows share their context: the scan probes
        // the same blank lines for every row of a run (a run of R rows
        // would otherwise probe up to R×500 lines), so the context is
        // computed once per run and reused while the run continues.
        if (indent_end == n) {
            var ctx_levels: u32 = 0;
            if (prev_blank != null and line == prev_blank.? + 1) {
                ctx_levels = blank_run_ctx;
            } else {
                ctx_levels = self.blankContextLevels(buf, line, line_count);
                blank_run_ctx = ctx_levels;
            }
            prev_blank = line;
            const start_col: u32 = indent_cols;
            const ctx_cols: u32 = @min(ctx_levels * tab_width, rect.width -| gutter);
            // the scope's highlighted guide column (only when it lies
            // past the line's own indent — deeper whitespace-only
            // lines already got it from the loop above); sentinel
            // rect.width when absent / off-screen
            const scope_col: u32 = if (in_scope and scope_indent_col >= indent_cols and
                scope_indent_col < rect.width -| gutter)
                scope_indent_col
            else
                rect.width;
            const end_col: u32 = @max(ctx_cols, if (scope_col < rect.width) scope_col + 1 else ctx_cols);
            if (end_col > start_col) {
                const n_cells = end_col - start_col;
                const row_buf = guide_buf[0..n_cells];
                @memset(row_buf, ' ');
                var gc: u32 = start_col;
                while (gc < end_col) : (gc += 1) {
                    // guide cells use a 1-byte marker; the real glyph
                    // is the 3-byte "│", emitted per cell below
                    if (gc % tab_width == 0 and gc != scope_col) row_buf[gc - start_col] = 0x01;
                }
                const gstyle: vaxis.Style = .{
                    .bg = .{ .rgb = if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                    .fg = .{ .rgb = self.theme.fg_dim },
                };
                // emit runs, converting markers to "│", splitting
                // around the scope cell so it gets its own color
                const off = if (scope_col >= start_col and scope_col < end_col) scope_col - start_col else n_cells;
                var run_start: usize = 0;
                var k: usize = 0;
                while (k < n_cells) : (k += 1) {
                    if (k == off) {
                        if (k > run_start) try segs.append(a, .{ .text = row_buf[run_start..k], .style = gstyle });
                        const level: u32 = scope_col / tab_width;
                        try segs.append(a, .{ .text = "│", .style = .{
                            .bg = gstyle.bg,
                            .fg = .{ .rgb = self.theme.indent[level % 8] },
                        } });
                        run_start = k + 1;
                    } else if (row_buf[k] == 0x01) {
                        if (k > run_start) try segs.append(a, .{ .text = row_buf[run_start..k], .style = gstyle });
                        try segs.append(a, .{ .text = "│", .style = gstyle });
                        run_start = k + 1;
                    }
                }
                if (run_start < n_cells) try segs.append(a, .{ .text = row_buf[run_start..], .style = gstyle });
            }
        } else {
            prev_blank = null;
        }
        var col: u32 = indent_end; // text starts after the indent region
        while (col < n) {
            // emit any hint whose insertion column is at/just passed col
            // (before the next text segment, so it reads token+hint)
            while (hint_i < line_hints.len and line_hints[hint_i].character <= col) {
                const hint = line_hints[hint_i];
                if (hint.label.len > 0) {
                    try segs.append(a, .{
                        .text = hint.label,
                        .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                    });
                }
                hint_i += 1;
            }
            while (span_i < merged.len and merged[span_i].end <= line_start + col) span_i += 1;
            var next: u32 = n;
            var fg: ?vaxis.Style = null;
            if (span_i < merged.len) {
                const sp = merged[span_i];
                if (sp.start < line_start + n and sp.end > line_start + col) {
                    fg = autil.syntaxStyle(sp.style, self.theme);
                    const sp_start: u32 = if (sp.start > line_start) sp.start - line_start else 0;
                    const sp_end: u32 = if (sp.end < line_start + n) sp.end - line_start else n;
                    next = if (sp_start > col) sp_start else sp_end;
                }
            }
            if (sel_s > col and sel_s < next) next = sel_s;
            if (sel_e > col and sel_e < next) next = sel_e;
            // stop the text segment at the next hint's insertion column so
            // the hint is spliced between tokens (hints sorted ascending)
            if (hint_i < line_hints.len) {
                const hc = line_hints[hint_i].character;
                if (hc > col and hc < next) next = hc;
            }
            const in_sel = col >= sel_s and col < sel_e;
            var style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
            if (is_cur_line) style.bg = .{ .rgb = self.theme.bg_curline };
            if (in_sel) style.bg = .{ .rgb = self.theme.bg_sel };
            // syntaxStyle returns a full vaxis.Style (e.g. Boolean is
            // bold) — merge the whole thing, not just the fg
            if (fg) |f| {
                style.fg = f.fg;
                style.bold = f.bold;
                style.italic = f.italic;
            }
            // snacks.indent.scope underline: the scope's FIRST line (its
            // declaration/opening line) is underlined from the text start
            // to end of line, once the animation spread has covered it
            // (snacks draws it when scope.from == from), in the scope's
            // own guide color. The e2e grid parses SGR colors only, so
            // this is cosmetic, never asserted.
            if (is_focused and in_scope and line == scope_start_line and anim_from <= scope_start_line) {
                style.ul = .{ .rgb = self.theme.indent[(scope_indent_col / tab_width) % 8] };
                style.ul_style = .single;
            }
            const seg_text = text[col..next];
            if (std.mem.indexOfScalar(u8, seg_text, '\t') != null) {
                // Expand tabs to `tab_width` spaces so they render (vaxis
                // skips 0-width chars) and their drawn width matches
                // lineCellCol/textWidth — otherwise the cursor column and
                // the visible line disagree on tab-containing files.
                var expanded = std.ArrayList(u8).empty;
                for (seg_text) |b| {
                    if (b == '\t') {
                        var k: u32 = 0;
                        while (k < tab_width) : (k += 1) try expanded.append(a, ' ');
                    } else {
                        try expanded.append(a, b);
                    }
                }
                try segs.append(a, .{ .text = expanded.items, .style = style });
            } else {
                try segs.append(a, .{ .text = seg_text, .style = style });
            }
            col = next;
        }
        // trailing hints past the visible text (still inside the line)
        while (hint_i < line_hints.len) {
            const hint = line_hints[hint_i];
            if (hint.label.len > 0) {
                try segs.append(a, .{
                    .text = hint.label,
                    .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                });
            }
            hint_i += 1;
        }

        // closed fold header: snacks-style dim "… N lines" marker after
        // the line text; the body's rows are skipped by the loop's
        // foldNextLine continuation
        if (foldAt(buf, line)) |f| {
            const marker = try std.fmt.allocPrint(a, " … {d} lines", .{f.hiddenCount()});
            try segs.append(a, .{ .text = marker, .style = .{
                .dim = true,
                .fg = .{ .rgb = self.theme.fg_dim },
                .bg = .{ .rgb = if (is_cur_line) self.theme.bg_curline else self.theme.bg },
            } });
        }

        _ = win.print(segs.items, .{
            .row_offset = @intCast(row),
            .col_offset = @intCast(rect.col),
            .wrap = .none,
        });
        // diagnostic mark: writeCell AFTER the line print so the glyph is
        // not overwritten by the gutter segment
        if (diag_mark.len > 1) { // Nerd Font icon (multi-byte); " " = none
            var mark_style = cursorline_style;
            if (diag_mark_fg) |f| mark_style.fg = f.fg;
            win.writeCell(@intCast(rect.col + gutter - 1), @intCast(row), .{
                .char = .{ .grapheme = diag_mark, .width = 1 },
                .style = mark_style,
            });
        } else if (git_mark) |k| {
            // git sign in the same cell (diagnostics win the priority).
            // Glyphs: ▎ for added/modified, ▁/▔ half-blocks for deleted
            // (signify-style markers on the neighbor lines).
            var mark_style = cursorline_style;
            if (git_mark_fg) |f| mark_style.fg = f.fg;
            const glyph: []const u8 = switch (k) {
                .added, .modified => "\u{258e}", // ▎ left half block
                .removed_above => "\u{2581}", // ▁ lower eighth block
                .removed_below => "\u{2594}", // ▔ upper eighth block
            };
            win.writeCell(@intCast(rect.col + gutter - 1), @intCast(row), .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = mark_style,
            });
        }
    }
}

/// One fenced-code line: the fence markers (```lang / ```) render dim;
/// the panel stays a solid bg_float block.
pub fn hoverFenceSegs(self: *App, a: std.mem.Allocator, line: []const u8, cols: u32) ![]vaxis.Segment {
    var segs = std.ArrayList(vaxis.Segment).empty;
    const style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } };
    const shown = @min(line.len, @as(usize, @intCast(cols)));
    if (shown > 0) try segs.append(a, .{ .text = line[0..shown], .style = style });
    if (shown < cols) {
        const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(shown))));
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = style });
    }
    return segs.items;
}

/// One code-block row inside the hover window: token colors from the
/// block's merged tree-sitter spans (each span clipped to this line,
/// syntaxStyle fg on bg_float), then padding to `cols` so the panel
/// stays solid. `line_start`/`line_end` are byte offsets into `block`.
pub fn hoverCodeLineSegs(self: *App, a: std.mem.Allocator, block: []const u8, line_start: u32, line_end: u32, spans: []const syntax.Span, cols: u32) ![]vaxis.Segment {
    var segs = std.ArrayList(vaxis.Segment).empty;
    const base: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
    var pos = line_start;
    var si: usize = 0;
    var consumed: usize = 0;
    while (si < spans.len and pos < line_end) {
        const sp = spans[si];
        if (sp.end <= pos) {
            si += 1;
            continue;
        }
        if (sp.start >= line_end) break;
        if (sp.start > pos) {
            const gap = @min(sp.start, line_end) - pos;
            try segs.append(a, .{ .text = block[pos .. pos + gap], .style = base });
            consumed += gap;
            pos = sp.start;
        }
        const s = @max(sp.start, pos);
        const e = @min(sp.end, line_end);
        if (e > s) {
            var st = autil.syntaxStyle(sp.style, self.theme);
            st.bg = .{ .rgb = self.theme.bg_float };
            try segs.append(a, .{ .text = block[s..e], .style = st });
            consumed += e - s;
            pos = e;
        }
        si += 1;
    }
    if (pos < line_end) {
        const tail = block[pos..line_end];
        try segs.append(a, .{ .text = tail, .style = base });
        consumed += line_end - pos;
    }
    if (consumed < cols) {
        const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(consumed))));
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = base });
    }
    return segs.items;
}

/// Minimal markdown-ish token styling for LSP hover/signature text:
/// `` `code` `` spans get the string color, `**bold**` bold, `*emphasis*`
/// dim+italic, `#`-prefixed headings accent+bold, bare http(s) URLs the
/// function color; everything else stays fg. The row is padded to `cols`
/// with bg_float so the floating panel remains a solid block (e2e asserts
/// rowAllBg on hover rows). The text slices reference the caller's owned
/// hover buffer, and the padding is allocator-owned — both outlive the
/// render call.
pub fn hoverLineSegs(self: *App, a: std.mem.Allocator, line: []const u8, cols: u32) ![]vaxis.Segment {
    var segs = std.ArrayList(vaxis.Segment).empty;
    const base: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
    const shown = @min(line.len, @as(usize, @intCast(cols)));
    // heading line: 1-6 '#' followed by a space
    var heading = false;
    if (shown >= 2 and line[0] == '#') {
        var h: usize = 0;
        while (h < shown and h < 6 and line[h] == '#') h += 1;
        heading = h < shown and line[h] == ' ';
    }
    if (heading) {
        const hstyle: vaxis.Style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
        if (shown > 0) try segs.append(a, .{ .text = line[0..shown], .style = hstyle });
        if (shown < cols) {
            const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(shown))));
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = base });
        }
    } else {
        var consumed: usize = 0;
        var i: usize = 0;
        while (i < shown) {
            var style = base;
            var end: usize = shown;
            if (line[i] == '`') {
                // inline code span: up to the next backtick
                style = .{ .fg = .{ .rgb = self.theme.string }, .bg = .{ .rgb = self.theme.bg_float } };
                i += 1;
                end = if (std.mem.indexOfScalar(u8, line[i..shown], '`')) |ci| i + ci else shown;
            } else if (line[i] == '*' and i + 1 < shown and line[i + 1] == '*') {
                style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
                i += 2;
                end = if (std.mem.indexOf(u8, line[i..shown], "**")) |ci| i + ci else shown;
            } else if (line[i] == '*') {
                style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float }, .italic = true };
                i += 1;
                end = if (std.mem.indexOfScalar(u8, line[i..shown], '*')) |ci| i + ci else shown;
            } else if (shown - i >= 4 and std.mem.eql(u8, line[i .. i + 4], "http")) {
                // bare URL: to the next whitespace / punctuation
                var ue = i;
                while (ue < shown and line[ue] != ' ' and line[ue] != '\t' and
                    line[ue] != ',' and line[ue] != ')' and line[ue] != ']') ue += 1;
                end = ue;
                style = .{ .fg = .{ .rgb = self.theme.function }, .bg = .{ .rgb = self.theme.bg_float } };
            }
            if (end <= i) end = shown;
            if (end > i) {
                try segs.append(a, .{ .text = line[i..end], .style = style });
                consumed += end - i;
            }
            i = end;
        }
        if (consumed < cols) {
            const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(consumed))));
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = base });
        }
    }
    return segs.items;
}
pub fn render(self: *App) !void {
    // vaxis cells reference the text slices passed to print, so all text
    // must stay alive until vx.render(); a per-frame arena handles that.
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // per-frame memo invalidation (screenCellCol is called with identical
    // args several times a frame)
    self.cell_col_memo.valid = false;

    const win = self.vx.window();
    win.clear();
    // Editor background: paint the whole screen with the theme's bg so
    // the palette is consistent (like nvim), not terminal-transparent.
    win.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg } } });

    const height: u32 = win.height;
    if (height <= status_row_count) return;
    // Content area rows: below the tab bar, above the status bar.
    const content_rows = height - status_row_count - self.tabBarRows(a);

    // Clamp the focused window's cursor/viewport BEFORE any lineOf /
    // column math below: switching windows or buffers can leave a stale
    // cursor past the end of the current buffer (e.g. both splits show
    // the same buffer and the other window deleted everything), and
    // piece_table.lineOf asserts pos <= len in Debug builds.
    const fw = &self.windows.items[self.current_win];
    if (fw.cursor > self.cur().pt.len()) fw.cursor = self.cur().pt.len();
    if (fw.view_top > self.cur().pt.lineCount() -| 1) fw.view_top = self.cur().pt.lineCount() -| 1;

    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const line_count = self.cur().pt.lineCount();
    // relative-number gutter: computed once per frame, reused by the
    // cursor offset, mc highlight and easymotion labels
    const gutter = self.gutterWidth(line_count);

    // tab bar. Single window: one entry per buffer, current highlighted,
    // + dirty marker — solid blocks separated by a 1-cell base-bg gap.
    // Split windows: each buffer's tab appears EXACTLY ONCE, in the pane
    // that last showed it (last_win) — a buffer displayed in a pane
    // belongs to that pane, a buffer hidden from every pane keeps its
    // tab in the pane it was last in. The pane's OWN buffer carries the
    // active style, so a buffer moving panes (<leader>bh/bl) is visible
    // on the tab bar.
    if (self.windows.items.len <= 1) {
        var tab_i: usize = 0;
        // the tab bar belongs to the BUFFER area: with the file tree
        // open it starts at the content column (right of the sidebar),
        // not glued above the tree at x=0
        var col: u16 = @intCast(self.contentCol());
        while (tab_i < self.buffers.items.len) : (tab_i += 1) {
            const buf = &self.buffers.items[tab_i];
            const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
            const dirty = if (buf.dirty) "\u{25cf}" else " ";
            const label = try std.fmt.allocPrint(a, " {s}{s} ", .{ name, dirty });
            const tab_style: vaxis.Style = if (tab_i == self.current)
                // bg_status, NOT bg_sel: tests (and the eye) read bg_sel
                // as an editor selection — the tab bar must not emit it
                .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true }
            else
                .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            // file icon in the tab's own semantic color (devicons style);
            // the name keeps the plain tab style
            const icon = icons.forPath(if (buf.path) |p| p else "", false);
            const icon_style: vaxis.Style = .{
                .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) },
                .bg = tab_style.bg,
                .bold = (tab_i == self.current),
            };
            const segs = [_]vaxis.Segment{
                .{ .text = icon.glyph, .style = icon_style },
                .{ .text = label, .style = tab_style },
                .{ .text = " ", .style = .{ .bg = .{ .rgb = self.theme.bg } } },
            };
            _ = win.print(&segs, .{ .row_offset = 0, .col_offset = col, .wrap = .none });
            col +|= @intCast(1 + label.len + 1);
            if (col >= win.width) break;
        }
    } else if (self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), win.width)) |tab_layout| {
        // each buffer's tab appears EXACTLY ONCE, owned by the pane that
        // displays it (the focused pane wins when several panes show the
        // same buffer); a buffer hidden from every pane keeps its tab in
        // the pane that last showed it. Panes whose column spans overlap
        // (horizontal splits) draw on separate tab-bar rows so tabs never
        // overwrite each other; within a row, tabs stream left to right
        // from each pane's column, borrowing space to the right when a
        // pane is too narrow to fit its tabs (labels clip only at the
        // row's right edge). The pane's displayed buffer carries the
        // active style, so <leader>bh/bl visibly moves the tab.
        const leaves = tab_layout.leaves;
        const pane_layer = a.alloc(u32, leaves.len) catch return;
        var order: std.ArrayList(usize) = .empty;
        for (0..leaves.len) |i| order.append(a, i) catch return;
        std.mem.sort(usize, order.items, TabSort{ .leaves = leaves }, TabSort.lt);
        var layer_end: std.ArrayList(u32) = .empty;
        var layers: u32 = 0;
        for (order.items) |oi| {
            const lr = leaves[oi];
            var lli: usize = 0;
            while (lli < layers and layer_end.items[lli] > lr.col) lli += 1;
            if (lli == layers) {
                layer_end.append(a, lr.col + lr.width) catch return;
                layers += 1;
            } else {
                layer_end.items[lli] = lr.col + lr.width;
            }
            pane_layer[oi] = @intCast(lli);
        }
        var lli: u32 = 0;
        while (lli < layers) : (lli += 1) {
            // right edge of the layer's widest span: tabs clip here
            var right: u32 = 0;
            for (order.items) |oi| {
                if (pane_layer[oi] == lli) right = @max(right, leaves[oi].col + leaves[oi].width);
            }
            var pos: u32 = 0;
            for (order.items) |oi| {
                if (pane_layer[oi] != lli) continue;
                const lr = leaves[oi];
                // start at the pane's own column, or right after the
                // previous pane's tabs when they overflow this span
                pos = @max(pos, lr.col);
                const own = self.windows.items[lr.win].buf;
                var tab_i: usize = 0;
                var col = pos;
                while (tab_i < self.buffers.items.len) : (tab_i += 1) {
                    // owner: the pane showing the buffer (the focused
                    // pane wins when several panes show it); a hidden
                    // buffer keeps the pane that last showed it
                    var owner: usize = self.buffers.items[tab_i].last_win;
                    if (owner >= self.windows.items.len) owner = self.windows.items.len - 1;
                    if (self.windows.items[self.current_win].buf == tab_i) owner = self.current_win;
                    if (owner != lr.win) continue;
                    const buf = &self.buffers.items[tab_i];
                    const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
                    const dirty = if (buf.dirty) "\u{25cf}" else " ";
                    const label = try std.fmt.allocPrint(a, " {s}{s} ", .{ name, dirty });
                    const active = tab_i == own;
                    const tab_style: vaxis.Style = if (active)
                        .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true }
                    else
                        .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                    const icon = icons.forPath(if (buf.path) |p| p else "", false);
                    const icon_style: vaxis.Style = .{
                        .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) },
                        .bg = tab_style.bg,
                        .bold = active,
                    };
                    // clip only at the row's right edge: tabs may borrow
                    // space right of their own (too narrow) pane span
                    const fit = autil.cellFitPrefix(win, label, right -| col -| 1);
                    if (fit.cells == 0) break;
                    const segs = [_]vaxis.Segment{
                        .{ .text = icon.glyph, .style = icon_style },
                        .{ .text = fit.slice, .style = tab_style },
                    };
                    _ = win.print(&segs, .{ .row_offset = @intCast(lli), .col_offset = @intCast(col), .wrap = .none });
                    col += @intCast(1 + fit.cells + 1); // icon + label + gap
                    if (col >= right) break;
                }
                pos = col;
            }
        }
    } else |_| {}

    // dashboard (no file open): title + recent files + hints
    if (self.isDashboard()) {
        const title_seg = [_]vaxis.Segment{.{
            .text = " oz  ",
            .style = .{ .fg = .{ .rgb = self.theme.accent }, .bold = true },
        }};
        _ = win.print(&title_seg, .{ .row_offset = @intCast(self.contentTop(a) + 2), .col_offset = 2, .wrap = .none });
        // key-hint line, segmented so the bindings get token colors while
        // the prose stays faint (the text content is unchanged, so e2e
        // `contains` assertions on the line still hold)
        const hint_segs = [_]vaxis.Segment{
            .{ .text = " 终端文本编辑器  —  ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            .{ .text = "j/k", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
            .{ .text = " 选择 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            .{ .text = "Enter", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
            .{ .text = " 打开 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            .{ .text = "<leader>", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
            .{ .text = "sf", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
            .{ .text = " 找文件 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            .{ .text = ":e", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
            .{ .text = " 打开 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            .{ .text = ":q", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
            .{ .text = " 退出", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
        };
        _ = win.print(&hint_segs, .{ .row_offset = @intCast(self.contentTop(a) + 3), .col_offset = 2, .wrap = .none });
        var ri: usize = 0;
        while (ri < @min(self.recent_files.items.len, 8)) : (ri += 1) {
            const fname = self.recent_files.items[ri];
            const row: u32 = 5 + @as(u32, @intCast(ri));
            const sel = (ri == self.recent_sel);
            const bg: vaxis.Color = if (sel) .{ .rgb = self.theme.bg_sel } else .default;
            const fg: vaxis.Color = if (sel) .default else .{ .rgb = self.theme.function };
            const icon = icons.forPath(fname, false);
            const segs = [_]vaxis.Segment{
                .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = bg } },
                .{ .text = " ", .style = .{ .bg = bg } },
                .{ .text = fname, .style = .{ .fg = fg, .bg = bg } },
            };
            _ = win.print(&segs, .{ .row_offset = @intCast(self.contentTop(a) + row), .col_offset = 2, .wrap = .none });
        }
        self.vx.screen.cursor = .{
            .row = @intCast(self.contentTop(a) + 5 + @as(u32, @intCast(@min(self.recent_sel, 7)))),
            .col = 2,
        };
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = .block;
        if (term.supported) try self.drawTerm(a, win);
        try self.vx.render(self.tty.writer());
        return;
    }

    // split windows: every leaf gets a rectangle and renders its buffer;
    // the focused window carries syntax highlighting and the selection
    const layout = try self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), win.width);
    const leaves = layout.leaves;
    var cur_rect: LeafRect = .{ .win = self.current_win, .row = 0, .col = 0, .height = 0, .width = 0 };
    var li: usize = 0;
    while (li < leaves.len) : (li += 1) {
        const lr = leaves[li];
        if (lr.win == self.current_win) cur_rect = lr;
        try self.renderWindowLines(a, lr, lr.win == self.current_win);
    }

    // window separators (vim statusline semantics): one "─" row per
    // horizontal split, one "│" column per vertical split, drawn OVER the
    // buffers so the panes read as distinct windows without changing the
    // layout math. The separator adjacent to the focused window (the
    // split path from the root to the current leaf) is bright; the rest
    // are dim. The bg is the editor background so the line fully hides
    // whatever buffer text it covers — no ghosting from the window below.
    for (layout.seps) |sep| {
        const sep_style: vaxis.Style = .{
            .fg = .{ .rgb = if (sep.active) self.theme.win_sep_active else self.theme.win_sep },
            .bg = .{ .rgb = self.theme.bg },
        };
        if (sep.horizontal) {
            var xs: u32 = 0;
            while (xs < sep.len) : (xs += 1) {
                win.writeCell(@intCast(sep.col + xs), @intCast(sep.row), .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = sep_style,
                });
            }
        } else {
            var ys: u32 = 0;
            while (ys < sep.len) : (ys += 1) {
                win.writeCell(@intCast(sep.col), @intCast(sep.row + ys), .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = sep_style,
                });
            }
        }
    }

    // file tree sidebar (nvim neo-tree style: the panel shares the
    // EDITOR background — Normal bg, not a float — so sidebar and text
    // area read as one surface; only the fg_faint border separates them)
    if (self.filetree_active) {
        const ft_col: u32 = 0;
        const ft_width = filetree_width;
        const ft_top = self.contentTop(a);
        const ft_bottom = height - status_row_count; // above the status bar
        const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg } };
        // Paint the whole panel with the editor background first — without
        // this only the border columns and the text-width of each item
        // got the bg, leaving the interior terminal-default (patchy).
        const panel = win.child(.{
            .x_off = @intCast(ft_col),
            .y_off = @intCast(ft_top),
            .width = @intCast(ft_width),
            .height = @intCast(ft_bottom - ft_top),
        });
        panel.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg } } });
        // left border column and panel background
        const left_col = ft_col;
        const inner_left = ft_col + 1;
        const inner_w = ft_width -| 1;
        var brow: u32 = ft_top;
        while (brow < ft_bottom) : (brow += 1) {
            const border_seg = [_]vaxis.Segment{.{
                .text = "│",
                .style = border_style,
            }};
            _ = win.print(&border_seg, .{ .row_offset = @intCast(brow), .col_offset = @intCast(left_col), .wrap = .none });
        }
        // title row: " files " with a top border (╭─ files ────╮)
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╭─ files ", .style = border_style });
            // inner_w cells between the borders; "╭─ files " is 9 cells
            var cx: u32 = 9;
            while (cx < inner_w) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╮", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(ft_top), .col_offset = @intCast(left_col), .wrap = .none });
        }
        // vim-style scroll window (same semantics as the picker)
        const ft_len = self.filetree_rows.items.len;
        // clamp the selection when the tree shrank (collapse) BEFORE the
        // scroll math, or a stale sel >= len would drive ft_top past the
        // end of the visible list (out of bounds on the row loop below)
        if (ft_len == 0) {
            self.filetree_sel = 0;
        } else if (self.filetree_sel >= ft_len) {
            self.filetree_sel = ft_len - 1;
        }
        const ft_vis = @min(ft_len, @as(usize, ft_bottom - ft_top - 2));
        if (ft_len > ft_vis) {
            if (self.filetree_top + ft_vis > ft_len) self.filetree_top = ft_len - ft_vis;
            if (self.filetree_sel < self.filetree_top) self.filetree_top = self.filetree_sel;
            if (self.filetree_sel >= self.filetree_top + ft_vis) self.filetree_top = self.filetree_sel - ft_vis + 1;
        } else self.filetree_top = 0;
        const ft_top_i = self.filetree_top;
        var k: usize = 0;
        while (k < ft_vis) : (k += 1) {
            const ri = ft_top_i + k;
            const frow = self.filetree_rows.items[ri];
            const node = frow.node;
            const indent = frow.depth * 2;
            // content = indent + icon (1 cell) + space + name; a
            // too-wide name is truncated from the RIGHT with "…" (never
            // head-truncated). The name budget excludes the right-border
            // column (the last inner cell), which the border draws over
            // afterwards, and the gap cell between icon and name — the
            // gap keeps the glyph from crowding the text (a Nerd Font
            // icon right against a name reads as a tiny broken glyph).
            const icon = if (node.is_dir) icons.folder(node.expanded) else icons.forPath(node.path, false);
            const avail = (inner_w -| 1) -| @as(usize, indent) -| 1 -| 1;
            var name = node.name;
            var ellipsized = false;
            if (name.len > avail) {
                name = name[0..avail -| 1];
                ellipsized = true;
            }
            const style: vaxis.Style = if (ri == self.filetree_sel)
                .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } }
            else
                .{ .bg = .{ .rgb = self.theme.bg }, .fg = .{ .rgb = self.theme.fg } };
            // Pad to the full inner width: the row background (plain and
            // selected alike) must span the panel edge to edge. NOTE:
            // vaxis cells REFERENCE the segment text — it must outlive
            // vx.render() — so the padding is arena-allocated, never a
            // stack buffer (a stack row_buf made every row render the
            // LAST file's name).
            var segs = std.ArrayList(vaxis.Segment).empty;
            if (indent > 0) {
                const pad = try a.alloc(u8, indent);
                @memset(pad, ' ');
                try segs.append(a, .{ .text = pad, .style = style });
            }
            try segs.append(a, .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = style.bg } });
            if (name.len > 0) {
                try segs.append(a, .{ .text = " ", .style = style });
                try segs.append(a, .{ .text = name, .style = style });
            }
            if (ellipsized) try segs.append(a, .{ .text = "…", .style = style });
            // count cells: indent spaces + icon (1) + gap (1) + name + "…"
            const content_len = indent + 2 + name.len + @as(usize, if (ellipsized) 1 else 0);
            const pads = try a.alloc(u8, inner_w -| @min(content_len, inner_w));
            @memset(pads, ' ');
            if (pads.len > 0) try segs.append(a, .{ .text = pads, .style = style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(ft_top + 1 + k), .col_offset = @intCast(inner_left), .wrap = .none });
        }
        // right border column — mirrors the left one so the panel is a
        // closed box. The title row's "╮" and the bottom row's "╯"
        // already cap the two corners, so only the interior rows need the
        // "│" (the item rows' trailing padding is what it covers).
        {
            const right_col = ft_col + ft_width - 1;
            var rrow: u32 = ft_top + 1;
            const rlast = ft_bottom - 1; // bottom border row
            while (rrow < rlast) : (rrow += 1) {
                const border_seg = [_]vaxis.Segment{.{
                    .text = "│",
                    .style = border_style,
                }};
                _ = win.print(&border_seg, .{ .row_offset = @intCast(rrow), .col_offset = @intCast(right_col), .wrap = .none });
            }
        }
        // bottom border
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╰", .style = border_style });
            // inner_w - 1 dashes: "╰" takes the left border column and
            // "╯" must land ON the right border column (ft_width-1) —
            // inner_w dashes would push it one cell past the edge
            var cx: u32 = 0;
            while (cx < inner_w -| 1) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╯", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(ft_bottom - 1), .col_offset = @intCast(left_col), .wrap = .none });
        }
    }

    // multi-cursor word highlights (overlay)
    if (self.mc_active) {
        for (self.mc.cursors.items) |cpos| {
            const w = self.mc.wordRange(&self.cur().pt, cpos);
            if (w.end <= w.start) continue;
            const wline = self.cur().pt.lineOf(w.start);
            if (wline < self.curViewTop().* or wline >= self.curViewTop().* + content_rows) continue;
            var p = w.start;
            while (p < w.end) {
                // byte offset -> SCREEN cell column (CJK word = 3 bytes/2
                // cells; inlay hints before it shift the cells right)
                const col = self.screenCellCol(win, wline, p);
                if (col >= @as(u32, win.width) - gutter) break;
                var clen: u32 = 1;
                while (p + clen < w.end and (self.cur().pt.byteAt(p + clen) & 0xC0) == 0x80) : (clen += 1) {}
                var char_buf: [4]u8 = undefined;
                self.cur().pt.copyRange(p, char_buf[0..clen]);
                const g = try a.dupe(u8, char_buf[0..clen]);
                win.writeCell(@intCast(cur_rect.col + gutter + col), @intCast(cur_rect.row + wline - self.curViewTop().*), .{
                    .char = .{ .grapheme = g, .width = 1 },
                    .style = .{ .bg = .{ .rgb = self.theme.bg_sel } },
                });
                p += clen;
            }
        }
    }

    // easymotion labels: overwrite the matched cells with jump labels
    if (self.em_labels) {
        for (self.em_matches) |m| {
            const mline = self.cur().pt.lineOf(m.pos);
            if (mline < self.curViewTop().* or mline >= self.curViewTop().* + content_rows) continue;
            // byte offset -> SCREEN cell column: a CJK char before the
            // match is 3 bytes but 2 cells, and an inlay hint before it
            // occupies screen cells without buffer bytes — a plain text
            // column (lineCellCol) paints the label left of the match by
            // the combined hint width
            const col_in_line = self.screenCellCol(win, mline, m.pos);
            const label = try a.dupe(u8, &[_]u8{m.label});
            win.writeCell(@intCast(cur_rect.col + gutter + col_in_line), @intCast(cur_rect.row + mline - self.curViewTop().*), .{
                .char = .{ .grapheme = label, .width = 1 },
                .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_sel } },
            });
        }
    }

    // embedded terminal overlay: drawn after the panes so it covers
    // them; the modal overlays below float above it
    if (term.supported) try self.drawTerm(a, win);

    // fuzzy picker overlay (telescope/snacks style: a solid bg_float
    // floating window with a border, a title and an in-panel input row,
    // centered on the screen instead of pinned to the bottom-left corner)
    if (self.picker_active) {
        const total = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
        // grep keeps at least one row ("no matches" hint) so the
        // fixed-size panel never collapses to a sliver while the query
        // has no hits yet
        var list_rows = @min(@as(usize, 10), total);
        if (self.picker_mode == .grep) list_rows = @max(list_rows, 1);
        // vim-style scroll window: the selection moves freely inside the
        // window; the window scrolls only when the selection crosses an
        // edge (persisted in picker_top so it doesn't jump around).
        if (total > list_rows) {
            if (self.picker_top + list_rows > total) self.picker_top = total - list_rows;
            if (self.picker_sel < self.picker_top) self.picker_top = self.picker_sel;
            if (self.picker_sel >= self.picker_top + list_rows) self.picker_top = self.picker_sel - list_rows + 1;
        } else self.picker_top = 0;
        const top = self.picker_top;
        // measure the widest label for the box width (capped); file /
        // recent / buffer rows carry a leading icon + space, keymap rows
        // are "keys + 2 + desc". Skipped for grep: its panel is a fixed
        // size, independent of the result set.
        var max_w: usize = 0;
        if (self.picker_mode != .grep) {
            var mk: usize = 0;
            while (mk < list_rows) : (mk += 1) {
                const ri = top + mk;
                const label: []const u8 = if (self.picker_mode == .grep) blk: {
                    const r = self.grep_results.items[ri];
                    break :blk std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ r.path, r.line, r.text }) catch "…";
                } else if (self.picker_mode == .buffers) blk: {
                    const bi = self.picker_matches.items[ri];
                    break :blk std.fmt.allocPrint(a, "{d} {s}", .{ bi + 1, self.bufferName(bi) }) catch "…";
                } else if (self.picker_mode == .recent) blk: {
                    const ri2 = self.picker_matches.items[ri];
                    break :blk self.recent_files.items[ri2];
                } else if (self.picker_mode == .keymaps) blk: {
                    const ei = self.picker_matches.items[ri];
                    const e = keymap_list.entries[ei];
                    break :blk std.fmt.allocPrint(a, "{s}  {s}", .{ e.keys, e.desc }) catch "…";
                } else if (self.picker_mode == .themes) blk: {
                    const ti = self.picker_matches.items[ri];
                    break :blk theme.themes[ti].name;
                } else self.picker_files.items[self.picker_matches.items[ri]];
                const icon_len: usize = switch (self.picker_mode) {
                    .files, .recent, .buffers => 2,
                    // themes rows lead with a 3-cell color swatch + space
                    .themes => 4,
                    else => 0,
                };
                max_w = @max(max_w, label.len + icon_len);
            }
            max_w = @min(max_w, 60);
        }
        var inner_w: u32 = @intCast(@max(max_w, 12));
        var box_w: u32 = undefined;
        if (self.picker_mode == .grep) {
            // fixed-size panel: width is independent of the result count
            // (no small→big pop when results arrive); 70% of the screen,
            // min 44 inner columns (≈54 on an 80-col pty)
            inner_w = @max(win.width * 7 / 10 -| 2, 44);
            box_w = @min(inner_w + 2, win.width * 7 / 10);
        } else {
            // box width capped at 60% of the screen so a very wide label
            // never spans the whole terminal (telescope/snacks feel)
            box_w = @min(inner_w + 2, win.width * 3 / 5);
        }
        inner_w = box_w - 2;
        const title = switch (self.picker_mode) {
            .grep => " Grep ",
            .buffers => " Buffers ",
            .recent => " Recent ",
            .keymaps => " Keymaps ",
            .themes => " Themes ",
            else => " Files ",
        };
        // centered floating window: title + input row + list + bottom
        // border; start_row biased slightly upward (1/3 down the screen)
        // so the list reads closer to eye level, clamped against tiny
        // terminals like the completion menu's overflow guard
        const box_h: u32 = @as(u32, @intCast(list_rows)) + 3;
        var start_row = (height -| box_h) / 3;
        if (start_row < 1) start_row = 1;
        if (start_row + box_h >= height) start_row = height -| box_h;
        const start_col = (win.width -| box_w) / 2;
        const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
        const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
        const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
        // grep split: left = result list, then a " │ " separator (1 cell
        // plus a bg_float space each side so text never touches the
        // line), right = preview (inner*2/5 ≈ 21 cols on an 80-col pty,
        // left ≈ 30)
        const preview_w: u32 = if (self.picker_mode == .grep) inner_w * 2 / 5 else 0;
        const left_w: u32 = inner_w -| 3 -| preview_w;
        const sep_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.win_sep }, .bg = .{ .rgb = self.theme.bg_float } };
        const sep_pad_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float } };
        // top border + title
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╭", .style = border_style });
            try segs.append(a, .{ .text = title, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
            var cx: u32 = 1 + @as(u32, @intCast(title.len));
            while (cx < inner_w + 1) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╮", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // input row: "❯ " prompt (accent) + the query, on the panel's
        // own bg_float (telescope/snacks style — no status-bar row at
        // the bottom of the screen). The whole interior row is bg_float
        // so the panel stays a solid block.
        var input_cells: usize = 0; // cells of the shown query (cursor col)
        {
            const input_cap: usize = @intCast(inner_w -| 2);
            // cell-truncate (grapheme-aligned): a byte count can split a
            // UTF-8 sequence or overflow the row on CJK input
            const input_fit = autil.cellFitPrefix(win, self.picker_input.items, input_cap);
            input_cells = input_fit.cells;
            // buffer size = text bytes + remaining pad CELLS (the text's
            // byte length can exceed its cell count on CJK input)
            const input_row = try a.alloc(u8, input_fit.slice.len + (input_cap - input_fit.cells));
            @memset(input_row, ' ');
            @memcpy(input_row[0..input_fit.slice.len], input_fit.slice);
            const seg = [_]vaxis.Segment{
                .{ .text = "│", .style = border_style },
                .{ .text = "❯ ", .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } },
                .{ .text = input_row, .style = row_style },
                .{ .text = "│", .style = border_style },
            };
            _ = win.print(&seg, .{ .row_offset = @intCast(start_row + 1), .col_offset = @intCast(start_col), .wrap = .none });
        }
        var k: usize = 0;
        while (k < list_rows) : (k += 1) {
            const ri = top + k;
            const selected = (ri == self.picker_sel);
            const rs: vaxis.Style = if (selected) sel_style else row_style;
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "│", .style = border_style });
            if (self.picker_mode == .keymaps) {
                // segmented keymap row: keys tokens split on spaces —
                // "space" / "ctrl-*" / "alt-*" / ":*" prefixes render
                // accent, the rest keyword; then "  " + desc in fg. The
                // selected row keeps the token colors and only swaps the
                // bg.
                const ei = self.picker_matches.items[ri];
                const entry = keymap_list.entries[ei];
                var it = std.mem.splitScalar(u8, entry.keys, ' ');
                var first = true;
                while (it.next()) |tok| {
                    if (tok.len == 0) continue;
                    if (!first) try segs.append(a, .{ .text = " ", .style = rs });
                    const is_prefix = first and (std.mem.eql(u8, tok, "space") or std.mem.startsWith(u8, tok, "ctrl-") or std.mem.startsWith(u8, tok, "alt-") or tok[0] == ':');
                    const tok_style: vaxis.Style = if (is_prefix)
                        .{ .fg = .{ .rgb = self.theme.accent }, .bg = rs.bg }
                    else
                        .{ .fg = .{ .rgb = self.theme.keyword }, .bg = rs.bg };
                    try segs.append(a, .{ .text = tok, .style = tok_style });
                    first = false;
                }
                try segs.append(a, .{ .text = "  ", .style = rs });
                try segs.append(a, .{ .text = entry.desc, .style = rs });
                // truncate the desc (the last segment) when the row
                // overflows the interior width. Widths are CELLS (a CJK
                // desc is 2 cells/char), and segs[0] is the border — the
                // interior starts at index 1.
                var content_cells: usize = 0;
                for (segs.items[1..]) |s| content_cells += autil.cellWidth(win, s.text);
                if (content_cells > inner_w) {
                    const over = content_cells - inner_w;
                    const last = &segs.items[segs.items.len - 1];
                    const last_cells = autil.cellWidth(win, last.text);
                    if (last_cells > over) {
                        last.text = autil.cellFitPrefix(win, last.text, last_cells - over).slice;
                        content_cells = inner_w;
                    }
                }
                const pad = try a.alloc(u8, inner_w -| content_cells);
                @memset(pad, ' ');
                if (pad.len > 0) try segs.append(a, .{ .text = pad, .style = rs });
            } else if (self.picker_mode == .grep) {
                // grep split panel: left column = the result row, then
                // the " │ " separator, then the highlighted preview column
                if (self.grep_results.items.len == 0) {
                    // "no matches" hint (dim); the preview column stays a
                    // blank bg_float block so the panel is continuous
                    const hint = "no matches";
                    const ids = [_]u8{0} ** 64;
                    try autil.appendRowSegs(&segs, a, win, hint, &ids, &[_]vaxis.Style{.{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } }}, left_w, .{ .bg = .{ .rgb = self.theme.bg_float } });
                    try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                    try segs.append(a, .{ .text = "│", .style = sep_style });
                    try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                    try autil.appendRowSegs(&segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, .{ .bg = .{ .rgb = self.theme.bg_float } });
                } else {
                    const r = self.grep_results.items[ri];
                    // "path:line:" prefix (dim) + " text" (fg); fzy match
                    // chars render keyword. The selected row keeps these
                    // colors and only swaps the bg to bg_sel. Truncation
                    // eats the match text's tail first (suffixed "…"),
                    // then the path's head ("…tail" keeps the meaningful
                    // end): path:line and the start of the match always
                    // stay visible. Tabs in the match text expand to
                    // spaces (tab_width, same as the renderer) so the
                    // cell math holds.
                    const lw: usize = @intCast(left_w);
                    const text_exp = try std.mem.replaceOwned(u8, a, r.text, "\t", "    ");
                    const line_tag = try std.fmt.allocPrint(a, ":{d}:", .{r.line});
                    // the path gets what ":line:" + the separator space +
                    // ≥1 text cell leave; overflow keeps the tail
                    const path_cap = lw -| autil.cellWidth(win, line_tag) -| 2;
                    const path_disp: []const u8 = if (autil.cellWidth(win, r.path) > path_cap)
                        try std.fmt.allocPrint(a, "…{s}", .{autil.cellFitSuffix(win, r.path, path_cap -| 1).slice})
                    else
                        r.path;
                    const prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ path_disp, line_tag });
                    const text_cap = lw -| autil.cellWidth(win, prefix) -| 1;
                    const text_disp: []const u8 = if (autil.cellWidth(win, text_exp) > text_cap)
                        try std.fmt.allocPrint(a, "{s}…", .{autil.cellFitPrefix(win, text_exp, text_cap -| 1).slice})
                    else
                        text_exp;
                    const label = try std.fmt.allocPrint(a, "{s} {s}", .{ prefix, text_disp });
                    const ids = try a.alloc(u8, label.len);
                    for (0..label.len) |i| ids[i] = if (i < prefix.len) 1 else 0;
                    if (self.picker_input.items.len > 0) {
                        if (try util.fzy.match(self.alloc, label, self.picker_input.items)) |m| {
                            defer self.alloc.free(m.positions);
                            for (m.positions) |p| {
                                if (p >= label.len) continue;
                                const cs = autil.utf8CharStart(label, p);
                                if (cs >= label.len) continue;
                                const ce = @min(cs + autil.utf8CharLenAt(label, cs), label.len);
                                for (cs..ce) |j| ids[j] = 2;
                            }
                        }
                    }
                    const styles = [_]vaxis.Style{
                        .{ .fg = .{ .rgb = self.theme.fg }, .bg = rs.bg },
                        .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = rs.bg },
                        .{ .fg = .{ .rgb = self.theme.keyword }, .bg = rs.bg },
                    };
                    try autil.appendRowSegs(&segs, a, win, label, ids, &styles, left_w, .{ .bg = rs.bg });
                    try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                    try segs.append(a, .{ .text = "│", .style = sep_style });
                    try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                    try self.renderGrepPreviewRow(&segs, a, win, k, list_rows, preview_w, r.path, r.line);
                }
            } else if (self.picker_mode == .themes) {
                // color-swatch row: 3 cells painted with the theme's OWN
                // bg / fg / accent — a preview of what the theme looks
                // like — then a space + the theme name. The swatch cells
                // keep the theme's own colors even on the selected row
                // (bg_sel must NOT cover them: the swatch IS the preview);
                // the name + trailing padding take the normal row style.
                const ti = self.picker_matches.items[ri];
                const t = theme.themes[ti];
                try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.bg } } });
                try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.fg } } });
                try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.accent } } });
                try segs.append(a, .{ .text = " ", .style = rs });
                try segs.append(a, .{ .text = t.name, .style = rs });
                const content_len = 4 + t.name.len;
                const pad = try a.alloc(u8, inner_w -| @min(content_len, @as(usize, @intCast(inner_w))));
                @memset(pad, ' ');
                if (pad.len > 0) try segs.append(a, .{ .text = pad, .style = rs });
            } else {
                const label: []const u8 = if (self.picker_mode == .buffers) blk: {
                    const bi = self.picker_matches.items[ri];
                    break :blk std.fmt.allocPrint(a, "{d} {s}", .{ bi + 1, self.bufferName(bi) }) catch "…";
                } else if (self.picker_mode == .recent) blk: {
                    const ri2 = self.picker_matches.items[ri];
                    break :blk self.recent_files.items[ri2];
                } else self.picker_files.items[self.picker_matches.items[ri]];
                // file/recent/buffer rows: leading icon + space, then the
                // label
                const icon_path: ?[]const u8 = switch (self.picker_mode) {
                    .files => self.picker_files.items[self.picker_matches.items[ri]],
                    .recent => self.recent_files.items[self.picker_matches.items[ri]],
                    .buffers => blk: {
                        const bi = self.picker_matches.items[ri];
                        break :blk if (self.buffers.items[bi].path) |p| p else "";
                    },
                    else => null,
                };
                const prefix_len: usize = if (icon_path != null) 2 else 0;
                // pad the label region to its width so the bg stays
                // continuous across the row (icon cell + space + label)
                const content_w = inner_w -| prefix_len;
                const row = try a.alloc(u8, content_w);
                @memset(row, ' ');
                const n = @min(label.len, @as(usize, @intCast(content_w)));
                @memcpy(row[0..n], label[0..n]);
                if (icon_path) |p| {
                    const icon = icons.forPath(p, false);
                    try segs.append(a, .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = rs.bg } });
                    try segs.append(a, .{ .text = " ", .style = rs });
                }
                try segs.append(a, .{ .text = row, .style = rs });
            }
            try segs.append(a, .{ .text = "│", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 2 + k), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // bottom border
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╰", .style = border_style });
            var cx: u32 = 0;
            while (cx < inner_w) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╯", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 2 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // the block cursor sits in the input row, right after the query:
        // 1 (left border) + 2 ("❯ " prompt) + the query's display cells
        // (input_cells, not the byte length — that lands the cursor
        // mid-row on CJK queries)
        self.vx.screen.cursor = .{
            .row = @intCast(start_row + 1),
            .col = @intCast(start_col + 3 + input_cells),
        };
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = .block;
        try self.vx.render(self.tty.writer());
        return;
    }

    // status bar (or command line in command mode)
    if (self.state.mode == .command) {
        const prompt_char: []const u8 = switch (self.cmdline_kind) {
            .ex => ":",
            .search_fwd => "/",
            .search_bwd => "?",
        };
        const prompt = try std.fmt.allocPrint(a, "{s}{s}", .{ prompt_char, self.cmdline.items });
        const cmd_seg = [_]vaxis.Segment{.{
            .text = prompt,
            .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status } },
        }};
        _ = win.print(&cmd_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
        self.vx.screen.cursor = .{
            .row = @intCast(height - 1),
            .col = @intCast(1 + self.cmdline.items.len),
        };
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = .block;
        try self.vx.render(self.tty.writer());
        return;
    }

    // diagnostics list overlay (<leader>sd): bottom list like the picker
    if (self.diag_list_active) {
        const total = self.lsp_diagnostics.items.len;
        const list_rows = @min(@as(usize, 8), total);
        if (total > list_rows) {
            if (self.diag_list_top + list_rows > total) self.diag_list_top = total - list_rows;
            if (self.diag_list_sel < self.diag_list_top) self.diag_list_top = self.diag_list_sel;
            if (self.diag_list_sel >= self.diag_list_top + list_rows) self.diag_list_top = self.diag_list_sel - list_rows + 1;
        } else self.diag_list_top = 0;
        const dtop = self.diag_list_top;
        const start_row = height - 1 - @as(u32, @intCast(list_rows)) - 1;
        var k: usize = 0;
        while (k < list_rows) : (k += 1) {
            const ri = dtop + k;
            const d = self.lsp_diagnostics.items[ri];
            const label = try std.fmt.allocPrint(a, "{d}: {s}", .{ d.range.start.line + 1, d.message });
            const seg = [_]vaxis.Segment{.{
                .text = label,
                .style = if (ri == self.diag_list_sel)
                    .{ .bg = .{ .rgb = self.theme.bg_sel } }
                else
                    .{},
            }};
            _ = win.print(&seg, .{ .row_offset = @intCast(start_row + k), .wrap = .none });
        }
    }

    // LSP navigation location list overlay (gr / gI / <leader>o outline):
    // a floating window in the same visual language as the pickers
    // (solid bg_float panel, fg_faint border, accent title, bg_sel
    // selection, centered on screen). Like the grep panel it is a
    // fixed-size split: left = the location list, then a " │ " separator,
    // right = a syntax-highlighted preview around the selected location —
    // a bare "line: file" row doesn't say what the reference is doing.
    if (self.nav_list_active) {
        const total = self.nav_locations.items.len;
        const list_rows = @min(@as(usize, 10), total);
        if (total > list_rows) {
            if (self.nav_loc_top + list_rows > total) self.nav_loc_top = total - list_rows;
            if (self.nav_list_sel < self.nav_loc_top) self.nav_loc_top = self.nav_list_sel;
            if (self.nav_list_sel >= self.nav_loc_top + list_rows) self.nav_loc_top = self.nav_list_sel - list_rows + 1;
        } else self.nav_loc_top = 0;
        const ntop = self.nav_loc_top;
        // fixed-size panel (same 70%-of-screen rule as the grep panel, so
        // the box doesn't resize as the selection moves between files)
        var inner_w: u32 = @max(win.width * 7 / 10 -| 2, 44);
        const box_w = @min(inner_w + 2, win.width * 7 / 10);
        inner_w = box_w - 2;
        const inner = inner_w;
        // split widths like the grep panel: the list gets inner-3-preview,
        // the " │ " separator is 1 cell plus a bg_float space each side
        const preview_w: u32 = inner * 2 / 5;
        const left_w: u32 = inner -| 3 -| preview_w;
        // title row + list rows + bottom border (no input row — the list
        // is navigated with j/k, not filtered)
        const box_h: u32 = @as(u32, @intCast(list_rows)) + 2;
        var start_row = (height -| box_h) / 3;
        if (start_row < 1) start_row = 1;
        if (start_row + box_h >= height) start_row = height -| box_h;
        const start_col = (win.width -| box_w) / 2;
        self.nav_float_row = start_row;
        self.nav_float_col = start_col;
        const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
        const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
        const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
        const sep_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.win_sep }, .bg = .{ .rgb = self.theme.bg_float } };
        const sep_pad_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float } };
        // top border + title (the title is cell-truncated to the interior
        // so a narrow terminal never pushes the ╮ corner off the box)
        {
            const title_fit = autil.cellFitPrefix(win, self.nav_list_title, inner);
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╭", .style = border_style });
            try segs.append(a, .{ .text = title_fit.slice, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
            var cx: u32 = 1 + @as(u32, @intCast(title_fit.cells));
            while (cx < inner + 1) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╮", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // preview target of the selected row, resolved once per frame:
        // outline rows pack "label\x00line" into uri and preview the
        // current buffer; gr/gI rows carry a file:// uri. LSP lines are
        // 0-based, the preview renderer wants 1-based.
        const sel_loc = self.nav_locations.items[self.nav_list_sel];
        const preview_path: []const u8 = if (std.mem.indexOfScalar(u8, sel_loc.uri, 0) != null)
            (self.cur().path orelse "")
        else
            lsp_types.fileUriToPath(a, sel_loc.uri) catch "";
        const preview_line: u32 = sel_loc.line + 1;
        var k: usize = 0;
        while (k < list_rows) : (k += 1) {
            const ri = ntop + k;
            const loc = self.nav_locations.items[ri];
            const label = if (std.mem.indexOfScalar(u8, loc.uri, 0)) |z|
                try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, loc.uri[0..z] })
            else
                try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, std.fs.path.basename(loc.uri) });
            const rs: vaxis.Style = if (ri == self.nav_list_sel) sel_style else row_style;
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "│", .style = border_style });
            // cell-truncate the label to the left column and pad the rest
            // so the row spans the full box width and the right "│" lands
            // flush under the top border's ╮
            const fit = autil.cellFitPrefix(win, label, left_w);
            const row = try a.alloc(u8, fit.slice.len + (left_w -| fit.cells));
            @memset(row, ' ');
            @memcpy(row[0..fit.slice.len], fit.slice);
            try segs.append(a, .{ .text = row, .style = rs });
            try segs.append(a, .{ .text = " ", .style = sep_pad_style });
            try segs.append(a, .{ .text = "│", .style = sep_style });
            try segs.append(a, .{ .text = " ", .style = sep_pad_style });
            try self.renderGrepPreviewRow(&segs, a, win, k, list_rows, preview_w, preview_path, preview_line);
            try segs.append(a, .{ .text = "│", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // bottom border
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╰", .style = border_style });
            var cx: u32 = 0;
            while (cx < inner) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╯", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
        }
    }

    // Hunk preview float (<leader>hp): the hunk's raw patch in a
    // floating window — same visual language as the pickers. '+' lines
    // green, '-' lines red, hunk headers accent, context dim.
    if (self.git_preview) |*pv| {
        const total_lines = gitPreviewLineCount(pv.text);
        const list_rows = @min(@as(usize, 12), total_lines);
        if (pv.top + list_rows > total_lines) pv.top = total_lines -| list_rows;
        // width: 70% of the screen like the grep panel (patch lines are
        // long); the panel has no input row: title + rows + bottom border
        const box_w = @min(win.width * 7 / 10, win.width -| 4);
        const inner = box_w - 2;
        const box_h: u32 = @as(u32, @intCast(list_rows)) + 2;
        var start_row = (height -| box_h) / 3;
        if (start_row < 1) start_row = 1;
        if (start_row + box_h >= height) start_row = height -| box_h;
        const start_col = (win.width -| box_w) / 2;
        const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
        const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
        // top border + title
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╭", .style = border_style });
            try segs.append(a, .{ .text = " Hunk ", .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
            var cx: u32 = 1 + 6;
            while (cx < inner + 1) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╮", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // split the patch into lines (the stored text ends with '\n')
        var line_it = std.mem.splitScalar(u8, pv.text, '\n');
        var k: usize = 0;
        while (k < list_rows) : (k += 1) {
            var line = line_it.next() orelse "";
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const rs: vaxis.Style = if (line.len > 0)
                switch (line[0]) {
                    '+' => .{ .fg = .{ .rgb = self.theme.git_add }, .bg = .{ .rgb = self.theme.bg_float } },
                    '-' => .{ .fg = .{ .rgb = self.theme.git_del }, .bg = .{ .rgb = self.theme.bg_float } },
                    '@' => .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } },
                    else => .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } },
                }
            else
                row_style;
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "│", .style = border_style });
            const fit = autil.cellFitPrefix(win, line, inner -| 1);
            const row = try a.alloc(u8, @intCast(fit.cells));
            @memset(row, ' ');
            @memcpy(row[0..fit.slice.len], fit.slice);
            try segs.append(a, .{ .text = row, .style = rs });
            try segs.append(a, .{ .text = "│", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(start_col), .wrap = .none });
        }
        // bottom border
        {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "╰", .style = border_style });
            var cx: u32 = 0;
            while (cx < inner) : (cx += 1) {
                try segs.append(a, .{ .text = "─", .style = border_style });
            }
            try segs.append(a, .{ .text = "╯", .style = border_style });
            _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
        }
    }

    // insert-mode completion menu (Ctrl+n / auto-suggest): a floating
    // window like nvim's blink.cmp — rounded border, solid bg_float
    // panel, selected row in bg_sel with a Nerd Font kind icon column.
    // The buffer cursor is left untouched.
    if (self.completion_active) {
        const total = self.completion_words.items.len;
        if (total > 0) {
            const list_rows = @min(@as(usize, 8), total);
            var top: usize = 0;
            if (self.completion_sel >= list_rows) top = self.completion_sel - list_rows + 1;
            const c_line = self.cur().pt.lineOf(self.curCursor().*);
            const c_col = self.screenCellCol(win, c_line, self.curCursor().*);
            // box width in cells: borders + icon + pad + longest label
            var max_label: usize = 0;
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                max_label = @max(max_label, self.completion_words.items[top + k].text.len);
            }
            max_label = @min(max_label, 46);
            const inner_cells: u32 = @intCast(2 + max_label);
            const box_w = inner_cells + 2;
            var start_row = c_line - self.curViewTop().* + cur_rect.row + 1;
            if (start_row + list_rows + 2 > height) {
                // near the bottom: show the menu above the cursor; the
                // saturating minus keeps short terminals from underflowing
                // (a 4.29e9 row would draw the menu off-screen silently)
                start_row = (c_line - self.curViewTop().* + cur_rect.row) -| (list_rows + 2);
            }
            // anchor the menu at the cursor column (not pinned left)
            var box_col = cur_rect.col + gutter + c_col;
            if (box_col + box_w > win.width) box_col = win.width -| box_w;
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
            const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
            // top border ╭───╮
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭", .style = border_style });
                try segs.append(a, .{ .text = "─", .style = border_style });
                // the remaining top edge (inner_cells - 1 cells)
                var cx: u32 = 1;
                while (cx < inner_cells) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(box_col), .wrap = .none });
            }
            k = 0;
            while (k < list_rows) : (k += 1) {
                const item = self.completion_words.items[top + k];
                const style = if (top + k == self.completion_sel) sel_style else row_style;
                const icon = if (item.kind != 0) kindGlyph(item.kind) else " ";
                const shown = @min(item.text.len, max_label);
                // byte layout: icon(≤3) + ' ' pad + label + spaces to fill
                const row = try a.alloc(u8, inner_cells + 2);
                @memset(row, ' ');
                @memcpy(row[0..icon.len], icon);
                if (shown > 0) @memcpy(row[icon.len + 1 .. icon.len + 1 + shown], item.text[0..shown]);
                const segs = [_]vaxis.Segment{
                    .{ .text = "│", .style = border_style },
                    .{ .text = row, .style = style },
                    .{ .text = "│", .style = border_style },
                };
                _ = win.print(&segs, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(box_col), .wrap = .none });
            }
            // bottom border ╰───╯
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner_cells) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(box_col), .wrap = .none });
            }
        }

        // Ghost text: the suffix of the selected item beyond the typed
        // prefix, shown dimmed right after the cursor (VS Code style).
        // Only when the item actually extends the typed prefix.
        if (self.state.mode == .insert and self.completion_sel < total) {
            const item = self.completion_words.items[self.completion_sel].text;
            const typed_len = self.curCursor().* - self.completion_pos;
            const ghost_line = self.cur().pt.lineOf(self.curCursor().*);
            const ghost_col = self.screenCellCol(win, ghost_line, self.curCursor().*);
            if (item.len > typed_len and typed_len > 0 and typed_len < 256) {
                var prefix_buf: [256]u8 = undefined;
                self.cur().pt.copyRange(self.completion_pos, prefix_buf[0..typed_len]);
                if (std.mem.startsWith(u8, item, prefix_buf[0..typed_len])) {
                    const ghost = item[typed_len..];
                    // the ghost starts right after the cursor (which sits
                    // after the typed prefix) — NOT offset by typed_len,
                    // which would push it away from the word when the
                    // word has a prefix like "b." (b.stand + ghost had a
                    // gap that made the completion look broken)
                    if (ghost.len > 0) {
                        // keep the ghost inside THIS pane: win.width is
                        // the whole screen, and a split's neighbor owns
                        // the columns past the pane's right edge
                        const ghost_start = cur_rect.col + gutter + ghost_col;
                        if (ghost_start + ghost.len <= cur_rect.col + cur_rect.width) {
                            const seg = [_]vaxis.Segment{.{
                                .text = ghost,
                                .style = .{ .dim = true },
                            }};
                            _ = win.print(&seg, .{
                                .row_offset = @intCast(ghost_line - self.curViewTop().* + cur_rect.row),
                                .col_offset = @intCast(ghost_start),
                                .wrap = .none,
                            });
                        }
                    }
                }
            }
        }
    }

    // Current-line blame ghost (<leader>tb, nvim gitsigns style): the
    // blame of the CURSOR line renders as dim end-of-line virtual
    // text — "<author>, HH:MM - <summary>" — 1s after the cursor
    // settles (CursorHold), hidden again while it moves. Mirrors the
    // nvim config: current_line_blame virt_text at eol, formatter
    // '<author>, <author_time:%R> - <summary>'.
    {
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
        if (self.curCursor().* != self.blame_last_cursor) {
            self.blame_last_cursor = self.curCursor().*;
            self.blame_move_ms = now_ms;
        }
        if (self.blame_active and self.state.mode == .normal and
            self.git_blame != null and now_ms - self.blame_move_ms >= blame_hold_ms)
        {
            const fbuf = self.cur();
            const blame_line = fbuf.pt.lineOf(self.curCursor().*);
            if (self.git_blame_path) |bp| {
                if (fbuf.path == null or !std.mem.eql(u8, bp, fbuf.path.?)) {
                    // cached blame is for another file — no ghost
                } else if (self.git_blame.?.at(blame_line)) |e| {
                    // The label is rebuilt only when the blame LINE or the
                    // blame DATA changed (the entry pointer identifies both:
                    // entries live in git_blame's own array, replaced on
                    // refresh) — the ghost repaints every idle frame.
                    var label: []const u8 = undefined;
                    if (self.blame_ghost_label) |*g| {
                        if (g.line == blame_line and g.entry == e) {
                            label = g.label;
                        } else {
                            self.alloc.free(g.label);
                            self.blame_ghost_label = null;
                        }
                    }
                    if (self.blame_ghost_label == null) {
                        var hm_buf: [5]u8 = undefined;
                        const hm = formatHm(&hm_buf, e.author_time);
                        const lbl = try std.fmt.allocPrint(self.alloc, " {s}, {s} - {s}", .{ e.author, hm, e.summary });
                        self.blame_ghost_label = .{ .line = blame_line, .entry = e, .label = lbl };
                        label = lbl;
                    }
                    const line_end = fbuf.pt.lineStart(blame_line) + fbuf.pt.lineLen(blame_line);
                    const end_col = self.screenCellCol(win, blame_line, line_end);
                    var start_col = cur_rect.col + gutter + end_col;
                    // a closed fold's " … N lines" marker also renders after
                    // the text — shift the ghost past it
                    if (foldAt(fbuf, blame_line)) |f| {
                        const marker = try std.fmt.allocPrint(a, " … {d} lines", .{f.hiddenCount()});
                        start_col += self.textWidth(win, marker);
                    }
                    // the ghost must stay inside THIS pane: win.width is
                    // the whole screen, and a split's neighbor owns the
                    // columns past the pane's right edge
                    const pane_end = cur_rect.col + cur_rect.width;
                    if (start_col < pane_end) {
                        const fit = autil.cellFitPrefix(win, label, pane_end - start_col);
                        if (fit.cells > 0) {
                            const seg = [_]vaxis.Segment{.{
                                .text = fit.slice,
                                .style = .{ .dim = true },
                            }};
                            _ = win.print(&seg, .{
                                .row_offset = @intCast(blame_line - self.curViewTop().* + cur_rect.row),
                                .col_offset = @intCast(start_col),
                                .wrap = .none,
                            });
                        }
                    }
                }
            }
        }
    }

    // LSP hover / signature floating window: a small box below the
    // cursor line (≤6 rows, ≤60 cols) showing nav_hover_text, wrapping
    // on newlines so multi-line hover (markdown blocks etc.) is readable.
    // Styled like nvim's floating windows: rounded border, title bar.
    // Every cell inside the box carries bg_float (including the border
    // and the padding after short lines) so the panel is a solid,
    // theme-colored block — never gaps of the editor background.
    if (self.nav_hover_text) |htext| {
        if (htext.len > 0) {
            const h_line = self.cur().pt.lineOf(self.curCursor().*);
            const hcols: u32 = 60;
            // the box hugs the text: its height is the number of wrapped
            // lines, capped at 6 so a huge hover never covers the buffer
            var hrows: u32 = 1;
            for (htext) |c| {
                if (c == '\n') hrows += 1;
            }
            hrows = @min(hrows, 6);
            var start_row = h_line - self.curViewTop().* + cur_rect.row + 1;
            if (start_row + hrows >= height) {
                start_row = (h_line - self.curViewTop().* + cur_rect.row) -| hrows;
            }
            const col0 = cur_rect.col + gutter + 1;
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const border = "│";
            const tl = "╭";
            const tr = "╮";
            const bl = "╰";
            const br = "╯";
            // top border
            {
                const seg = [_]vaxis.Segment{
                    .{ .text = tl, .style = border_style },
                    .{ .text = "─", .style = border_style },
                };
                _ = win.print(&seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0), .wrap = .none });
                var cx: u32 = 1;
                while (cx <= hcols) : (cx += 1) {
                    const hseg = [_]vaxis.Segment{.{
                        .text = "─",
                        .style = border_style,
                    }};
                    _ = win.print(&hseg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0 + cx), .wrap = .none });
                }
                const rseg = [_]vaxis.Segment{.{
                    .text = tr,
                    .style = border_style,
                }};
                _ = win.print(&rseg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0 + hcols + 1), .wrap = .none });
            }
            // Split the text into up to hrows lines; fence off ```lang
            // code blocks and syntax-highlight their content with
            // tree-sitter (hoverCodeLineSegs); prose lines get markdown-
            // ish token colors (hoverLineSegs). Fence lines render dim.
            // Every cell keeps bg_float — the panel stays a solid block.
            const HoverBlock = struct {
                start: usize,
                end: usize, // line indices, end exclusive
                lang: ?[]const u8,
                text: []u8, // lines joined with '\n' (arena)
                offsets: []u32, // byte offset of each line in text
                spans: []syntax.Span, // merged spans over text
            };
            var lines = std.ArrayList([]const u8).empty;
            var kinds = std.ArrayList(u8).empty; // 0 prose, 1 fence, 2 code
            var blocks = std.ArrayList(HoverBlock).empty;
            {
                var remaining = htext;
                var r: u32 = 0;
                var in_fence: ?[]const u8 = null;
                var block_start: usize = 0;
                while (r < hrows) : (r += 1) {
                    const nl = std.mem.indexOfScalar(u8, remaining, '\n');
                    const line_len = if (nl) |i| i else remaining.len;
                    try lines.append(a, remaining[0..line_len]);
                    if (in_fence == null) {
                        if (autil.isFenceLine(remaining[0..line_len])) |flang| {
                            try kinds.append(a, 1);
                            in_fence = flang;
                            block_start = lines.items.len;
                        } else {
                            try kinds.append(a, 0);
                        }
                    } else {
                        if (autil.isFenceLine(remaining[0..line_len]) != null) {
                            try kinds.append(a, 1);
                            try blocks.append(a, .{ .start = block_start, .end = lines.items.len, .lang = in_fence, .text = &.{}, .offsets = &.{}, .spans = &.{} });
                            in_fence = null;
                        } else {
                            try kinds.append(a, 2);
                        }
                    }
                    if (nl) |i| {
                        remaining = remaining[@min(i + 1, remaining.len)..];
                    } else {
                        remaining = remaining[remaining.len..];
                    }
                }
                if (in_fence != null) {
                    try blocks.append(a, .{ .start = block_start, .end = lines.items.len, .lang = in_fence, .text = &.{}, .offsets = &.{}, .spans = &.{} });
                }
            }
            // Build each block: joined text, per-line byte offsets, and
            // merged tree-sitter spans (all arena — the highlighter lives
            // only for this frame). The fence language wins; a bare or
            // unknown fence falls back to the current file's language.
            for (blocks.items) |*blk| {
                if (blk.start >= blk.end) continue;
                var text = std.ArrayList(u8).empty;
                var offsets = std.ArrayList(u32).empty;
                var bli = blk.start;
                while (bli < blk.end) : (bli += 1) {
                    try offsets.append(a, @intCast(text.items.len));
                    try text.appendSlice(a, lines.items[bli]);
                    try text.append(a, '\n');
                }
                blk.text = try text.toOwnedSlice(a);
                blk.offsets = try offsets.toOwnedSlice(a);
                var hl: ?syntax.Highlighter = null;
                if (blk.lang) |l| {
                    if (l.len > 0) {
                        if (syntax.languageFor(l)) |ln| hl = syntax.Highlighter.init(a, ln) catch null;
                    }
                }
                if (hl == null) {
                    const ft = autil.filetypeOf(self.cur().path);
                    if (syntax.languageFor(ft)) |ln| hl = syntax.Highlighter.init(a, ln) catch null;
                }
                if (hl) |*h| {
                    h.reparse(blk.text) catch {};
                    var raw = std.ArrayList(syntax.Span).empty;
                    h.spansInRange(0, @intCast(blk.text.len), a, &raw) catch {};
                    var merged = std.ArrayList(syntax.Span).empty;
                    for (raw.items) |sp| {
                        while (merged.items.len > 0) {
                            var last = &merged.items[merged.items.len - 1];
                            if (sp.start >= last.end) break; // disjoint
                            if (sp.start <= last.start) {
                                _ = merged.pop(); // covered wholly
                                continue;
                            }
                            last.end = sp.start; // later span wins
                            break;
                        }
                        try merged.append(a, sp);
                    }
                    blk.spans = try merged.toOwnedSlice(a);
                }
            }
            // Render each row: code lines use their block's spans, fence
            // lines dim, prose lines the markdown tokenizer.
            var r: u32 = 0;
            var cur_block: usize = 0;
            while (r < hrows) : (r += 1) {
                const line = lines.items[r];
                var inner: []vaxis.Segment = undefined;
                switch (kinds.items[r]) {
                    1 => inner = try self.hoverFenceSegs(a, line, hcols),
                    2 => {
                        while (cur_block < blocks.items.len and blocks.items[cur_block].end <= r) cur_block += 1;
                        if (cur_block < blocks.items.len and blocks.items[cur_block].start <= r) {
                            const blk = &blocks.items[cur_block];
                            const bi = r - blk.start;
                            const ls = blk.offsets[bi];
                            const shown = @min(line.len, @as(usize, @intCast(hcols)));
                            inner = try self.hoverCodeLineSegs(a, blk.text, ls, ls + shown, blk.spans, hcols);
                        } else {
                            inner = try self.hoverLineSegs(a, line, hcols);
                        }
                    },
                    else => inner = try self.hoverLineSegs(a, line, hcols),
                }
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = border, .style = border_style });
                try segs.appendSlice(a, inner);
                try segs.append(a, .{ .text = border, .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + r), .col_offset = @intCast(col0), .wrap = .none });
            }
            // bottom border
            {
                const bseg = [_]vaxis.Segment{.{
                    .text = bl,
                    .style = border_style,
                }};
                _ = win.print(&bseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0), .wrap = .none });
                var cx: u32 = 1;
                while (cx <= hcols) : (cx += 1) {
                    const hseg = [_]vaxis.Segment{.{
                        .text = "─",
                        .style = border_style,
                    }};
                    _ = win.print(&hseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0 + cx), .wrap = .none });
                }
                const rseg = [_]vaxis.Segment{.{
                    .text = br,
                    .style = border_style,
                }};
                _ = win.print(&rseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0 + hcols + 1), .wrap = .none });
            }
        }
    }

    const mode_str = switch (self.state.mode) {
        .normal => " NORMAL ",
        .insert => " INSERT ",
        .visual_char, .visual_line, .visual_block => " VISUAL ",
        .command => " COMMAND ",
    };
    const status_col = self.screenCellCol(win, cursor_line, self.curCursor().*);
    // a completion request is in flight (zls can take many seconds on
    // build.zig while its build_runner analyses the project) — show "…"
    // so a slow response isn't mistaken for a dead completion that
    // silently turns the next Enter into a newline.
    const status = if (self.completion_slot != null)
        try std.fmt.allocPrint(
            a,
            "{s} line {d}/{d} col {d}  …",
            .{ mode_str, cursor_line + 1, line_count, status_col },
        )
    else if (self.msg) |m|
        try std.fmt.allocPrint(
            a,
            "{s} line {d}/{d} col {d}  {s}",
            .{ mode_str, cursor_line + 1, line_count, status_col, m },
        )
    else
        try std.fmt.allocPrint(
            a,
            "{s} line {d}/{d} col {d}",
            .{ mode_str, cursor_line + 1, line_count, status_col },
        );
    const status_seg = [_]vaxis.Segment{.{
        .text = status,
        .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status } },
    }};
    _ = win.print(&status_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
    // git branch (M3a): "  ⎇ main" right after the mode/message text, in
    // the accent color — the design's StatusLine git component.
    if (self.git_branch) |b| {
        const branch_seg = [_]vaxis.Segment{.{
            .text = try std.fmt.allocPrint(a, "  ⎇ {s}", .{std.mem.trim(u8, b, " \t\r\n")}),
            .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_status } },
        }};
        _ = win.print(&branch_seg, .{ .row_offset = @intCast(height - 1), .col_offset = @intCast(status.len), .wrap = .none });
    }

    // terminal focused: the widget's draw() already placed the child's
    // cursor — the editor cursor must not overwrite it
    if (term.supported) {
        if (self.term_pane) |*tp| {
            if (tp.focused) {
                try self.vx.render(self.tty.writer());
                return;
            }
        }
    }
    // cursor position — in the file tree when the tree has focus,
    // otherwise in the buffer
    if (self.filetree_active and self.focus == .filetree) {
        // Items render at contentTop()+1+k (below the "╭─ files" title
        // row) with text starting at column 1 (after the left border) —
        // the cursor must land on the same row/column as the highlight.
        const sel_row: u32 = self.contentTop(a) + 1 + @as(u32, @intCast(self.filetree_sel -| self.filetree_top));
        self.vx.screen.cursor = .{
            .row = @intCast(sel_row),
            .col = 1,
        };
    } else if (self.nav_list_active) {
        // The location-list float (gr/gI/<leader>o) is navigated with
        // j/k: the block cursor sits on the selected row of the float
        // (start_col + 1 = after the left border), like the file tree.
        self.vx.screen.cursor = .{
            .row = @intCast(self.nav_float_row + 1 + @as(u32, @intCast(self.nav_list_sel -| self.nav_loc_top))),
            .col = @intCast(self.nav_float_col + 1),
        };
    } else {
        const cursor_col = self.screenCellCol(win, cursor_line, self.curCursor().*);
        // screen row = count of VISIBLE lines between view_top and the
        // cursor (a closed fold's hidden body occupies zero rows)
        var cursor_row: u32 = cur_rect.row;
        {
            const fbuf = self.cur();
            var l = self.curViewTop().*;
            while (l < cursor_line) : (cursor_row += 1) l = foldNextLine(fbuf, l);
        }
        self.vx.screen.cursor = .{
            .row = @intCast(cursor_row),
            .col = @intCast(cur_rect.col + gutter + cursor_col), // window offset + gutter
        };
    }
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_shape = if (self.state.mode == .insert) .beam else .block;

    try self.vx.render(self.tty.writer());
}

/// True while the current-line blame's 1s CursorHold window is still
/// counting (the loop then polls instead of blocking, so the ghost
/// appears without a keypress).
pub fn blameHoldActive(self: *App) bool {
    if (!self.blame_active or self.git_blame == null) return false;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
    return now - self.blame_move_ms < blame_hold_ms;
}

/// True while the scope highlight animation is still spreading: the run
/// loop then polls instead of blocking in pollEvent, so the spread
/// advances frame by frame without keypresses.
pub fn scopeAnimActive(self: *App) bool {
    const a = self.scope_anim orelse return false;
    const now = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms);
    return now - a.start_ms < ScopeAnim.duration_ms;
}

pub fn run(self: *App) !void {
    try self.vx.enterAltScreen(self.tty.writer());
    try self.loop.start();
    defer self.loop.stop();
    // monotonic ms of the last frame we actually drew — poll-mode
    // iterations without events skip render() until 16ms have elapsed
    // (the animation frame cadence), so idle polling costs no renders.
    var last_render_ms: i64 = 0;
    while (!self.quit) {
        // LSP messages first: responses fill request slots, notifications
        // reach the handler before the frame renders; then consume any
        // completed navigation request before the frame is drawn.
        if (self.lsp_client) |c| c.drain(self, App.lspHandler);
        // Server exited/crashed (stdout EOF or read error): nothing more
        // will ever arrive — drop the dead client, clear its state and
        // tell the user, instead of letting pending requests hang forever.
        if (self.lsp_client) |c| {
            if (c.server_died.load(.acquire)) {
                self.teardownLsp(true);
            }
        }
        // Consume async LSP responses (navigation, completion) and render
        // immediately — otherwise the loop would block in pollEvent below
        // before the new hover window / completion menu is drawn.
        const nav_ready = self.processNav();
        const comp_ready = self.processCompletion();
        const fmt_ready = self.processFormat();
        const inlay_ready = self.processInlay();
        const outline_ready = self.processOutline();
        const diag_changed = self.diag_dirty;
        self.diag_dirty = false;
        // Consume a completed git job (status refresh / blame / hunk
        // apply): gutter marks, branch and floats update without a
        // keypress, same as the LSP slots.
        var git_ready = false;
        if (self.git_job) |job| {
            if (job.done.load(.acquire)) {
                self.consumeGitJob(job);
                git_ready = true;
            }
        }
        // A finished async LSP attach installs its client (and opens the
        // document) — render so diagnostics/inlay requests can start.
        const lsp_ready = self.finishLspStart();
        // Embedded terminal events (redraw / exited / title_change):
        // drain before the frame renders. The vaxis widget has no wake
        // hook — while a terminal is open the loop polls at 16ms below
        // instead of blocking in pollEvent.
        var term_ready = false;
        if (term.supported) {
            if (self.term_pane) |*tp| {
                // .exited closes the terminal, freeing `tp` — break out
                // of the loop first (the while condition would
                // dereference the freed pane) and close after draining.
                var term_exited = false;
                while (try tp.t.pollEvent()) |ev| {
                    switch (ev) {
                        .exited => {
                            term_exited = true;
                            break;
                        },
                        .redraw => term_ready = true,
                        .bell => {},
                        .title_change => |t| {
                            // event slice borrows the widget's internal
                            // buffer — dupe before the next event
                            if (tp.title) |x| self.alloc.free(x);
                            tp.title = try self.alloc.dupe(u8, t);
                        },
                        .pwd_change => {},
                    }
                }
                if (term_exited) {
                    const m = self.alloc.dupe(u8, "terminal exited") catch null;
                    if (m) |mm| try self.setMsg(mm);
                    self.closeTerm();
                }
            }
        }
        if (nav_ready or comp_ready or fmt_ready or inlay_ready or outline_ready or diag_changed or git_ready or lsp_ready or term_ready) {
            try self.render();
            last_render_ms = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
            continue;
        }
        // Auto-refresh inlay hints when the view scrolls (LSP available and
        // the visible range left the band covered by the last request — see
        // requestInlayHints). While a request is in flight the refresh is
        // SKIPPED: fast scrolling must not pile superseded requests into the
        // server queue (zls would compute and discard each one, delaying the
        // hints for the viewport the user actually stopped at); the band
        // check below fires again as soon as the response lands.
        if (self.lsp_client) |client| {
            if (client.caps_inlay and !self.inlay_inflight) {
                const top = self.curViewTop().*;
                var in_band = false;
                if (self.inlay_view_top) |band_top| {
                    if (self.inlay_view_end) |band_end| {
                        if (top >= band_top) {
                            // The request reached the last line of the
                            // document (EOF clamp): nothing more can be
                            // fetched, so the band is always "enough" no
                            // matter how tall the viewport is.
                            const line_count = self.cur().pt.lineCount();
                            if (band_end + 1 >= line_count) {
                                in_band = true;
                            } else {
                                const viewport_last = @as(u64, top) + self.focusedWinHeight();
                                in_band = viewport_last <= band_end;
                            }
                        }
                    }
                }
                if (!in_band) try self.requestInlayHints();
            }
        }
        // poll + drain: block until an event arrives (keypress OR an
        // LSP wake posted by the reader thread), then handle the whole
        // batch and render once. While the scope highlight is animating,
        // the blame hold is counting, or a terminal is open (its reader
        // thread has no wake hook), poll instead of blocking so the
        // frame advances without keypresses (16ms ≈ 60fps; vaxis diffs
        // the output). The poll slice is SHORT (1ms) — a keypress must
        // wake the loop within ~1ms, not up to 16ms: while the animation
        // runs, the loop would otherwise sleep past the key and add a
        // full frame's latency to every keypress (a "G k x20" script
        // spends its whole run inside the 500ms animation window).
        // The render pacing below keeps animation frames at ~16ms.
        // Poll-mode transition guard: while scope-animating / blame-
        // holding / terminal-open, the loop sleeps in 1ms slices so a
        // keypress wakes it within ~1ms. When the last such condition
        // flips false the loop is about to block in pollEvent — the
        // render pacing below could otherwise skip the FINAL frame (e.g.
        // the blame ghost appearing as the 1s CursorHold expires, or the
        // animation's last spread) and the loop would block forever
        // without ever drawing it. Force that one render.
        var poll_transition = false;
        if (self.scopeAnimActive() or self.blameHoldActive() or (term.supported and self.term_pane != null)) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .real) catch {};
            self.poll_mode_active = true;
        } else if (self.poll_mode_active) {
            // Transition out of poll mode: do NOT block in pollEvent
            // yet — the render below (forced via poll_transition) must
            // draw the final poll state first (the blame ghost appearing
            // as the 1s CursorHold expires, the animation's last spread).
            // The next iteration blocks as usual.
            self.poll_mode_active = false;
            poll_transition = true;
        } else {
            try self.loop.pollEvent();
        }
        var handled = false;
        while (try self.loop.tryEvent()) |event| {
            handled = true;
            switch (event) {
                .key_press => |key| try self.handleKey(key),
                .paste => |text| {
                    // terminal focus: forward the paste to the child
                    if (term.supported) {
                        if (self.term_pane) |*tp| {
                            if (tp.focused) {
                                try tp.t.sendText(text);
                                continue;
                            }
                        }
                    }
                    if (self.state.mode == .insert) {
                        if (self.mc_active) try self.mcInsertText(text) else try self.insertText(text);
                    }
                },
                .winsize => |ws| {
                    try self.vx.resize(self.alloc, self.tty.writer(), ws);
                },
                else => {},
            }
        }
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
        if (handled or poll_transition or now_ms - last_render_ms >= 16) {
            try self.render();
            last_render_ms = now_ms;
        }
    }

    try self.vx.exitAltScreen(self.tty.writer());
}
