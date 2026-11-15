//! diagnostics — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const lsp_diag = @import("../lsp/diagnostics.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- M2 diagnostics UI ----

/// ]d / [d: jump to the next/previous diagnostic line (current file).
pub fn gotoDiagnostic(self: *App, next: bool) void {
    if (self.lsp_diagnostics.items.len == 0) return;
    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const idx: ?usize = if (next)
        lsp_diag.nextAtOrAfter(self.lsp_diagnostics.items, cursor_line + 1)
    else
        lsp_diag.prevAtOrBefore(self.lsp_diagnostics.items, cursor_line -| 1);
    const i = idx orelse return;
    const target_line = self.lsp_diagnostics.items[i].range.start.line;
    self.curCursor().* = self.cur().pt.lineStart(@min(target_line, self.cur().pt.lineCount() - 1));
}

/// gl: open the complete current-line diagnostic messages near the cursor.
pub fn showLineDiagnostics(self: *App) void {
    const line = self.cur().pt.lineOf(self.curCursor().*);
    self.clearHover();
    if (lsp_diag.lineSummary(self.lsp_diagnostics.items, line) == null) {
        const m = self.alloc.dupe(u8, "no diagnostics on this line") catch return;
        self.setMsg(m) catch return;
        return;
    }
    self.diag_float_active = true;
    self.diag_float_cursor = self.curCursor().*;
    self.diag_float_buf = self.current;
    self.diag_float_window = self.current_win;
    self.diag_float_scroll = 0;
}

/// Only scrolling and dismissal are modal; all other keys close the float
/// and retain their ordinary editor meaning.
pub fn floatKey(self: *App, key: vaxis.Key) bool {
    if (!self.diag_float_active) return false;
    if (key.codepoint == vaxis.Key.escape) {
        self.diag_float_active = false;
        return true;
    }
    if (key.mods.ctrl and (key.codepoint == 'f' or key.codepoint == 'b')) {
        if (key.codepoint == 'f') self.diag_float_scroll +|= 3 else self.diag_float_scroll -|= 3;
        return true;
    }
    self.diag_float_active = false;
    return false;
}

/// <leader>sd: toggle the diagnostics list overlay.
pub fn toggleDiagnosticsList(self: *App) void {
    if (self.diag_list_active) {
        self.diag_list_active = false;
        return;
    }
    if (self.lsp_diagnostics.items.len == 0) {
        const m = self.alloc.dupe(u8, "no diagnostics") catch return;
        self.setMsg(m) catch return;
        return;
    }
    self.diag_list_active = true;
    self.diag_list_sel = 0;
    self.diag_list_top = 0;
}

/// j/k/Enter/Esc while the diagnostics list is open; returns true if
/// consumed.
pub fn diagnosticsListKey(self: *App, key: vaxis.Key) bool {
    switch (key.codepoint) {
        vaxis.Key.escape => {
            self.diag_list_active = false;
            return true;
        },
        'j', vaxis.Key.down => {
            if (self.diag_list_sel + 1 < self.lsp_diagnostics.items.len) self.diag_list_sel += 1;
            return true;
        },
        'k', vaxis.Key.up => {
            if (self.diag_list_sel > 0) self.diag_list_sel -= 1;
            return true;
        },
        vaxis.Key.enter => {
            if (self.diag_list_sel < self.lsp_diagnostics.items.len) {
                const line = self.lsp_diagnostics.items[self.diag_list_sel].range.start.line;
                self.curCursor().* = self.cur().pt.lineStart(@min(line, self.cur().pt.lineCount() - 1));
                self.diag_list_active = false;
            }
            return true;
        },
        else => return false,
    }
}

const autil = @import("util.zig");
const types = @import("../lsp/types.zig");
const term = @import("../term.zig");

fn color(self: *App, severity: types.Severity) [3]u8 {
    return switch (severity) {
        .err => self.theme.diag_error,
        .warning => self.theme.diag_warn,
        .info, .hint => self.theme.diag_info,
    };
}

/// Decorate source text only; syntax, search and selection colors survive.
pub fn underline(self: *App, style: *vaxis.Style, severity: types.Severity) void {
    style.ul = .{ .rgb = color(self, severity) };
    style.ul_style = switch (severity) {
        .err, .warning => .curly,
        .info => .dotted,
        .hint => .dashed,
    };
}

