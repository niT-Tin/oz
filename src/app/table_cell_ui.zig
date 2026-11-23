const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const utf8 = @import("../buffer/utf8.zig");
const util = @import("util.zig");
const cells = @import("table_cell.zig");
const markdown = @import("markdown.zig");
const highlight = @import("highlight.zig");
const syntax = @import("../syntax.zig");

pub fn start(self: *App) !bool {
    if (!self.editorOwnsKeys() or self.mc_active or self.macro_rec != null or self.macro_play_depth != 0)
        return false;
    const pos = self.curCursor().*;
    const buf = self.cur();
    if (!std.mem.eql(u8, syntax.languageFor(util.filetypeOf(buf.path)) orelse "", "markdown")) return false;
    const line = buf.pt.lineOf(pos);
    const range = (try rangeAt(self, buf, line, pos)) orelse return false;
    if (self.focusedWinHeight() < 4 or self.focusedContentWidth() < 12) return false;
    const src = try self.alloc.alloc(u8, range.end - range.start);
    defer self.alloc.free(src);
    buf.pt.copyRange(range.start, src);
    self.cell_edit = try cells.Edit.init(self.alloc, range, self.current, self.windows.items[self.current_win].id, buf.history.revision, src, pos);
    self.closeCompletion();
    self.clearHover();
    self.state.mode = .insert;
    return true;
}

fn rangeAt(self: *App, buf: *App.Buffer, line: u32, pos: u32) !?cells.Range {
    if (self.markdown_frame_buf == self.current and self.markdown_frame_rev == buf.history.revision) {
        if (self.markdown_frame) |md| {
            if (md.get(line)) |info| return matchingCell(info, pos);
        }
    }
    // A batch of keys can edit or jump before a new frame is painted.
    // Never apply a source range obtained from an earlier buffer revision.
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try self.visibleSpansFor(buf, a, line, 1);
    if (buf.hl == null) return null;
    const decors = try self.visibleDecorsFor(buf, a, line, 1);
    if (decors.len == 0) return null;
    const md = try highlight.markdownForRange(buf, a, self.vx.window(), decors, line, 1, self.focusedContentWidth(), null);
    return matchingCell(md.get(line) orelse return null, pos);
}

fn matchingCell(info: markdown.Line, pos: u32) ?cells.Range {
    for (info.cells) |cell| {
        const range = cell.range;
        if (pos < range.outer_start or (pos >= range.outer_end and pos != range.start)) continue;
        return range;
    }
    return null;
}

pub fn valid(self: *App) bool {
    const cell = self.cell_edit orelse return false;
    const win = self.windows.items[self.current_win];
    return cell.buf == win.buf and cell.window_id == win.id and self.cur().history.revision == cell.revision;
}

fn close(self: *App) void {
    if (self.cell_edit) |*cell| cell.deinit(self.alloc);
    self.cell_edit = null;
    self.state.mode = .normal;
}

pub fn check(self: *App) !void {
    if (self.cell_edit != null and !valid(self)) {
        close(self);
        try self.setMsg(try self.alloc.dupe(u8, "Cell changed outside the editor"));
    }
}

pub fn key(self: *App, k: vaxis.Key) !void {
    try check(self);
    const cell = if (self.cell_edit) |*edit| edit else return;
    if (k.codepoint == 'c' and k.mods.ctrl and !k.mods.alt and !k.mods.super) return close(self);
    if (k.codepoint != vaxis.Key.escape) return cell.key(self.alloc, self.vx.window(), k);
    if (!cell.changed()) return close(self);

    const range = cell.range;
    const encoded = try cells.encode(self.alloc, cell.text.items, cell.cursor);
    defer self.alloc.free(encoded.bytes);
    // An unpadded cell ending in a backslash could escape its own delimiter.
    const replacement = if (std.mem.endsWith(u8, encoded.bytes, "\\") and
        range.end < self.cur().pt.len() and self.cur().pt.byteAt(range.end) == '|')
        try std.mem.concat(self.alloc, u8, &.{ encoded.bytes, " " })
    else
        encoded.bytes;
    defer if (replacement.ptr != encoded.bytes.ptr) self.alloc.free(replacement);
    try self.applyEdit(range.start, range.end, replacement);
    self.curCursor().* = range.start + @as(u32, @intCast(utf8.prevBoundary(encoded.bytes, encoded.cursor)));
    close(self);
}

pub fn paste(self: *App, text: []const u8) !void {
    try check(self);
    if (self.cell_edit) |*cell| try cell.paste(self.alloc, text);
}

/// Leave at least one table row visible, even if the terminal shrinks.
pub fn panelHeight(height: u32) u32 {
    return @min(height -| 1, @min(@max(height / 3, 3), 10));
}

pub fn draw(self: *App, a: std.mem.Allocator, win: vaxis.Window, rect: App.LeafRect) !bool {
    const cell = if (self.cell_edit) |*edit| edit else return false;
    if (rect.width == 0 or rect.height == 0) return false;
    const panel = win.child(.{
        .x_off = @intCast(rect.col),
        .y_off = @intCast(rect.row),
        .width = @intCast(rect.width),
        .height = @intCast(rect.height),
    });
    panel.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg_float } } });
    const title = util.cellFitPrefix(panel, " Edit cell   Esc done   Ctrl+C cancel", rect.width);
    _ = panel.print(&.{.{ .text = title.slice, .style = .{
        .bg = .{ .rgb = self.theme.bg_alt },
        .fg = .{ .rgb = self.theme.accent },
        .bold = true,
    } }}, .{ .wrap = .none });
    if (rect.height <= 1) return false;
    const left: u32 = if (rect.width > 2) 1 else 0;
    const width = @max(rect.width -| (left + 1), 1);
    cell.panel_width = width;
    const text = try a.dupe(u8, cell.text.items);
    const caret = cells.screenCaret(panel, text, cell.cursor, width);
    const first = (caret.row + 1) -| (rect.height - 1);
    var iter = cells.ScreenText.init(panel, text, width);
    while (iter.next()) |g| {
        if (g.pos.row < first or g.width == 0 or g.width > width) continue;
        const row = g.pos.row - first + 1;
        if (row >= rect.height) break;
        panel.writeCell(@intCast(left + g.pos.col), @intCast(row), .{
            .char = .{ .grapheme = g.bytes, .width = @intCast(g.width) },
            .style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } },
        });
    }
    panel.showCursor(@intCast(left + caret.col), @intCast(caret.row - first + 1));
    return true;
}
