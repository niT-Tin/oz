//! render — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const util = @import("../util/root.zig");
const syntax = @import("../syntax.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_nav = @import("../lsp/navigation.zig");
const lsp_diag = @import("../lsp/diagnostics.zig");
const diagnostic_ui = @import("diagnostics.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const keymap_list = @import("../editor/keymap_list.zig");
const git = @import("../git.zig");
const term = @import("../term.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const nav_tabs = @import("navigator.zig");
const gutter_model = @import("gutter.zig");
const note_store = @import("note_store.zig");
const autil = @import("util.zig");
const chrome = @import("chrome.zig");
const statusline = @import("statusline.zig");
const completion = @import("completion.zig");
const completion_layout = @import("completion_layout.zig");
const hover_layout = @import("hover_layout.zig");
const server_config = @import("../lsp/server_config.zig");
const tabstrip = @import("tabstrip.zig");
const animation = @import("animation.zig");
const git_job = @import("git_job.zig");
const markdown = @import("markdown.zig");
const table_cell_ui = @import("table_cell_ui.zig");
const wrap = @import("wrap.zig");

const tab_width = app_mod.tab_width;
const status_row_count = app_mod.status_row_count;
const blame_hold_ms = app_mod.blame_hold_ms;
const git_marks_hold_ms = app_mod.git_marks_hold_ms;
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

pub const filetree_width: u32 = nav_tabs.panel_width;
/// Blank column between the navigator's right border and editor content.
pub const filetree_gutter: u32 = nav_tabs.gutter;

/// There is no global header stack. layoutWindows reserves each pane's
/// own single label row, and all cursor/mouse/popup users receive its body.
pub fn tabBarRows(self: *App, a: std.mem.Allocator) u32 {
    _ = self;
    _ = a;
    return 0;
}

/// Start of the editor layout, including each pane's local header.
pub fn contentTop(self: *App, a: std.mem.Allocator) u32 {
    return self.tabBarRows(a);
}

pub fn navigatorMode(self: *App) nav_tabs.Mode {
    if (self.ai.agent_focus) return .compact;
    return nav_tabs.modeForCols(self.vx.window().width);
}

pub fn contentCol(self: *App) u32 {
    // Agent-focus deliberately keeps the 7-cell icon rail at every width.
    return nav_tabs.editorColForMode(self.filetree_active, self.navigatorMode());
}

/// Width of the editor's usable area after the navigator takes its column
/// slice. Layouts/splits/tab layers must use this (not `aiEditorWidth`,
/// which is the full span from column 0 to the rail) or a navigator-open
/// pane would wrap text underneath the navigator/rail.
pub fn editorAreaWidth(self: *App) u32 {
    return self.aiEditorWidth() -| self.contentCol();
}

/// First navigator body row below its single mode strip.
pub fn navigatorBodyTop(self: *App, a: std.mem.Allocator) u32 {
    return self.contentTop(a) + nav_tabs.full_header_rows;
}

/// True when the compact icon rail's peek drawer should be drawn/owned.
pub fn navigatorPeekActive(self: *App) bool {
    return self.filetree_active and self.navigator_peek and
        self.navigatorMode() == .compact;
}

/// Adaptive numbers plus independent number/sign and sign/source padding.
/// Every geometry consumer (render, wrap, mouse, cursor and popups) uses this.
pub fn gutterWidth(self: *const App, line_count: u32) u32 {
    _ = self;
    return gutter_model.forLineCount(line_count).width;
}

/// Pane-aware width for every source-coordinate consumer. The nominal API
/// above remains available to callers that only need the full layout.
pub fn gutterWidthFor(self: *const App, line_count: u32, pane_width: u32) u32 {
    _ = self;
    return gutter_model.forPane(line_count, pane_width).width;
}

/// Display column (in cells) of `byte_pos` within `line`. vaxis renders a
/// multi-byte grapheme as one or two cells, so anything positioned from a
/// byte offset (the text cursor, the completion menu, ghost text) must be
/// converted — otherwise the cursor appears stuck mid-text on lines that
/// contain non-ASCII characters (e.g. after accepting a suggestion that
/// inserted text before/after CJK characters).
pub fn lineCellCol(self: *App, win: vaxis.Window, line: u32, byte_pos: u32) u32 {
    const pt = &self.cur().pt;
    const start = pt.lineStart(line);
    var iter = LineGraphemes{ .pt = pt, .pos = start, .end = start + pt.lineTextLen(line) };
    var col: u32 = 0;
    while (iter.next()) |g| {
        if (g.start + g.bytes.len > byte_pos) break;
        col += if (std.mem.eql(u8, g.bytes, "\t")) tab_width else win.gwidth(g.bytes);
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
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        col += if (std.mem.eql(u8, bytes, "\t")) tab_width else win.gwidth(bytes);
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
    const end = ls + pt.lineTextLen(line);
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
    const ll = buf.pt.lineTextLen(l);
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
    const ll = buf.pt.lineTextLen(l);
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

/// Soft-wrap measurement and painting share grapheme widths, tab expansion
/// and edge-gap rules. Insertion after an exactly full line reserves a row.
// Iterate whole graphemes from a bounded piece-table cache. Refill before
// consuming a grapheme at a chunk boundary so combining marks/ZWJ stay joined.
const LineGraphemes = struct {
    pt: *const buffer.PieceTable,
    pos: u32,
    end: u32,
    begin: u32 = 0,
    len: u32 = 0,
    cache: [4096]u8 = undefined,
    fn refill(it: *@This()) void {
        it.begin = it.pos;
        it.len = @min(it.end - it.pos, it.cache.len);
        it.pt.copyRange(it.pos, it.cache[0..it.len]);
    }
    fn next(it: *@This()) ?struct { start: u32, bytes: []const u8 } {
        if (it.pos >= it.end) return null;
        if (it.pos < it.begin or it.pos >= it.begin + it.len) it.refill();
        var rest = it.cache[it.pos - it.begin .. it.len];
        var iter = vaxis.unicode.graphemeIterator(rest);
        var g = iter.next() orelse return null;
        if (g.len + 4 >= rest.len and it.begin + it.len < it.end and it.pos > it.begin) {
            it.refill();
            rest = it.cache[0..it.len];
            iter = vaxis.unicode.graphemeIterator(rest);
            g = iter.next() orelse return null;
        }
        const start = it.pos;
        it.pos += @intCast(g.len);
        return .{ .start = start, .bytes = g.bytes(rest) };
    }
};
fn addWrappedText(layout: *wrap.Layout, win: vaxis.Window, text: []const u8) void {
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        if (std.mem.eql(u8, bytes, "\t")) {
            for (0..tab_width) |_| layout.add(1);
        } else layout.add(win.gwidth(bytes));
    }
}
const LineWrap = struct { cursor: wrap.Pos, rows: u32 };

// Printable ASCII has exactly one cell per byte. Inspect complete lines so a
// combining mark in the next piece always selects the grapheme-aware path.
fn plainAscii(pt: *const buffer.PieceTable, start: u32, end: u32) bool {
    var pos = start;
    while (pos < end) {
        const piece = pt.bytesAt(pos);
        const bytes = piece[0..@min(end - pos, piece.len)];
        for (bytes) |b| if (!std.ascii.isPrint(b)) return false;
        pos += @intCast(bytes.len);
    }
    return true;
}

fn lineWrap(self: *App, win: vaxis.Window, buf: *Buffer, buf_index: usize, line: u32, width: u32, target: ?u32) LineWrap {
    const ls = buf.pt.lineStart(line);
    const end = ls + buf.pt.lineTextLen(line);
    var layout = wrap.Layout{ .width = @max(width, 1) };
    var result: ?wrap.Pos = null;
    var hint_i: usize = 0;
    const hints = if (!self.inlay_stale and self.inlay_buf == buf_index) self.inlay_hints.items else &.{};
    while (hint_i < hints.len and hints[hint_i].line < line) hint_i += 1;
    const insert_eol = self.state.mode == .insert and buf_index == self.current and self.curCursor().* == end;
    if ((hint_i == hints.len or hints[hint_i].line != line) and foldAt(buf, line) == null and plainAscii(&buf.pt, ls, end)) {
        const col = @min(target orelse end, end) -| ls;
        const cw = layout.width;
        const cursor = wrap.Pos{ .row = col / cw, .col = col % cw };
        const text_rows = (end - ls -| 1) / cw + 1;
        return .{ .cursor = cursor, .rows = if (insert_eol) @max(text_rows, cursor.row + 1) else text_rows };
    }
    var it = LineGraphemes{ .pt = &buf.pt, .pos = ls, .end = end };
    while (it.next()) |g| {
        while (hint_i < hints.len and hints[hint_i].line == line and hints[hint_i].character <= g.start - ls) : (hint_i += 1)
            addWrappedText(&layout, win, hints[hint_i].label);
        const is_tab = std.mem.eql(u8, g.bytes, "\t");
        const cells: u32 = if (is_tab) 1 else win.gwidth(g.bytes);
        _ = layout.place(cells);
        if (target) |pos| if (result == null and pos < g.start + g.bytes.len) {
            result = layout.cursor();
        };
        if (is_tab) {
            for (0..tab_width) |_| layout.add(1);
        } else layout.add(cells);
    }
    while (hint_i < hints.len and hints[hint_i].line == line) : (hint_i += 1) addWrappedText(&layout, win, hints[hint_i].label);
    if (result == null) result = layout.cursor();
    if (foldAt(buf, line)) |f| {
        var mbuf: [24]u8 = undefined;
        addWrappedText(&layout, win, std.fmt.bufPrint(&mbuf, " … {d} lines", .{f.hiddenCount()}) catch "");
    }
    var rows = layout.pos.row + 1;
    if (insert_eol)
        rows = @max(rows, result.?.row + 1);
    return .{ .cursor = result.?, .rows = rows };
}
pub fn lineDisplayRows(self: *App, win: vaxis.Window, buf: *Buffer, buf_index: usize, line: u32, content_width: u32) u32 {
    return lineWrap(self, win, buf, buf_index, line, content_width, null).rows;
}

pub fn markdownTopRuleRows(layout: ?*const markdown.Layout, line: u32) u32 {
    const md = layout orelse return 0;
    const info = md.get(line) orelse return 0;
    return @intFromBool(info.top_rule != null);
}

fn loadMarkdownImage(self: *App, path: []const u8) !vaxis.Image {
    if (std.mem.eql(u8, std.fs.path.extension(path), ".png")) {
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only });
        defer file.close(self.io);
        var header: [24]u8 = undefined;
        const n = try file.readPositionalAll(self.io, &header, 0);
        if (n == header.len and std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n") and
            std.mem.eql(u8, header[12..16], "IHDR"))
        {
            const width = std.mem.readInt(u32, header[16..20], .big);
            const height = std.mem.readInt(u32, header[20..24], .big);
            if (width > 0 and height > 0 and width <= std.math.maxInt(u16) and height <= std.math.maxInt(u16)) {
                return self.vx.transmitLocalImagePath(self.alloc, self.tty.writer(), path, @intCast(width), @intCast(height), .file, .png);
            }
        }
    }
    return self.vx.loadImage(self.alloc, self.tty.writer(), .{ .path = path });
}

fn prepareMarkdownImages(self: *App, layout: ?*const markdown.Layout) !void {
    const md = layout orelse return;
    if (!self.vx.caps.kitty_graphics) return;
    var it = md.entries.valueIterator();
    while (it.next()) |info| {
        const image = info.image orelse continue;
        const path = image.path orelse continue;
        if (self.markdown_images.contains(path)) continue;
        const key = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(key);
        const loaded = loadMarkdownImage(self, path) catch {
            try self.markdown_images.put(key, .failed);
            continue;
        };
        try self.markdown_images.put(key, .{ .loaded = loaded });
    }
}

fn hideInactiveMarkdownImages(self: *App) void {
    var i: usize = 0;
    while (i < self.markdown_placed_images.items.len) {
        const id = self.markdown_placed_images.items[i];
        if (std.mem.indexOfScalar(u32, self.markdown_visible_images.items, id) != null) {
            i += 1;
            continue;
        }
        self.tty.writer().print("\x1b_Ga=d,d=i,i={d};\x1b\\", .{id}) catch {};
        _ = self.markdown_placed_images.swapRemove(i);
    }
    const previous = self.markdown_placed_images;
    self.markdown_placed_images = self.markdown_visible_images;
    self.markdown_visible_images = previous;
    self.markdown_visible_images.clearRetainingCapacity();
}

fn markdownImage(self: *App, info: markdown.Line) ?vaxis.Image {
    if (!self.vx.caps.kitty_graphics) return null;
    if (info.diagram) |diagram| return self.mermaid.image(diagram);
    const image = info.image orelse return null;
    const path = image.path orelse return null;
    if (self.markdown_images.get(path) == null) {
        // Capability responses and image loads can arrive after the layout
        // was built; load on demand here so the first frame that renders the
        // image can place it, instead of caching a zero-row placeholder.
        const key = self.alloc.dupe(u8, path) catch return null;
        const loaded = loadMarkdownImage(self, path) catch {
            self.markdown_images.put(key, .failed) catch self.alloc.free(key);
            return null;
        };
        self.markdown_images.put(key, .{ .loaded = loaded }) catch {
            self.alloc.free(key);
            self.vx.freeImage(self.tty.writer(), loaded.id);
            return null;
        };
    }
    return switch (self.markdown_images.get(path).?) {
        .loaded => |img| img,
        .failed => null,
    };
}

const MarkdownImageFit = struct {
    rows: u32,
    options: vaxis.Image.DrawOptions = .{},
};

fn fitMarkdownImage(img: vaxis.Image, win: vaxis.Window, cols: u32, rows: u32) ?MarkdownImageFit {
    if (cols == 0 or rows == 0 or win.screen.width_pix == 0 or win.screen.height_pix == 0) return null;
    const cell_w = std.math.divCeil(u64, win.screen.width_pix, win.screen.width) catch return null;
    const cell_h = std.math.divCeil(u64, win.screen.height_pix, win.screen.height) catch return null;
    const max_width = cols * cell_w;
    const max_height = rows * cell_h;
    if (img.width <= max_width and img.height <= max_height)
        return .{ .rows = @intCast(std.math.divCeil(u64, img.height, cell_h) catch return null) };
    // Give Kitty the limiting axis. The other axis scales proportionally.
    if (max_width * img.height <= max_height * img.width) {
        const height = std.math.divCeil(u64, max_width * img.height, @as(u64, img.width) * cell_h) catch return null;
        return .{ .rows = @intCast(height), .options = .{ .size = .{ .cols = @intCast(cols) } } };
    }
    return .{ .rows = rows, .options = .{ .size = .{ .rows = @intCast(rows) } } };
}

fn markdownImageRows(self: *App, win: vaxis.Window, info: markdown.Line, content_width: u32) u32 {
    const loaded = markdownImage(self, info) orelse return 0;
    const fit = fitMarkdownImage(loaded, win, content_width, 20) orelse return 0;
    return fit.rows;
}

fn drawMarkdownImage(self: *App, a: std.mem.Allocator, win: vaxis.Window, rect: LeafRect, row: u32, gutter: u32, content_width: u32, info: markdown.Line) !u32 {
    if (row >= rect.row + rect.height or !self.vx.caps.kitty_graphics) return row;
    if (info.diagram) |diagram| @import("mermaid.zig").State.request(self, diagram);
    const loaded = markdownImage(self, info) orelse return row;
    const fit = fitMarkdownImage(loaded, win, content_width, @min(20, rect.row + rect.height - row)) orelse return row;
    const blank = try a.alloc(u8, gutter + content_width);
    @memset(blank, ' ');
    const blank_seg = [_]vaxis.Segment{.{ .text = blank, .style = .{ .bg = .{ .rgb = self.theme.bg } } }};
    var y = row;
    const last = row + fit.rows;
    while (y < last) : (y += 1) {
        _ = win.print(&blank_seg, .{ .row_offset = @intCast(y), .col_offset = @intCast(rect.col), .wrap = .none });
    }
    const sub = win.child(.{
        .x_off = @intCast(rect.col + gutter),
        .y_off = @intCast(row),
        .width = @intCast(content_width),
        .height = @intCast(fit.rows),
    });
    loaded.draw(sub, fit.options) catch return last;
    if (std.mem.indexOfScalar(u32, self.markdown_visible_images.items, loaded.id) == null) {
        try self.markdown_visible_images.append(self.alloc, loaded.id);
    }
    return last;
}

pub fn displayRowsWithMarkdown(self: *App, win: vaxis.Window, buf: *Buffer, buf_index: usize, line: u32, content_width: u32, layout: ?*const markdown.Layout, cursor_line: u32) u32 {
    if (layout) |md| {
        if (md.get(line)) |info| {
            const virtual_rows = markdownImageRows(self, win, info, content_width) +
                @intFromBool(info.top_rule != null) + @intFromBool(info.bottom_rule != null);
            if (info.wrapped_table) |table| return virtual_rows + @as(u32, @intCast(table.rows.len));
            var display_width = info.display_width;
            if (display_width == 0 and info.gaps.len == 1 and
                info.gaps[0].start == buf.pt.lineStart(line) and
                info.gaps[0].end == buf.pt.lineStart(line) + buf.pt.lineLen(line))
            {
                display_width = self.textWidth(win, info.gaps[0].text);
            }
            const rows = if (display_width > 0 and line != cursor_line)
                @max(1, (display_width + content_width - 1) / content_width)
            else
                self.lineDisplayRows(win, buf, buf_index, line, content_width);
            return rows + virtual_rows;
        }
    }
    return self.lineDisplayRows(win, buf, buf_index, line, content_width);
}

/// On-screen position of byte `pos` (on buffer line `line`) in the FOCUSED
/// window: `row` counts the soft-wrapped rows of the visible lines in
/// [view_top, line) plus the wrap chunk holding the byte; `col` is the
/// cell column within that chunk (text-area relative — the gutter is NOT
/// included). With soft wrap a buffer line no longer maps to exactly one
/// screen row, so every overlay (multicursor highlights, easymotion
/// labels, completion menu, ghost/blame text, the cursor itself) must go
/// through this instead of `line - view_top`.
pub const ScreenPos = struct { row: u32, col: u32 };
pub fn focusedScreenPos(self: *App, win: vaxis.Window, rect: LeafRect, line: u32, pos: u32) ScreenPos {
    const buf = self.cur();
    const cw: u32 = @max(rect.width -| self.gutterWidthFor(buf.pt.lineCountUpperBound(), rect.width), 1);
    const md_layout = if (self.state.mode == .normal and !self.mc_active and !self.em_active and self.markdown_frame_buf == self.current)
        self.markdown_frame
    else
        null;
    var row: u32 = 0;
    var l = self.curViewTop().*;
    const cursor_line = buf.pt.lineOf(self.curCursor().*);
    while (l < line) : (l = foldNextLine(buf, l)) {
        row += displayRowsWithMarkdown(self, win, buf, self.current, l, cw, md_layout, cursor_line);
    }
    row += markdownTopRuleRows(md_layout, line);
    const cursor = markdownCursor(md_layout, line, pos) orelse lineWrap(self, win, buf, self.current, line, cw, pos).cursor;
    const skipped = self.windows.items[self.current_win].view_wrap;
    return .{
        .row = (row + cursor.row) -| skipped,
        .col = @min(cursor.col, cw - 1),
    };
}

fn markdownCursor(layout: ?*const markdown.Layout, line: u32, pos: u32) ?wrap.Pos {
    const info = (layout orelse return null).get(line) orelse return null;
    return (info.wrapped_table orelse return null).cursorAt(pos);
}

fn printMarkdownRule(
    a: std.mem.Allocator,
    win: vaxis.Window,
    rect: LeafRect,
    row: u32,
    gutter: u32,
    rule: ?[]const u8,
    style: vaxis.Style,
) !u32 {
    const text = rule orelse return row;
    if (row >= rect.row + rect.height) return row;
    // A table rule is a single structural row. The layout already sizes
    // its cells; never feed a corner into an ordinary text continuation.
    const pane_row = win.child(.{
        .x_off = @intCast(rect.col),
        .y_off = @intCast(row),
        .width = @intCast(rect.width),
        .height = 1,
    });
    const blank = try a.alloc(u8, gutter);
    @memset(blank, ' ');
    const segs = [_]vaxis.Segment{
        .{ .text = blank, .style = style },
        // The per-buffer layout may be replaced by another split this frame.
        .{ .text = try a.dupe(u8, text), .style = style },
    };
    _ = pane_row.print(&segs, .{ .wrap = .none });
    return row + 1;
}

fn drawWrappedTable(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    rect: LeafRect,
    gutter: u32,
    start_row: u32,
    skip: u32,
    table: markdown.WrappedTableLine,
    num_str: []const u8,
    number_style: vaxis.Style,
    spans: []const syntax.Span,
    current_line: bool,
    search: ?*const @import("../editor/search.zig").Index,
    cursor: ?u32,
) !u32 {
    const chrome_text = try a.dupe(u8, table.chrome);
    const blank = try a.alloc(u8, gutter);
    @memset(blank, ' ');
    const bg: vaxis.Color = .{ .rgb = if (current_line) self.theme.bg_curline else self.theme.bg };
    const limit = rect.row + rect.height;
    var row = start_row;
    for (table.rows[@min(skip, table.rows.len)..], skip..) |parts, ri| {
        if (row >= limit) break;
        if (current_line) fillStripRow(win, row, rect.col, rect.width, bg);
        const number = [_]vaxis.Segment{.{ .text = if (ri == 0) num_str else blank, .style = number_style }};
        _ = win.print(&number, .{ .row_offset = @intCast(row), .col_offset = @intCast(rect.col), .wrap = .none });
        const edge = [_]vaxis.Segment{.{ .text = chrome_text, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } }};
        const text_start = rect.col + gutter;
        _ = win.print(&edge, .{ .row_offset = @intCast(row), .col_offset = @intCast(text_start), .wrap = .none });
        for (parts.items) |part| {
            const editing = part.draft_end != null;
            var col = text_start + part.col;
            for (part.glyphs) |glyph| {
                const span = std.sort.upperBound(syntax.Span, spans, glyph.start, struct {
                    fn order(pos: u32, s: syntax.Span) std.math.Order {
                        return std.math.order(pos, s.end);
                    }
                }.order);
                var style = if (!editing and span < spans.len and spans[span].start <= glyph.start)
                    autil.syntaxStyle(spans[span].style, self.theme)
                else
                    vaxis.Style{ .fg = .{ .rgb = self.theme.fg } };
                style.bg = if (editing) .{ .rgb = self.theme.bg_sel } else bg;
                if (if (editing) null else search) |index| {
                    const hit_i = index.lowerBound(glyph.end);
                    if (hit_i > 0) {
                        const hit = index.starts.items[hit_i - 1];
                        const end = @as(u64, hit) + index.query.?.len;
                        if (glyph.start < end) {
                            const primary = if (cursor) |c| c >= hit and c < end else false;
                            style.bg = .{ .rgb = theme.searchBg(self.theme, if (primary) .current else .match).? };
                        }
                    }
                }
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = try a.dupe(u8, glyph.text), .width = @intCast(glyph.width) },
                    .style = style,
                });
                col += glyph.width;
            }
        }
        row += 1;
    }
    return row;
}

