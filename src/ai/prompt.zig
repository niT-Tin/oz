//! Single-line agent draft editing. Cursor offsets count bytes and always
//! land between extended grapheme clusters, even when an edit joins clusters.
const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../buffer/utf8.zig");
const Thread = @import("workspace.zig").Thread;

pub const Edit = enum {
    left,
    right,
    home,
    end,
    word_left,
    word_right,
    backspace,
    delete,
    kill_left,
    kill_right,
    kill_word_left,
    kill_word_right,
    yank,
};

/// An insertion or deletion can merge the clusters on either side (e.g. a
/// ZWJ between emoji). Advance to the far boundary in that case.
pub fn clampCursor(text: []const u8, offset: usize) usize {
    if (offset == 0 or offset >= text.len) return @min(offset, text.len);
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        if (g.start + g.len >= offset) return g.start + g.len;
    }
    return text.len;
}

fn word(grapheme: []const u8) bool {
    return switch (vaxis.uucode.get(.general_category, utf8.decodeAt(grapheme, 0).cp)) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other, .number_decimal_digit, .number_letter, .number_other, .mark_nonspacing, .mark_spacing_combining, .mark_enclosing, .punctuation_connector => true,
        else => false,
    };
}

fn backward(prefix: []const u8, by_word: bool) usize {
    var it = vaxis.unicode.graphemeIterator(prefix);
    var target: usize = 0;
    var in_word = false;
    while (it.next()) |g| {
        if (by_word) {
            const is_word = word(g.bytes(prefix));
            if (is_word and !in_word) target = g.start;
            in_word = is_word;
        } else target = g.start;
    }
    return target;
}

fn forward(suffix: []const u8, by_word: bool) usize {
    var it = vaxis.unicode.graphemeIterator(suffix);
    var in_word = false;
    while (it.next()) |g| {
        if (!by_word) return g.len;
        const is_word = word(g.bytes(suffix));
        if (in_word and !is_word) return g.start;
        in_word = is_word;
    }
    return suffix.len;
}

pub fn insert(t: *Thread, alloc: std.mem.Allocator, text: []const u8) !void {
    const pos = t.input_cursor;
    try t.input.insertSlice(alloc, pos, text);
    t.input_cursor = clampCursor(t.input.items, pos + text.len);
}

pub fn edit(t: *Thread, alloc: std.mem.Allocator, action: Edit) !void {
    const pos = t.input_cursor;
    const text = t.input.items;
    const target = switch (action) {
        .yank => return insert(t, alloc, t.input_kill.items),
        .home, .kill_left => 0,
        .end, .kill_right => text.len,
        .left, .backspace => backward(text[0..pos], false),
        .right, .delete => pos + forward(text[pos..], false),
        .word_left, .kill_word_left => backward(text[0..pos], true),
        .word_right, .kill_word_right => pos + forward(text[pos..], true),
    };
    if (pos == target) return;
    const start = @min(pos, target);
    const len = @max(pos, target) - start;
    switch (action) {
        .kill_left, .kill_right, .kill_word_left, .kill_word_right => {
            try t.input_kill.ensureTotalCapacity(alloc, len);
            t.input_kill.clearRetainingCapacity();
            t.input_kill.appendSliceAssumeCapacity(text[start..][0..len]);
        },
        .delete, .backspace => {},
        else => {
            t.input_cursor = target;
            return;
        },
    }
    t.input.replaceRangeAssumeCapacity(start, len, "");
    t.input_cursor = clampCursor(t.input.items, start);
}

/// Collapse CRLF once, expand tabs, and replace malformed UTF-8 before
/// committing a single edit. OSC-52 and bracketed paste use the same path.
pub fn paste(t: *Thread, alloc: std.mem.Allocator, text: []const u8) !void {
    var flat = std.ArrayList(u8).empty;
    defer flat.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const c = utf8.decodeAt(text, i);
        const bytes = text[i..][0..c.len];
        i += c.len;
        switch (c.cp) {
            '\r', '\n' => {
                if (c.cp == '\r' and i < text.len and text[i] == '\n') i += 1;
                try flat.append(alloc, ' ');
            },
            '\t' => try flat.appendSlice(alloc, "    "),
            0...8, 11, 12, 14...31, 0x7f...0x9f => {},
            0xfffd => try flat.appendSlice(alloc, "�"),
            else => try flat.appendSlice(alloc, bytes),
        }
    }
    try insert(t, alloc, flat.items);
}

test "agent prompt: edit seams, Unicode words, and invalid pasted bytes" {
    const a = std.testing.allocator;
    var t: Thread = .{ .id = 1, .title = &.{} };
    defer t.input.deinit(a);
    defer t.input_kill.deinit(a);

    for (std.enums.values(Edit)) |op| try edit(&t, a, op);
    try std.testing.expectEqual(@as(usize, 0), t.input_cursor);

    try insert(&t, a, "👩🚀");
    try edit(&t, a, .left);
    try insert(&t, a, "\u{200d}");
    try std.testing.expectEqual(t.input.items.len, t.input_cursor);
    try std.testing.expectEqual(t.input.items.len, clampCursor(t.input.items, 1));
    try edit(&t, a, .backspace);
    try std.testing.expectEqualStrings("", t.input.items);

    try paste(&t, a, "你\r\n好\tfoo_bar /cafe\u{0301}\x00\xff");
    try std.testing.expectEqualStrings("你 好    foo_bar /cafe\u{0301}�", t.input.items);
    try edit(&t, a, .kill_word_left);
    try std.testing.expectEqualStrings("cafe\u{0301}�", t.input_kill.items);
    try edit(&t, a, .word_left);
    try edit(&t, a, .kill_word_right);
    try std.testing.expectEqualStrings("你 好     /", t.input.items);
    try edit(&t, a, .yank);
    try std.testing.expectEqualStrings("你 好    foo_bar /", t.input.items);
    try edit(&t, a, .home);
    try edit(&t, a, .delete);
    try std.testing.expectEqualStrings(" 好    foo_bar /", t.input.items);
    try std.testing.expectEqual(t.input.items.len, clampCursor(t.input.items, 999));
}

test "agent prompt: failed allocation preserves text, caret and kill slot" {
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failure.allocator();
    var t: Thread = .{ .id = 1, .title = &.{} };
    defer t.input.deinit(a);
    defer t.input_kill.deinit(a);
    try insert(&t, a, "hello");
    try edit(&t, a, .left);
    failure.fail_index = failure.alloc_index;
    failure.resize_fail_index = failure.resize_index;
    const large: [256]u8 = @splat('z');
    try std.testing.expectError(error.OutOfMemory, edit(&t, a, .kill_left));
    try std.testing.expectError(error.OutOfMemory, insert(&t, a, &large));
    try std.testing.expectError(error.OutOfMemory, paste(&t, a, "x\r\ny"));
    try std.testing.expectEqualStrings("hello", t.input.items);
    try std.testing.expectEqual(@as(usize, 4), t.input_cursor);
    try std.testing.expectEqualStrings("", t.input_kill.items);
}
