//! Plain multiline editing for a single GFM table cell. Physical newlines
//! stay in the draft; the buffer stores them as <br> so the table stays valid.
const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../buffer/utf8.zig");
const wrap = @import("wrap.zig");
const prompt = @import("../ai/prompt.zig");

pub const Range = struct {
    start: u32,
    end: u32,
    outer_start: u32,
    outer_end: u32,
};

pub const Preview = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

pub fn breakLen(s: []const u8) usize {
    if (s.len > 0 and s[0] == '\n') return 1;
    for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |tag| {
        if (std.ascii.startsWithIgnoreCase(s, tag)) return tag.len;
    }
    return 0;
}

/// Backtick-delimited text can contain a literal <br>. Only treat it as a
/// structural break outside a complete inline code span.
pub fn codeSpanEnd(text: []const u8, at: usize) ?usize {
    const tick = 0x60;
    if (text[at] != tick or (at > 0 and text[at - 1] == tick)) return null;
    var slash = at;
    while (slash > 0 and text[slash - 1] == '\\') slash -= 1;
    if ((at - slash) % 2 != 0) return null;
    var end = at + 1;
    while (end < text.len and text[end] == tick) end += 1;
    const len = end - at;
    while (std.mem.indexOfScalarPos(u8, text, end, tick)) |close| {
        end = close + 1;
        while (end < text.len and text[end] == tick) end += 1;
        if (end - close == len) return end;
    }
    return null;
}

pub const Marker = struct {
    len: usize,
    number: ?u32 = null,
    punctuation: u8,
};

/// First-level Markdown list items. Whitespace after the marker is required
/// so a negative number or "2.0" stays ordinary text.
pub fn marker(s: []const u8) ?Marker {
    if (s.len >= 2 and s[1] == ' ' and std.mem.indexOfScalar(u8, "-+*", s[0]) != null)
        return .{ .len = 2, .punctuation = s[0] };
    var end: usize = 0;
    while (end < s.len and end < 9 and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (end == 0 or end + 1 >= s.len or (s[end] != '.' and s[end] != ')') or s[end + 1] != ' ') return null;
    return .{
        .len = end + 2,
        .number = std.fmt.parseInt(u32, s[0..end], 10) catch return null,
        .punctuation = s[end],
    };
}

pub const Decoded = struct { bytes: []u8, cursor: usize };

fn decode(a: std.mem.Allocator, src: []const u8, source_cursor: usize) !Decoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var code_end: usize = 0;
    var cursor: ?usize = null;
    while (i < src.len) {
        if (i >= source_cursor and cursor == null) cursor = out.items.len;
        const rest = src[i..];
        if (i >= code_end) if (codeSpanEnd(src, i)) |end| {
            code_end = end;
        };
        const br = if (i < code_end) 0 else breakLen(rest);
        if (br > 0) {
            try out.append(a, '\n');
            i += br;
        } else if (std.mem.startsWith(u8, rest, "\\|")) {
            try out.append(a, '|');
            i += 2;
        } else if (i >= code_end and std.mem.startsWith(u8, rest, "&#124;")) {
            try out.append(a, '|');
            i += "&#124;".len;
        } else {
            const cp = utf8.decodeAt(src, i);
            if (cp.cp == 0xfffd) {
                try out.appendSlice(a, "�");
            } else if (cp.cp >= 32 and (cp.cp < 0x7f or cp.cp > 0x9f) or cp.cp == '\t') {
                try out.appendSlice(a, rest[0..cp.len]);
            }
            i += cp.len;
        }
    }
    const pos = prompt.clampCursor(out.items, cursor orelse out.items.len);
    return .{ .bytes = try out.toOwnedSlice(a), .cursor = pos };
}

pub fn encode(a: std.mem.Allocator, text: []const u8, caret: usize) !Decoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var cursor: usize = 0;
    var slashes: usize = 0;
    for (text, 0..) |ch, i| {
        if (i == caret) cursor = out.items.len;
        switch (ch) {
            '\n' => try out.appendSlice(a, "<br>"),
            // An odd run would cancel the escape protecting a literal pipe
            // in Markdown. An entity keeps that case inside the cell too.
            '|' => try out.appendSlice(a, if (slashes % 2 == 0) "\\|" else "&#124;"),
            else => try out.append(a, ch),
        }
        slashes = if (ch == '\\') slashes + 1 else 0;
    }
    if (caret >= text.len) cursor = out.items.len;
    return .{ .bytes = try out.toOwnedSlice(a), .cursor = cursor };
}