fn drawEditorLineSign(win: vaxis.Window, col: u32, row: u32, glyph: []const u8, fg: ?vaxis.Style, base: vaxis.Style) void {
    if (glyph.len == 1) return;
    var style = base;
    if (fg) |f| style.fg = f.fg;
    win.writeCell(@intCast(col), @intCast(row), .{
        .char = .{ .grapheme = glyph, .width = 1 },
        .style = style,
    });
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
    w.view_top = buf.pt.clampLine(w.view_top);

    // Fold backstop: the cursor must never sit on a hidden line. Every
    // fold-aware motion snaps already; this catches the paths that don't
    // go through them (search jumps, LSP goto, :N, splits' stale cursors).
    w.cursor = foldSnapPos(buf, w.cursor);

    const cursor_line = buf.pt.lineOf(w.cursor);
    // Folded ranges can skip arbitrary distances. In an unfolded pane only
    // the viewport and its next line need to be addressable.
    const line_count = buf.pt.knownLineCount() orelse if (buf.folds.items.len != 0)
        buf.pt.lineCount()
    else
        buf.pt.clampLine(@max(w.view_top, cursor_line) +| rect.height +| 1) + 1;
    // relative-number gutter: computed once per frame per window
    const gutter_layout = gutter_model.forPane(buf.pt.lineCountUpperBound(), rect.width);
    const gutter = gutter_layout.width;
    const gutter_digits = gutter_layout.number_columns;
    // text columns per screen row: soft wrap splits a line every
    // content_width cells (long lines wrap instead of clipping)
    const content_width: u32 = @max(rect.width -| gutter, 1);
    if (rect.height == 0 or rect.width == 0) return;
    const draft = if (is_focused and self.cell_edit != null) self.cell_edit.?.preview() else null;
    const conceal_mode = draft != null or (self.state.mode == .normal and !self.mc_active and !self.em_active);
    const viewport_anchor = if (cursor_line < w.view_top or cursor_line >= w.view_top +| rect.height)
        cursor_line
    else
        w.view_top;
    const layout_top = viewport_anchor -| rect.height;
    const layout_rows = @min(rect.height * 3, line_count -| layout_top);
    const lang = syntax.languageFor(autil.filetypeOf(buf.path));
    const md_layout = if (conceal_mode and std.mem.eql(u8, lang orelse "", "markdown")) blk: {
        if (buf.hl == null or buf.syntax_revision != buf.history.revision)
            _ = try self.visibleSpansFor(buf, a, layout_top, layout_rows);
        const initial_decors = try self.visibleDecorsFor(buf, a, layout_top, layout_rows);
        if (draft != null and buf.hl != null)
            break :blk try @import("highlight.zig").markdownForRange(buf, a, win, initial_decors, layout_top, layout_rows, content_width, draft);
        break :blk try self.visibleMarkdownFor(buf, win, initial_decors, layout_top, layout_rows, content_width);
    } else null;
    if (is_focused and draft == null) {
        self.markdown_frame = md_layout;
        self.markdown_frame_buf = w.buf;
        self.markdown_frame_rev = buf.history.revision;
    }
    try prepareMarkdownImages(self, md_layout);
    const active_md = if (conceal_mode) md_layout else null;

    // keep cursor line visible (per-window viewport). Fold- AND wrap-aware:
    // a closed fold occupies ONE screen row, a long line as many rows as
    // its cells need, so screen distances are counted in display rows.
    // view_top itself must be a visible line — snap it up out of any
    // closed fold it fell into.
    const view_top_before = w.view_top;
    if (foldCovering(buf, w.view_top)) |f| w.view_top = f.start;
    if (cursor_line < w.view_top) {
        w.view_top = cursor_line;
    }
    // the cursor's cell column decides which wrap chunk of its line it
    // sits on — that chunk must be visible, not just the line's first row
    const draft_cursor = blk: {
        if (draft == null) break :blk null;
        const info = (active_md orelse break :blk null).get(cursor_line) orelse break :blk null;
        const table = info.wrapped_table orelse break :blk null;
        break :blk table.draftCursorAt(self.cell_edit.?.cursor);
    };
    const cursor_pos = draft_cursor orelse markdownCursor(active_md, cursor_line, w.cursor) orelse
        lineWrap(self, win, buf, w.buf, cursor_line, content_width, w.cursor).cursor;
    const cur_line_rows = displayRowsWithMarkdown(self, win, buf, w.buf, cursor_line, content_width, active_md, cursor_line);
    const cursor_before_rows = markdownTopRuleRows(active_md, cursor_line);
    const cursor_wrap_row: u32 = cursor_before_rows + cursor_pos.row;
    // Walk back from the destination. Once the screen is full, no earlier
    // line can be visible. A jump to EOF costs at most one viewport of
    // measurements even when the old viewport was millions of lines away.
    var rows_to_cursor = cursor_wrap_row;
    var top = cursor_line;
    while (top > w.view_top and rows_to_cursor < rect.height) {
        const prev = foldPrevLine(buf, top);
        const rows = displayRowsWithMarkdown(self, win, buf, w.buf, prev, content_width, active_md, cursor_line);
        if (rows >= rect.height - rows_to_cursor) break;
        rows_to_cursor += rows;
        top = prev;
    }
    w.view_top = top;
    w.view_wrap = if (w.view_top == cursor_line and cursor_wrap_row >= rect.height)
        cursor_wrap_row - rect.height + 1
    else
        0;
    rows_to_cursor -|= w.view_wrap;
    // The cursor (or a fold snap) forced the view to scroll: an explicit
    // zz/zt/zb pin no longer applies and normal scroll rules resume.
    // Moving the cursor INSIDE the viewport never reaches this — the pin
    // and the "~" filler rows below EOF stay put (vim behavior).
    if (w.view_top != view_top_before) w.view_pinned = false;
    // don't scroll past the end leaving blank rows: pull view_top up
    // while fewer than `height` visible rows remain below it (without
    // pushing the cursor's row off-screen). Skipped while the view is
    // pinned by an explicit zz/zt/zb: those MAY legitimately scroll past
    // EOF, showing "~" filler rows below the last line (vim behavior).
    if (!w.view_pinned) {
        // rows from view_top through the END of the cursor line
        var below: u32 = rows_to_cursor + (cur_line_rows -| cursor_wrap_row);
        // Count the visible rows below the cursor, but only up to the
        // viewport height: the pull-up below only cares whether fewer
        // than `height` rows remain, and the walk to EOF is O(lines)
        // per frame (a 135k-line file would scan to the end on every
        // render). Early-exit keeps this O(height) in the common case.
        var l = cursor_line;
        while (l + 1 < line_count and below < rect.height) {
            l = foldNextLine(buf, l);
            below += displayRowsWithMarkdown(self, win, buf, w.buf, l, content_width, active_md, cursor_line);
        }
        while (below < rect.height and w.view_top > 0) {
            const prev = foldPrevLine(buf, w.view_top);
            const r = displayRowsWithMarkdown(self, win, buf, w.buf, prev, content_width, active_md, cursor_line);
            // pulling `prev` in adds r rows above the cursor — stop before
            // its row would scroll off the bottom
            if (rows_to_cursor + r >= rect.height) break;
            w.view_top = prev;
            w.view_wrap = 0;
            below += r;
            rows_to_cursor += r;
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

    // markdown decorations (M4): conceal ranges, checkbox replacements and
    // heading/fence band props over the same visible range — empty for
    // non-markdown buffers. Conceal gating (anti-conceal): byte-column math
    // (cursor placement, selection, easymotion labels) must never meet a
    // concealed line, so conceal applies only in normal mode with no
    // multi-cursor or easymotion overlay, and never on the window's cursor
    // line (checked per row below). Bands are display-only: always on.
    const decors: []syntax.Decor = try self.visibleDecorsFor(buf, a, w.view_top, span_rows);

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
    // ---- scope range emphasis (issue #14) ----
    // The horizontal rule marks the ACTIVE scope's header line: its source
    // cells from the structural indent to the end of the line's text. It is
    // deliberately not the removed full-row SGR underline — gutter/indent
    // guides, inlay hints, diagnostic virtual text and EOL padding never
    // carry it, and it is clipped to this window. Only the keyboard-active
    // window shows it (focus loss drops it next frame); diagnostics are
    // merged AFTER this style, so their curly/dotted underline wins.
    const scope_rule_on = self.scope_underline and is_focused and self.editorOwnsKeys() and has_scope;

    var span_i: usize = 0;
    var decor_i: usize = 0; // moving pointer into `decors` (rows ascend)
    var row: u32 = rect.row;
    var line = w.view_top;
    // blank-run context cache: consecutive blank rows share the nearest
    // non-blank line's indent levels (see the scan below)
    var prev_blank: ?u32 = null;
    var blank_run_ctx: u32 = 0;
    // Per-row allocations are a per-frame cost, not a per-row one: one
    // gutter-number buffer and one guide-row buffer for the whole window,
    // and ONE segs ArrayList whose capacity is reserved once per frame
    // (clearRetainingCapacity per row). The segments' text slices reference
    // these frame buffers (and the arena), both alive until vx.render().
    // The line text itself is arena-allocated per line: with soft wrap a
    // line can be longer than rect.width, so a fixed width×height grid no
    // longer bounds it.
    const num_buf = try a.alloc(u8, @as(usize, gutter) * rect.height);
    const guide_buf = try a.alloc(u8, rect.width);
    // markdown band fill (heading/fence rows): padding spaces past the
    // line text. NOT guide_buf — blank-line guide segments reference
    // guide_buf and must survive until win.print.
    const pad_buf = try a.alloc(u8, rect.width);
    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.ensureTotalCapacity(a, @as(usize, rect.width) * 2 + 64);
    // one wrapped chunk (screen row) of the line's segments
    var chunk_segs = std.ArrayList(vaxis.Segment).empty;
    try chunk_segs.ensureTotalCapacity(a, 64);
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
        // (row is advanced per WRAPPED CHUNK inside the body, not here)
        line = foldNextLine(buf, line);
    }) {
        const md_info = if (active_md) |md| md.get(line) else null;
        const md_source = if (line != cursor_line) md_info else null;
        const table = if (md_info) |info| info.wrapped_table else null;
        const skip_rows = if (line == w.view_top) w.view_wrap else 0;
        const skip_before = table != null and skip_rows > 0 and md_info.?.top_rule != null;
        if (md_info) |info| {
            const virtual_style: vaxis.Style = .{
                .fg = .{ .rgb = self.theme.fg_dim },
                .bg = .{ .rgb = if (info.fence) self.theme.bg_alt else self.theme.bg },
            };
            if (!skip_before) row = try printMarkdownRule(a, win, rect, row, gutter, info.top_rule, virtual_style);
            if (row >= rect.row + rect.height) break;
        }
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
        if (gutter_digits > 0) {
            // forPane either reserves every digit or hides the field.
            std.debug.assert(num_raw.len <= gutter_digits);
            @memcpy(num_str[gutter_digits - num_raw.len .. gutter_digits], num_raw);
        }

        // LSP diagnostic mark in the gutter's dedicated sign column (this window
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
                var d = diags[diag_i];
                var same = diag_i + 1;
                while (same < diags.len and diags[same].range.start.line == line) : (same += 1) {
                    if (@backingInt(diags[same].severity) < @backingInt(d.severity)) d = diags[same];
                }
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
        // carries no diagnostic mark. The diff describes the VISIBLE
        // buffer text vs HEAD (the worker diffs a snapshot of the buffer,
        // not the disk file) — so marks render while the buffer is dirty
        // too and live-update once an edit quiesces and the async refresh
        // lands. Only when the diff was computed for THIS buffer's path.
        var git_mark: ?git.LineKind = null;
        var git_mark_fg: ?vaxis.Style = null;
        if (w.buf == self.current) {
            if (self.git_diff_path) |dp| {
                if (buf.path) |cp| {
                    if (std.mem.eql(u8, dp, cp)) {
                        if (self.git_diff.untracked) {
                            // untracked file: every line reads as added
                            git_mark = .added;
                            git_mark_fg = .{ .fg = .{ .rgb = self.theme.git_add } };
                        } else {
                            // advance past hunks whose marked region ends
                            // before this row's line (hunks sorted; runs[]
                            // is indexed by absolute line number)
                            while (hunk_i < hunks.len and hunks[hunk_i].end_line <= line) hunk_i += 1;
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

        // Source and rendered tables share the same number and sign gutter.
        const is_cur_line = line == cursor_line;
        const cursorline_style: vaxis.Style = if (is_cur_line)
            .{ .bg = .{ .rgb = self.theme.bg_curline }, .fg = .{ .rgb = self.theme.fg } }
        else
            .{ .bg = .{ .rgb = self.theme.bg_alt }, .fg = .{ .rgb = self.theme.fg_faint } };
        const sign = if (diag_mark.len > 1) diag_mark else if (git_mark) |kind| switch (kind) {
            .added, .modified => "\u{258e}",
            .removed_above => "\u{2581}",
            .removed_below => "\u{2594}",
        } else " ";
        const sign_fg = if (diag_mark.len > 1) diag_mark_fg else git_mark_fg;
        const line_row = row;
        if (table) |wrapped_table| {
            const skip = skip_rows - @intFromBool(skip_before);
            if (is_focused and is_cur_line) self.rendered_cursor_row = row + (cursor_pos.row -| skip);
            const query = self.activeSearchQuery();
            if (query) |q| try buf.search_index.ensure(self.alloc, &buf.pt, buf.history.revision, q);
            row = try drawWrappedTable(self, a, win, rect, gutter, row, skip, wrapped_table, num_str, cursorline_style, merged, is_cur_line, if (query != null) &buf.search_index else null, if (is_focused) w.cursor else null);
            if (skip == 0 and gutter_layout.show_sign)
                drawEditorLineSign(win, rect.col + gutter_layout.sign_column, line_row, sign, sign_fg, cursorline_style);
            const info = md_info.?;
            const virtual_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } };
            row = try printMarkdownRule(a, win, rect, row, gutter, info.bottom_rule, virtual_style);
            row = try drawMarkdownImage(self, a, win, rect, row, gutter, content_width, info);
            continue;
        }

        const line_len = buf.pt.lineTextLen(line);
        const line_start = buf.pt.lineStart(line);
        // Soft wrap: the WHOLE line renders over as many screen rows as
        // its display cells need — no right-edge clipping. Only the bytes
        // that can still fit on the rows remaining below this one are read
        // at all, so a huge (minified) line near the window bottom doesn't
        // cost a full scan (tabs count tab_width cells, like the cursor
        // math — the text segment builder expands them to spaces).
        var n: u32 = line_len;
        {
            const max_cells: u32 = content_width * (rect.row + rect.height - row + (if (line == w.view_top) w.view_wrap else 0));
            var cells: u32 = 0;
            var iter = LineGraphemes{ .pt = &buf.pt, .pos = line_start, .end = line_start + line_len };
            while (iter.next()) |g| {
                cells += if (std.mem.eql(u8, g.bytes, "\t")) tab_width else win.gwidth(g.bytes);
                if (cells >= max_cells) break;
            }
            n = iter.pos - line_start;
        }
        // line text lives in a per-line arena slice (valid until vx.render,
        // like every other segment slice)
        const text = try a.alloc(u8, n);
        buf.pt.copyRange(line_start, text);
        const diagnostic_ranges: []const lsp_diag.ByteRange = if (w.buf == self.current)
            try diagnostic_ui.lineRanges(self, a, line, text)
        else
            &.{};

        // markdown decorations (M4): advance the row pointer and derive
        // this row's band prop (heading/fence). Conceal per row: never on
        // the window's cursor line (anti-conceal — the cursor's byte column
        // must match what is on screen).
        const line_end_byte = line_start + n;
        while (decor_i < decors.len and decors[decor_i].end <= line_start) decor_i += 1;
        var band = if (md_info) |info| info.fence else false;
        {
            var di = decor_i;
            while (di < decors.len and decors[di].start < line_end_byte) : (di += 1) {
                switch (decors[di].kind) {
                    .heading, .fence => band = true,
                    else => {},
                }
            }
        }
        const conceal_on = conceal_mode and line != cursor_line;

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
                    sel_end = buf.pt.lineStart(buf.pt.lineOf(sel_end)) + buf.pt.lineTextLen(buf.pt.lineOf(sel_end));
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
        segs.clearRetainingCapacity();
        const gutter_split = gutter -| 1;
        // Always keep two segments: the wrap loop skips them, including
        // when a one-cell pane has no number/sign gutter at all.
        try segs.append(a, .{ .text = num_str[0..gutter_split], .style = cursorline_style });
        try segs.append(a, .{ .text = num_str[gutter_split..gutter], .style = cursorline_style });
        if (md_source) |info| {
            if (info.prefix.len > 0) try segs.append(a, .{ .text = info.prefix, .style = .{
                .fg = .{ .rgb = self.theme.fg_dim },
                .bg = .{ .rgb = self.theme.bg_alt },
            } });
        }
        var md_gap_i: usize = 0;
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
        if (md_source) |info| {
            if (info.gaps.len > 0 and info.gaps[0].start <= line_start and info.gaps[0].end > line_start) indent_end = 0;
        }
        // expanded column count of the indent region (space = 1 col,
        // tab = tab_width cols) — also needed by the blank-line
        // continuation below, so computed here for both paths
        var indent_cols: u32 = 0;
        var ib: u32 = 0;
        while (ib < indent_end) : (ib += 1) indent_cols += if (text[ib] == '\t') tab_width else 1;
        // Source byte range of the scope-header rule. Starting at the end of
        // the structural indent skips the guide cells; trailing whitespace is
        // not source emphasis, so it is trimmed off the end (never below the
        // first source byte).
        var scope_from: u32 = 0;
        var scope_to: u32 = 0;
        if (scope_rule_on and line == scope_start_line and indent_end < n) {
            scope_from = indent_end;
            var scope_end = n;
            while (scope_end > scope_from and (text[scope_end - 1] == ' ' or text[scope_end - 1] == '\t')) scope_end -= 1;
            scope_to = scope_end;
        }
        {
            const indent_levels: u32 = indent_cols / tab_width;
            var gcol: u32 = 0; // source indentation cells, excluding hints
            ib = 0;
            while (ib <= indent_end) : (ib += 1) {
                // Interleave virtual text with the whitespace at its real
                // byte anchor. A parameter hint at indent_end belongs AFTER
                // the indent, while an anchor inside it splits the guides.
                // The final iteration also handles BOL/empty-line anchors.
                while (hint_i < line_hints.len and line_hints[hint_i].character <= ib) {
                    const hint = line_hints[hint_i];
                    if (hint.label.len > 0) {
                        const hint_sel = ib >= sel_s and ib < sel_e;
                        try segs.append(a, .{
                            .text = hint.label,
                            .style = .{
                                .fg = .{ .rgb = theme.hintFg(self.theme) },
                                .bg = .{ .rgb = if (hint_sel) self.theme.bg_sel else if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                            },
                        });
                    }
                    hint_i += 1;
                }
                if (ib == indent_end) break;
                const cell_w: u32 = if (text[ib] == '\t') tab_width else 1;
                var j: u32 = 0;
                while (j < cell_w) : (j += 1) {
                    const level: u32 = gcol / tab_width;
                    const is_guide = gcol % tab_width == 0 and gcol < indent_levels * tab_width;
                    var gstyle: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
                    if (is_cur_line) gstyle.bg = .{ .rgb = self.theme.bg_curline };
                    if (ib >= sel_s and ib < sel_e) gstyle.bg = .{ .rgb = self.theme.bg_sel };
                    if (lsp_diag.rangeRun(diagnostic_ranges, ib, n).severity) |severity|
                        diagnostic_ui.underline(self, &gstyle, severity);
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
                const context_count = buf.pt.knownLineCount() orelse (buf.pt.clampLine(line +| 500) + 1);
                ctx_levels = self.blankContextLevels(buf, line, context_count);
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
            if (md_source) |info| {
                while (md_gap_i < info.gaps.len and info.gaps[md_gap_i].end <= line_start + col) md_gap_i += 1;
                if (md_gap_i < info.gaps.len) {
                    const gap = info.gaps[md_gap_i];
                    const ds = gap.start -| line_start;
                    const de = @min(gap.end -| line_start, n);
                    if (ds <= col and col < de) {
                        try segs.append(a, .{ .text = gap.text, .style = .{
                            .fg = .{ .rgb = self.theme.fg_dim },
                            .bg = .{ .rgb = if (info.fence) self.theme.bg_alt else self.theme.bg },
                        } });
                        col = de;
                        continue;
                    }
                }
            }
            // markdown conceal/replace (M4): drop decors this row has
            // passed, then act on the one covering col. With conceal off
            // (cursor line, insert/visual mode) the decor is inert and the
            // markup chrome renders as plain text.
            while (decor_i < decors.len) {
                const d = decors[decor_i];
                if (d.end <= line_start + col or (d.kind != .conceal and d.kind != .replace)) {
                    decor_i += 1;
                    continue;
                }
                break;
            }
            if (decor_i < decors.len) {
                const d = decors[decor_i];
                const ds: u32 = if (d.start > line_start) d.start - line_start else 0;
                const de: u32 = @min(d.end -| line_start, n);
                if (conceal_on and ds <= col and col < de) {
                    switch (d.kind) {
                        .conceal => {
                            col = de;
                            continue;
                        },
                        .replace => {
                            try segs.append(a, .{ .text = d.replacement, .style = .{
                                .fg = .{ .rgb = if (d.aux == 1) self.theme.git_add else self.theme.fg_dim },
                                .bg = .{ .rgb = if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                            } });
                            col = de;
                            continue;
                        },
                        else => {},
                    }
                }
            }
            // emit any hint whose insertion column is at/just passed col
            // (before the next text segment, so it reads token+hint)
            while (hint_i < line_hints.len and line_hints[hint_i].character <= col) {
                const hint = line_hints[hint_i];
                if (hint.label.len > 0) {
                    const hint_sel = col >= sel_s and col < sel_e;
                    try segs.append(a, .{
                        .text = hint.label,
                        .style = .{
                            .fg = .{ .rgb = theme.hintFg(self.theme) },
                            .bg = .{ .rgb = if (hint_sel) self.theme.bg_sel else if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                        },
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
                    const sp_start: u32 = if (sp.start > line_start) sp.start - line_start else 0;
                    const sp_end: u32 = if (sp.end < line_start + n) sp.end - line_start else n;
                    // the span's style applies only where the span COVERS
                    // the column — a span starting further right must not
                    // tint the uncovered gap before it (invisible for
                    // dense code captures, glaring for markdown prose)
                    if (sp_start <= col) fg = autil.syntaxStyle(sp.style, self.theme);
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
            // stop at the next decoration boundary so concealed/replaced
            // chrome is never mixed into a text run
            if (decor_i < decors.len and decors[decor_i].start > line_start) {
                const dnext = decors[decor_i].start - line_start;
                if (dnext > col and dnext < next) next = dnext;
            }
            if (md_source) |info| {
                if (md_gap_i < info.gaps.len and info.gaps[md_gap_i].start > line_start) {
                    const gnext = info.gaps[md_gap_i].start - line_start;
                    if (gnext > col and gnext < next) next = gnext;
                }
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
                style.ul = f.ul;
                style.ul_style = f.ul_style;
            }
            // Scope-header range emphasis (issue #14): underline only, so
            // the syntax fg and the selection/cursorline bg survive. The
            // segment is clipped exactly at the source end (no EOL padding),
            // and diagnostics below overwrite this underline when they
            // overlap — they always keep priority.
            if (scope_to > scope_from and col < scope_to) {
                const scope_style = chrome.scopeRangeStyle(self.theme);
                style.ul = scope_style.ul;
                style.ul_style = scope_style.ul_style;
                if (next > scope_to) next = scope_to;
            }
            const diagnostic_run = lsp_diag.rangeRun(diagnostic_ranges, col, n);
            next = @min(next, diagnostic_run.end);
            if (diagnostic_run.severity) |severity| diagnostic_ui.underline(self, &style, severity);
            const seg_text = text[col..next];
            if (std.mem.indexOfScalar(u8, seg_text, '\t') != null) {
                // Expand tabs to `tab_width` spaces so they render (vaxis
                // skips 0-width chars) and their drawn width matches
                // lineCellCol/textWidth — otherwise the cursor column and
                // the visible line disagree on tab-containing files.
                var from: usize = 0;
                for (seg_text, 0..) |b, i| {
                    if (b != '\t') continue;
                    if (i > from) try segs.append(a, .{ .text = seg_text[from..i], .style = style });
                    const spaces = try a.alloc(u8, tab_width);
                    @memset(spaces, ' ');
                    try segs.append(a, .{ .text = spaces, .style = style });
                    from = i + 1;
                }
                if (from < seg_text.len) try segs.append(a, .{ .text = seg_text[from..], .style = style });
            } else {
                try segs.append(a, .{ .text = seg_text, .style = style });
            }
            col = next;
        }
        // trailing hints past the visible text (still inside the line)
        while (hint_i < line_hints.len) {
            const hint = line_hints[hint_i];
            if (hint.label.len > 0) {
                const hint_sel = sel_e > col and sel_s <= col;
                try segs.append(a, .{
                    .text = hint.label,
                    .style = .{
                        .fg = .{ .rgb = theme.hintFg(self.theme) },
                        .bg = .{ .rgb = if (hint_sel) self.theme.bg_sel else if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                    },
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

        // markdown heading/fence band (M4): repaint the row background —
        // text cells and the empty rest of the line alike — with bg_alt.
        // Selection/cursorline keep priority: their segments already carry
        // a non-default bg and stay untouched (and the cursor line itself
        // keeps its plain cursorline look, no band).
        if (band and !is_cur_line) {
            const brgb = self.theme.bg_alt;
            var used: u32 = 0;
            for (segs.items) |*seg| {
                switch (seg.style.bg) {
                    .rgb => |rgb| {
                        if (rgb[0] == self.theme.bg[0] and
                            rgb[1] == self.theme.bg[1] and
                            rgb[2] == self.theme.bg[2])
                        {
                            seg.style.bg = .{ .rgb = brgb };
                        }
                    },
                    else => seg.style.bg = .{ .rgb = brgb },
                }
                used += self.textWidth(win, seg.text);
            }
            if (used < rect.width) {
                const pad = pad_buf[0 .. rect.width - used];
                @memset(pad, ' ');
                try segs.append(a, .{ .text = pad, .style = .{ .bg = .{ .rgb = brgb } } });
            }
        }

        if (self.activeSearchQuery()) |query| {
            try buf.search_index.ensure(self.alloc, &buf.pt, buf.history.revision, query);
            try applySearchHighlight(self, a, &segs, text[0..n], &buf.search_index, line_start, if (is_focused) w.cursor else null);
        }

        // Soft wrap: split the content segments (everything past the two
        // gutter segments) into content_width-cell chunks, one screen row
        // each. The gutter shows the line number on the first chunk row
        // and blanks on continuation rows (vim 'wrap' + 'number').
        if (is_focused and line == cursor_line) {
            self.rendered_cursor_row = line_row + (cursor_wrap_row - cursor_before_rows) -| (if (line == w.view_top) w.view_wrap else 0);
        }
        var seg_i: usize = 2; // skip the two gutter segments
        var seg_off: usize = 0; // grapheme-aligned byte offset into seg.text
        var wrap_row: u32 = 0;
        while (row < rect.row + rect.height) {
            const visible = wrap_row >= skip_rows;
            // Cursor line is a full-width surface: paint the whole content
            // row (gutter + blank after EOL) before text so it never stops at
            // the last glyph. Selection/hint segments repaint over it.
            if (visible and is_cur_line) {
                fillStripRow(win, row, rect.col, rect.width, .{ .rgb = self.theme.bg_curline });
            }
            if (visible and wrap_row == 0) {
                const gseg = [_]vaxis.Segment{.{ .text = num_str, .style = cursorline_style }};
                _ = win.print(&gseg, .{ .row_offset = @intCast(row), .col_offset = @intCast(rect.col), .wrap = .none });
            } else if (visible) {
                const blank = num_buf[(row - rect.row) * gutter ..][0..gutter];
                @memset(blank, ' ');
                const gseg = [_]vaxis.Segment{.{ .text = blank, .style = cursorline_style }};
                _ = win.print(&gseg, .{ .row_offset = @intCast(row), .col_offset = @intCast(rect.col), .wrap = .none });
            }
            chunk_segs.clearRetainingCapacity();
            var used: u32 = 0;
            var consumed = true;
            while (seg_i < segs.items.len) {
                const seg = segs.items[seg_i];
                const rest = seg.text[seg_off..];
                var take: usize = 0;
                var iter = vaxis.unicode.graphemeIterator(rest);
                while (iter.next()) |g| {
                    const gw: u32 = win.gwidth(g.bytes(rest));
                    // a wide grapheme that would straddle the edge goes to
                    // the next row whole — but always take at least one per
                    // row or the loop never advances (narrow pane)
                    if (used + gw > content_width and used > 0) break;
                    used += gw;
                    take = g.start + g.len;
                }
                if (take > 0) try chunk_segs.append(a, .{ .text = rest[0..take], .style = seg.style });
                if (take < rest.len) {
                    // row full: resume this segment on the next row
                    seg_off += take;
                    consumed = false;
                    break;
                }
                seg_i += 1;
                seg_off = 0;
            }
            if (visible and chunk_segs.items.len > 0) {
                _ = win.print(chunk_segs.items, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(rect.col + gutter),
                    .wrap = .none,
                });
            }
            if (visible) row += 1;
            wrap_row += 1;
            if (consumed) {
                // The insertion point after an exactly full line owns an
                // empty continuation row; don't paint the next line there.
                if (line == cursor_line and cursor_pos.row == wrap_row and self.state.mode == .insert and row < rect.row + rect.height) row += 1;
                break;
            }
        }
        if (gutter_layout.show_sign)
            drawEditorLineSign(win, rect.col + gutter_layout.sign_column, line_row, sign, sign_fg, cursorline_style);
        if (md_info) |info| {
            const virtual_style: vaxis.Style = .{
                .fg = .{ .rgb = self.theme.fg_dim },
                .bg = .{ .rgb = if (info.fence) self.theme.bg_alt else self.theme.bg },
            };
            row = try printMarkdownRule(a, win, rect, row, gutter, info.bottom_rule, virtual_style);
            row = try drawMarkdownImage(self, a, win, rect, row, gutter, content_width, info);
        }
    }
    // Rows past the last buffer line: vim's "~" filler (NonText), so an
    // explicit scroll past EOF (a pinned zz/zt/zb view) is legible instead
    // of looking like the file simply ends higher up.
    const tilde = [_]vaxis.Segment{.{ .text = "~", .style = .{
        .fg = .{ .rgb = self.theme.fg_dim },
        .bg = .{ .rgb = self.theme.bg },
    } }};
    while (row < rect.row + rect.height) : (row += 1) {
        _ = win.print(&tilde, .{ .row_offset = @intCast(row), .col_offset = @intCast(rect.col), .wrap = .none });
    }
}

/// One fenced-code line: the fence markers (```lang / ```) render dim;
/// the panel stays a solid bg_float block.
pub fn hoverFenceSegs(self: *App, a: std.mem.Allocator, line: []const u8, cols: u32) ![]vaxis.Segment {
    var segs = std.ArrayList(vaxis.Segment).empty;
    const style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } };
    // Byte length and cell width differ for every non-ASCII glyph; pad by
    // CELLS or the right border of this row lands left of the box corners.
    const shown = buffer.utf8.truncateWidth(line, cols);
    if (shown.len > 0) try segs.append(a, .{ .text = shown, .style = style });
    const used = buffer.utf8.displayWidth(shown);
    if (used < cols) {
        const pad = try a.alloc(u8, @intCast(cols - used));
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
            pos = sp.start;
        }
        const s = @max(sp.start, pos);
        const e = @min(sp.end, line_end);
        if (e > s) {
            var st = autil.syntaxStyle(sp.style, self.theme);
            st.bg = .{ .rgb = self.theme.bg_float };
            try segs.append(a, .{ .text = block[s..e], .style = st });
            pos = e;
        }
        si += 1;
    }
    if (pos < line_end) {
        const tail = block[pos..line_end];
        try segs.append(a, .{ .text = tail, .style = base });
    }
    const used = buffer.utf8.displayWidth(block[line_start..line_end]);
    if (used < cols) {
        const pad = try a.alloc(u8, @intCast(cols - used));
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
    // Truncate by terminal CELLS, not bytes: "→" is 3 bytes but one cell,
    // and a byte-counted prefix/pad shifts the box's right border.
    const shown = buffer.utf8.truncateWidth(line, cols);
    const shown_len = shown.len;
    // heading line: 1-6 '#' followed by a space; the markers are concealed
    // (a markdown render, not source text), so only the title is emitted.
    var heading = false;
    var heading_start: usize = 0;
    if (shown_len >= 2 and line[0] == '#') {
        var h: usize = 0;
        while (h < shown_len and h < 6 and line[h] == '#') h += 1;
        if (h < shown_len and line[h] == ' ') {
            heading = true;
            heading_start = h + 1;
        }
    }
    var used: u32 = 0;
    if (heading) {
        const hstyle: vaxis.Style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
        const title = line[heading_start..shown_len];
        if (title.len > 0) try segs.append(a, .{ .text = title, .style = hstyle });
        used = buffer.utf8.displayWidth(title);
    } else {
        // Inline markdown can start ANYWHERE in the line ("Returns `Foo`"),
        // not just at column 0: scan for the next marker, emit the plain
        // prefix, then consume the marker run. Markers are concealed, so
        // `used` accumulates only the emitted (visible) text.
        var i: usize = 0;
        while (i < shown_len) {
            var next = shown_len;
            var marker: u8 = 0; // 1 code, 2 bold, 3 italic, 4 url
            var k = i;
            while (k < shown_len) : (k += 1) {
                if (line[k] == '`') {
                    next = k;
                    marker = 1;
                    break;
                }
                if (line[k] == '*') {
                    next = k;
                    marker = if (k + 1 < shown_len and line[k + 1] == '*') 2 else 3;
                    break;
                }
                if (line[k] == 'h' and k + 4 <= shown_len and std.mem.eql(u8, line[k .. k + 4], "http")) {
                    next = k;
                    marker = 4;
                    break;
                }
            }
            if (next > i) {
                const plain = line[i..next];
                try segs.append(a, .{ .text = plain, .style = base });
                used += buffer.utf8.displayWidth(plain);
            }
            if (marker == 0) break; // no marker: the rest is plain text

            var style = base;
            var start = next;
            var content_end = shown_len;
            var after = shown_len;
            switch (marker) {
                1 => {
                    // inline code: up to the next backtick
                    style = .{ .fg = .{ .rgb = self.theme.string }, .bg = .{ .rgb = self.theme.bg_float } };
                    start = next + 1;
                    if (std.mem.indexOfScalar(u8, line[start..shown_len], '`')) |ci| {
                        content_end = start + ci;
                        after = content_end + 1;
                    }
                },
                2 => {
                    style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
                    start = next + 2;
                    if (std.mem.indexOf(u8, line[start..shown_len], "**")) |ci| {
                        content_end = start + ci;
                        after = content_end + 2;
                    }
                },
                3 => {
                    style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float }, .italic = true };
                    start = next + 1;
                    if (std.mem.indexOfScalar(u8, line[start..shown_len], '*')) |ci| {
                        content_end = start + ci;
                        after = content_end + 1;
                    }
                },
                4 => {
                    // bare URL: to the next whitespace / punctuation
                    style = .{ .fg = .{ .rgb = self.theme.function }, .bg = .{ .rgb = self.theme.bg_float } };
                    start = next;
                    var ue = next;
                    while (ue < shown_len and line[ue] != ' ' and line[ue] != '\t' and
                        line[ue] != ',' and line[ue] != ')' and line[ue] != ']') ue += 1;
                    content_end = ue;
                    after = ue;
                },
                else => {},
            }
            if (content_end > start) {
                const text = line[start..content_end];
                try segs.append(a, .{ .text = text, .style = style });
                used += buffer.utf8.displayWidth(text);
            }
            if (after <= next) after = next + 1; // never stall on a stray marker
            i = after;
        }
    }
    if (used < cols) {
        const pad = try a.alloc(u8, @intCast(cols - used));
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = base });
    }
    return segs.items;
}
/// Render the left navigator. Two layouts:
///   * >= 90 cols — a 30-cell auxiliary column with a single mode strip
///     and shared right divider, followed by the active tab's real content.
///   * < 90 cols  — a 7-cell icon rail (`OZ`, folder/notes/agents). Selecting
///     an icon opens the same 30-cell panel as a peek overlay over the
///     editor; Esc/outside-click closes it. The editor keeps its full width
///     underneath in both compact states.
/// Files keeps the tree's exact rendering/keys; Notes and Agents render from
/// the cached note list and the real thread model. Counts come from those
/// existing caches — never from a per-frame filesystem scan.
pub fn renderNavigator(self: *App, a: std.mem.Allocator, win: vaxis.Window, height: u32) !void {
    if (height <= status_row_count) return;
    const mode = self.navigatorMode();
    if (mode == .compact) {
        // Keyboard focus leaving the navigator closes the peek, so a user
        // can never type into the editor under an open overlay.
        if (self.focus != .navigator) self.navigator_peek = false;
        if (self.navigator_peek) {
            try renderNavigatorPanel(self, a, win, height, true);
        } else {
            try renderCompactRail(self, a, win, height);
        }
    } else {
        self.navigator_peek = false;
        try renderNavigatorPanel(self, a, win, height, false);
    }
}

/// One compact mode strip and a shared right divider. The navigator owns
/// its body but has no nested frame, brand row or repeated workspace row.
fn renderNavigatorPanel(self: *App, a: std.mem.Allocator, win: vaxis.Window, height: u32, peek: bool) !void {
    const width = @min(nav_tabs.panel_width, win.width);
    const bottom = height -| status_row_count;
    const top = self.contentTop(a);
    const body_top = top + nav_tabs.full_header_rows;
    if (width < nav_tabs.panel_width or bottom <= body_top) return;
    const bg: vaxis.Color = .{ .rgb = self.theme.bg };
    const panel = win.child(.{ .x_off = 0, .y_off = @intCast(top), .width = @intCast(width), .height = @intCast(bottom - top) });
    panel.fill(.{ .style = .{ .bg = bg } });
    const rule = chrome.separatorStyle(self.theme, .minor, bg);
    for (top..bottom) |r| win.writeCell(@intCast(width - 1), @intCast(r), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = rule });
    try renderNavigatorTabs(self, a, win, top);
    if (peek) {
        win.writeCell(@intCast(width - 1), @intCast(top), .{ .char = .{ .grapheme = "×", .width = 1 }, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } });
        if (self.mouseTargetsCollecting()) self.addHintTarget(.{ .row = top, .col = width - 1, .width = 1, .height = 1 }, .navigator_peek_close);
    }
    self.addMouseScrollTarget(body_top, 0, width, bottom - body_top, switch (self.navigator_tab) {
        .files => .navigator_files,
        .notes => .navigator_notes,
        .agents => .navigator_agents,
    });
    switch (self.navigator_tab) {
        .files => try renderFiletreeRows(self, a, win, body_top, bottom, width - 2),
        .notes => try renderNotesRows(self, a, win, body_top, bottom, width - 2),
        .agents => try renderAgentsRows(self, a, win, body_top, bottom, width - 2),
    }
}

/// Compact icon rail (cols < 90): `OZ` + one two-row button per tab, with a
/// right border and no content. The 30-cell peek drawer is the content view.
fn renderCompactRail(self: *App, a: std.mem.Allocator, win: vaxis.Window, height: u32) !void {
    const rail_w: u32 = nav_tabs.compact_width;
    const content_w = rail_w - 1;
    const top = self.contentTop(a);
    const bottom = height -| status_row_count;
    if (bottom <= top or content_w == 0) return;

    const panel_bg: vaxis.Color = .{ .rgb = self.theme.bg };
    const nav_focused = self.focus == .navigator and self.ai.focus == .editor;
    const border_style = chrome.panelBorderStyle(self.theme, nav_focused, panel_bg);
    const brand_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = panel_bg, .bold = true };
    const rule_style = chrome.separatorStyle(self.theme, .minor, panel_bg);

    const panel = win.child(.{
        .x_off = 0,
        .y_off = @intCast(top),
        .width = @intCast(rail_w),
        .height = @intCast(bottom - top),
    });
    panel.fill(.{ .style = .{ .bg = panel_bg } });

    // Right border (the demo's compact rail has no left border; the editor
    // starts after a one-cell gutter at `compact_width + 1`).
    {
        var r: u32 = top;
        while (r < bottom) : (r += 1) {
            const seg = [_]vaxis.Segment{.{ .text = "│", .style = border_style }};
            _ = win.print(&seg, .{ .row_offset = @intCast(r), .col_offset = @intCast(rail_w - 1), .wrap = .none });
        }
    }

    // OZ mark, centered in the six content cells.
    {
        const oz = [_]vaxis.Segment{
            .{ .text = "  ", .style = .{ .bg = panel_bg } },
            .{ .text = "OZ", .style = brand_style },
            .{ .text = "  ", .style = .{ .bg = panel_bg } },
        };
        _ = win.print(&oz, .{ .row_offset = @intCast(top), .col_offset = 0, .wrap = .none });
    }

    // Hairline under the brand head.
    if (top + 1 < bottom) {
        var cx: u32 = 0;
        while (cx < content_w) : (cx += 1) {
            const seg = [_]vaxis.Segment{.{ .text = "─", .style = rule_style }};
            _ = win.print(&seg, .{ .row_offset = @intCast(top + 1), .col_offset = @intCast(cx), .wrap = .none });
        }
    }

    // One two-row button per tab, icon only:  OZ / rule / [icon][icon][icon].
    const active_bg: vaxis.Color = .{ .rgb = self.theme.bg_sel };
    var i: usize = 0;
    while (i < nav_tabs.count) : (i += 1) {
        const tab = nav_tabs.all[i];
        const row = top + nav_tabs.compact_first_tab_row + @as(u32, @intCast(i)) * nav_tabs.compact_tab_rows;
        if (row + 1 >= bottom) break;
        const active = self.navigator_tab == tab;
        const bg: vaxis.Color = if (active) active_bg else panel_bg;
        const icon = icons.tabIcon(tab);
        const icon_style: vaxis.Style = if (active)
            .{ .fg = .{ .rgb = self.theme.accent_alt }, .bg = bg, .bold = true }
        else
            .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg };

        // Both rows of the button share the selection background.
        const blank = "      "; // compact content width, no per-frame alloc
        var rr: u32 = 0;
        while (rr < nav_tabs.compact_tab_rows) : (rr += 1) {
            const segs = [_]vaxis.Segment{.{ .text = blank[0..content_w], .style = .{ .bg = bg } }};
            _ = win.print(&segs, .{ .row_offset = @intCast(row + rr), .col_offset = 0, .wrap = .none });
        }
        if (active) {
            // Accent inset bar, the terminal equivalent of the demo's 2px
            // active rail marker; drawn on both rows.
            var bar_r: u32 = 0;
            while (bar_r < nav_tabs.compact_tab_rows) : (bar_r += 1) {
                const bar = [_]vaxis.Segment{.{ .text = "│", .style = .{
                    .fg = .{ .rgb = self.theme.accent_alt },
                    .bg = bg,
                    .bold = true,
                } }};
                _ = win.print(&bar, .{ .row_offset = @intCast(row + bar_r), .col_offset = 0, .wrap = .none });
            }
        }
        // Icon centered horizontally in the six content cells.
        const icon_col: u32 = 2;
        const icon_seg = [_]vaxis.Segment{.{ .text = icon.glyph, .style = icon_style }};
        _ = win.print(&icon_seg, .{ .row_offset = @intCast(row), .col_offset = icon_col, .wrap = .none });

        if (self.mouseTargetsCollecting()) {
            self.addHintTarget(.{
                .row = row,
                .col = 0,
                .width = content_w,
                .height = nav_tabs.compact_tab_rows,
            }, .{ .navigator_tab = tab });
        }
    }
}

/// Full-mode tab strip: folder/notes/agents icons, labels and compact real
/// count badges. `layoutTabs` fits the strip into the 28 inner cells and
/// drops badges (never labels) if a huge count cannot fit; the same layout
/// drives the hint/mouse rectangles.
fn renderNavigatorTabs(self: *App, a: std.mem.Allocator, win: vaxis.Window, row: u32) !void {
    const inner: u16 = nav_tabs.panel_width - 2;
    const counts: nav_tabs.Counts = .{
        self.filetree_rows.items.len,
        if (self.notes.loaded and self.notes.err == null) self.notes.items.items.len else null,
        self.ai.threads.items.items.len,
    };
    const layout = nav_tabs.layoutTabs(counts, inner);
    const active_label = chrome.activeTabStyle(self.theme);
    const active_icon = chrome.activeTabMarkerStyle(self.theme);
    const active_count: vaxis.Style = .{
        .fg = .{ .rgb = self.theme.accent_alt },
        .bg = .{ .rgb = self.theme.bg_sel },
        .bold = true,
        .ul = .{ .rgb = self.theme.accent_alt },
        .ul_style = .single,
    };
    const inactive_icon: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } };
    const inactive_label = chrome.inactiveTabStyle(self.theme, .{ .rgb = self.theme.bg });
    const inactive_count: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg } };
    const gap_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
    const sep_style = chrome.separatorStyle(self.theme, .minor, .{ .rgb = self.theme.bg });
    const border_style = chrome.separatorStyle(self.theme, .minor, .{ .rgb = self.theme.bg });

    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.append(a, .{ .text = " ", .style = gap_style });

    var used: u16 = 0;
    var ti: usize = 0;
    while (ti < nav_tabs.count) : (ti += 1) {
        const tab = nav_tabs.all[ti];
        const start = layout.starts[ti];
        // The fitter leaves one cell between tabs whenever possible; draw
        // it as the demo's dim accent separator. A zero-gap fallback (only
        // when even compact badges overflow) has no separator cell.
        if (ti > 0 and used < start) {
            try segs.append(a, .{ .text = " ", .style = sep_style });
            used += 1;
        }
        while (used < start) : (used += 1) {
            try segs.append(a, .{ .text = " ", .style = gap_style });
        }
        const active = self.navigator_tab == tab;
        const icon = icons.tabIcon(tab);
        const icon_style: vaxis.Style = if (active) active_icon else inactive_icon;
        const label_style: vaxis.Style = if (active) active_label else inactive_label;
        try segs.append(a, .{ .text = icon.glyph, .style = icon_style });
        try segs.append(a, .{ .text = " ", .style = .{ .bg = icon_style.bg } });
        try segs.append(a, .{ .text = nav_tabs.label(tab), .style = label_style });
        if (layout.has_count[ti]) {
            if (counts[ti]) |n| {
                // Frame-arena text: vaxis holds the slice until render.
                const text = std.fmt.allocPrint(a, "{d}", .{n}) catch "";
                try segs.append(a, .{ .text = text, .style = if (active) active_count else inactive_count });
            }
        }
        used = start + layout.widths[ti];
    }
    while (used < inner) : (used += 1) {
        try segs.append(a, .{ .text = " ", .style = gap_style });
    }
    try segs.append(a, .{ .text = "│", .style = border_style });
    _ = win.print(segs.items, .{ .row_offset = @intCast(row), .col_offset = 0, .wrap = .none });

    if (self.mouseTargetsCollecting()) {
        ti = 0;
        while (ti < nav_tabs.count) : (ti += 1) {
            self.addHintTarget(.{
                .row = row,
                .col = 1 + layout.starts[ti],
                .width = layout.widths[ti],
                .height = 1,
            }, .{ .navigator_tab = nav_tabs.all[ti] });
        }
    }
}

/// Files rows share one immutable repository snapshot until the next refresh.
fn renderFiletreeRows(self: *App, a: std.mem.Allocator, win: vaxis.Window, body_top: u32, body_bottom: u32, usable: u32) !void {
    const ft_col: u32 = 0;
    const inner_left = ft_col + 1;
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
    const ft_vis = @min(ft_len, @as(usize, body_bottom -| body_top));
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
        // nvim/snacks-explorer geometry: one cell of padding inside the
        // border, then per-level guides ("│ " or "  "), then the branch
        // ("├╴"/"└╴"), then icon + space + name. The terminal cursor sits
        // on the padding cell (col 1), not on the icon, so the block cursor
        // no longer touches the glyph.
        const icon = if (node.is_dir) icons.folder(node.expanded) else icons.forPath(node.path, false);

        // ancestors, top-down. frow.depth is the number of visible
        // ancestors (the root itself is not a row).
        var anc_stack: [256]@TypeOf(node) = undefined;
        const badge = self.navigator_git.get(self.filetree_root.?.path, node.path);
        const badge_width: u32 = if (badge != null) 3 else 0; // gap + XY
        // Clip deep tree guides first so the branch, icon and badge fit.
        const an = @min(frow.depth, anc_stack.len, (usable -| badge_width -| 6) / 2);
        var p = node.parent;
        var ai: usize = 0;
        while (ai < an) : (ai += 1) {
            anc_stack[an - 1 - ai] = p.?;
            p = p.?.parent;
        }

        const last_sibling = blk: {
            const par = node.parent orelse break :blk true;
            if (par.children.items.len == 0) break :blk true;
            break :blk par.children.items[par.children.items.len - 1] == node;
        };

        var line = std.ArrayList(u8).empty;
        try line.append(a, ' '); // leading padding (cursor cell)
        for (anc_stack[0..an]) |anc| {
            const anc_last = blk: {
                const par = anc.parent orelse break :blk true;
                if (par.children.items.len == 0) break :blk true;
                break :blk par.children.items[par.children.items.len - 1] == anc;
            };
            try line.appendSlice(a, if (anc_last) "  " else "│ ");
        }
        try line.appendSlice(a, if (last_sibling) "└╴" else "├╴");
        const prefix_cells: u32 = 1 + 2 * @as(u32, @intCast(an)) + 2;

        const icon_cells = win.gwidth(icon.glyph);
        const avail = usable -| badge_width -| prefix_cells -| icon_cells -| 1;
        var fit = autil.cellFitPrefix(win, node.name, avail);
        const ellipsized = fit.slice.len < node.name.len and avail >= win.gwidth("…");
        if (ellipsized) fit = autil.cellFitPrefix(win, node.name, avail - win.gwidth("…"));
        const name_cells = fit.cells + (if (ellipsized) win.gwidth("…") else 0);
        const content_cells = prefix_cells + icon_cells + @as(u32, @intCast(if (name_cells > 0) name_cells + 1 else 0));

        const style: vaxis.Style = if (ri == self.filetree_sel)
            .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } }
        else
            .{ .bg = .{ .rgb = self.theme.bg }, .fg = .{ .rgb = self.theme.fg } };

        const badge_rgb = if (badge) |b| switch (b.color) {
            .modified => self.theme.git_mod,
            .added => self.theme.git_add,
            .deleted => self.theme.git_del,
            .renamed => self.theme.accent_alt,
            .conflict => self.theme.diag_error,
            .directory => self.theme.fg_dim,
        } else self.theme.fg;
        var name_style = style;
        if (badge != null) name_style.fg = .{ .rgb = theme.blend(self.theme.fg, badge_rgb, 40) };
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = line.items, .style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = style.bg } });
        try segs.append(a, .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = style.bg } });
        if (name_cells > 0) {
            try segs.append(a, .{ .text = " ", .style = style });
            try segs.append(a, .{ .text = fit.slice, .style = name_style });
            if (ellipsized) try segs.append(a, .{ .text = "…", .style = style });
        }
        const pads = try a.alloc(u8, usable -| content_cells -| (if (badge != null) @as(u32, 2) else 0));
        @memset(pads, ' ');
        if (pads.len > 0) try segs.append(a, .{ .text = pads, .style = style });
        if (badge) |b| {
            try segs.append(a, .{ .text = try a.dupe(u8, &b.text), .style = .{ .fg = .{ .rgb = badge_rgb }, .bg = style.bg, .bold = true } });
        }
        _ = win.print(segs.items, .{ .row_offset = @intCast(body_top + @as(u32, @intCast(k))), .col_offset = @intCast(inner_left), .wrap = .none });
        if (self.mouseTargetsCollecting()) {
            // Inner row rect (starts after the left border so a label never
            // breaks the panel frame). Payload is the absolute row index in
            // filetree_rows, not the visible slot.
            self.addHintTarget(.{
                .row = body_top + @as(u32, @intCast(k)),
                .col = inner_left,
                .width = usable,
                .height = 1,
            }, .{ .filetree_activate = ri });
        }
    }
}

