const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const syntax = @import("../syntax.zig");
const wrap = @import("wrap.zig");

pub const Gap = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

pub const Image = struct {
    destination: []const u8,
    alt: []const u8,
    path: ?[]const u8 = null,
};

pub const Line = struct {
    gaps: []const Gap = &.{},
    top_rule: ?[]const u8 = null,
    bottom_rule: ?[]const u8 = null,
    prefix: []const u8 = "",
    display_width: u32 = 0,
    wrapped_table: ?WrappedTableLine = null,
    fence: bool = false,
    table: bool = false,
    image: ?Image = null,
};

pub const Layout = struct {
    entries: std.AutoHashMap(u32, Line),

    pub fn get(self: *const Layout, line: u32) ?Line {
        return self.entries.get(line);
    }
};

const Cell = struct {
    start: u32,
    end: u32,
    width: u32,
};

pub const TableGlyph = struct {
    text: []const u8,
    start: u32,
    end: u32,
    width: u32,
};

pub const TablePart = struct {
    col: u32,
    glyphs: []const TableGlyph,
};

pub const WrappedTableLine = struct {
    chrome: []const u8,
    rows: []const std.ArrayList(TablePart),
    width: u32,
    start: u32,
    end: u32,

    pub fn cursorAt(self: WrappedTableLine, pos: u32) wrap.Pos {
        if (pos <= self.start) return .{ .row = 0, .col = 0 };
        var nearest = self.end;
        var result: wrap.Pos = .{ .row = 0, .col = self.width - 1 };
        var last: u32 = self.start;
        var last_row: u32 = 0;
        for (self.rows, 0..) |row, ri| {
            for (row.items) |part| {
                var col = part.col;
                for (part.glyphs) |g| {
                    if (pos >= g.start and pos < g.end) return .{ .row = @intCast(ri), .col = col };
                    if (pos < g.start and g.start < nearest) {
                        nearest = g.start;
                        result = .{ .row = @intCast(ri), .col = col };
                    }
                    if (g.end > last) {
                        last = g.end;
                        last_row = @intCast(ri);
                    }
                    col += g.width;
                }
            }
        }
        if (self.rows.len == 1 and self.rows[0].items.len == 0)
            return .{ .row = 0, .col = @min(pos - self.start, self.width - 1) };
        if (nearest == self.end) result.row = last_row;
        return result;
    }

    pub fn byteAt(self: WrappedTableLine, row: u32, col: u32) u32 {
        var pos = self.start;
        for (self.rows[row].items) |part| {
            var x = part.col;
            for (part.glyphs) |g| {
                if (col < x + g.width) return g.start;
                pos = g.start;
                x += g.width;
            }
        }
        return pos;
    }
};

const Row = struct {
    line: u32,
    start: u32,
    end: u32,
    cells: []Cell,
};

const Alignment = enum { left, right, center };

pub const LineRange = struct {
    start: u32,
    end: u32,

    fn contains(self: LineRange, line: u32) bool {
        return line >= self.start and line < self.end;
    }
};

pub fn build(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    decors: []const syntax.Decor,
    win: vaxis.Window,
    content_width: u32,
    document_path: ?[]const u8,
    visible: LineRange,
) !*Layout {
    const layout = try a.create(Layout);
    layout.* = .{ .entries = std.AutoHashMap(u32, Line).init(a) };
    for (decors) |d| {
        if (d.kind == .table) {
            const first = pt.lineOf(d.start);
            if (!layout.entries.contains(first)) try buildTable(a, pt, decors, win, layout, d, content_width, visible);
        }
    }
    for (decors) |d| {
        if (d.kind == .fence) try buildFence(a, pt, decors, win, layout, d, content_width);
        if (d.kind == .image and visible.contains(pt.lineOf(d.start))) try buildImage(a, pt, decors, layout, d, document_path);
    }
    return layout;
}