pub fn lineRanges(self: *App, a: std.mem.Allocator, line: u32, text: []const u8) ![]const lsp_diag.ByteRange {
    var ranges: std.ArrayList(lsp_diag.ByteRange) = .empty;
    for (self.lsp_diagnostics.items) |d| {
        if (d.range.start.line > line) break; // publications are sorted
        var r = lsp_diag.byteRangeOnLine(d, line, text) orelse continue;
        // Terminals underline whole grapheme clusters. Expand a range that
        // selects a combining mark/base, without splitting the printed glyph.
        var iter = vaxis.unicode.graphemeIterator(text);
        while (iter.next()) |g| {
            if (g.start >= r.end) break;
            if (r.start > g.start and r.start < g.start + g.len) r.start = @intCast(g.start);
            if (r.end > g.start and r.end < g.start + g.len) r.end = @intCast(g.start + g.len);
        }
        try ranges.append(a, r);
    }
    return ranges.items;
}
fn safeText(a: std.mem.Allocator, text: []const u8, multiline: bool) ![]const u8 {
    const out = try a.dupe(u8, text);
    for (out) |*byte| if ((byte.* < 32 and !(multiline and byte.* == '\n')) or byte.* == 127) {
        byte.* = ' ';
    };
    return out;
}
const FloatRow = struct { text: []const u8, severity: types.Severity };
fn wrapMessage(a: std.mem.Allocator, win: vaxis.Window, rows: *std.ArrayList(FloatRow), text: []const u8, severity: types.Severity, width: u32) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try rows.append(a, .{ .text = "", .severity = severity });
            continue;
        }
        var start: usize = 0;
        var end: usize = 0;
        var cells: u32 = 0;
        var iter = vaxis.unicode.graphemeIterator(line);
        while (iter.next()) |g| {
            const w = win.gwidth(g.bytes(line));
            if (cells > 0 and cells + w > width) {
                try rows.append(a, .{ .text = line[start..end], .severity = severity });
                start = g.start;
                cells = 0;
            }
            end = g.start + g.len;
            cells += w;
        }
        try rows.append(a, .{ .text = line[start..end], .severity = severity });
    }
}
fn popupLine(win: vaxis.Window, a: std.mem.Allocator, row: u32, col: u32, text: []const u8, width: u32, style: vaxis.Style) !void {
    const fit = autil.cellFitPrefix(win, text, width);
    const blank = try a.alloc(u8, width - @as(u32, @intCast(fit.cells)));
    @memset(blank, ' ');
    const segs = [_]vaxis.Segment{ .{ .text = fit.slice, .style = style }, .{ .text = blank, .style = style } };
    _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col), .wrap = .none });
}

fn framedRule(a: std.mem.Allocator, win: vaxis.Window, label: []const u8, width: u32, left: []const u8, right: []const u8) ![]const u8 {
    const fit = autil.cellFitPrefix(win, label, width - 2);
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, left);
    try bytes.appendSlice(a, fit.slice);
    for (0..width - 2 - fit.cells) |_| try bytes.appendSlice(a, "─");
    try bytes.appendSlice(a, right);
    return bytes.toOwnedSlice(a);
}