/// Notes tab: two rows per note (title + right-aligned age, then
/// filename · snippet). The list is the cached `Store`, refreshed by the
/// action paths, never by this renderer; rows scroll in note units.
fn renderNotesRows(self: *App, a: std.mem.Allocator, win: vaxis.Window, body_top: u32, body_bottom: u32, usable: u32) !void {
    const inner_left: u32 = 1;
    const content_top = body_top;
    const content_rows: usize = @intCast(body_bottom -| body_top);
    const base_bg: vaxis.Color = .{ .rgb = self.theme.bg };

    if (self.notes.err) |msg| {
        const err_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.diag_error }, .bg = base_bg };
        const head = [_]vaxis.Segment{.{ .text = " ! notes unavailable", .style = err_style }};
        _ = win.print(&head, .{ .row_offset = @intCast(content_top), .col_offset = @intCast(inner_left), .wrap = .none });
        if (content_rows >= 2) {
            const line = try std.fmt.allocPrint(a, " {s}", .{msg});
            const shown = buffer.utf8.truncateWidth(line, usable);
            const seg = [_]vaxis.Segment{.{ .text = shown, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg } }};
            _ = win.print(&seg, .{ .row_offset = @intCast(content_top + 1), .col_offset = @intCast(inner_left), .wrap = .none });
        }
        return;
    }
    if (self.notes.items.items.len == 0) {
        const seg = [_]vaxis.Segment{.{ .text = " no notes yet", .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg } }};
        _ = win.print(&seg, .{ .row_offset = @intCast(content_top), .col_offset = @intCast(inner_left), .wrap = .none });
        if (content_rows >= 2) {
            const seg2 = [_]vaxis.Segment{.{ .text = " n creates a note", .style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = base_bg } }};
            _ = win.print(&seg2, .{ .row_offset = @intCast(content_top + 1), .col_offset = @intCast(inner_left), .wrap = .none });
        }
        return;
    }

    const n = self.notes.items.items.len;
    if (self.notes.sel >= n) self.notes.sel = n - 1;
    const vis = @max(@as(usize, 1), content_rows / 2);
    if (n > vis) {
        if (self.notes.top + vis > n) self.notes.top = n - vis;
        if (self.notes.sel < self.notes.top) self.notes.top = self.notes.sel;
        if (self.notes.sel >= self.notes.top + vis) self.notes.top = self.notes.sel - vis + 1;
    } else self.notes.top = 0;

    const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
    var k: usize = 0;
    while (k < vis) : (k += 1) {
        const idx = self.notes.top + k;
        if (idx >= n) break;
        const row1 = content_top + 2 * @as(u32, @intCast(k));
        if (row1 >= body_bottom) break;
        const note = &self.notes.items.items[idx];
        const selected = idx == self.notes.sel;
        const bg: vaxis.Color = if (selected) .{ .rgb = self.theme.bg_sel } else base_bg;
        const base_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = bg };

        var age_buf: [16]u8 = undefined;
        const age_raw = note_store.formatAge(now, note.mtime_ns, &age_buf);
        const age = try a.dupe(u8, age_raw);
        const age_cells: u32 = @intCast(buffer.utf8.displayWidth(age));
        var title_budget: u32 = usable -| 2; // marker + space
        var show_age = false;
        if (age_cells + 1 < title_budget) {
            title_budget -= age_cells + 1;
            show_age = true;
        }
        const title = buffer.utf8.truncateWidth(note.title, title_budget);
        const title_cells: u32 = @intCast(buffer.utf8.displayWidth(title));

        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{
            .text = if (selected) "> " else "  ",
            .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = bg },
        });
        try segs.append(a, .{ .text = title, .style = base_style });
        var filled: u32 = 2 + title_cells;
        if (show_age) {
            const pad = usable -| filled -| age_cells;
            if (pad > 0) {
                const spaces = try a.alloc(u8, pad);
                @memset(spaces, ' ');
                try segs.append(a, .{ .text = spaces, .style = base_style });
                filled += pad;
            }
            try segs.append(a, .{ .text = age, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } });
            filled += age_cells;
        }
        if (filled < usable) {
            const spaces = try a.alloc(u8, usable - filled);
            @memset(spaces, ' ');
            try segs.append(a, .{ .text = spaces, .style = base_style });
        }
        _ = win.print(segs.items, .{ .row_offset = @intCast(row1), .col_offset = @intCast(inner_left), .wrap = .none });
        if (self.mouseTargetsCollecting()) {
            self.addHintTarget(.{
                .row = row1,
                .col = inner_left,
                .width = usable,
                .height = 1,
            }, .{ .note_open = idx });
        }

        if (row1 + 1 < body_bottom) {
            const row2 = row1 + 1;
            var line = std.ArrayList(u8).empty;
            try line.appendSlice(a, "  ");
            try line.appendSlice(a, note.filename);
            if (note.snippet.len > 0) {
                try line.appendSlice(a, " · ");
                try line.appendSlice(a, note.snippet);
            }
            const shown = buffer.utf8.truncateWidth(line.items, usable);
            const shown_cells: u32 = @intCast(buffer.utf8.displayWidth(shown));
            var segs2 = std.ArrayList(vaxis.Segment).empty;
            try segs2.append(a, .{ .text = shown, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } });
            if (shown_cells < usable) {
                const spaces = try a.alloc(u8, usable - shown_cells);
                @memset(spaces, ' ');
                try segs2.append(a, .{ .text = spaces, .style = .{ .bg = bg } });
            }
            _ = win.print(segs2.items, .{ .row_offset = @intCast(row2), .col_offset = @intCast(inner_left), .wrap = .none });
        }
    }
}