fn buildTable(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    decors: []const syntax.Decor,
    win: vaxis.Window,
    layout: *Layout,
    table: syntax.Decor,
    content_width: u32,
    visible: LineRange,
) !void {
    const first = pt.lineOf(table.start);
    const last = pt.lineOf(table.end -| 1);
    var widths = std.ArrayList(u32).empty;
    var minimums = std.ArrayList(u32).empty;
    var aligns = std.ArrayList(Alignment).empty;
    var rows = std.ArrayList(Row).empty;
    var delimiter: ?u32 = null;
    const first_decor = decorLowerBound(decors, table.start);
    const table_decors = decors[first_decor..decorLowerBound(decors, table.end)];
    for (table_decors) |d| {
        if (d.kind != .table_align or d.start < table.start or d.end > table.end) continue;
        const text = try copyRange(a, pt, d.start, d.end);
        const trimmed = std.mem.trim(u8, text, " \t");
        try aligns.append(a, if (trimmed.len >= 2 and trimmed[0] == ':' and trimmed[trimmed.len - 1] == ':')
            .center
        else if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ':')
            .right
        else
            .left);
    }

    var line = first;
    var decor_i: usize = 0;
    while (line <= last) : (line += 1) {
        const start = pt.lineStart(line);
        const end = start + pt.lineTextLen(line);
        const begin = decor_i;
        while (decor_i < table_decors.len and table_decors[decor_i].start < end) : (decor_i += 1) {}
        const line_decors = table_decors[begin..decor_i];
        var cells = std.ArrayList(Cell).empty;
        for (line_decors) |d| {
            if (d.kind == .table_delimiter) delimiter = line;
            if (d.kind != .table_cell or d.start < start or d.end > end) continue;
            const cell_text = try copyRange(a, pt, d.start, d.end);
            const lead = std.mem.indexOfNone(u8, cell_text, " \t") orelse cell_text.len;
            const cs = d.start + @as(u32, @intCast(lead));
            const ce = if (lead == cell_text.len) cs else d.start + @as(u32, @intCast((std.mem.lastIndexOfNone(u8, cell_text, " \t").? + 1)));
            const metrics = try tableGlyphs(a, win, cell_text[lead .. ce - d.start], cs, line_decors, null);
            const col = cells.items.len;
            try cells.append(a, .{ .start = cs, .end = ce, .width = metrics.width });
            if (col >= widths.items.len) {
                try widths.append(a, metrics.width);
                try minimums.append(a, metrics.min_width);
            } else {
                widths.items[col] = @max(widths.items[col], metrics.width);
                minimums.items[col] = @max(minimums.items[col], metrics.min_width);
            }
        }
        if (cells.items.len > 0 and visible.contains(line)) {
            try rows.append(a, .{ .line = line, .start = start, .end = end, .cells = cells.items });
        } else {
            cells.deinit(a);
        }
    }
    if (widths.items.len == 0) return;
    while (aligns.items.len < widths.items.len) try aligns.append(a, .left);

    const edge = @as(u32, win.gwidth("│"));
    const edges = edge * @as(u32, @intCast(widths.items.len + 1));
    const natural_width = sumWidths(widths.items) + edges + @as(u32, @intCast(widths.items.len * 2));
    // Keep the right edge clear of the pane boundary, including when
    // the pane ends at the terminal's autowrap column.
    const budget = content_width -| 1;
    const wrapped = natural_width > budget;
    var padding: u32 = 1;
    if (wrapped) {
        const min_width = sumWidths(minimums.items) + edges;
        // When even unpadded cells and dividers cannot fit, show editable
        // source instead of emitting a clipped or overlapping table.
        if (min_width > budget) return;
        if (min_width + @as(u32, @intCast(widths.items.len * 2)) > budget) padding = 0;
        const overhead = edges + padding * 2 * @as(u32, @intCast(widths.items.len));
        fitWidths(widths.items, minimums.items, budget - overhead);
    }
    const top = try tableBorder(a, widths.items, padding, "┌", "┬", "┐");
    const middle = try tableBorder(a, widths.items, padding, "├", "┼", "┤");
    const bottom = try tableBorder(a, widths.items, padding, "└", "┴", "┘");
    const table_width = autilWidth(win, top);
    const chrome = if (wrapped) try tableChrome(a, widths.items, padding) else "";
    for (rows.items) |row| {
        const top_rule = if (row.line == first) top else null;
        const bottom_rule = if (row.line == last) bottom else null;
        if (wrapped) {
            const parts = try wrapTableRow(a, pt, win, table_decors, row.cells, widths.items, aligns.items, padding);
            try layout.entries.put(row.line, .{
                .top_rule = top_rule,
                .bottom_rule = bottom_rule,
                .display_width = table_width,
                .table = true,
                .wrapped_table = .{ .chrome = chrome, .rows = parts, .width = table_width, .start = row.start, .end = row.end },
            });
            continue;
        }
        var gaps = std.ArrayList(Gap).empty;
        const first_cell = row.cells[0];
        try gaps.append(a, .{
            .start = row.start,
            .end = first_cell.start,
            .text = try std.mem.concat(a, u8, &.{ "│ ", try alignmentPad(a, widths.items[0], first_cell.width, aligns.items[0], true) }),
        });
        for (row.cells, 0..) |cell, ci| {
            const right_pad = try alignmentPad(a, widths.items[ci], cell.width, aligns.items[ci], false);
            if (ci + 1 < row.cells.len) {
                const next = row.cells[ci + 1];
                const left_pad = try alignmentPad(a, widths.items[ci + 1], next.width, aligns.items[ci + 1], true);
                try gaps.append(a, .{
                    .start = cell.end,
                    .end = next.start,
                    .text = try std.mem.concat(a, u8, &.{ right_pad, " │ ", left_pad }),
                });
            } else {
                var suffix = std.ArrayList(u8).empty;
                try suffix.appendSlice(a, right_pad);
                try suffix.appendSlice(a, " │");
                var missing = ci + 1;
                while (missing < widths.items.len) : (missing += 1) {
                    try appendSpaces(a, &suffix, widths.items[missing] + 2);
                    try suffix.appendSlice(a, "│");
                }
                try gaps.append(a, .{ .start = cell.end, .end = row.end, .text = suffix.items });
            }
        }
        try layout.entries.put(row.line, .{ .gaps = gaps.items, .top_rule = top_rule, .bottom_rule = bottom_rule, .display_width = table_width, .table = true });
    }
    if (delimiter) |dl| {
        if (!visible.contains(dl)) return;
        const start = pt.lineStart(dl);
        const end = start + pt.lineTextLen(dl);
        try layout.entries.put(dl, .{
            .gaps = if (wrapped) &.{} else try a.dupe(Gap, &.{.{ .start = start, .end = end, .text = middle }}),
            .bottom_rule = if (dl == last) bottom else null,
            .display_width = table_width,
            .table = true,
            .wrapped_table = if (wrapped) .{ .chrome = middle, .rows = &.{.empty}, .width = table_width, .start = start, .end = end } else null,
        });
    }
}

