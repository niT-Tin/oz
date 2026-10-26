const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const syntax = @import("../syntax.zig");

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
    before: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    prefix: []const u8 = "",
    display_width: u32 = 0,
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

const Row = struct {
    line: u32,
    start: u32,
    end: u32,
    cells: []Cell,
};

const Alignment = enum { left, right, center };

pub fn build(
    a: std.mem.Allocator,
    pt: *const buffer.PieceTable,
    decors: []const syntax.Decor,
    win: vaxis.Window,
    content_width: u32,
    document_path: ?[]const u8,
) !*Layout {
    const layout = try a.create(Layout);
    layout.* = .{ .entries = std.AutoHashMap(u32, Line).init(a) };
    for (decors) |d| {
        if (d.kind == .table) {
            const first = pt.lineOf(d.start);
            if (!layout.entries.contains(first)) try buildTable(a, pt, decors, win, layout, d);
        }
    }
    for (decors) |d| {
        if (d.kind == .fence) try buildFence(a, pt, decors, win, layout, d, content_width);
        if (d.kind == .image) try buildImage(a, pt, decors, layout, d, document_path);
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
) !void {
    const first = pt.lineOf(table.start);
    const last = pt.lineOf(table.end -| 1);
    var widths = std.ArrayList(u32).empty;
    var aligns = std.ArrayList(Alignment).empty;
    var rows = std.ArrayList(Row).empty;
    for (decors) |d| {
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
    while (line <= last) : (line += 1) {
        var is_delimiter = false;
        for (decors) |d| {
            if (d.kind == .table_delimiter and d.start < table.end and d.end > table.start and pt.lineOf(d.start) == line) {
                is_delimiter = true;
                break;
            }
        }
        if (is_delimiter) continue;
        const start = pt.lineStart(line);
        const end = start + pt.lineLen(line);
        var cells = std.ArrayList(Cell).empty;
        for (decors) |d| {
            if (d.kind != .table_cell or d.start < start or d.start >= end or d.end > table.end) continue;
            const cell_text = try copyRange(a, pt, d.start, d.end);
            const lead = std.mem.indexOfNone(u8, cell_text, " \t") orelse cell_text.len;
            const cs = d.start + @as(u32, @intCast(lead));
            const ce = if (lead == cell_text.len) cs else d.start + @as(u32, @intCast((std.mem.lastIndexOfNone(u8, cell_text, " \t").? + 1)));
            const width = if (ce > cs) try visibleWidth(a, pt, decors, win, cs, ce) else 0;
            const col = cells.items.len;
            try cells.append(a, .{ .start = cs, .end = ce, .width = width });
            if (col >= widths.items.len) try widths.append(a, width) else widths.items[col] = @max(widths.items[col], width);
        }
        if (cells.items.len > 0) try rows.append(a, .{ .line = line, .start = start, .end = end, .cells = cells.items });
    }
    if (rows.items.len == 0 or widths.items.len == 0) return;
    while (aligns.items.len < widths.items.len) try aligns.append(a, .left);

    const top = try tableBorder(a, widths.items, "┌", "┬", "┐");
    const middle = try tableBorder(a, widths.items, "├", "┼", "┤");
    const bottom = try tableBorder(a, widths.items, "└", "┴", "┘");
    const table_width = autilWidth(win, top);
    for (rows.items, 0..) |row, ri| {
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
        const before: []const []const u8 = if (ri == 0) try a.dupe([]const u8, &.{top}) else &.{};
        const after: []const []const u8 = if (row.line == last) try a.dupe([]const u8, &.{bottom}) else &.{};
        try layout.entries.put(row.line, .{ .gaps = gaps.items, .before = before, .after = after, .display_width = table_width, .table = true });
    }
    line = first;
    while (line <= last) : (line += 1) {
        for (decors) |d| {
            if (d.kind == .table_delimiter and pt.lineOf(d.start) == line and d.start >= table.start and d.end <= table.end) {
                const start = pt.lineStart(line);
                const end = start + pt.lineLen(line);
                const after: []const []const u8 = if (line == last) try a.dupe([]const u8, &.{bottom}) else &.{};
                try layout.entries.put(line, .{ .gaps = try a.dupe(Gap, &.{.{ .start = start, .end = end, .text = middle }}), .after = after, .display_width = table_width, .table = true });
                break;
            }
        }
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

fn tableBorder(a: std.mem.Allocator, widths: []const u32, left: []const u8, join: []const u8, right: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, left);
    for (widths, 0..) |width, i| {
        var n: u32 = 0;
        while (n < width + 2) : (n += 1) try out.appendSlice(a, "─");
        try out.appendSlice(a, if (i + 1 == widths.len) right else join);
    }
    return out.items;
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

fn visibleWidth(a: std.mem.Allocator, pt: *const buffer.PieceTable, decors: []const syntax.Decor, win: vaxis.Window, start: u32, end: u32) !u32 {
    const raw = try copyRange(a, pt, start, end);
    var visible = std.ArrayList(u8).empty;
    var pos: u32 = 0;
    while (pos < raw.len) {
        var concealed: ?u32 = null;
        for (decors) |d| {
            if (d.kind != .conceal or d.start > start + pos or d.end <= start + pos or d.start < start or d.end > end) continue;
            concealed = d.end - start;
            break;
        }
        if (concealed) |next| {
            pos = next;
            continue;
        }
        try visible.append(a, raw[pos]);
        pos += 1;
    }
    return autilWidth(win, visible.items);
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

pub fn wrappedRows(win: vaxis.Window, text: []const u8, width: u32) u32 {
    return @max(1, (autilWidth(win, text) + @max(width, 1) - 1) / @max(width, 1));
}

const TestLayout = struct {
    arena: std.heap.ArenaAllocator,
    pt: buffer.PieceTable,
    hl: syntax.Highlighter,
    screen: vaxis.Screen,
    layout: *Layout,

    fn init(src: []const u8, document_path: ?[]const u8) !TestLayout {
        const alloc = std.testing.allocator;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        var pt = try buffer.PieceTable.init(alloc, src);
        errdefer pt.deinit();
        var hl = try syntax.Highlighter.init(alloc, "markdown");
        errdefer hl.deinit();
        try hl.reparse(src);
        var screen = try vaxis.Screen.init(alloc, .{ .rows = 24, .cols = 80, .x_pixel = 800, .y_pixel = 480 });
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
        const layout = try build(arena.allocator(), &pt, decors.items, win, 60, document_path);
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
    try std.testing.expectEqualStrings("┌──────┬──────┐", header.before[0]);
    try std.testing.expect(header.table);
    const delimiter = fixture.layout.get(1).?;
    try std.testing.expectEqualStrings("├──────┼──────┤", delimiter.gaps[0].text);
    const bold = fixture.layout.get(2).?;
    try std.testing.expectEqual(@as(u32, 15), bold.display_width);
    const last = fixture.layout.get(3).?;
    try std.testing.expectEqualStrings("└──────┴──────┘", last.after[0]);
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
    try std.testing.expectEqual(@as(usize, 1), delimiter.after.len);
    try std.testing.expect(std.mem.startsWith(u8, delimiter.after[0], "└"));
}