/// Agents tab: one workspace group header (current workspace + provider
/// model), then the session's REAL threads with an ASCII status marker, name
/// and status label. The attached thread carries `>` + bold; the selected
/// row keeps the fill. Enter = the same `aiSelectThread` attach path as the
/// rail; `n` = `aiNewThread`. No synthetic rows, no second thread model.
fn renderAgentsRows(self: *App, a: std.mem.Allocator, win: vaxis.Window, body_top: u32, body_bottom: u32, usable: u32) !void {
    const inner_left: u32 = 1;
    const content_top = body_top;
    const content_rows: usize = @intCast(body_bottom -| body_top);
    const base_bg: vaxis.Color = .{ .rgb = self.theme.bg };

    var header = std.ArrayList(u8).empty;
    try header.appendSlice(a, " ");
    try header.appendSlice(a, self.curWsName());
    if (self.ai.config) |cfg| {
        try header.appendSlice(a, " · ");
        try header.appendSlice(a, cfg.model);
    }
    const head_shown = buffer.utf8.truncateWidth(header.items, usable);
    const head_seg = [_]vaxis.Segment{.{ .text = head_shown, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg } }};
    _ = win.print(&head_seg, .{ .row_offset = @intCast(content_top), .col_offset = @intCast(inner_left), .wrap = .none });

    const list_top = content_top + 1;
    const avail = content_rows -| 1;
    if (avail == 0) return;
    const n = self.ai.threads.items.items.len;
    if (n == 0) {
        const seg = [_]vaxis.Segment{.{ .text = " no threads yet", .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg } }};
        _ = win.print(&seg, .{ .row_offset = @intCast(list_top), .col_offset = @intCast(inner_left), .wrap = .none });
        return;
    }
    if (self.ai.thread_cursor >= n) self.ai.thread_cursor = n - 1;
    if (n > avail) {
        if (self.ai.thread_top + avail > n) self.ai.thread_top = n - avail;
        if (self.ai.thread_cursor < self.ai.thread_top) self.ai.thread_top = self.ai.thread_cursor;
        if (self.ai.thread_cursor >= self.ai.thread_top + avail) {
            self.ai.thread_top = self.ai.thread_cursor - avail + 1;
        }
    } else self.ai.thread_top = 0;

    const now_ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
    var k: usize = 0;
    while (k < avail) : (k += 1) {
        const idx = self.ai.thread_top + k;
        if (idx >= n) break;
        const thread = &self.ai.threads.items.items[idx];
        const row = list_top + @as(u32, @intCast(k));
        const selected = idx == self.ai.thread_cursor;
        const bg: vaxis.Color = if (selected) .{ .rgb = self.theme.bg_sel } else base_bg;
        const label = try @import("ai.zig").threadListStatus(self, a, idx, now_ns);
        const label_cells: u32 = @intCast(buffer.utf8.displayWidth(label));
        var title_budget: u32 = usable -| 2; // dot + space
        var show_status = false;
        if (label_cells + 1 < title_budget) {
            title_budget -= label_cells + 1;
            show_status = true;
        }
        const title = buffer.utf8.truncateWidth(try @import("ai.zig").threadListTitle(self, a, idx), title_budget);
        const title_cells: u32 = @intCast(buffer.utf8.displayWidth(title));
        const dot_color = switch (thread.status) {
            .idle => self.theme.fg_faint,
            .streaming => self.theme.accent,
            .cancelled => self.theme.fg_dim,
            .err => self.theme.diag_error,
        };
        const attached = idx == self.ai.threads.active;
        var segs = std.ArrayList(vaxis.Segment).empty;
        // ASCII marker (`>` attached, `o` otherwise): no tofu-prone glyph,
        // and the attached row stays distinct in monochrome via bold.
        try segs.append(a, .{
            .text = if (attached) ">" else "o",
            .style = .{
                .fg = .{ .rgb = if (attached) self.theme.accent else dot_color },
                .bg = bg,
                .bold = attached,
            },
        });
        try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
        try segs.append(a, .{
            .text = title,
            .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = bg, .bold = attached },
        });
        var filled: u32 = 2 + title_cells;
        if (show_status) {
            const pad = usable -| filled -| label_cells;
            if (pad > 0) {
                const spaces = try a.alloc(u8, pad);
                @memset(spaces, ' ');
                try segs.append(a, .{ .text = spaces, .style = .{ .bg = bg } });
                filled += pad;
            }
            try segs.append(a, .{ .text = label, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } });
            filled += label_cells;
        }
        if (filled < usable) {
            const spaces = try a.alloc(u8, usable - filled);
            @memset(spaces, ' ');
            try segs.append(a, .{ .text = spaces, .style = .{ .bg = bg } });
        }
        _ = win.print(segs.items, .{ .row_offset = @intCast(row), .col_offset = @intCast(inner_left), .wrap = .none });
        if (self.mouseTargetsCollecting()) {
            self.addHintTarget(.{
                .row = row,
                .col = inner_left,
                .width = usable,
                .height = 1,
            }, .{ .agent_thread_select = idx });
        }
    }
}

/// Automatic signatureHelp contains a literal label. Bound it to six lines
/// and let the same pane layout as K decide which side of the caret fits.
fn drawSignature(self: *App, win: vaxis.Window, text: []const u8, pane: completion_layout.Rect, cursor_row: u32, anchor_col: u32) void {
    var rows: [6][]const u8 = undefined;
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (n < rows.len) : (n += 1) rows[n] = lines.next() orelse break;
    const layout = hover_layout.plan(pane, cursor_row, anchor_col, n, 60);
    if (layout.visible_rows == 0) return;
    const rect = layout.rect;
    const bg: vaxis.Color = .{ .rgb = self.theme.bg_float };
    const inner = win.child(.{
        .x_off = @intCast(rect.col),
        .y_off = @intCast(rect.row),
        .width = @intCast(rect.width),
        .height = @intCast(rect.height),
        .border = .{ .where = .all, .style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = bg } },
    });
    inner.fill(.{ .style = .{ .bg = bg } });
    for (rows[0..layout.visible_rows], 0..) |line, row| {
        const fit = autil.cellFitPrefix(inner, line, inner.width);
        const segs = [_]vaxis.Segment{.{ .text = fit.slice, .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = bg } }};
        _ = inner.print(&segs, .{ .row_offset = @intCast(row), .wrap = .none });
    }
}

/// Natural width is capped by the pane, but short hover payloads do not
/// become a mostly empty 80-column panel. Measure rendered link labels and
/// hide fence markers before spending columns on their transport syntax.
fn hoverDocumentColumns(self: *App, a: std.mem.Allocator, win: vaxis.Window, text: []const u8, pane: completion_layout.Rect) !u32 {
    var natural: u32 = 0;
    var lines = std.mem.splitScalar(u8, hover_layout.bytePrefix(text, 256 * 1024), '\n');
    var fenced = false;
    while (lines.next()) |line| {
        if (self.nav_hover_markdown and autil.isFenceLine(line) != null) {
            fenced = !fenced;
            continue;
        }
        const shown = if (self.nav_hover_markdown and !fenced) try hover_layout.readableLinks(a, line) else line;
        natural = @max(natural, @as(u32, @intCast(autil.cellWidth(win, shown))));
        if (natural >= 80) break;
    }
    return hover_layout.columns(pane, natural);
}