fn buildFence(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    decors: []const syntax.Decor,
    win: vaxis.Window,
    layout: *Layout,
    fence: syntax.Decor,
    content_width: u32,
) !void {
    var first: ?syntax.Decor = null;
    var last: ?syntax.Decor = null;
    var language: []const u8 = "code";
    for (decors) |d| {
        if (d.start < fence.start or d.end > fence.end) continue;
        if (d.kind == .fence_delimiter) {
            if (first == null or d.start < first.?.start) first = d;
            if (last == null or d.start > last.?.start) last = d;
        } else if (d.kind == .fence_info and (first == null or d.start < first.?.end + 1)) {
            const info = try copyRange(a, pt, d.start, d.end);
            language = std.mem.trim(u8, info, " \t");
            if (language.len == 0) language = "code";
        }
    }
    const open = first orelse return;
    const close = last orelse return;
    const open_line = pt.lineOf(open.start);
    const close_line = pt.lineOf(close.start);
    const label = try std.fmt.allocPrint(a, " {s} ", .{language});
    const top = try fenceBorder(a, win, "╭", "╮", label, content_width);
    const bottom = try fenceBorder(a, win, "╰", "╯", "", content_width);
    try replaceWholeLine(a, pt, layout, open_line, top, true);
    if (close.start != open.start) try replaceWholeLine(a, pt, layout, close_line, bottom, true);
    var line = open_line + 1;
    while (line < close_line) : (line += 1) {
        if (layout.entries.get(line)) |existing| {
            var changed = existing;
            changed.prefix = "│ ";
            changed.fence = true;
            try layout.entries.put(line, changed);
        } else {
            try layout.entries.put(line, .{ .prefix = "│ ", .fence = true });
        }
    }
}

