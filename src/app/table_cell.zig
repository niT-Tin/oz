//! Modal multiline editing for a single GFM table cell. Physical newlines
//! stay in the draft; the buffer stores them as <br> so the table stays valid.
const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../buffer/utf8.zig");
const wrap = @import("wrap.zig");
const prompt = @import("../ai/prompt.zig");
const editor = @import("../editor/root.zig");
const edit_range = @import("../editor/edit_range.zig");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

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
    normal: editor.Mode.State = .{},
    in_insert: bool = true,
    replace_count: ?u32 = null,
    register: ?struct { text: []u8, linewise: bool } = null,

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
        if (self.register) |reg| a.free(reg.text);
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

    fn graphemeStart(self: *const Edit, at: usize) usize {
        var it = vaxis.unicode.graphemeIterator(self.text.items);
        while (it.next()) |g| {
            if (at < g.start + g.len) return g.start;
        }
        return self.text.items.len;
    }

    fn nextGrapheme(self: *const Edit, at: usize) usize {
        var it = vaxis.unicode.graphemeIterator(self.text.items[at..]);
        return if (it.next()) |g| at + g.len else at;
    }

    pub fn normalCaret(self: *const Edit) usize {
        const start = self.lineStart();
        return if (self.cursor > start and (self.in_insert or self.cursor == self.lineEnd()))
            self.graphemeStart(self.cursor - 1)
        else
            self.graphemeStart(self.cursor);
    }

    pub fn leaveInsert(self: *Edit) void {
        self.cursor = self.normalCaret();
        self.in_insert = false;
        self.normal.mode = .normal;
        self.goal_col = null;
    }

    pub fn normalKey(self: *Edit, a: std.mem.Allocator, k: vaxis.Key) !void {
        if (self.replace_count) |count| {
            self.replace_count = null;
            const text = k.text orelse return;
            if (text.len == 0 or k.mods.ctrl or k.mods.alt or k.mods.super or
                k.mods.meta or k.mods.hyper or k.codepoint < ' ' or k.codepoint == vaxis.Key.backspace) return;
            var end = self.cursor;
            for (0..count) |_| {
                if (end == self.lineEnd()) return;
                end = self.nextGrapheme(end);
            }
            const replacement = try a.alloc(u8, try std.math.mul(usize, count, text.len));
            defer a.free(replacement);
            for (0..count) |i| @memcpy(replacement[i * text.len ..][0..text.len], text);
            try self.text.replaceRange(a, self.cursor, end - self.cursor, replacement);
            self.cursor = self.graphemeStart(self.cursor + replacement.len - text.len);
            return;
        }
        switch (editor.Mode.handle(&self.normal, k, editor.Keymaps.normal)) {
            .action => |action| try self.normalAction(a, action.action, action.count),
            .motion => |m| {
                // Vim's horizontal cursor steps in the draft follow the same
                // graphemes that the source panel displays.
                if (m.motion == .left or m.motion == .right) {
                    const start = self.lineStart();
                    const end = self.lineEnd();
                    for (0..m.count) |_| {
                        const next = if (m.motion == .left)
                            self.graphemeStart(@max(start, self.cursor -| 1))
                        else
                            self.nextGrapheme(self.cursor);
                        if (next == self.cursor or next >= end) break;
                        self.cursor = next;
                    }
                } else {
                    var pt = try PieceTable.init(a, self.text.items);
                    defer pt.deinit();
                    self.cursor = editor.Motion.target(&pt, m.motion, m.args, @intCast(self.cursor), m.count);
                    self.cursor = self.normalCaret();
                }
            },
            .op_motion => |op| try self.normalOperator(a, op),
            else => {},
        }
        // The shared parser also recognizes document and Visual commands.
        // Only the actions handled here can change the draft's mode.
        self.normal.mode = .normal;
    }

    fn normalAction(self: *Edit, a: std.mem.Allocator, action: editor.KeyEvent.ActionId, count: u32) !void {
        switch (action) {
            .insert_mode, .insert_before, .append, .append_end, .insert_line_before, .insert_line_after => {
                switch (action) {
                    .insert_before => {
                        self.cursor = self.lineStart();
                        const end = self.lineEnd();
                        while (self.cursor < end and std.ascii.isWhitespace(self.text.items[self.cursor])) self.cursor += 1;
                    },
                    .append => if (self.cursor < self.lineEnd()) {
                        self.cursor = self.nextGrapheme(self.cursor);
                    },
                    .append_end => self.cursor = self.lineEnd(),
                    .insert_line_before => {
                        self.cursor = self.lineStart();
                        try self.insert(a, "\n");
                        self.cursor -= 1;
                    },
                    .insert_line_after => {
                        self.cursor = self.lineEnd();
                        try self.insert(a, "\n");
                    },
                    else => {},
                }
                self.in_insert = true;
            },
            .delete_char, .delete_char_before => {
                var start = self.cursor;
                var end = self.cursor;
                const limit = if (action == .delete_char) self.lineEnd() else self.lineStart();
                for (0..count) |_| {
                    if (action == .delete_char) {
                        if (end == limit) break;
                        end = self.nextGrapheme(end);
                    } else {
                        if (start == limit) break;
                        start = self.graphemeStart(start - 1);
                    }
                }
                try self.applyOperator(a, .delete, start, end, false);
            },
            .delete_to_eol, .change_to_eol => try self.applyOperator(a, if (action == .delete_to_eol) .delete else .change, self.cursor, self.lineEnd(), false),
            .change_line => try self.normalOperator(a, .{ .op = .change, .motion = .line_start, .args = .{}, .count = count, .exclusive_end = false }),
            .replace_char => self.replace_count = count,
            .paste, .paste_before => if (self.register) |reg| {
                const after = action == .paste;
                const end = self.lineEnd();
                const append_line = reg.linewise and after and end == self.text.items.len;
                const size = try std.math.mul(usize, reg.text.len, count);
                try self.text.ensureUnusedCapacity(a, try std.math.add(usize, size, @intFromBool(append_line)));
                if (reg.linewise) {
                    self.cursor = if (after) @min(end + 1, self.text.items.len) else self.lineStart();
                    if (append_line) {
                        self.text.appendAssumeCapacity('\n');
                        self.cursor += 1;
                    }
                } else if (after and self.cursor < end) self.cursor = self.nextGrapheme(self.cursor);
                const pos = self.cursor;
                for (0..count) |_| {
                    self.text.insertSliceAssumeCapacity(self.cursor, reg.text);
                    self.cursor += reg.text.len;
                }
                if (append_line) _ = self.text.pop();
                if (reg.linewise) {
                    self.cursor = pos;
                    self.cursor = self.normalCaret();
                } else {
                    self.cursor = self.graphemeStart(self.cursor - 1);
                }
            },
            else => {},
        }
    }

    fn normalOperator(self: *Edit, a: std.mem.Allocator, op: editor.OpMotion) !void {
        var pt = try PieceTable.init(a, self.text.items);
        defer pt.deinit();
        const from: u32 = @intCast(self.cursor);
        if (op.text_object) |kind| {
            const range = editor.TextObject.range(&pt, kind, from, op.count);
            return self.applyOperator(a, op.op, range.start, range.end, false);
        }
        if (!op.exclusive_end) {
            const to = switch (op.motion) {
                .line_start => pt.lineStart(@min(pt.lineOf(from) +| (op.count - 1), pt.lineCount() - 1)),
                .view_top_line, .view_middle_line, .view_bottom_line => return,
                else => editor.Motion.target(&pt, op.motion, op.args, from, op.count),
            };
            const range = edit_range.linewise(&pt, from, to);
            const end = if (op.op == .change and range.end > range.start and pt.byteAt(range.end - 1) == '\n') range.end - 1 else range.end;
            return self.applyOperator(a, op.op, range.start, end, true);
        }
        const to = switch (op.motion) {
            .find, .find_back => editor.Motion.findTarget(&pt, from, op.args.ch, if (op.motion == .find) 1 else -1, op.count) orelse return,
            .till, .till_back => editor.Motion.tillTarget(&pt, from, op.args.ch, if (op.motion == .till) 1 else -1, op.count) orelse return,
            else => editor.Motion.target(&pt, op.motion, op.args, from, op.count),
        };
        const start = self.graphemeStart(@min(from, to));
        const last = self.graphemeStart(@max(from, to));
        const end = if (op.inclusive and last < self.text.items.len and self.text.items[last] != '\n')
            self.nextGrapheme(last)
        else if (last < @max(from, to))
            self.nextGrapheme(last)
        else
            last;
        try self.applyOperator(a, op.op, start, end, false);
    }

    fn applyOperator(self: *Edit, a: std.mem.Allocator, op: editor.KeyEvent.ActionId, start: usize, end: usize, linewise: bool) !void {
        if (end > start or linewise) {
            const text = self.text.items[start..end];
            const captured = if (linewise and !std.mem.endsWith(u8, text, "\n"))
                try std.mem.concat(a, u8, &.{ text, "\n" })
            else
                try a.dupe(u8, text);
            if (self.register) |reg| a.free(reg.text);
            self.register = .{ .text = captured, .linewise = linewise };
            if (op == .yank) return;
            const remove_at = if (linewise and op == .delete and end == self.text.items.len and start > 0)
                start - 1
            else
                start;
            self.text.replaceRangeAssumeCapacity(remove_at, end - remove_at, "");
            self.cursor = prompt.clampCursor(self.text.items, remove_at);
        } else if (op == .change) {
            self.cursor = self.graphemeStart(start);
        }
        self.in_insert = op == .change;
        if (!self.in_insert) self.cursor = self.normalCaret();
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

test "table cell: counted Normal deletes and puts preserve whole graphemes" {
    const a = std.testing.allocator;
    const source = "e\u{301}👩‍💻Z";
    var edit = try Edit.init(a, .{
        .start = 0,
        .end = source.len,
        .outer_start = 0,
        .outer_end = source.len,
    }, 0, 1, 0, source, 0);
    defer edit.deinit(a);
    edit.leaveInsert();
    try edit.normalKey(a, .{ .codepoint = '2' });
    try edit.normalKey(a, .{ .codepoint = 'x' });
    try std.testing.expectEqualStrings("Z", edit.text.items);
    try edit.normalKey(a, .{ .codepoint = 'P' });
    try std.testing.expectEqualStrings(source, edit.text.items);
    try std.testing.expectEqual(@as(usize, "e\u{301}".len), edit.cursor);
}