fn drawHoverDocument(self: *App, a: std.mem.Allocator, win: vaxis.Window, text: []u8, pane: completion_layout.Rect, cursor_row: u32, cursor_col: u32) !void {
    self.nav_hover_visible_rows = 0;
    self.nav_hover_scroll_max = 0;
    const cols = try hoverDocumentColumns(self, a, win, text, pane);
    if (cols == 0) return;
    // Borrowed adapter: no deinit, because nav_hover_text owns the payload.
    const item = lsp_nav.CompletionItem{ .label = @constCast(""), .doc = text, .doc_kind = if (self.nav_hover_markdown) .markdown else .plaintext };
    const rows = try buildRichDocRows(self, a, win, &item, cols, .{ .max_rows = 2048, .max_bytes = 256 * 1024 });
    const layout = hover_layout.plan(pane, cursor_row, cursor_col, @intCast(rows.len), cols);
    self.nav_hover_visible_rows = layout.visible_rows;
    self.nav_hover_scroll_max = layout.scroll_max;
    self.nav_hover_scroll = @min(self.nav_hover_scroll, layout.scroll_max);
    if (layout.visible_rows == 0) return;
    const rect = layout.rect;
    const outer = win.child(.{ .x_off = @intCast(rect.col), .y_off = @intCast(rect.row), .width = @intCast(rect.width), .height = @intCast(rect.height) });
    const style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
    outer.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg_float } } });
    for (0..rect.width) |c| {
        outer.writeCell(@intCast(c), 0, .{ .char = .{ .grapheme = if (c == 0) "╭" else if (c + 1 == rect.width) "╮" else "─", .width = 1 }, .style = style });
        outer.writeCell(@intCast(c), @intCast(rect.height - 1), .{ .char = .{ .grapheme = if (c == 0) "╰" else if (c + 1 == rect.width) "╯" else "─", .width = 1 }, .style = style });
    }
    for (0..layout.visible_rows) |row| {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "│", .style = style });
        try segs.appendSlice(a, rows[self.nav_hover_scroll + row]);
        try segs.append(a, .{ .text = "│", .style = style });
        _ = outer.print(segs.items, .{ .row_offset = @intCast(row + 1), .wrap = .none });
    }
    if (layout.scroll_max > 0) {
        const footer = try std.fmt.allocPrint(a, " {d}-{d}/{d}  ^F/^B ", .{ self.nav_hover_scroll + 1, self.nav_hover_scroll + layout.visible_rows, rows.len });
        const n = @min(footer.len, cols);
        for (0..n) |i| outer.writeCell(@intCast(i + 1), @intCast(rect.height - 1), .{ .char = .{ .grapheme = footer[i .. i + 1], .width = 1 }, .style = style });
    }
}

/// Human name of the configured language server for a filetype (`zig` →
/// `zls`), so the status line reports the service that is actually running,
/// not the buffer's language. Falls back to the language when no server is
/// configured.
fn lspServerName(lang: []const u8) []const u8 {
    const cmd = server_config.commandFor(lang) orelse return lang;
    if (cmd.len == 0) return lang;
    return std.fs.path.basename(cmd[0]);
}

/// Bottom chrome: one quiet status band. The background change supplies the
/// boundary without spending another row on a full-width rule.
pub fn drawStatusChrome(self: *App, win: vaxis.Window) void {
    const rows: u32 = win.height;
    if (rows <= status_row_count) return;
    const band = win.child(.{
        .x_off = 0,
        .y_off = @intCast(rows - status_row_count),
        .width = @intCast(win.width),
        .height = @intCast(status_row_count),
    });
    band.fill(.{ .style = chrome.bandStyle(self.theme) });
}

/// Fill one strip row span with the strip's flat background. The buffer
/// strip is a distinct chrome band (demo `.buffer-bar`), so every cell in
/// its rows owns a background even where there is no tab.
fn fillStripRow(win: vaxis.Window, row: u32, col: u32, width: u32, bg: vaxis.Color) void {
    if (width == 0) return;
    const child = win.child(.{
        .x_off = @intCast(col),
        .y_off = @intCast(row),
        .width = @intCast(width),
        .height = 1,
    });
    child.fill(.{ .style = .{ .bg = bg } });
}

const BufferTabKind = enum { plain, diff, note };

/// Tab label: basename normally, parent/basename when two open buffers
/// share a basename (CMP/tab identity without a permanent path row).
fn bufferTabName(self: *App, buf: *const Buffer) []const u8 {
    const path = buf.path orelse return "[No Name]";
    const base = std.fs.path.basename(path);
    var duplicate = false;
    for (self.buffers.items) |*other| {
        const op = other.path orelse continue;
        if (op.ptr == path.ptr and op.len == path.len) continue;
        if (std.mem.eql(u8, std.fs.path.basename(op), base)) {
            duplicate = true;
            break;
        }
    }
    return tabstrip.displayName(path, duplicate);
}

fn bufferTabKind(self: *App, buf: *const Buffer) BufferTabKind {
    const path = buf.path orelse return .plain;
    if (self.notesIsPath(path)) return .note;
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".diff") or
        std.ascii.eqlIgnoreCase(ext, ".patch"))
    {
        return .diff;
    }
    return .plain;
}

/// Draw one planned tab strip on a single-window row or a split pane layer.
/// `origin` is the screen column of plan x=0; `buf_map` maps plan slots back
/// to buffers. Active emphasis stays in the label row so the shared context
/// row below remains readable for every split arrangement.
pub fn drawBufferTabPlan(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    label_row: u32,
    origin: u32,
    pane_win: usize,
    p: tabstrip.Plan,
    buf_map: []const usize,
) !void {
    const t = self.theme;
    const strip_bg = chrome.bandStyle(t).bg;
    const editor_bg = chrome.surfaceStyle(t).bg;
    const dashboard = self.isDashboard();
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        const slot = p.slots[i];
        const buf_idx = buf_map[slot.index];
        if (buf_idx >= self.buffers.items.len) continue;
        const buf = &self.buffers.items[buf_idx];
        const tab_x = origin + slot.x;
        const body_bg: vaxis.Color = if (slot.active) editor_bg else strip_bg;
        fillStripRow(win, label_row, tab_x, slot.width, body_bg);
        if (!slot.first_visible and slot.x > 0) {
            win.writeCell(@intCast(tab_x - 1), @intCast(label_row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = chrome.separatorStyle(t, .minor, strip_bg),
            });
        }
        const icon = icons.forPath(if (buf.path) |path| path else "", false);
        const icon_style: vaxis.Style = .{
            // Active tabs keep the file-type color: selection is carried by
            // the marker and weight, not by painting every icon the same.
            .fg = .{ .rgb = icons.rgbOf(t, icon.color) },
            .bg = body_bg,
            .bold = slot.active,
        };
        if (slot.active and slot.width > 0) {
            win.writeCell(@intCast(tab_x), @intCast(label_row), .{
                .char = .{ .grapheme = "▏", .width = 1 },
                .style = chrome.activeSurfaceTabCellStyle(t),
            });
        }
        if (slot.width > tabstrip.pad_left) {
            win.writeCell(@intCast(tab_x + tabstrip.pad_left), @intCast(label_row), .{
                .char = .{ .grapheme = icon.glyph, .width = 1 },
                .style = icon_style,
            });
        }
        const name = bufferTabName(self, buf);
        var kind_fg = t.fg_dim;
        switch (bufferTabKind(self, buf)) {
            .plain => {},
            .diff => kind_fg = t.constant,
            .note => kind_fg = t.type,
        }
        const name_style: vaxis.Style = if (slot.active)
            chrome.activeSurfaceTabStyle(t)
        else
            chrome.inactiveTabNameStyle(t, strip_bg);
        if (slot.name_alloc > 0) {
            var text = name;
            if (slot.truncated) {
                // Middle truncation: readable prefix + `…` + extension.
                // `cellFitSuffix` is grapheme-aligned, so the suffix never
                // splits a wide glyph; the loop shrinks it only if the
                // prefix/suffix would overlap in the original name.
                const split = tabstrip.nameSplit(slot.name_alloc);
                const pref = autil.cellFitPrefix(win, name, split.prefix);
                var suffix_cells = split.suffix;
                var suf = autil.cellFitSuffix(win, name, suffix_cells);
                while (suffix_cells > 0 and pref.slice.len + suf.slice.len > name.len) {
                    suffix_cells -= 1;
                    suf = autil.cellFitSuffix(win, name, suffix_cells);
                }
                text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ pref.slice, tabstrip.ellipsis, suf.slice });
            }
            if (text.len > 0) {
                const seg = [_]vaxis.Segment{.{ .text = text, .style = name_style }};
                _ = win.print(&seg, .{
                    .row_offset = @intCast(label_row),
                    .col_offset = @intCast(origin + slot.name_x),
                    .wrap = .none,
                });
            }
        }
        if (slot.dirty and slot.name_alloc > 0) {
            win.writeCell(@intCast(origin + slot.name_x + slot.name_alloc), @intCast(label_row), .{
                .char = .{ .grapheme = "●", .width = 1 },
                .style = .{ .fg = .{ .rgb = t.constant }, .bg = body_bg },
            });
        }
        if (slot.closeable) {
            win.writeCell(@intCast(origin + slot.close_x), @intCast(label_row), .{
                .char = .{ .grapheme = "×", .width = 1 },
                .style = .{
                    .fg = .{ .rgb = if (slot.active) t.fg_dim else t.fg_faint },
                    .bg = body_bg,
                },
            });
        }
        if (self.mouseTargetsCollecting()) {
            // The select target starts at the icon so the hint label covers
            // the tab's identity, not its one-cell left padding. The close
            // cell is its own target, wired to the SAME close-buffer path as
            // the keyboard commands.
            if (!dashboard and slot.width > tabstrip.pad_left) {
                self.addHintTarget(.{
                    .row = label_row,
                    .col = tab_x + tabstrip.pad_left,
                    .width = slot.width -| tabstrip.pad_left,
                    .height = 1,
                }, .{ .pane_buffer_select = .{ .win = pane_win, .buffer = buf_idx } });
            }
            if (slot.closeable) {
                self.addHintTarget(.{
                    .row = label_row,
                    .col = origin + slot.close_x,
                    .width = tabstrip.close_cells,
                    .height = 1,
                }, .{ .buffer_close = buf_idx });
            }
        }
    }
}

/// Wrap one source line into slices that each fit `width` display cells.
/// Slices point into the caller's line (no copy); grapheme boundaries are
/// respected so CJK/emoji are never split. An empty line yields one empty
/// slice.
fn wrapCompletionLine(a: std.mem.Allocator, win: vaxis.Window, line: []const u8, width: u32) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (width == 0) {
        try out.append(a, line[0..0]);
        return out.toOwnedSlice(a);
    }
    var start: usize = 0;
    var used: u32 = 0;
    var iter = vaxis.unicode.graphemeIterator(line);
    while (iter.next()) |g| {
        const bytes = g.bytes(line);
        const gw: u32 = win.gwidth(bytes);
        if (used > 0 and used + gw > width) {
            try out.append(a, line[start..g.start]);
            start = g.start;
            used = 0;
        }
        used += gw;
    }
    try out.append(a, line[start..]);
    return out.toOwnedSlice(a);
}

/// Word-aware wrap for prose: fill lines up to `width` cells, breaking at
/// spaces when possible. A word wider than the pane still uses grapheme
/// wrapping so no text is lost. Returned slices point into `line`.
fn wrapCompletionWords(a: std.mem.Allocator, win: vaxis.Window, line: []const u8, width: u32) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (line.len == 0 or width == 0) {
        try out.append(a, line);
        return out.toOwnedSlice(a);
    }
    const cellsIn = struct {
        fn f(w: vaxis.Window, text: []const u8) u32 {
            var n: u32 = 0;
            var it = vaxis.unicode.graphemeIterator(text);
            while (it.next()) |g| n += w.gwidth(g.bytes(text));
            return n;
        }
    }.f;
    var line_start: usize = 0;
    var last_space: ?usize = null;
    var used: u32 = 0;
    var iter = vaxis.unicode.graphemeIterator(line);
    while (iter.next()) |g| {
        const bytes = g.bytes(line);
        const gw: u32 = win.gwidth(bytes);
        if (used > 0 and used + gw > width) {
            if (last_space) |sp| {
                if (sp > line_start) {
                    try out.append(a, line[line_start..sp]);
                    line_start = sp + 1;
                    used = cellsIn(win, line[line_start..g.start]);
                    last_space = null;
                } else {
                    try out.append(a, line[line_start..g.start]);
                    line_start = g.start;
                    used = 0;
                    last_space = null;
                }
            } else {
                try out.append(a, line[line_start..g.start]);
                line_start = g.start;
                used = 0;
            }
        }
        if (std.mem.eql(u8, bytes, " ")) last_space = g.start;
        used += gw;
    }
    try out.append(a, line[line_start..]);
    return out.toOwnedSlice(a);
}

fn completionPad(a: std.mem.Allocator, win: vaxis.Window, used: u32, width: u32, style: vaxis.Style) !?vaxis.Segment {
    _ = win;
    if (used >= width) return null;
    const pad = try a.alloc(u8, width - used);
    @memset(pad, ' ');
    return .{ .text = pad, .style = style };
}

const CompletionFit = struct { slice: []const u8, cells: u32 };

/// Fit a menu column to `max` cells, replacing the cut tail with one ellipsis
/// cell. Keeps the first readable part of a label/signature instead of a hard
/// chop ("comptim type" → "comptim…").
fn completionFit(a: std.mem.Allocator, win: vaxis.Window, text: []const u8, max: u32) !CompletionFit {
    const cells: u32 = @intCast(autil.cellWidth(win, text));
    if (cells <= max) return .{ .slice = text, .cells = cells };
    if (max == 0) return .{ .slice = text[0..0], .cells = 0 };
    if (max == 1) return .{ .slice = "…", .cells = 1 };
    const fit = autil.cellFitPrefix(win, text, max - 1);
    return .{ .slice = try std.fmt.allocPrint(a, "{s}…", .{fit.slice}), .cells = @intCast(fit.cells + 1) };
}

/// Literal (non-Markdown) documentation row: the text is shown exactly, then
/// padded to the pane width with the floating surface.
fn completionLiteralRow(self: *App, a: std.mem.Allocator, win: vaxis.Window, text: []const u8, width: u32, style: vaxis.Style) ![]vaxis.Segment {
    _ = self;
    var segs = std.ArrayList(vaxis.Segment).empty;
    const fit = autil.cellFitPrefix(win, text, width);
    if (fit.slice.len > 0) try segs.append(a, .{ .text = fit.slice, .style = style });
    if (try completionPad(a, win, @intCast(fit.cells), width, style)) |pad| try segs.append(a, pad);
    return segs.toOwnedSlice(a);
}

/// Highlight one complete documentation code block with ONE tree-sitter
/// Highlighter. The old per-line `completionCodeRow` created a parser/query/
/// tree for every wrapped line, turning a 160-line fenced block into 160
/// native parsers per frame (a multi-second stall on completion docs).
fn completionBlockSpans(self: *App, a: std.mem.Allocator, text: []const u8, lang: []const u8) ![]syntax.Span {
    var hl: ?syntax.Highlighter = null;
    if (syntax.languageFor(lang)) |ln| hl = self.newHighlighter(ln) catch null;
    if (hl == null) {
        const ft = autil.filetypeOf(self.cur().path);
        if (syntax.languageFor(ft)) |ln| hl = self.newHighlighter(ln) catch null;
    }
    if (hl) |*h| {
        // Parser/query/tree/cursor are native resources: freeing the frame
        // arena alone does not release them. Spans contain byte offsets only.
        defer h.deinit();
        h.reparse(text) catch {};
        var raw = std.ArrayList(syntax.Span).empty;
        h.spansInRange(0, @intCast(text.len), a, &raw) catch {};
        var merged = std.ArrayList(syntax.Span).empty;
        for (raw.items) |sp| {
            while (merged.items.len > 0) {
                var last = &merged.items[merged.items.len - 1];
                if (sp.start >= last.end) break;
                if (sp.start <= last.start) {
                    _ = merged.pop();
                    continue;
                }
                last.end = sp.start;
                break;
            }
            try merged.append(a, sp);
        }
        return merged.toOwnedSlice(a);
    }
    return &.{};
}

/// One code row sliced out of a pre-highlighted block.
fn completionCodeRowFromBlock(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    block_text: []const u8,
    line_start: u32,
    line_end: u32,
    spans: []const syntax.Span,
    width: u32,
) ![]vaxis.Segment {
    _ = win;
    return self.hoverCodeLineSegs(a, block_text, line_start, line_end, spans, width);
}

/// Append rows for one fenced code block (already collected as lines) using a
/// single highlighter. Returns false when the row cap was reached.
fn appendFencedBlockRows(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    rows: *std.ArrayList([]vaxis.Segment),
    lines: *std.ArrayList([]const u8),
    lang: []const u8,
    width: u32,
    max_rows: usize,
) !bool {
    if (lines.items.len == 0) return true;
    var block = std.ArrayList(u8).empty;
    // Do NOT deinit `block` here: the returned segment text slices reference
    // this buffer and are drawn after this helper returns. The frame arena
    // owns it until the frame ends (freeing it can rewind the arena and let
    // later row allocations overwrite the text). `offsets` only holds numbers.
    var offsets = std.ArrayList(u32).empty;
    defer offsets.deinit(a);
    for (lines.items) |line| {
        try offsets.append(a, @intCast(block.items.len));
        try block.appendSlice(a, line);
        try block.append(a, '\n');
    }
    const spans = try completionBlockSpans(self, a, block.items, lang);
    for (lines.items, offsets.items) |line, off| {
        const chunks = try wrapCompletionLine(a, win, line, width);
        for (chunks) |chunk| {
            if (rows.items.len >= max_rows) return false;
            const chunk_off = off + @as(u32, @intCast(@intFromPtr(chunk.ptr) - @intFromPtr(line.ptr)));
            try rows.append(a, try completionCodeRowFromBlock(
                self,
                a,
                win,
                block.items,
                chunk_off,
                chunk_off + @as(u32, @intCast(chunk.len)),
                spans,
                width,
            ));
        }
    }
    return true;
}

/// Build the wrapped display rows for the completion documentation popup:
/// syntax-highlighted signature header, divider, then Markdown/plaintext
/// body. Returns a slice of rows, each exactly `width` cells wide.
const RichDocLimits = struct { max_rows: usize = 256, max_bytes: usize = 64 * 1024 };

fn buildCompletionDocRows(self: *App, a: std.mem.Allocator, win: vaxis.Window, item: *const lsp_nav.CompletionItem, width: u32) ![]const []vaxis.Segment {
    return buildRichDocRows(self, a, win, item, width, .{});
}

fn buildRichDocRows(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    item: *const lsp_nav.CompletionItem,
    width: u32,
    limits: RichDocLimits,
) ![]const []vaxis.Segment {
    var rows = std.ArrayList([]vaxis.Segment).empty;
    if (width == 0) return rows.toOwnedSlice(a);
    const base: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float } };
    const faint: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
    const dim: vaxis.Style = .{ .fg = .{ .rgb = theme.hintFg(self.theme) }, .bg = .{ .rgb = self.theme.bg_float } };
    const ft = autil.filetypeOf(self.cur().path);

    const sig: ?[]const u8 = if (item.detail) |d|
        d
    else if (item.label_detail) |d|
        d
    else
        null;
    const has_body = item.doc != null and item.doc.?.len > 0;

    if (sig) |sig_text| {
        const sig_spans = try completionBlockSpans(self, a, sig_text, ft);
        var sig_lines = std.mem.splitScalar(u8, sig_text, '\n');
        var line_off: u32 = 0;
        while (sig_lines.next()) |line| {
            const chunks = try wrapCompletionLine(a, win, line, width);
            for (chunks) |chunk| {
                const chunk_off = line_off + @as(u32, @intCast(@intFromPtr(chunk.ptr) - @intFromPtr(line.ptr)));
                try rows.append(a, try completionCodeRowFromBlock(
                    self,
                    a,
                    win,
                    sig_text,
                    chunk_off,
                    chunk_off + @as(u32, @intCast(chunk.len)),
                    sig_spans,
                    width,
                ));
            }
            line_off += @as(u32, @intCast(line.len)) + 1;
        }
        if (has_body) {
            // Divider between signature and prose; the signature is not lost
            // when documentation exists (the old `doc orelse detail` bug).
            var rule: std.ArrayList(u8) = .empty;
            try rule.append(a, ' ');
            var ri: u32 = 1;
            while (ri < width) : (ri += 1) try rule.appendSlice(a, "─");
            try rows.append(a, try completionLiteralRow(self, a, win, rule.items, width, faint));
        }
    }

    if (has_body) {
        var body: []const u8 = item.doc.?;
        body = hover_layout.bytePrefix(body, limits.max_bytes);
        var in_fence: ?[]const u8 = null;
        var fence_lines = std.ArrayList([]const u8).empty;
        defer fence_lines.deinit(a);
        var line_it = std.mem.splitScalar(u8, body, '\n');
        // Bound per-frame layout work for pathological docs; 256 wrapped
        // rows is far more than the pane can show, and the pane still
        // scrolls through all of it.
        var truncated_rows = false;
        body_lines: while (line_it.next()) |raw_line| {
            if (rows.items.len >= limits.max_rows) {
                truncated_rows = true;
                break;
            }
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
            if (item.doc_kind == .markdown) {
                if (autil.isFenceLine(line)) |lang| {
                    if (in_fence == null) {
                        in_fence = lang;
                    } else {
                        // Closing fence: highlight the whole block once.
                        if (!try appendFencedBlockRows(self, a, win, &rows, &fence_lines, in_fence.?, width, limits.max_rows)) {
                            truncated_rows = true;
                            break;
                        }
                        fence_lines.clearRetainingCapacity();
                        in_fence = null;
                    }
                    // Fence markers are concealed: keep a blank row so the
                    // block keeps its vertical rhythm.
                    try rows.append(a, try completionLiteralRow(self, a, win, "", width, .{ .bg = .{ .rgb = self.theme.bg_float } }));
                    continue;
                }
                if (in_fence != null) {
                    try fence_lines.append(a, line);
                    continue;
                }
                const readable = try hover_layout.readableLinks(a, line);
                const chunks = try wrapCompletionWords(a, win, readable, width);
                for (chunks) |chunk| {
                    if (rows.items.len >= limits.max_rows) {
                        truncated_rows = true;
                        break :body_lines;
                    }
                    try rows.append(a, try self.hoverLineSegs(a, chunk, width));
                }
                continue;
            }
            // plaintext: preserve literal stars/backticks; word-wrap only at
            // spaces so prose stays readable.
            const chunks = try wrapCompletionWords(a, win, line, width);
            for (chunks) |chunk| {
                if (rows.items.len >= limits.max_rows) {
                    truncated_rows = true;
                    break :body_lines;
                }
                try rows.append(a, try completionLiteralRow(self, a, win, chunk, width, base));
            }
        }
        if (in_fence) |lang| {
            if (!try appendFencedBlockRows(self, a, win, &rows, &fence_lines, lang, width, limits.max_rows)) truncated_rows = true;
        }
        if (item.doc.?.len > limits.max_bytes or truncated_rows) {
            try rows.append(a, try completionLiteralRow(self, a, win, "… documentation truncated", width, dim));
        }
    } else if (sig == null) {
        const status: ?[]const u8 = switch (item.resolve_state) {
            .loading => "loading documentation…",
            .failed => "documentation unavailable",
            .empty => "no documentation",
            else => null,
        };
        if (status) |txt| try rows.append(a, try completionLiteralRow(self, a, win, txt, width, dim));
    }
    return rows.toOwnedSlice(a);
}