fn buildImage(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    decors: []const syntax.Decor,
    layout: *Layout,
    image: syntax.Decor,
    document_path: ?[]const u8,
) !void {
    const line = pt.lineOf(image.start);
    if (line != pt.lineOf(image.end -| 1)) return;
    var destination: ?[]const u8 = null;
    for (decors) |d| {
        if (d.kind == .image_destination and d.start >= image.start and d.end <= image.end) {
            destination = try copyRange(a, pt, d.start, d.end);
            break;
        }
    }
    const dest = destination orelse return;
    var local_path: ?[]const u8 = null;
    if (dest.len > 0 and dest.len <= std.fs.max_path_bytes and
        std.mem.indexOf(u8, dest, "://") == null and !std.mem.startsWith(u8, dest, "data:"))
    {
        if (std.fs.path.isAbsolute(dest)) {
            local_path = try std.fs.path.resolve(a, &.{dest});
        } else if (document_path) |doc| {
            local_path = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(doc) orelse ".", dest });
        }
    }
    const raw = try copyRange(a, pt, image.start, image.end);
    const alt = if (std.mem.startsWith(u8, raw, "![")) blk: {
        const close = std.mem.indexOf(u8, raw, "](") orelse raw.len;
        break :blk raw[2..close];
    } else "";
    const label = if (alt.len > 0) alt else std.fs.path.basename(dest);
    const replacement = try std.fmt.allocPrint(a, "  {s} ", .{label});
    const gap = Gap{ .start = image.start, .end = image.end, .text = replacement };
    if (layout.entries.get(line)) |existing| {
        var changed = existing;
        changed.gaps = try joinGaps(a, existing.gaps, gap);
        changed.image = .{ .destination = dest, .alt = alt, .path = local_path };
        try layout.entries.put(line, changed);
    } else {
        try layout.entries.put(line, .{
            .gaps = try a.dupe(Gap, &.{gap}),
            .image = .{ .destination = dest, .alt = alt, .path = local_path },
        });
    }
}

fn replaceWholeLine(a: std.mem.Allocator, pt: *const buffer.PieceTable, layout: *Layout, line: u32, text: []const u8, is_fence: bool) !void {
    const start = pt.lineStart(line);
    const end = start + pt.lineLen(line);
    const gap = Gap{ .start = start, .end = end, .text = text };
    if (layout.entries.get(line)) |existing| {
        var changed = existing;
        changed.gaps = try joinGaps(a, existing.gaps, gap);
        changed.fence = changed.fence or is_fence;
        try layout.entries.put(line, changed);
    } else {
        try layout.entries.put(line, .{ .gaps = try a.dupe(Gap, &.{gap}), .fence = is_fence });
    }
}

fn joinGaps(a: std.mem.Allocator, old: []const Gap, gap: Gap) ![]const Gap {
    var out = try a.alloc(Gap, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = gap;
    std.mem.sort(Gap, out, {}, struct {
        fn lt(_: void, x: Gap, y: Gap) bool {
            return x.start < y.start;
        }
    }.lt);
    return out;
}

fn tableBorder(a: std.mem.Allocator, widths: []const u32, padding: u32, left: []const u8, join: []const u8, right: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, left);
    for (widths, 0..) |width, i| {
        var n: u32 = 0;
        while (n < width + 2 * padding) : (n += 1) try out.appendSlice(a, "─");
        try out.appendSlice(a, if (i + 1 == widths.len) right else join);
    }
    return out.items;
}

fn tableChrome(a: std.mem.Allocator, widths: []const u32, padding: u32) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "│");
    for (widths) |width| {
        try appendSpaces(a, &out, width + 2 * padding);
        try out.appendSlice(a, "│");
    }
    return out.items;
}

fn sumWidths(widths: []const u32) u32 {
    var total: u32 = 0;
    for (widths) |width| total += width;
    return total;
}