/// Returns true when diagnostics own the cursor line's virtual-text slot,
/// so blame text cannot overlap the message. Neither mode moves the cursor.
pub fn draw(self: *App, a: std.mem.Allocator, win: vaxis.Window, rect: App.LeafRect) !bool {
    const busy = self.state.mode != .normal or self.focus != .buffer or self.hints.active or
        self.picker_active or self.diag_list_active or self.nav_list_active or self.nav_hover_text != null or
        self.git_preview != null or self.em_active or self.inlinePromptOpen() or
        (self.ai.rail_open and self.ai.focus != .editor);
    if (busy) {
        self.diag_float_active = false;
        return false;
    }
    if (term.supported) if (self.term_pane) |pane| if (pane.focused) {
        self.diag_float_active = false;
        return false;
    };
    if (self.diag_float_active and (self.current != self.diag_float_buf or self.current_win != self.diag_float_window or self.curCursor().* != self.diag_float_cursor)) self.diag_float_active = false;
    const line = self.cur().pt.lineOf(self.curCursor().*);
    const summary = lsp_diag.lineSummary(self.lsp_diagnostics.items, line) orelse {
        self.diag_float_active = false;
        return false;
    };
    const diagnostic = self.lsp_diagnostics.items[summary.index];
    const tint = color(self, diagnostic.severity);
    var pane_end = rect.col + rect.width;
    if (self.ai.rail_open) {
        const lay = self.aiLayout();
        pane_end = @min(pane_end, lay.rail_col -| lay.rail_gutter);
    }
    if (pane_end <= rect.col + 4 or rect.height == 0) return true;
    if (self.diag_float_active) {
        const columns: u32 = @min(72, pane_end - rect.col - 2);
        var rows: std.ArrayList(FloatRow) = .empty;
        for (self.lsp_diagnostics.items) |d| {
            if (!lsp_diag.coversLine(d, line)) continue;
            const safe = try safeText(a, d.message, true);
            const label = try std.fmt.allocPrint(a, "{s}: {s}", .{ lsp_diag.severityLabel(d.severity), safe });
            try wrapMessage(a, win, &rows, label, d.severity, columns);
        }
        const point = self.focusedScreenPos(win, rect, line, self.curCursor().*);
        const anchor = @min(rect.row + point.row, rect.row + rect.height - 1);
        const above = anchor - rect.row;
        const below = rect.row + rect.height - anchor - 1;
        const space = @max(above, below);
        if (space < 3 or rows.items.len == 0) return true;
        const shown: u32 = @intCast(@min(rows.items.len, @min(10, space - 2)));
        const height = shown + 2;
        const y = if (below >= height) anchor + 1 else anchor - height;
        const x = @min(rect.col + self.gutterWidth(self.cur().pt.lineCount()) + point.col, pane_end - columns - 2);
        self.diag_float_scroll = @min(self.diag_float_scroll, rows.items.len - shown);
        const border = vaxis.Style{ .fg = .{ .rgb = tint }, .bg = .{ .rgb = self.theme.bg_float } };
        const label = try std.fmt.allocPrint(a, " Diagnostics ({d}) ", .{summary.count});
        const top = try framedRule(a, win, label, columns + 2, "╭", "╮");
        try popupLine(win, a, y, x, top, columns + 2, border);
        for (rows.items[self.diag_float_scroll..][0..shown], 0..) |r, i| {
            const text = try std.fmt.allocPrint(a, "│{s}", .{r.text});
            const style = vaxis.Style{ .fg = .{ .rgb = color(self, r.severity) }, .bg = .{ .rgb = self.theme.bg_float } };
            try popupLine(win, a, y + 1 + @as(u32, @intCast(i)), x, text, columns + 2, style);
            const right = [_]vaxis.Segment{.{ .text = "│", .style = border }};
            _ = win.print(&right, .{ .row_offset = @intCast(y + 1 + i), .col_offset = @intCast(x + columns + 1), .wrap = .none });
        }
        const footer = if (rows.items.len > shown)
            try std.fmt.allocPrint(a, " {d}/{d}  ^F/^B scroll · Esc ", .{ self.diag_float_scroll + 1, rows.items.len })
        else
            "╰ Esc close";
        try popupLine(win, a, y + height - 1, x, try framedRule(a, win, footer, columns + 2, "╰", "╯"), columns + 2, border);
        return true;
    }
    const end = self.cur().pt.lineStart(line) + self.cur().pt.lineTextLen(line);
    const point = self.focusedScreenPos(win, rect, line, end);
    // An exactly full row has no room; never paint on the next source line.
    if ((point.col == 0 and end > self.cur().pt.lineStart(line)) or point.row >= rect.height) return true;
    var x = rect.col + self.gutterWidth(self.cur().pt.lineCount()) + point.col;
    if (App.foldAt(self.cur(), line)) |fold| {
        const marker = try std.fmt.allocPrint(a, " … {d} lines", .{fold.hiddenCount()});
        x += self.textWidth(win, marker);
    }
    x += 2;
    const available = pane_end -| x;
    if (available < 12) return true;
    const safe = try safeText(a, diagnostic.message, false);
    const suffix = if (summary.count > 1) try std.fmt.allocPrint(a, " +{d}", .{summary.count - 1}) else "";
    const label = try std.fmt.allocPrint(a, "← {s} {s}", .{ lsp_diag.severityMark(diagnostic.severity), safe });
    const budget = available -| @as(u32, @intCast(autil.cellWidth(win, suffix)));
    if (budget < 5) return true;
    const truncated = autil.cellWidth(win, label) > budget;
    const fit = autil.cellFitPrefix(win, label, budget - @as(u32, if (truncated) 1 else 0));
    const text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ fit.slice, if (truncated) "…" else "", suffix });
    var bg = self.theme.bg;
    for (&bg, tint) |*b, c| b.* = @intCast((@as(u16, b.*) * 4 + c) / 5);
    const segs = [_]vaxis.Segment{.{ .text = text, .style = .{ .fg = .{ .rgb = tint }, .bg = .{ .rgb = bg } } }};
    _ = win.print(&segs, .{ .row_offset = @intCast(rect.row + point.row), .col_offset = @intCast(x), .wrap = .none });
    return true;
}