/// Overlay search-match backgrounds on the already-built text segments.
/// Selection wins; otherwise search (current hit stronger) overrides the
/// cursorline/band surfaces. Segments that are not verbatim slices of the
/// line (expanded tabs, concealed markdown, virtual text) are left alone:
/// highlight is visual only and never changes bytes or columns.
fn applySearchHighlight(self: *App, a: std.mem.Allocator, segs: *std.ArrayList(vaxis.Segment), text: []const u8, index: *const @import("../editor/search.zig").Index, line_start: u32, cursor: ?u32) !void {
    const q = index.query orelse return;
    if (q.len == 0) return;
    var first = index.lowerBound(line_start);
    if (first > 0 and @as(u64, index.starts.items[first - 1]) + q.len > line_start) first -= 1;
    const last = index.lowerBound(line_start + @as(u32, @intCast(text.len)));
    const hits = index.starts.items[first..last];
    if (hits.len == 0) return;
    const sel_bg = self.theme.bg_sel;
    const match_bg = theme.searchBg(self.theme, .match).?;
    const current_bg = theme.searchBg(self.theme, .current).?;
    var out = std.ArrayList(vaxis.Segment).empty;
    var si: usize = 0;
    while (si < segs.items.len and si < 2) : (si += 1) try out.append(a, segs.items[si]);
    var ri: usize = 0;
    while (si < segs.items.len) : (si += 1) {
        const seg = segs.items[si];
        if (seg.text.len == 0) continue;
        // Only borrowed source slices have document coordinates. Searching
        // for equal bytes would mistake an inlay label for later source text.
        const base = @intFromPtr(text.ptr);
        const ptr = @intFromPtr(seg.text.ptr);
        if (ptr < base or ptr - base > text.len or seg.text.len > text.len - (ptr - base)) {
            try out.append(a, seg);
            continue;
        }
        const at = ptr - base;
        const keep_sel = switch (seg.style.bg) {
            .rgb => |rgb| std.mem.eql(u8, &rgb, &sel_bg),
            else => false,
        };
        if (keep_sel) {
            try out.append(a, seg);
            continue;
        }
        var pos = at;
        const end = at + seg.text.len;
        while (pos < end) {
            const abs = @as(u64, line_start) + pos;
            while (ri < hits.len and @as(u64, hits[ri]) + q.len <= abs) ri += 1;
            var next = end;
            var style = seg.style;
            if (ri < hits.len) {
                const hit = hits[ri];
                if (abs < hit) {
                    next = @min(next, hit - line_start);
                } else {
                    next = @min(next, @as(usize, hit) + q.len - line_start);
                    const current = if (cursor) |c| c >= hit and @as(u64, c) < @as(u64, hit) + q.len else false;
                    style.bg = .{ .rgb = if (current) current_bg else match_bg };
                }
            }
            try out.append(a, .{ .text = seg.text[pos - at .. next - at], .style = style });
            pos = next;
        }
    }
    segs.* = out;
}