/// Keep narrow columns at their natural width. Cap the wider columns at a
/// common width, reserving enough room for an entire grapheme in every cell.
fn fitWidths(widths: []u32, minimums: []const u32, budget: u32) void {
    var lo: u32 = 0;
    var hi = budget + 1;
    while (lo + 1 < hi) {
        const cap = lo + (hi - lo) / 2;
        var used: u32 = 0;
        for (widths, minimums) |width, min| used += std.math.clamp(cap, min, width);
        if (used <= budget) lo = cap else hi = cap;
    }
    // Sum the fitted widths first. Zig 0.17 ReleaseFast on macOS arm64
    // miscompiles the subtracting reduction for runtime slices.
    var fitted_total: u32 = 0;
    for (widths, minimums) |width, min| fitted_total += std.math.clamp(lo, min, width);
    var remaining = budget - fitted_total;
    for (widths, minimums) |*width, min| {
        const natural = width.*;
        width.* = std.math.clamp(lo, min, natural);
        if (remaining == 0 or width.* != lo or width.* == natural) continue;
        width.* += 1;
        remaining -= 1;
    }
}

fn wrapTableRow(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    win: vaxis.Window,
    decors: []const syntax.Decor,
    cells: []const Cell,
    widths: []const u32,
    aligns: []const Alignment,
    padding: u32,
) ![]const std.ArrayList(TablePart) {
    var rows = std.ArrayList(std.ArrayList(TablePart)).empty;
    try rows.append(a, .empty);
    const edge: u32 = win.gwidth("│");
    var col = edge + padding;
    for (cells, widths[0..cells.len], aligns[0..cells.len]) |cell, width, alignment| {
        const raw = try copyRange(a, pt, cell.start, cell.end);
        var glyphs = std.ArrayList(TableGlyph).empty;
        _ = try tableGlyphs(a, win, raw, cell.start, decors, &glyphs);
        var i: usize = 0;
        var ri: usize = 0;
        while (i < glyphs.items.len) : (ri += 1) {
            const part = takeCellLine(glyphs.items, &i, width);
            if (ri == rows.items.len) try rows.append(a, .empty);
            const left = switch (alignment) {
                .left => 0,
                .center => (width - part.width) / 2,
                .right => width - part.width,
            };
            try rows.items[ri].append(a, .{ .col = col + left, .glyphs = part.glyphs });
        }
        col += width + padding * 2 + edge;
    }
    return rows.items;
}

fn takeCellLine(glyphs: []const TableGlyph, offset: *usize, width: u32) struct { glyphs: []const TableGlyph, width: u32 } {
    const start = offset.*;
    var i = start;
    var used: u32 = 0;
    var word_end: ?usize = null;
    var word_width: u32 = 0;
    while (i < glyphs.len and used + glyphs[i].width <= width) : (i += 1) {
        if (i > start and isCellSpace(glyphs[i]) and !isCellSpace(glyphs[i - 1])) {
            word_end = i;
            word_width = used;
        }
        used += glyphs[i].width;
    }
    // Prefer the latest word boundary. Split unbroken tokens and CJK text
    // at grapheme boundaries when no whitespace is available.
    if (i < glyphs.len and !isCellSpace(glyphs[i])) {
        if (word_end) |end| {
            i = end;
            used = word_width;
        }
    }
    std.debug.assert(i > start);
    offset.* = i;
    while (offset.* < glyphs.len and isCellSpace(glyphs[offset.*])) offset.* += 1;
    return .{ .glyphs = glyphs[start..i], .width = used };
}

fn isCellSpace(glyph: TableGlyph) bool {
    return std.mem.eql(u8, glyph.text, " ");
}

fn fenceBorder(a: std.mem.Allocator, win: vaxis.Window, left: []const u8, right: []const u8, label: []const u8, width: u32) ![]const u8 {
    const w = @max(width, 4);
    const fixed = autilWidth(win, left) + autilWidth(win, right) + autilWidth(win, label);
    const dashes = w -| @min(w -| 2, fixed);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, left);
    try out.appendSlice(a, label);
    var i: u32 = 0;
    while (i < dashes) : (i += 1) try out.appendSlice(a, "─");
    try out.appendSlice(a, right);
    return out.items;
}