pub const Edit = struct {
    range: Range,
    buf: usize,
    window_id: u64,
    revision: u64,
    original: []const u8,
    text: std.ArrayList(u8),
    cursor: usize,
    panel_width: u32 = 1,
    goal_col: ?u32 = null,

    pub fn init(a: std.mem.Allocator, range: Range, buf: usize, window_id: u64, revision: u64, src: []const u8, caret: u32) !Edit {
        const draft = try decode(a, src, caret -| range.start);
        errdefer a.free(draft.bytes);
        return .{
            .range = range,
            .buf = buf,
            .window_id = window_id,
            .revision = revision,
            .original = try a.dupe(u8, draft.bytes),
            .text = .fromOwnedSlice(draft.bytes),
            .cursor = draft.cursor,
        };
    }

    pub fn deinit(self: *Edit, a: std.mem.Allocator) void {
        a.free(self.original);
        self.text.deinit(a);
    }

    pub fn preview(self: *const Edit) Preview {
        return .{ .start = self.range.start, .end = self.range.end, .text = self.text.items };
    }

    pub fn changed(self: *const Edit) bool {
        return !std.mem.eql(u8, self.original, self.text.items);
    }

    pub fn insert(self: *Edit, a: std.mem.Allocator, bytes: []const u8) !void {
        try self.text.insertSlice(a, self.cursor, bytes);
        self.cursor = prompt.clampCursor(self.text.items, self.cursor + bytes.len);
        self.goal_col = null;
    }

    pub fn paste(self: *Edit, a: std.mem.Allocator, bytes: []const u8) !void {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(a);
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = utf8.decodeAt(bytes, i);
            const from = i;
            i += cp.len;
            switch (cp.cp) {
                '\r' => {
                    if (i < bytes.len and bytes[i] == '\n') i += 1;
                    try clean.append(a, '\n');
                },
                '\n' => try clean.append(a, '\n'),
                '\t' => try clean.appendSlice(a, "    "),
                0...8, 11, 12, 14...31, 0x7f...0x9f => {},
                0xfffd => try clean.appendSlice(a, "�"),
                else => try clean.appendSlice(a, bytes[from..i]),
            }
        }
        try self.insert(a, clean.items);
    }

    fn lineStart(self: *const Edit) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.text.items[0..self.cursor], '\n')) |at| at + 1 else 0;
    }

    fn lineEnd(self: *const Edit) usize {
        return std.mem.indexOfScalarPos(u8, self.text.items, self.cursor, '\n') orelse self.text.items.len;
    }

    pub fn enter(self: *Edit, a: std.mem.Allocator) !void {
        const start = self.lineStart();
        const end = self.lineEnd();
        if (self.cursor == end) {
            const line = self.text.items[start..end];
            if (marker(line)) |m| {
                if (std.mem.trim(u8, line[m.len..], " \t").len == 0) {
                    self.text.replaceRangeAssumeCapacity(start, end - start, "");
                    self.cursor = start;
                    return;
                }
                var buf: [24]u8 = undefined;
                const next = if (m.number) |n|
                    try std.fmt.bufPrint(&buf, "\n{d}{c} ", .{ n + 1, m.punctuation })
                else
                    try std.fmt.bufPrint(&buf, "\n{c} ", .{m.punctuation});
                return self.insert(a, next);
            }
        }
        try self.insert(a, "\n");
    }

    pub fn key(self: *Edit, a: std.mem.Allocator, win: vaxis.Window, k: vaxis.Key) !void {
        if (k.codepoint != vaxis.Key.up and k.codepoint != vaxis.Key.down) self.goal_col = null;
        switch (k.codepoint) {
            vaxis.Key.enter => try self.enter(a),
            vaxis.Key.home => self.cursor = self.lineStart(),
            vaxis.Key.end => self.cursor = self.lineEnd(),
            vaxis.Key.up, vaxis.Key.down => self.moveVertical(win, k.codepoint == vaxis.Key.down),
            vaxis.Key.left, vaxis.Key.backspace => {
                var it = vaxis.unicode.graphemeIterator(self.text.items[0..self.cursor]);
                var prev: usize = 0;
                while (it.next()) |g| prev = g.start;
                if (k.codepoint == vaxis.Key.backspace)
                    self.text.replaceRangeAssumeCapacity(prev, self.cursor - prev, "");
                self.cursor = prompt.clampCursor(self.text.items, prev);
            },
            vaxis.Key.right, vaxis.Key.delete => {
                var it = vaxis.unicode.graphemeIterator(self.text.items[self.cursor..]);
                const g = it.next() orelse return;
                if (k.codepoint == vaxis.Key.delete) {
                    self.text.replaceRangeAssumeCapacity(self.cursor, g.len, "");
                    self.cursor = prompt.clampCursor(self.text.items, self.cursor);
                } else self.cursor += g.len;
            },
            else => if (k.text) |s| {
                if (!k.mods.ctrl and !k.mods.alt and !k.mods.super) try self.paste(a, s);
            },
        }
    }

    fn moveVertical(self: *Edit, win: vaxis.Window, down: bool) void {
        const current = screenCaret(win, self.text.items, self.cursor, self.panel_width);
        if (!down and current.row == 0) return;
        const row = if (down) current.row + 1 else current.row - 1;
        const goal = self.goal_col orelse current.col;
        self.goal_col = goal;

        var it = ScreenText.init(win, self.text.items, self.panel_width);
        var next: ?usize = null;
        while (it.next()) |g| {
            if (g.pos.row > row) break;
            if (g.pos.row == row and (next == null or g.pos.col <= goal)) next = g.start;
        }
        const end = it.layout.cursor();
        if (end.row == row and (next == null or end.col <= goal)) next = self.text.items.len;
        if (next) |pos| self.cursor = pos;
    }
};