pub fn render(self: *App) !void {
    self.mermaid.frame += 1;
    try table_cell_ui.check(self);
    // Final safeguard for focus changes outside input dispatch. Event
    // boundaries already synchronize before subsequent input can request
    // a new hint in that focus.
    self.syncPassiveFocus();
    // vaxis cells reference the text slices passed to print, so all text
    // must stay alive until vx.render(); a per-frame arena handles that.
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // per-frame memo invalidation (screenCellCol is called with identical
    // args several times a frame)
    self.cell_col_memo.valid = false;
    self.markdown_frame = null;
    self.markdown_frame_buf = std.math.maxInt(usize);
    self.markdown_visible_images.clearRetainingCapacity();
    self.rendered_cursor_row = null;

    const win = self.vx.window();
    win.clear();
    // Editor background: paint the whole screen with the theme's bg so
    // the palette is consistent (like nvim), not terminal-transparent.
    win.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg } } });

    const height: u32 = win.height;
    // feat/mouse: reset the hit-test target list for this frame. Cheap (one
    // branch) unless mouse reporting is enabled; the same registrations that
    // feed hint labels also feed hit-testing on mouse frames.
    self.beginMouseFrame(height, win.width);
    if (self.review.open) {
        hideInactiveMarkdownImages(self);
        win.hideCursor();
        try @import("git_review_render.zig").draw(self, a, win);
        return self.vx.render(self.tty.writer());
    }
    if (height <= status_row_count) return;
    // One timestamp for every animated element this frame (streaming dots,
    // tool spinners, badge flash). Idle frames compute it but draw nothing
    // time-dependent.
    self.frame_now_ms = self.nowMs();
    // M2.6a hints: clear this frame's target list. One boolean test per
    // frame outside hint mode; normal frames never touch the fixed array.
    self.hints.beginFrame(height, win.width);
    // Content area rows: below the buffer labels/context, above the status
    // band. The strip's rows are real layout rows, so the cursor/viewport
    // math below can never paint into them.
    const bar_rows = self.tabBarRows(a);
    const content_top = bar_rows;
    const content_rows = height - status_row_count - bar_rows;

    // Clamp the focused window's cursor/viewport BEFORE any lineOf /
    // column math below: switching windows or buffers can leave a stale
    // cursor past the end of the current buffer (e.g. both splits show
    // the same buffer and the other window deleted everything), and
    // piece_table.lineOf asserts pos <= len in Debug builds.
    const fw = &self.windows.items[self.current_win];
    if (fw.cursor > self.cur().pt.len()) fw.cursor = self.cur().pt.len();
    fw.view_top = self.cur().pt.clampLine(fw.view_top);

    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    // Each pane owns one row immediately above its source. Hidden buffers
    // keep their last pane; a buffer shown in several panes has one tab,
    // with the focused pane taking ownership. No header can spill into a
    // neighboring split, even when its filename is long.
    const tab_layout = try self.layoutWindows(a, content_top, content_rows, self.contentCol(), self.editorAreaWidth());
    const tab_specs = try a.alloc(tabstrip.Spec, self.buffers.items.len);
    const tab_bufs = try a.alloc(usize, self.buffers.items.len);
    for (tab_layout.leaves) |lr| {
        if (lr.header_rows == 0 or lr.width == 0) continue;
        const label_row = lr.row - lr.header_rows;
        fillStripRow(win, label_row, lr.col, lr.width, chrome.bandStyle(self.theme).bg);
        const own = self.windows.items[lr.win].buf;
        var n: usize = 0;
        for (self.buffers.items, 0..) |*buf, bi| {
            var owner = @min(buf.last_win, self.windows.items.len - 1);
            for (self.windows.items, 0..) |w, wi| {
                if (w.buf == bi) {
                    owner = wi;
                    break;
                }
            }
            if (self.windows.items[self.current_win].buf == bi) owner = self.current_win;
            if (owner != lr.win) continue;
            tab_specs[n] = .{
                .name_cells = @intCast(autil.cellWidth(win, bufferTabName(self, buf))),
                .dirty = buf.dirty,
                .active = bi == own,
                .closeable = self.buffers.items.len > 1,
            };
            tab_bufs[n] = bi;
            n += 1;
        }
        // The first filename shares the source's left text spine. On tiny
        // panes readability takes priority over the decorative alignment.
        const text_col = self.gutterWidthFor(self.buffers.items[own].pt.lineCountUpperBound(), lr.width);
        const inset = text_col -| (tabstrip.pad_left + tabstrip.icon_cells + tabstrip.gap_cells);
        const p = tabstrip.plan(tab_specs[0..n], lr.width -| inset);
        try self.drawBufferTabPlan(a, win, label_row, lr.col + inset, lr.win, p, tab_bufs[0..n]);
    }

    // dashboard (no file open): snacks.nvim style — a big ASCII logo, a
    // subtitle, a centered key menu, then the recent-files list (j/k/Enter).
    if (self.isDashboard()) {
        const t = self.theme;
        // Segment styles replace the cell's style; a default background
        // would punch transparent holes through the themed base fill.
        const faint: vaxis.Style = .{ .fg = .{ .rgb = t.fg_faint }, .bg = .{ .rgb = t.bg } };
        const logo_style: vaxis.Style = .{ .fg = .{ .rgb = t.accent }, .bg = .{ .rgb = t.bg }, .bold = true };
        const key_style: vaxis.Style = .{ .fg = .{ .rgb = t.accent }, .bg = .{ .rgb = t.bg }, .bold = true };
        const label_style: vaxis.Style = .{ .fg = .{ .rgb = t.fg }, .bg = .{ .rgb = t.bg } };
        // content area between the sidebar and the right edge
        const area_col: u32 = self.contentCol();
        const area_w: u32 = self.aiEditorWidth() -| area_col;
        // horizontal centering helper: the column that centers a `width`-cell
        // block inside the content area (never negative)
        const centerCol = struct {
            fn c(col: u32, w: u32, width: u32) u32 {
                return col + (w -| width) / 2;
            }
        }.c;

        // ANSI-Shadow "OZ" logo (FIGlet), 6 rows
        const logo = [_][]const u8{
            " ██████╗ ███████╗",
            "██╔═══██╗╚══███╔╝",
            "██║   ██║  ███╔╝ ",
            "██║   ██║ ███╔╝  ",
            "╚██████╔╝███████╗",
            " ╚═════╝ ╚══════╝",
        };
        var row: u32 = self.contentTop(a) + 1;
        for (logo) |line| {
            const lw: u32 = @intCast(line.len);
            const seg = [_]vaxis.Segment{.{ .text = line, .style = logo_style }};
            _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(centerCol(area_col, area_w, lw)), .wrap = .none });
            row += 1;
        }
        // subtitle (kept verbatim: e2e keys on this string)
        {
            const seg = [_]vaxis.Segment{.{ .text = "终端文本编辑器", .style = faint }};
            // 8 CJK cells wide (each glyph is 2 cells)
            _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(centerCol(area_col, area_w, 14)), .wrap = .none });
            row += 2;
        }

        // centered key menu: two columns of "[key] Label"
        const menu = [_]struct { key: []const u8, label: []const u8 }{
            .{ .key = "f", .label = "Find File" },
            .{ .key = "n", .label = "New File" },
            .{ .key = "r", .label = "Recent Files" },
            .{ .key = "q", .label = "Quit" },
        };
        // each item renders as "[k] Label" (3 + label cells); two per row
        // with a fixed gap, the pair centered as one block
        const item_w: u32 = 3 + 12; // "[f] " + widest label ("Recent Files")
        const pair_w: u32 = item_w * 2 + 4;
        var mi: usize = 0;
        while (mi < menu.len) : (mi += 2) {
            const base_col = centerCol(area_col, area_w, pair_w);
            var col: u32 = base_col;
            var k: usize = 0;
            while (k < 2 and mi + k < menu.len) : (k += 1) {
                const item = menu[mi + k];
                const key_seg = [_]vaxis.Segment{
                    .{ .text = "[", .style = faint },
                    .{ .text = item.key, .style = key_style },
                    .{ .text = "] ", .style = faint },
                };
                _ = win.print(&key_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col), .wrap = .none });
                const label_seg = [_]vaxis.Segment{.{ .text = item.label, .style = label_style }};
                _ = win.print(&label_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col + 4), .wrap = .none });
                col += item_w + 4;
            }
            row += 1;
        }
        row += 1;

        // recent files: a left-aligned block centered as a whole
        const recents_n = @min(self.recent_files.items.len, 8);
        // the block's left edge: center a fixed 56-cell column
        const list_col = centerCol(area_col, area_w, 56);
        {
            const seg = [_]vaxis.Segment{.{ .text = "Recent:", .style = faint }};
            _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(list_col), .wrap = .none });
            row += 1;
        }
        const recent_first_row = row; // the row recent item 0 lands on
        var ri: usize = 0;
        while (ri < recents_n) : (ri += 1) {
            const fname = self.recent_files.items[ri];
            const sel = (ri == self.recent_sel);
            const bg: vaxis.Color = .{ .rgb = if (sel) t.bg_sel else t.bg };
            const fg: vaxis.Color = .{ .rgb = if (sel) t.fg else t.function };
            const icon = icons.forPath(fname, false);
            const segs = [_]vaxis.Segment{
                .{ .text = if (sel) "▸ " else "  ", .style = .{ .fg = .{ .rgb = t.accent }, .bg = bg } },
                .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(t, icon.color) }, .bg = bg } },
                .{ .text = " ", .style = .{ .bg = bg } },
                .{ .text = fname, .style = .{ .fg = fg, .bg = bg } },
            };
            _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(list_col), .wrap = .none });
            row += 1;
        }
        // the block cursor sits on the selected recent row
        self.vx.screen.cursor = .{
            .row = @intCast(recent_first_row + @as(u32, @intCast(@min(self.recent_sel, 7)))),
            .col = @intCast(list_col),
        };
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = .block;
        // the dashboard returns before the window loop, so the file tree
        // (rendered after that loop) would never draw over it — draw it
        // here too, or <leader>e on the dashboard shows a stale screen
        if (self.filetree_active) try renderNavigator(self, a, win, height);
        // <leader>a works on the dashboard too: draw the rail last (it
        // places the cursor only when the rail/prompt owns focus; otherwise
        // the dashboard's recent-row cursor stays visible).
        if (self.ai.rail_open) try self.drawAiRail(a, win);
        if (term.supported) try self.drawTerm(a, win);
        // M2b2 inline prompt floats above the rail; hint labels remain the
        // topmost overlay below.
        if (self.inlinePromptOpen()) try self.drawInlinePrompt(a, win);
        // Dashboard actions can fail (e.g. an unreadable search root).
        // Keep their message visible without replacing the welcome screen.
        self.drawStatusChrome(win);
        if (self.msg) |message| {
            if (height > status_row_count) {
                const segs = [_]vaxis.Segment{.{ .text = message, .style = chrome.bandStyle(t) }};
                _ = win.print(&segs, .{ .row_offset = @intCast(height - 1), .wrap = .none });
            }
        }
        // M2.6a: labels + status indicator are the topmost layer, and must be
        // drawn after rail/filetree/dashboard before the frame is flushed.
        try self.drawHintOverlay(a, win);
        try @import("filetree.zig").drawFiletreeCreate(self, a, win);
        hideInactiveMarkdownImages(self);
        try self.vx.render(self.tty.writer());
        return;
    }

    // split windows: every leaf gets a rectangle and renders its buffer;
    // the focused window carries syntax highlighting and the selection
    const layout = try self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), self.editorAreaWidth());
    const leaves = layout.leaves;
    var cur_rect: LeafRect = .{ .win = self.current_win, .row = 0, .col = 0, .height = 0, .width = 0 };
    for (leaves) |lr| {
        if (lr.win == self.current_win) {
            cur_rect = lr;
            continue;
        }
        // Mouse-only: each split leaf is clickable (focus + cursor
        // placement) and scrollable. Registered from the SAME layout rect
        // the pane draws into, so hit geometry cannot drift.
        self.addMousePaneTarget(lr.win, lr.row, lr.col, lr.height, lr.width);
        try self.renderWindowLines(a, lr, false);
    }
    var cell_rect = cur_rect;
    cell_rect.height = if (self.cell_edit != null) table_cell_ui.panelHeight(cur_rect.height) else 0;
    cur_rect.height -= cell_rect.height;
    cell_rect.row += cur_rect.height;
    // Cursor/overlays use the same focused-pane gutter as source and mouse.
    const gutter = self.gutterWidthFor(self.cur().pt.lineCountUpperBound(), cur_rect.width);
    self.addMousePaneTarget(cur_rect.win, cur_rect.row, cur_rect.col, cur_rect.height, cur_rect.width);
    try self.renderWindowLines(a, cur_rect, true);
    if (cur_rect.width > 0 and cur_rect.height > 0) self.cur().line_index_frame_seen = true;
    hideInactiveMarkdownImages(self);

    // window separators (vim statusline semantics): one "─" row per
    // horizontal split, one "│" column per vertical split, drawn OVER the
    // buffers so the panes read as distinct windows without changing the
    // layout math. The separator adjacent to the focused window (the
    // split path from the root to the current leaf) is bright; the rest
    // are dim. The bg is the editor background so the line fully hides
    // whatever buffer text it covers — no ghosting from the window below.
    for (layout.seps) |sep| {
        // A separator click is an explicit v1 no-op (no resize); its
        // 1-cell-thick rect wins over the adjacent pane by area.
        const sep_style: vaxis.Style = .{
            .fg = .{ .rgb = if (sep.active) self.theme.win_sep_active else self.theme.win_sep },
            .bg = .{ .rgb = self.theme.bg },
        };
        if (sep.horizontal) {
            self.addMouseSeparatorTarget(sep.row, sep.col, sep.len, true);
            var xs: u32 = 0;
            while (xs < sep.len) : (xs += 1) {
                win.writeCell(@intCast(sep.col + xs), @intCast(sep.row), .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = sep_style,
                });
            }
        } else {
            var segment_start: ?u32 = null;
            var ys: u32 = 0;
            while (ys < sep.len) : (ys += 1) {
                const source_cell = blk: {
                    for (leaves) |leaf| {
                        if (leaf.width == 1 and leaf.col == sep.col and sep.row + ys >= leaf.row and sep.row + ys < leaf.row + leaf.height) break :blk true;
                    }
                    break :blk false;
                };
                if (source_cell) {
                    if (segment_start) |start| self.addMouseSeparatorTarget(sep.row + start, sep.col, ys - start, false);
                    segment_start = null;
                    continue;
                }
                if (segment_start == null) segment_start = ys;
                win.writeCell(@intCast(sep.col), @intCast(sep.row + ys), .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = sep_style,
                });
            }
            if (segment_start) |start| self.addMouseSeparatorTarget(sep.row + start, sep.col, sep.len - start, false);
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
                // byte offset -> SCREEN position (CJK word = 3 bytes/2
                // cells; inlay hints before it shift the cells right; a
                // soft-wrapped line's tail cells sit on lower rows)
                const sp = self.focusedScreenPos(win, cur_rect, wline, p);
                if (sp.row >= cur_rect.height) break;
                var clen: u32 = 1;
                while (p + clen < w.end and (self.cur().pt.byteAt(p + clen) & 0xC0) == 0x80) : (clen += 1) {}
                var char_buf: [4]u8 = undefined;
                self.cur().pt.copyRange(p, char_buf[0..clen]);
                const g = try a.dupe(u8, char_buf[0..clen]);
                win.writeCell(@intCast(cur_rect.col + gutter + sp.col), @intCast(cur_rect.row + sp.row), .{
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
            // byte offset -> SCREEN position: a CJK char before the match
            // is 3 bytes but 2 cells, an inlay hint before it occupies
            // screen cells without buffer bytes, and a soft-wrapped line's
            // tail cells sit on lower rows — a plain line-relative row and
            // text column would paint the label off the match
            const sp = self.focusedScreenPos(win, cur_rect, mline, m.pos);
            if (sp.row >= cur_rect.height) continue;
            const label = try a.dupe(u8, &[_]u8{m.label});
            win.writeCell(@intCast(cur_rect.col + gutter + sp.col), @intCast(cur_rect.row + sp.row), .{
                .char = .{ .grapheme = label, .width = 1 },
                .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_sel } },
            });
        }
    }

    // Current-line virtual text is part of the editor surface. Paint it
    // before terminal frames/content and other overlays, including when
    // asynchronous blame finishes while a terminal is already visible.
    const diagnostic_owns_line = try @import("diagnostics.zig").draw(self, a, win, cur_rect, .inline_text);

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
        if (!diagnostic_owns_line and self.blame_active and self.state.mode == .normal and
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
                    // the ghost follows the line END — on a soft-wrapped
                    // line that's the last chunk's row, not the first
                    const b_sp = self.focusedScreenPos(win, cur_rect, blame_line, line_end);
                    var start_col = cur_rect.col + gutter + b_sp.col;
                    // a closed fold's " … N lines" marker also renders after
                    // the text — shift the ghost past it
                    if (foldAt(fbuf, blame_line)) |f| {
                        const marker = try std.fmt.allocPrint(a, " … {d} lines", .{f.hiddenCount()});
                        start_col += self.textWidth(win, marker);
                    }
                    // the ghost must stay inside THIS pane: win.width is
                    // the whole screen, and a split's neighbor owns the
                    // columns past the pane's right edge. With the Agent
                    // Rail open (docked OR drawer) the ghost is also clipped
                    // one cell before the rail border, so a long blame never
                    // touches/enters the agent column and a one-cell gap
                    // keeps the rail's left rule readable.
                    const pane_end = cur_rect.col + cur_rect.width;
                    var ghost_end = pane_end;
                    if (self.ai.rail_open) {
                        const lay = self.aiLayout();
                        const rail_limit = lay.rail_col -| lay.rail_gutter;
                        if (rail_limit < ghost_end) ghost_end = rail_limit;
                    }
                    if (b_sp.row < cur_rect.height and start_col < ghost_end) {
                        const fit = autil.cellFitPrefix(win, label, ghost_end - start_col);
                        if (fit.cells > 0) {
                            const seg = [_]vaxis.Segment{.{
                                .text = fit.slice,
                                .style = .{
                                    .fg = .{ .rgb = theme.blameFg(self.theme) },
                                    .bg = .{ .rgb = self.theme.bg_curline },
                                },
                            }};
                            _ = win.print(&seg, .{
                                .row_offset = @intCast(cur_rect.row + b_sp.row),
                                .col_offset = @intCast(start_col),
                                .wrap = .none,
                            });
                        }
                    }
                }
            }
        }
    }

    // The compact Files peek covers editor cells, including inline
    // diagnostics, blame text and motion labels painted above.
    if (self.filetree_active) try renderNavigator(self, a, win, height);

    // Pane surfaces first; the terminal then covers their shared rectangle.
    // Global modal overlays below retain their matching input priority.
    // Agent Rail / drawer (M2a): above editor panes, below terminal content. Pickers/hovers below are
    // genuine modal overlays and may draw above it.
    if (self.ai.rail_open) try self.drawAiRail(a, win);
    if (term.supported) try self.drawTerm(a, win);

    // Inline edit prompt (M2b2): a compact centered float above the rail and
    // editor, below the hint overlay. It owns a beam cursor while open.
    if (self.inlinePromptOpen()) try self.drawInlinePrompt(a, win);

    // fuzzy picker overlay (telescope/snacks style: a solid bg_float
    // floating window with a border, a title and an in-panel input row,
    // centered on the screen instead of pinned to the bottom-left corner)
    if (self.picker_active) {
        const total = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
        // grep keeps at least one row ("no matches" hint) so the
        // fixed-size panel never collapses to a sliver while the query
        // has no hits yet
        var list_rows = @min(@as(usize, 10), total);
        if (self.picker_mode == .grep or self.picker_from_home) list_rows = @max(list_rows, 1);
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
            while (mk < list_rows and top + mk < total) : (mk += 1) {
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
                } else if (self.picker_mode == .workspaces) blk: {
                    const wi = self.picker_matches.items[ri];
                    break :blk self.workspaces.items[wi].name;
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
        if (self.picker_from_home) inner_w = @max(inner_w, 26);
        // Keymap descriptions are long; a slightly wider card gives the
        // reference room to breathe instead of reading as a cramped list.
        if (self.picker_mode == .keymaps) inner_w = @max(inner_w, 48);
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
        inner_w = box_w -| 2;
        const title = switch (self.picker_mode) {
            .grep => " Grep ",
            .buffers => " Buffers ",
            .recent => " Recent ",
            .keymaps => " Keymaps ",
            .themes => " Themes ",
            .workspaces => " Workspaces ",
            .files => if (!self.picker_from_home or self.home_search_fallback)
                " Files "
            else if (self.home_search_limited)
                " Files · Home (partial) "
            else
                " Files · Home ",
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
            const fit = autil.cellFitPrefix(win, title, inner_w);
            try segs.append(a, .{ .text = fit.slice, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
            for (fit.cells..inner_w) |_| {
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
            if (self.picker_from_home and total == 0) {
                const text = self.msg orelse if (self.home_search != null)
                    "Searching files…"
                else if (self.picker_input.items.len == 0)
                    "Type to search files"
                else
                    "No matching files";
                const fit = autil.cellFitPrefix(win, text, inner_w);
                const row = try a.alloc(u8, fit.slice.len + inner_w - fit.cells);
                @memset(row, ' ');
                @memcpy(row[0..fit.slice.len], fit.slice);
                try segs.append(a, .{ .text = row, .style = row_style });
            } else if (self.picker_mode == .keymaps) {
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
                    const ids: [64]u8 = @splat(0);
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
                    // The preview column is one file (the selected result),
                    // not the result of whatever row k happens to be: pass
                    // the selected path/line for every row. Using r.line
                    // here shifted/blanked the content rows whenever the
                    // selection was not row 0.
                    const selr = self.grep_results.items[@min(self.picker_sel, self.grep_results.items.len - 1)];
                    try self.renderGrepPreviewRow(&segs, a, win, k, list_rows, preview_w, selr.path, selr.line);
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
                } else if (self.picker_mode == .workspaces) blk: {
                    const wi = self.picker_matches.items[ri];
                    break :blk self.workspaces.items[wi].name;
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
        // A picker is modal, but the mode must stay visible. Draw a compact
        // status band before the early return (the normal status code below
        // would otherwise be skipped for every picker).
        self.drawStatusChrome(win);
        const picker_mode = switch (self.state.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual_char, .visual_line, .visual_block => "VISUAL",
            .command => "COMMAND",
        };
        const picker_badge_style: vaxis.Style = .{
            .fg = .{ .rgb = self.theme.accent },
            .bg = .{ .rgb = self.theme.bg_status },
            .bold = true,
        };
        _ = win.print(&.{.{ .text = "[", .style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_status } } }}, .{
            .row_offset = @intCast(height - 1),
            .col_offset = 0,
            .wrap = .none,
        });
        _ = win.print(&.{.{ .text = picker_mode, .style = picker_badge_style }}, .{
            .row_offset = @intCast(height - 1),
            .col_offset = 1,
            .wrap = .none,
        });
        _ = win.print(&.{.{ .text = "]", .style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_status } } }}, .{
            .row_offset = @intCast(height - 1),
            .col_offset = @intCast(1 + picker_mode.len),
            .wrap = .none,
        });
        const picker_hint = " Esc close ";
        const picker_hint_w: u32 = @intCast(autil.cellWidth(win, picker_hint));
        if (picker_hint_w < win.width) {
            _ = win.print(&.{.{ .text = picker_hint, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_status } } }}, .{
                .row_offset = @intCast(height - 1),
                .col_offset = @intCast(win.width - picker_hint_w),
                .wrap = .none,
            });
        }
        try self.vx.render(self.tty.writer());
        return;
    }

    // status bar (or command line in command mode)
    if (self.state.mode == .command) {
        self.drawStatusChrome(win);
        if (self.pending_filetree_create != null) {
            try @import("filetree.zig").drawFiletreeCreate(self, a, win);
            try self.vx.render(self.tty.writer());
            return;
        }
        const prompt_char: []const u8 = switch (self.cmdline_kind) {
            .ex => ":",
            .search_fwd => "/",
            .search_bwd => "?",
        };
        const count = if (self.cmdline_kind != .ex) try self.searchCountText(a) else null;
        const count_w: u32 = if (count) |txt| @intCast(txt.len + 1) else 0;
        const show_count = count != null and win.width >= count_w + 3;
        const input_w = win.width -| (if (show_count) count_w else 0);
        const fit = autil.cellFitSuffix(win, self.cmdline.items, input_w -| 2);
        const prompt = try std.fmt.allocPrint(a, "{s}{s}", .{ prompt_char, fit.slice });
        const cmd_seg = [_]vaxis.Segment{.{
            .text = prompt,
            .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status } },
        }};
        _ = win.print(&cmd_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
        if (show_count) {
            _ = win.print(&.{.{ .text = count.?, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_status } } }}, .{
                .row_offset = @intCast(height - 1),
                .col_offset = @intCast(win.width - count_w + 1),
                .wrap = .none,
            });
        }
        self.vx.screen.cursor = .{
            .row = @intCast(height - 1),
            .col = @intCast(@min(1 + fit.cells, win.width -| 1)),
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

    // Hunk preview float (<leader>gp): the hunk's raw patch in a
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
    // panel, selected row in bg_sel. The row is split into measured
    // segments: kind icon (category color), label, labelDetails.detail
    // and a right-aligned labelDetails.description. Descriptions are never
    // synthesized from `kind` or from the signature.
    if (self.completion_active) {
        const total = self.completion_words.items.len;
        if (total > 0) completion_menu: {
            const c_line = self.cur().pt.lineOf(self.curCursor().*);
            const c_sp = self.focusedScreenPos(win, cur_rect, c_line, self.curCursor().*);
            const pane_left = cur_rect.col;
            const pane_width = cur_rect.width;
            const pane_rect = completion_layout.Rect{ .row = cur_rect.row, .col = pane_left, .width = pane_width, .height = cur_rect.height };
            const list_rows = completion_layout.visibleMenuRows(pane_rect, cur_rect.row + c_sp.row, @intCast(@min(@as(usize, 8), total)));
            if (list_rows == 0 or pane_width < 6) break :completion_menu;
            var top: usize = 0;
            if (self.completion_sel >= list_rows) top = self.completion_sel - list_rows + 1;

            // Measure the visible rows first. The description column is
            // stable across rows so long signatures cannot make it jump.
            var max_label: u32 = 0;
            var max_detail: u32 = 0;
            var max_desc: u32 = 0;
            var max_icon: u32 = 1;
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const item = self.completion_words.items[top + k];
                max_label = @max(max_label, @as(u32, @intCast(autil.cellWidth(win, item.label))));
                if (item.label_detail) |d| max_detail = @max(max_detail, @as(u32, @intCast(autil.cellWidth(win, d))));
                if (item.label_description) |d| max_desc = @max(max_desc, @as(u32, @intCast(autil.cellWidth(win, d))));
                const icon = if (item.kind != 0) kindGlyph(item.kind) else " ";
                max_icon = @max(max_icon, @as(u32, @intCast(autil.cellWidth(win, icon))));
            }
            var doc_rows_list = try buildCompletionDocRows(self, a, win, &self.completion_words.items[self.completion_sel], @min(@as(u32, 64), pane_width -| 4));
            const menu_budget = completion_layout.menuWidthBudget(pane_width, doc_rows_list.len > 0, 24);
            const budget: u32 = menu_budget -| 4;
            // Keep the label identifiable before spending cells on detail
            // and description. The cap is a cell budget, not a byte count.
            var label_w = @min(max_label, @min(@as(u32, 46), budget -| 4));
            var detail_w = @min(max_detail, @min(@as(u32, 34), budget -| (max_icon + 1 + label_w + 2)));
            var desc_w = @min(max_desc, @min(@as(u32, 20), budget -| (max_icon + 1 + label_w + detail_w + 2)));
            while (max_icon + 1 + label_w + (if (detail_w > 0) 1 + detail_w else 0) +
                (if (desc_w > 0) 1 + desc_w else 0) + 2 > menu_budget and label_w > 8)
            {
                if (detail_w > 0) detail_w -= 1 else if (desc_w > 0) desc_w -= 1 else label_w -= 1;
            }
            const inner_cells: u32 = max_icon + 1 + label_w +
                (if (detail_w > 0) 1 + detail_w else 0) +
                (if (desc_w > 0) 1 + desc_w else 0);
            const box_w = @min(inner_cells + 2, menu_budget);
            // Joint menu/docs placement inside the focused pane. Doc rows
            // are wrapped at a provisional width, then rebuilt at the width
            // the planner actually granted (narrow pane/split/Agent rail).
            var lp = completion_layout.plan(.{
                .pane = .{ .row = cur_rect.row, .col = cur_rect.col, .width = cur_rect.width, .height = cur_rect.height },
                .cursor_row = cur_rect.row + c_sp.row,
                .cursor_col = pane_left + gutter + c_sp.col,
                .gutter = gutter,
                .menu_width = box_w,
                .menu_rows = list_rows,
                .doc_width = @min(@as(u32, 64), pane_width -| 4),
                .doc_total_rows = @intCast(doc_rows_list.len),
            });
            if (lp.doc.width > 2 and lp.doc.width - 2 != @min(@as(u32, 64), pane_width -| 4)) {
                const inner_width = lp.doc.width - 2;
                doc_rows_list = try buildCompletionDocRows(self, a, win, &self.completion_words.items[self.completion_sel], inner_width);
                lp = completion_layout.plan(.{
                    .pane = .{ .row = cur_rect.row, .col = cur_rect.col, .width = cur_rect.width, .height = cur_rect.height },
                    .cursor_row = cur_rect.row + c_sp.row,
                    .cursor_col = pane_left + gutter + c_sp.col,
                    .gutter = gutter,
                    .menu_width = box_w,
                    .menu_rows = list_rows,
                    .doc_width = inner_width,
                    .doc_total_rows = @intCast(doc_rows_list.len),
                });
            }
            const start_row = lp.menu.row;
            const box_col = lp.menu.col;

            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
            const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };

            // top border ╭───╮
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner_cells) : (cx += 1) try segs.append(a, .{ .text = "─", .style = border_style });
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(box_col), .wrap = .none });
            }
            k = 0;
            while (k < list_rows) : (k += 1) {
                const item = self.completion_words.items[top + k];
                const selected = top + k == self.completion_sel;
                const style = if (selected) sel_style else row_style;
                const row_bg: vaxis.Color = if (selected) .{ .rgb = self.theme.bg_sel } else .{ .rgb = self.theme.bg_float };
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "│", .style = border_style });
                const icon = if (item.kind != 0) kindGlyph(item.kind) else " ";
                const icon_color = completion.kindColor(self.theme, item.kind);
                try segs.append(a, .{ .text = icon, .style = .{ .fg = .{ .rgb = icon_color }, .bg = row_bg, .bold = selected } });
                const icon_cells: u32 = @intCast(autil.cellWidth(win, icon));
                if (icon_cells < max_icon) {
                    const pad = try a.alloc(u8, @intCast(max_icon - icon_cells));
                    @memset(pad, ' ');
                    try segs.append(a, .{ .text = pad, .style = .{ .bg = row_bg } });
                }
                try segs.append(a, .{ .text = " ", .style = .{ .bg = row_bg } });

                const lab = try completionFit(a, win, item.label, label_w);
                try segs.append(a, .{ .text = lab.slice, .style = style });
                if (lab.cells < label_w) {
                    const pad = try a.alloc(u8, @intCast(label_w - lab.cells));
                    @memset(pad, ' ');
                    try segs.append(a, .{ .text = pad, .style = .{ .bg = row_bg } });
                }
                if (detail_w > 0) {
                    try segs.append(a, .{ .text = " ", .style = .{ .bg = row_bg } });
                    const dtext = item.label_detail orelse "";
                    const det = try completionFit(a, win, dtext, detail_w);
                    try segs.append(a, .{ .text = det.slice, .style = .{
                        .fg = .{ .rgb = if (selected) self.theme.fg_dim else self.theme.fg_dim },
                        .bg = row_bg,
                    } });
                    if (det.cells < detail_w) {
                        const pad = try a.alloc(u8, @intCast(detail_w - det.cells));
                        @memset(pad, ' ');
                        try segs.append(a, .{ .text = pad, .style = .{ .bg = row_bg } });
                    }
                }
                if (desc_w > 0) {
                    try segs.append(a, .{ .text = " ", .style = .{ .bg = row_bg } });
                    const dtext = item.label_description orelse "";
                    const desc = try completionFit(a, win, dtext, desc_w);
                    if (desc.cells < desc_w) {
                        const pad = try a.alloc(u8, @intCast(desc_w - desc.cells));
                        @memset(pad, ' ');
                        try segs.append(a, .{ .text = pad, .style = .{ .bg = row_bg } });
                    }
                    try segs.append(a, .{ .text = desc.slice, .style = .{
                        .fg = .{ .rgb = if (selected) self.theme.fg_dim else self.theme.fg_faint },
                        .bg = row_bg,
                    } });
                }
                try segs.append(a, .{ .text = "│", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(box_col), .wrap = .none });
            }
            // bottom border ╰───╯
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner_cells) : (cx += 1) try segs.append(a, .{ .text = "─", .style = border_style });
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(box_col), .wrap = .none });
            }

            // Documentation pane: signature + body, wrapped and scrolled,
            // placed by the same planner. Keeps the same bg_float surface and
            // never overlaps the menu or leaves the focused pane.
            if (lp.doc.width > 2 and doc_rows_list.len > 0) {
                const doc_inner_width = lp.doc.width - 2;
                const visible = lp.doc_visible_rows;
                const scroll = @min(self.completion_doc_scroll, lp.scroll_max);
                self.completion_doc_scroll = scroll;
                const doc_border: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                // top border
                {
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = "╭", .style = doc_border });
                    var cx: u32 = 0;
                    while (cx < doc_inner_width) : (cx += 1) try segs.append(a, .{ .text = "─", .style = doc_border });
                    try segs.append(a, .{ .text = "╮", .style = doc_border });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(lp.doc.row), .col_offset = @intCast(lp.doc.col), .wrap = .none });
                }
                var dr: u32 = 0;
                while (dr < visible) : (dr += 1) {
                    const row_segs = doc_rows_list[scroll + dr];
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = "│", .style = doc_border });
                    try segs.appendSlice(a, row_segs);
                    try segs.append(a, .{ .text = "│", .style = doc_border });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(lp.doc.row + 1 + dr), .col_offset = @intCast(lp.doc.col), .wrap = .none });
                }
                // bottom border (scroll position when it overflows)
                {
                    const footer = if (lp.scroll_max > 0)
                        try std.fmt.allocPrint(a, "{d}/{d}  ^F/^B", .{ scroll + 1, doc_rows_list.len })
                    else
                        "";
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = "╰", .style = doc_border });
                    var used: u32 = 0;
                    if (footer.len > 0) {
                        const fit = autil.cellFitPrefix(win, footer, doc_inner_width -| 2);
                        try segs.append(a, .{ .text = " ", .style = doc_border });
                        try segs.append(a, .{ .text = fit.slice, .style = doc_border });
                        used = 1 + @as(u32, @intCast(fit.cells));
                    }
                    while (used < doc_inner_width) : (used += 1) try segs.append(a, .{ .text = "─", .style = doc_border });
                    try segs.append(a, .{ .text = "╯", .style = doc_border });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(lp.doc.row + lp.doc.height - 1), .col_offset = @intCast(lp.doc.col), .wrap = .none });
                }
            }
        }

        // Ghost text: the suffix of the selected item beyond the typed
        // prefix, shown dimmed right after the cursor (VS Code style).
        // Only when the item actually extends the typed prefix.
        if (self.state.mode == .insert and self.completion_sel < total) {
            const item = self.completion_words.items[self.completion_sel].insertText();
            const typed_len = self.curCursor().* - self.completion_pos;
            const ghost_line = self.cur().pt.lineOf(self.curCursor().*);
            const g_sp = self.focusedScreenPos(win, cur_rect, ghost_line, self.curCursor().*);
            const ghost_row = cur_rect.row + g_sp.row;
            // Horizontal separators currently overlay a leaf's edge row.
            // A virtual suffix must not repaint that neighbouring boundary.
            var on_separator = false;
            for (layout.seps) |sep| {
                if (sep.horizontal and sep.row == ghost_row) on_separator = true;
            }
            if (!on_separator and item.len > typed_len and typed_len > 0 and typed_len < 256 and g_sp.row < cur_rect.height) {
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
                        const ghost_start = cur_rect.col + gutter + g_sp.col;
                        const pane_end = cur_rect.col + cur_rect.width;
                        // The pane's right edge is a CELL budget: a ghost
                        // containing non-ASCII glyphs must be cut by width,
                        // not by bytes (and a byte test let wide glyphs
                        // spill into a split's neighbour).
                        if (ghost_start < pane_end) {
                            const fits = buffer.utf8.truncateWidth(ghost, pane_end - ghost_start);
                            if (fits.len > 0) {
                                const seg = [_]vaxis.Segment{.{
                                    .text = fits,
                                    .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_curline } },
                                }};
                                _ = win.print(&seg, .{
                                    .row_offset = @intCast(cur_rect.row + g_sp.row),
                                    .col_offset = @intCast(ghost_start),
                                    .wrap = .none,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    // Explicit diagnostic floats are modal and stay above terminal surfaces.
    _ = try @import("diagnostics.zig").draw(self, a, win, cur_rect, .floating);

    // Explicit K documentation owns a pane-bounded, scrollable rich-text
    // viewport. Automatic signatures retain their short passive window.
    if (self.nav_hover_text) |htext| {
        if (htext.len > 0 and self.navHoverAlive()) {
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const pos = self.focusedScreenPos(win, cur_rect, line, self.curCursor().*);
            const pane = completion_layout.Rect{ .row = cur_rect.row, .col = cur_rect.col, .width = cur_rect.width, .height = cur_rect.height };
            if (self.nav_hover_action == .hover) {
                try drawHoverDocument(self, a, win, htext, pane, pane.row + pos.row, pane.col + gutter + pos.col);
            } else {
                drawSignature(self, win, htext, pane, pane.row + pos.row, pane.col + gutter + 1);
            }
        }
    }

    // Paint one status row after document overlays. The pure planner owns
    // the information priority; the renderer only measures text in cells and
    // draws the placed segments. Agent state keeps a right-hand reservation.
    self.drawStatusChrome(win);
    const t = self.theme;
    const status_bg = chrome.bandStyle(t).bg;
    const status_row: u32 = height - 1;
    const doc_col = self.lineCellCol(win, cursor_line, self.curCursor().*);

    const mode_text: []const u8 = if (self.pending_window) "Ctrl-w … " else switch (self.state.mode) {
        .normal => "[NORMAL] ",
        .insert => "[INSERT] ",
        .visual_char, .visual_line, .visual_block => "[VISUAL] ",
        .command => "[COMMAND]",
    };
    const mode_role: statusline.Role = switch (self.state.mode) {
        .normal => .mode_normal,
        .insert => .mode_insert,
        .visual_char, .visual_line, .visual_block => .mode_visual,
        .command => .mode_command,
    };

    var pos_buf: [64]u8 = undefined;
    // Keep the established, testable wording while sourcing the column from
    // document cells (not `screenCellCol`, which includes inlay hints).
    const known_total = self.cur().pt.knownLineCount();
    const pos_text = if (known_total) |n|
        std.fmt.bufPrint(&pos_buf, "line {d}/{d} col {d}", .{ cursor_line + 1, n, doc_col }) catch "?"
    else
        std.fmt.bufPrint(&pos_buf, "line {d}/… col {d}", .{ cursor_line + 1, doc_col }) catch "?";

    var lsp_buf: [64]u8 = undefined;
    var lsp_text: ?[]const u8 = null;
    var lsp_connected = false;
    if (self.lsp_client) |c| {
        lsp_text = std.fmt.bufPrint(&lsp_buf, "[{s}]", .{lspServerName(c.lang)}) catch null;
        lsp_connected = true;
    } else if (self.lsp_starting) |job| {
        lsp_text = std.fmt.bufPrint(&lsp_buf, "[{s}…]", .{lspServerName(job.lang)}) catch null;
    }

    const ft = autil.filetypeOf(self.cur().path);
    var ft_buf: [32]u8 = undefined;
    const ft_text: ?[]const u8 = if (ft.len > 0)
        (std.fmt.bufPrint(&ft_buf, "{s}", .{ft}) catch null)
    else
        null;

    // Real git counts (marked lines), not a guessed summary.
    const diff_counts = self.git_diff.counts();
    var diff_text: ?[]const u8 = null;
    if (diff_counts.any()) {
        var db: std.ArrayList(u8) = .empty;
        if (diff_counts.added > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "+{d} ", .{diff_counts.added})) catch {};
        if (diff_counts.modified > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "~{d} ", .{diff_counts.modified})) catch {};
        if (diff_counts.removed > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "-{d} ", .{diff_counts.removed})) catch {};
        const trimmed = std.mem.trim(u8, db.items, " ");
        if (trimmed.len > 0) diff_text = try a.dupe(u8, trimmed);
    }

    // Honest diagnostic counts: only severities the server actually sent.
    var diag_text: ?[]const u8 = null;
    {
        var errs: u32 = 0;
        var warns: u32 = 0;
        var infos: u32 = 0;
        var hints: u32 = 0;
        for (self.lsp_diagnostics.items) |d| switch (d.severity) {
            .err => errs += 1,
            .warning => warns += 1,
            .info => infos += 1,
            .hint => hints += 1,
        };
        if (errs + warns + infos + hints > 0) {
            var db: std.ArrayList(u8) = .empty;
            if (errs > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "E{d} ", .{errs})) catch {};
            if (warns > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "W{d} ", .{warns})) catch {};
            if (infos > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "I{d} ", .{infos})) catch {};
            if (hints > 0) db.appendSlice(a, try std.fmt.allocPrint(a, "H{d} ", .{hints})) catch {};
            const trimmed = std.mem.trim(u8, db.items, " ");
            if (trimmed.len > 0) diag_text = try a.dupe(u8, trimmed);
        }
    }

    var rec_buf: [24]u8 = undefined;
    const rec_text: ?[]const u8 = if (self.macro_rec) |r|
        (std.fmt.bufPrint(&rec_buf, "REC @{c}", .{@as(u8, @intCast('a' + r))}) catch null)
    else
        null;

    var progress_buf: [32]u8 = undefined;
    const progress_text: ?[]const u8 = blk: {
        if (win.width < 88) break :blk null;
        if (cursor_line == 0) break :blk "Top";
        const line_count = known_total orelse break :blk null;
        if (cursor_line + 1 >= line_count) break :blk "Bot";
        const pct = (@as(u64, cursor_line + 1) * 100) / @as(u64, line_count);
        break :blk std.fmt.bufPrint(&progress_buf, "{d}%", .{pct}) catch null;
    };

    // Agent text keeps its existing responsive ladder; the planner reserves
    // the resulting cells on the right before placing services/position.
    var ai_text: ?[]const u8 = null;
    var ai_cells: u32 = 0;
    if (!self.hints.active and (self.msg == null or self.aiApprovalAttention())) {
        const ai_budget = @min(win.width / 3, 48);
        if (ai_budget > 0) {
            if (try self.aiStatusText(a)) |full| {
                ai_text = full;
                ai_cells = @intCast(autil.cellWidth(win, full));
                if (ai_cells > ai_budget) {
                    if (try self.aiStatusTextCompact(a)) |compact| {
                        ai_text = compact;
                        ai_cells = @intCast(autil.cellWidth(win, compact));
                    }
                }
                if (ai_cells > ai_budget) {
                    if (try self.aiStatusTextMini(a)) |mini| {
                        ai_text = mini;
                        ai_cells = @intCast(autil.cellWidth(win, mini));
                    }
                }
                if (ai_cells > ai_budget) {
                    const fit = autil.cellFitSuffix(win, ai_text.?, ai_budget -| 1);
                    ai_text = try std.fmt.allocPrint(a, "{s}{s}", .{ tabstrip.ellipsis, fit.slice });
                    ai_cells = ai_budget;
                }
            }
        }
    }

    // Workspace identity is its own dimension (not a buffer tab): keep the
    // name visible even in a single-workspace session so workspace switching
    // is observable, but let the planner drop it on narrow rows.
    var ws_buf: [128]u8 = undefined;
    const ws_text: ?[]const u8 = std.fmt.bufPrint(&ws_buf, "[{s}]", .{self.curWsName()}) catch null;

    var branch_buf: [96]u8 = undefined;
    const branch_text: ?[]const u8 = if (self.git_branch) |b| blk: {
        const trimmed = std.mem.trim(u8, b, " \t\r\n");
        if (trimmed.len == 0) break :blk null;
        break :blk std.fmt.bufPrint(&branch_buf, "⎇ {s}", .{trimmed}) catch null;
    } else null;

    const search_count = try self.searchCountText(a);
    const model = statusline.Model{
        .search = if (search_count) |txt| .{ .text = txt, .cells = @intCast(txt.len), .role = .search } else null,
        .mode = .{ .text = mode_text, .cells = @intCast(autil.cellWidth(win, mode_text)), .role = mode_role },
        .dirty = self.cur().dirty,
        .branch = if (branch_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .branch } else null,
        .diff = if (diff_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .diff_add } else null,
        .diagnostics = if (diag_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .diag_error } else null,
        .message = if (self.msg) |m| .{ .text = m, .cells = @intCast(autil.cellWidth(win, m)), .role = .message } else null,
        .recording = if (rec_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .recording } else null,
        .workspace = if (ws_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .secondary } else null,
        .agent = if (ai_text) |txt| .{ .text = txt, .cells = ai_cells, .role = .agent } else null,
        .lsp = if (lsp_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .lsp } else null,
        .filetype = if (ft_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .filetype } else null,
        .position = .{ .text = pos_text, .cells = @intCast(autil.cellWidth(win, pos_text)), .role = .position },
        .progress = if (progress_text) |txt| .{ .text = txt, .cells = @intCast(autil.cellWidth(win, txt)), .role = .progress } else null,
        .completion_marker = if (self.completion_slot != null) statusline.Item{ .text = "…", .cells = 1, .role = .muted } else null,
    };
    const status_plan = statusline.plan(model, win.width);

    for (status_plan.slice()) |seg| {
        if (seg.x >= win.width or seg.cells == 0) continue;
        var style: vaxis.Style = .{ .fg = .{ .rgb = t.fg }, .bg = status_bg };
        switch (seg.item.role) {
            .mode_normal, .mode_insert, .mode_visual, .mode_command => {
                const bg = switch (seg.item.role) {
                    .mode_normal => t.accent_alt,
                    .mode_insert => t.git_add,
                    .mode_visual => t.keyword,
                    .mode_command => t.accent,
                    else => unreachable,
                };
                const on_light = theme.contrastRatio(bg, t.bg) >= theme.contrastRatio(bg, t.fg);
                style = .{
                    .fg = .{ .rgb = if (on_light) t.bg else t.fg },
                    .bg = .{ .rgb = bg },
                    .bold = true,
                };
            },
            .separator => style = .{ .fg = .{ .rgb = t.win_sep }, .bg = status_bg },
            .muted => style = .{ .fg = .{ .rgb = t.fg_faint }, .bg = status_bg },
            .secondary, .branch, .filetype, .progress => style = .{ .fg = .{ .rgb = t.fg_dim }, .bg = status_bg },
            .dirty => style = .{ .fg = .{ .rgb = t.accent }, .bg = status_bg, .bold = true },
            .diff_add => style = .{ .fg = .{ .rgb = t.git_add }, .bg = status_bg },
            .diff_del => style = .{ .fg = .{ .rgb = t.git_del }, .bg = status_bg },
            .diag_error => style = .{ .fg = .{ .rgb = t.diag_error }, .bg = status_bg },
            .diag_warn => style = .{ .fg = .{ .rgb = t.diag_warn }, .bg = status_bg },
            .diag_info => style = .{ .fg = .{ .rgb = t.diag_info }, .bg = status_bg },
            .lsp => style = .{ .fg = .{ .rgb = if (lsp_connected) t.accent_alt else t.fg_faint }, .bg = status_bg },
            .position => style = .{ .fg = .{ .rgb = t.fg }, .bg = status_bg, .bold = true },
            .search => style = .{ .fg = .{ .rgb = t.accent }, .bg = status_bg },
            .message, .primary => style = .{ .fg = .{ .rgb = t.fg }, .bg = status_bg },
            .recording => style = .{ .fg = .{ .rgb = t.diag_warn }, .bg = status_bg, .bold = true },
            .agent => {
                const ai_status = self.ai.threads.activeStatus();
                style = .{
                    .fg = .{ .rgb = switch (ai_status) {
                        .streaming => t.accent,
                        .err => t.diag_error,
                        else => t.fg_dim,
                    } },
                    .bg = status_bg,
                };
            },
        }
        const fit = autil.cellFitPrefix(win, seg.item.text, seg.cells);
        if (fit.slice.len == 0) continue;
        // The mode badge owns its full reserved width so the badge shape is
        // stable while switching modes.
        if (seg.item.role == .mode_normal or seg.item.role == .mode_insert or
            seg.item.role == .mode_visual or seg.item.role == .mode_command)
        {
            var badge = win.child(.{
                .x_off = @intCast(seg.x),
                .y_off = @intCast(status_row),
                .width = @intCast(seg.cells),
                .height = 1,
            });
            badge.fill(.{ .style = .{ .bg = style.bg } });
        }
        const line = [_]vaxis.Segment{.{ .text = fit.slice, .style = style }};
        _ = win.print(&line, .{
            .row_offset = @intCast(status_row),
            .col_offset = @intCast(seg.x),
            .wrap = .none,
        });
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
    // cursor position — drawAiRail already placed the prompt/thread cursor
    // when the rail or prompt owns focus; otherwise the editor cursor wins.
    var editor_cursor_hidden = false;
    if (self.cell_edit != null) {
        editor_cursor_hidden = !try table_cell_ui.draw(self, a, win, cell_rect);
    } else if (self.inlinePromptOpen()) {
        // cursor was placed by drawInlinePrompt
    } else if (self.ai.rail_open and self.ai.focus != .editor) {
        // rail cursor was set by drawAiRail
    } else if (self.filetree_active and self.focus == .navigator) {
        // The navigator's selected row depends on the active tab (tree row,
        // note title row, or thread row); column 1 is the inner padding cell
        // shared by all three, after the left border.
        self.vx.screen.cursor = .{
            .row = @intCast(self.navigatorCursorRow(a)),
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
        editor_cursor_hidden = cur_rect.width == 0 or cur_rect.height == 0;
        // The row is recorded while painting the cursorline itself, so
        // markdown virtual rows can never make the terminal cursor and the
        // highlighted source row disagree. Columns still use byte-to-cell
        // mapping for CJK, hints and soft wrap.
        const c_sp = self.focusedScreenPos(win, cur_rect, cursor_line, self.curCursor().*);
        const cursor_col = cur_rect.col + gutter + c_sp.col;
        const cursor_row = self.rendered_cursor_row orelse cur_rect.row + @min(c_sp.row, cur_rect.height -| 1);
        // In drawer mode the editor keeps its full layout width but the
        // rail floats over it. A cursor that would sit on the rail's gutter
        // or underneath the panel is hidden rather than painted on top of
        // the drawer chrome.
        if (self.ai.rail_open) {
            const lay = self.aiLayout();
            if (lay.mode == .drawer and cursor_col >= lay.rail_col -| lay.rail_gutter) {
                editor_cursor_hidden = true;
            }
        }
        self.vx.screen.cursor = .{
            .row = @intCast(@min(@min(cursor_row, cur_rect.row + cur_rect.height -| 1), win.height -| 1)),
            .col = @intCast(@min(cursor_col, win.width -| 1)),
        };
        if (term.supported and self.term_pane != null and self.term_pane.?.visible) {
            const cursor = self.vx.screen.cursor;
            if (self.termRect(a).contains(cursor.col, cursor.row)) editor_cursor_hidden = true;
        }
    }
    self.vx.screen.cursor_vis = !editor_cursor_hidden;
    self.vx.screen.cursor_shape = if (self.state.mode == .insert) .beam else .block;

    // M2.6a: final overlay pass — labels over every collected target and the
    // compact hint indicator on the status bar. Drawn after everything else
    // (editor, rail/workbox, filetree, floats) so it is topmost.
    try self.drawHintOverlay(a, win);
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

/// True while the live gutter-mark hold is still counting after an edit
/// left the diff stale (the loop then polls instead of blocking, so the
/// buffer-vs-HEAD refresh fires once the edit hold expires — no keypress
/// needed, like the blame ghost's CursorHold). The deadline (git_marks_at)
/// is set per edit: typing hold while in insert, shorter discrete hold for
/// normal-mode ops, immediate after insert-exit.
pub fn gitHoldActive(self: *App) bool {
    if (!self.git_marks_stale) return false;
    if (self.git_marks_at <= 0) return false;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
    return now < self.git_marks_at;
}

/// True while the scope highlight animation is still spreading: the run
/// loop then polls instead of blocking in pollEvent, so the spread
/// advances frame by frame without keypresses.
pub fn scopeAnimActive(self: *App) bool {
    const a = self.scope_anim orelse return false;
    const now = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms);
    return now - a.start_ms < ScopeAnim.duration_ms;
}

/// True while a short Changes-badge flash is still inside its deadline.
/// Once this is false the run loop stops polling for it (no idle churn).
pub fn reviewFlashActive(self: *App) bool {
    return animation.flashActive(self.review_flash_start_ms, self.nowMs(), animation.badge_flash_ms);
}

/// True while any TUI animation needs frames: AI streaming/tool work, the
/// inline assistant stream, or a badge flash. Scope/blame/git holds add
/// themselves separately in the run loop. Idle editors return false, so the
/// loop blocks in pollEvent and no timer runs.
pub fn animationActive(self: *App) bool {
    return self.aiStreaming() or self.inlineStreaming() or self.reviewFlashActive();
}

pub fn run(self: *App) !void {
    try self.vx.enterAltScreen(self.tty.writer());
    // Bracketed paste (DECSET 2004): the terminal wraps pasted text in
    // paste_start/paste_end markers so it can be told apart from typed
    // keys (without it a paste IS a burst of keystrokes — each pasted
    // newline triggers Enter's auto-indent and wrecks the indentation).
    // vx.deinit resets the mode (state.bracketed_paste check there).
    try self.vx.setBracketedPaste(self.tty.writer(), true);
    // feat/mouse: enable SGR cell mouse reporting (button + wheel). A failure
    // is non-fatal (keyboard-only startup); the defer guarantees cleanup on
    // every exit path, and the explicit call before leaving the alt screen
    // restores the terminal in the normal path.
    self.enableMouse();
    defer self.disableMouse();
    try self.loop.start();
    defer self.loop.stop();
    try self.tty.writer().writeAll(vaxis.ctlseqs.kitty_graphics_query);
    try self.tty.writer().flush();
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
        const passive_ready = self.processPassiveNav();
        const comp_ready = self.processCompletion();
        const comp_resolved = self.processCompletionResolve();
        const fmt_ready = self.processFormat();
        const inlay_ready = self.processInlay();
        const outline_ready = self.processOutline();
        const diag_changed = self.diag_dirty;
        self.diag_dirty = false;
        // Consume a completed git job (status refresh / blame / hunk
        // apply): gutter marks, branch and floats update without a
        // keypress, same as the LSP slots.
        var git_ready = self.navigator_git.tick(self);
        const home_ready = try @import("picker.zig").pollHomeSearch(self);
        const mermaid_ready = @import("mermaid.zig").State.poll(self);
        if (@import("git_review.zig").poll(self)) git_ready = true;
        if (self.git_job) |job| {
            if (job.done.load(.acquire)) {
                self.consumeGitJob(job);
                git_ready = true;
            }
        }
        // AI stream events: append deltas / settle status before the frame
        // renders, like the LSP/git slots above. Repaint immediately so
        // tokens appear incrementally.
        const ai_ready = self.drainAi() catch false;
        // Background read-only tool batches (M3a): consume finished results
        // and start the automatic follow-up request. The worker never blocks
        // this loop; `aiStreaming()` keeps the poll slice short while it runs.
        const ai_tools_ready = self.drainToolJobs() catch false;
        // M3b3 approved terminal commands: a finished background job flips
        // the card to ok/error and resumes the model follow-up. Never blocks
        // the frame.
        const ai_terminal_ready = self.drainTerminal() catch false;
        // Inline assistant stream (M2b2): dedicated client, never a chat
        // thread. Repaint on deltas/completion/errors.
        const inline_ready = self.drainInline() catch false;
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
        if (nav_ready or passive_ready or comp_ready or comp_resolved or fmt_ready or inlay_ready or outline_ready or diag_changed or git_ready or home_ready or mermaid_ready or lsp_ready or term_ready or ai_ready or ai_tools_ready or ai_terminal_ready or inline_ready) {
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
        // Present the first frame before counting far-away lines. Drain input
        // between slices, and paint the final exact total even when idle.
        const indexing = self.cur().line_index_frame_seen and self.cur().pt.knownLineCount() == null;
        if (indexing) self.cur().pt.advanceLineIndex();
        var poll_transition = indexing and self.cur().pt.knownLineCount() != null;
        if (self.scopeAnimActive() or self.blameHoldActive() or self.gitHoldActive() or self.animationActive() or self.completionResolveWaiting() or (term.supported and self.term_pane != null)) {
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
        } else if (!indexing) {
            try self.loop.pollEvent();
        }
        var handled = false;
        // terminal pane focused: pasted keys are forwarded to the child
        // one by one (handleKey), byte-faithful — no accumulation needed
        const term_focused = term.supported and self.term_pane != null and self.term_pane.?.focused;
        while (try self.loop.tryEvent()) |event| {
            // One batch may click back into the editor and immediately
            // type '('. Invalidate the OLD focus after each event, before
            // the next event can create a valid new signature request.
            // defer also covers paste/terminal branches that continue.
            defer self.syncPassiveFocus();
            switch (event) {
                .mouse => |m| {
                    if (self.review.open) continue;
                    // Left press = click, wheel = scroll. Motion/drag/
                    // release/unbound buttons return false, so moving the
                    // mouse cannot cause renders or steal terminal selection.
                    if (try self.handleMouse(m)) {
                        self.prev_insert_key = null;
                        handled = true;
                    }
                },
                .key_press => |key| {
                    handled = true;
                    // mid-paste keystrokes are paste content, not input:
                    // buffer them (paste_end inserts the whole thing) so
                    // auto-indent/auto-pairs can't mangle pasted text
                    if (self.pasting and self.review.open) continue;
                    if (self.pasting and !term_focused) {
                        try self.pasteAccumulate(key);
                        continue;
                    }
                    try self.handleKey(key);
                },
                .paste_start => {
                    handled = true;
                    self.prev_insert_key = null;
                    self.pasting = true;
                    self.paste_buf.clearRetainingCapacity();
                },
                .paste_end => {
                    handled = true;
                    if (!self.pasting) continue;
                    self.pasting = false;
                    if (self.review.open) continue;
                    if (term_focused) continue; // child got the keys already
                    if (self.cell_edit != null) {
                        try table_cell_ui.paste(self, self.paste_buf.items);
                        self.paste_buf.clearRetainingCapacity();
                        continue;
                    }
                    if (self.pending_filetree_create != null) {
                        try @import("filetree.zig").filetreeCreatePaste(self, self.paste_buf.items);
                        self.paste_buf.clearRetainingCapacity();
                        continue;
                    }
                    if (self.inlinePromptOpen()) {
                        try self.inlinePaste(self.paste_buf.items);
                        self.paste_buf.clearRetainingCapacity();
                        continue;
                    }
                    if (self.ai.rail_open and self.ai.focus != .editor) {
                        if (self.ai.focus == .prompt) try self.aiPaste(self.paste_buf.items);
                        self.paste_buf.clearRetainingCapacity();
                        continue;
                    }
                    switch (self.state.mode) {
                        .insert => if (self.mc_active)
                            try self.mcInsertText(self.paste_buf.items)
                        else
                            try self.pasteText(self.paste_buf.items),
                        // normal mode: insert the paste at the cursor as one
                        // undo group (before, the paste was dropped here)
                        .normal => try self.pasteText(self.paste_buf.items),
                        .command => try self.pasteCommandText(self.paste_buf.items),
                        // Visual replacement uses its own explicit operator.
                        else => {},
                    }
                },
                .paste => |text| {
                    if (self.review.open) continue;
                    handled = true;
                    // OSC 52 clipboard reply — terminal focus: forward the
                    // paste to the child
                    if (term.supported) {
                        if (self.term_pane) |*tp| {
                            if (tp.focused) {
                                try tp.t.sendText(text);
                                continue;
                            }
                        }
                    }
                    if (self.cell_edit != null) {
                        try table_cell_ui.paste(self, text);
                    } else if (self.pending_filetree_create != null) {
                        try @import("filetree.zig").filetreeCreatePaste(self, text);
                    } else if (self.inlinePromptOpen()) {
                        try self.inlinePaste(text);
                    } else if (self.ai.rail_open and self.ai.focus != .editor) {
                        try self.aiPaste(text);
                    } else if (self.state.mode == .command) {
                        try self.pasteCommandText(text);
                    } else if (self.state.mode == .insert) {
                        if (self.mc_active) try self.mcInsertText(text) else try self.insertText(text);
                    }
                },
                .winsize => |ws| {
                    handled = true;
                    try self.vx.resize(self.alloc, self.tty.writer(), ws);
                },
                .cap_kitty_graphics => handled = true,
                else => {},
            }
        }
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
        // Live gutter marks: an edit left the diff stale. Once the edit
        // hold has expired (the user paused), refresh the buffer-vs-HEAD
        // diff async — the job wake re-renders the marks. A status job
        // already running will settle staleness itself when it lands; a
        // running blame/apply job gets a pending status so finishGitJob
        // re-spawns it as soon as the slot frees.
        if (self.git_marks_stale and !self.gitHoldActive()) {
            if (self.git_job) |job| {
                if (job.kind != .status) self.git_refresh_pending = true;
            } else if (!self.git_refresh_pending) {
                self.scheduleGitStatus();
            }
        }
        // Render on a handled event, on the poll-mode → blocking transition,
        // and on the 16ms animation cadence while polling. In blocking mode
        // an ignored event (mouse motion/drag/release, focus reports) must
        // NOT trigger a frame: mouse movement then causes no renders and no
        // busy loop (feat/mouse).
        if (handled or poll_transition or (self.poll_mode_active and now_ms - last_render_ms >= 16)) {
            try self.render();
            last_render_ms = now_ms;
        }
    }

    self.disableMouse();
    try self.vx.exitAltScreen(self.tty.writer());
}