fn alignmentPad(a: std.mem.Allocator, column_width: u32, text_width: u32, alignment: Alignment, left: bool) ![]const u8 {
    const diff = column_width -| text_width;
    const before: u32 = switch (alignment) {
        .left => 0,
        .right => diff,
        .center => diff / 2,
    };
    const count = if (left) before else diff - before;
    const out = try a.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

fn appendSpaces(a: std.mem.Allocator, out: *std.ArrayList(u8), count: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(a, ' ');
}

fn decorLowerBound(decors: []const syntax.Decor, pos: u32) usize {
    return std.sort.lowerBound(syntax.Decor, decors, pos, struct {
        fn order(p: u32, d: syntax.Decor) std.math.Order {
            return std.math.order(p, d.start);
        }
    }.order);
}

fn tableGlyphs(
    a: std.mem.Allocator,
    win: vaxis.Window,
    raw: []const u8,
    start: u32,
    decors: []const syntax.Decor,
    out: ?*std.ArrayList(TableGlyph),
) !struct { width: u32, min_width: u32 } {
    const end = start + @as(u32, @intCast(raw.len));
    var di = decorLowerBound(decors, start);
    var hidden_until = start;
    var width: u32 = 0;
    var min_width: u32 = 0;
    var iter = vaxis.unicode.graphemeIterator(raw);
    while (iter.next()) |g| {
        const source_start = start + @as(u32, @intCast(g.start));
        const source_end = source_start + @as(u32, @intCast(g.len));
        while (di < decors.len and decors[di].start < source_end) : (di += 1) {
            const d = decors[di];
            if (d.kind == .conceal and d.end <= end) hidden_until = @max(hidden_until, d.end);
        }
        if (source_start < hidden_until) continue;
        const text = g.bytes(raw);
        const tab = std.mem.eql(u8, text, "\t");
        const columns: u32 = if (tab) 1 else win.gwidth(text);
        if (columns == 0) continue;
        width += if (tab) @import("../app.zig").tab_width else columns;
        min_width = @max(min_width, columns);
        if (out) |glyphs| {
            try glyphs.append(a, .{ .text = if (tab) " " else text, .start = source_start, .end = source_end, .width = columns });
        }
    }
    return .{ .width = width, .min_width = min_width };
}

fn autilWidth(win: vaxis.Window, text: []const u8) u32 {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: u32 = 0;
    while (iter.next()) |g| cells += win.gwidth(g.bytes(text));
    return cells;
}

fn copyRange(a: std.mem.Allocator, pt: *const buffer.PieceTable, start: u32, end: u32) ![]u8 {
    const text = try a.alloc(u8, end - start);
    pt.copyRange(start, text);
    return text;
}

const TestLayout = struct {
    arena: std.heap.ArenaAllocator,
    pt: buffer.PieceTable,
    hl: syntax.Highlighter,
    screen: vaxis.Screen,
    layout: *Layout,

    fn init(src: []const u8, document_path: ?[]const u8) !TestLayout {
        return initWidth(src, document_path, 60);
    }

    fn initWidth(src: []const u8, document_path: ?[]const u8, content_width: u32) !TestLayout {
        const alloc = std.testing.allocator;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        var pt = try buffer.PieceTable.init(alloc, src);
        errdefer pt.deinit();
        var hl = try syntax.Highlighter.init(alloc, "markdown");
        errdefer hl.deinit();
        try hl.reparse(src);
        const cols: u16 = @intCast(@max(80, content_width));
        var screen = try vaxis.Screen.init(alloc, .{ .rows = 24, .cols = cols, .x_pixel = cols * 10, .y_pixel = 480 });
        errdefer screen.deinit(alloc);
        const win = vaxis.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = screen.width,
            .height = screen.height,
            .screen = &screen,
        };
        var decors = std.ArrayList(syntax.Decor).empty;
        try hl.decorInRange(0, @intCast(src.len), arena.allocator(), &decors);
        const layout = try build(arena.allocator(), &pt, decors.items, win, content_width, document_path, .{ .start = 0, .end = pt.lineCount() });
        return .{ .arena = arena, .pt = pt, .hl = hl, .screen = screen, .layout = layout };
    }

    fn deinit(self: *TestLayout) void {
        const alloc = std.testing.allocator;
        self.arena.deinit();
        self.pt.deinit();
        self.hl.deinit();
        self.screen.deinit(alloc);
    }
};