pub const ScreenText = struct {
    win: vaxis.Window,
    text: []const u8,
    iter: vaxis.unicode.GraphemeIterator,
    layout: wrap.Layout,

    pub fn init(win: vaxis.Window, text: []const u8, width: u32) ScreenText {
        return .{ .win = win, .text = text, .iter = vaxis.unicode.graphemeIterator(text), .layout = .{ .width = width } };
    }

    pub fn next(self: *ScreenText) ?struct { start: usize, bytes: []const u8, pos: wrap.Pos, width: u32 } {
        const g = self.iter.next() orelse return null;
        const bytes = g.bytes(self.text);
        if (std.mem.eql(u8, bytes, "\n")) {
            const pos = self.layout.pos;
            self.layout.pos = .{ .row = pos.row + 1 };
            return .{ .start = g.start, .bytes = "", .pos = pos, .width = 0 };
        }
        const shown = if (std.mem.eql(u8, bytes, "\t")) " " else bytes;
        const width: u32 = self.win.gwidth(shown);
        const pos = self.layout.place(width);
        self.layout.add(width);
        return .{ .start = g.start, .bytes = shown, .pos = pos, .width = width };
    }
};

pub fn screenCaret(win: vaxis.Window, text: []const u8, caret: usize, width: u32) wrap.Pos {
    var it = ScreenText.init(win, text, width);
    while (it.next()) |g| {
        if (g.start >= caret) return .{ .row = g.pos.row, .col = @min(g.pos.col, width -| 1) };
    }
    return it.layout.cursor();
}

test "table cell: lists, escaped pipes and multiline clipboard round trip" {
    const a = std.testing.allocator;
    var edit = try Edit.init(a, .{ .start = 0, .end = 7, .outer_start = 0, .outer_end = 7 }, 0, 1, 0, "1. 中文", 7);
    defer edit.deinit(a);
    edit.cursor = edit.text.items.len;
    try edit.enter(a);
    try edit.paste(a, "检查 | logs\r\n- 回滚");
    try edit.enter(a);
    try std.testing.expectEqualStrings("1. 中文\n2. 检查 | logs\n- 回滚\n- ", edit.text.items);
    try edit.enter(a);
    try std.testing.expectEqualStrings("1. 中文\n2. 检查 | logs\n- 回滚\n", edit.text.items);
    const saved = try encode(a, edit.text.items, edit.cursor);
    defer a.free(saved.bytes);
    try std.testing.expectEqualStrings("1. 中文<br>2. 检查 \\| logs<br>- 回滚<br>", saved.bytes);
    const roundtrip = try decode(a, saved.bytes, saved.cursor);
    defer a.free(roundtrip.bytes);
    try std.testing.expectEqualStrings(edit.text.items, roundtrip.bytes);
    try std.testing.expectEqual(edit.cursor, roundtrip.cursor);

    const verbatim = try decode(a, "\x60<br>\x60<br>- next", 0);
    defer a.free(verbatim.bytes);
    try std.testing.expectEqualStrings("\x60<br>\x60\n- next", verbatim.bytes);
}