test "markdown layout: table borders, CJK widths and alignment" {
    const src =
        \\| Name | 值 |
        \\| :--- | ---: |
        \\| **oz** | 中文 |
        \\| x | y |
        \\
    ;
    var fixture = try TestLayout.init(src, null);
    defer fixture.deinit();
    const header = fixture.layout.get(0).?;
    try std.testing.expectEqualStrings("┌──────┬──────┐", header.top_rule.?);
    try std.testing.expect(header.table);
    const delimiter = fixture.layout.get(1).?;
    try std.testing.expectEqualStrings("├──────┼──────┤", delimiter.gaps[0].text);
    const bold = fixture.layout.get(2).?;
    try std.testing.expectEqual(@as(u32, 15), bold.display_width);
    const last = fixture.layout.get(3).?;
    try std.testing.expectEqualStrings("└──────┴──────┘", last.bottom_rule.?);
    try std.testing.expect(std.mem.indexOf(u8, last.gaps[1].text, "│  ") != null);
}

test "markdown layout: fence labels and body rules" {
    const src =
        \\```zig
        \\const x = 1;
        \\```
        \\
    ;
    var fixture = try TestLayout.init(src, null);
    defer fixture.deinit();
    const open = fixture.layout.get(0).?;
    try std.testing.expect(std.mem.startsWith(u8, open.gaps[0].text, "╭ zig "));
    try std.testing.expect(std.mem.endsWith(u8, open.gaps[0].text, "╮"));
    try std.testing.expectEqualStrings("│ ", fixture.layout.get(1).?.prefix);
    const close = fixture.layout.get(2).?;
    try std.testing.expect(std.mem.startsWith(u8, close.gaps[0].text, "╰"));
    try std.testing.expect(std.mem.endsWith(u8, close.gaps[0].text, "╯"));
}

test "markdown layout: local image path and remote fallback" {
    const local = "![截图](assets/demo.png)\n";
    var fixture = try TestLayout.init(local, "/tmp/docs/readme.md");
    defer fixture.deinit();
    const image = fixture.layout.get(0).?.image.?;
    try std.testing.expectEqualStrings("/tmp/docs/assets/demo.png", image.path.?);
    try std.testing.expectEqualStrings("截图", image.alt);
    try std.testing.expectEqualStrings("  截图 ", fixture.layout.get(0).?.gaps[0].text);

    const remote = "![remote](https://example.com/a.png)\n";
    var remote_fixture = try TestLayout.init(remote, "/tmp/docs/readme.md");
    defer remote_fixture.deinit();
    try std.testing.expect(remote_fixture.layout.get(0).?.image.?.path == null);
}

test "markdown layout: header-only table keeps its bottom border" {
    const src = "| A | B |\n| --- | --- |\n";
    var fixture = try TestLayout.init(src, null);
    defer fixture.deinit();
    const delimiter = fixture.layout.get(1).?;
    try std.testing.expect(std.mem.startsWith(u8, delimiter.bottom_rule.?, "└"));
}

test "markdown layout: wide tables fit borders inside the pane" {
    const src =
        \\| ID | Details | 值 |
        \\| --- | --- | ---: |
        \\| oz | a long explanation with 中文 and an emoji 👩‍💻 | 42 |
        \\
    ;
    var fixture = try TestLayout.initWidth(src, null, 26);
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u32, 25), fixture.layout.get(0).?.display_width);
    try std.testing.expectEqual(@as(u32, 25), fixture.layout.get(2).?.display_width);
}

test "markdown layout: four columns stay within even and odd cell budgets" {
    const src =
        \\| 分类 | 场景 | 操作步骤 | 完成标准 |
        \\| --- | --- | --- | --- |
        \\| 服务 | 发布 | 先检查服务状态，再处理实例。 Start with the canary deployment and wait for it to become healthy before continuing with the rest of the deployment. | 确认流量恢复并检查日志。 Check that the service has returned to its normal request rate, that alerts are quiet, and that the rollout is complete. |
        \\
    ;
    for ([_]u32{ 119, 120 }) |pane_width| {
        var fixture = try TestLayout.initWidth(src, null, pane_width);
        defer fixture.deinit();
        const header = fixture.layout.get(0).?;
        const body = fixture.layout.get(2).?;
        try std.testing.expectEqual(pane_width - 1, header.display_width);
        try std.testing.expectEqual(header.display_width, body.display_width);
        try std.testing.expect(header.top_rule != null);
        try std.testing.expect(body.bottom_rule != null);
    }
}
