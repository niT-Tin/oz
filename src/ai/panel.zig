//! Pure key classification for the AI workspace (M2a).
//!
//! Two modal surfaces share this module so their key contracts are
//! unit-testable without constructing an editor:
//!   - `classify`     prompt input (M1 semantics, plus Tab -> thread rail)
//!   - `classifyRail` thread-list / workbox navigation
const std = @import("std");
const vaxis = @import("vaxis");
const prompt = @import("prompt.zig");

pub fn threadStep(key: vaxis.Key) ?i8 {
    if (!key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.shift) return null;
    return switch (key.codepoint) {
        vaxis.Key.page_up => -1,
        vaxis.Key.page_down => 1,
        else => null,
    };
}

pub const Action = union(enum) {
    close,
    send,
    cancel,
    new_thread,
    focus_rail,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
    edit: prompt.Edit,
    text,
    ignore,
};

pub fn classify(key: vaxis.Key) Action {
    var mods = key.mods;
    mods.caps_lock = false;
    mods.num_lock = false;
    if (mods.eql(.{ .ctrl = true })) return switch (key.codepoint) {
        'c' => .cancel,
        'n' => .new_thread,
        'a' => .{ .edit = .home },
        'e' => .{ .edit = .end },
        'b' => .{ .edit = .left },
        'f' => .{ .edit = .right },
        'd' => .{ .edit = .delete },
        'k' => .{ .edit = .kill_right },
        'u' => .{ .edit = .kill_left },
        'y' => .{ .edit = .yank },
        vaxis.Key.left => .{ .edit = .word_left },
        vaxis.Key.right => .{ .edit = .word_right },
        else => .ignore,
    };
    if (mods.eql(.{ .alt = true })) return switch (key.codepoint) {
        'b' => .{ .edit = .word_left },
        'f' => .{ .edit = .word_right },
        'd' => .{ .edit = .kill_word_right },
        vaxis.Key.backspace => .{ .edit = .kill_word_left },
        else => .ignore,
    };
    if (mods.eql(.{})) switch (key.codepoint) {
        vaxis.Key.escape => return .close,
        vaxis.Key.tab => return .focus_rail,
        vaxis.Key.enter => return .send,
        vaxis.Key.up => return .scroll_up,
        vaxis.Key.down => return .scroll_down,
        vaxis.Key.page_up => return .page_up,
        vaxis.Key.page_down => return .page_down,
        vaxis.Key.left => return .{ .edit = .left },
        vaxis.Key.right => return .{ .edit = .right },
        vaxis.Key.home => return .{ .edit = .home },
        vaxis.Key.end => return .{ .edit = .end },
        vaxis.Key.delete => return .{ .edit = .delete },
        vaxis.Key.backspace => return .{ .edit = .backspace },
        else => {},
    };
    mods.shift = false;
    if (mods.eql(.{}) and key.text != null and key.text.?.len > 0) return .text;
    return .ignore;
}

/// Keys for the thread list / workbox while the rail (not the prompt) is
/// focused. All printable prompt input is impossible in this state: letters
/// are commands, which is why attaching to the prompt is explicit (Enter).
pub const RailAction = enum {
    up, // k
    down, // j
    select_thread, // Enter
    new_thread, // n or +
    tab_chat, // c
    tab_changes, // d
    tab_tools, // t
    tab_terminal, // r
    tab_next, // Tab
    tab_prev, // Shift+Tab
    focus_editor, // q / Esc
    cancel, // Ctrl+c
    ignore,
};

pub fn classifyRail(key: vaxis.Key) RailAction {
    if (key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        if (key.codepoint == 'c') return .cancel;
        if (key.codepoint == 'n') return .new_thread;
        return .ignore;
    }
    if (key.mods.alt or key.mods.super) return .ignore;
    if (key.codepoint == vaxis.Key.escape) return .focus_editor;
    if (key.codepoint == vaxis.Key.enter) return .select_thread;
    if (key.codepoint == vaxis.Key.tab) {
        return if (key.mods.shift) .tab_prev else .tab_next;
    }
    return switch (key.codepoint) {
        'j' => .down,
        'k' => .up,
        'n', '+' => .new_thread,
        'q' => .focus_editor,
        'c' => .tab_chat,
        'd' => .tab_changes,
        't' => .tab_tools,
        'r' => .tab_terminal,
        else => .ignore,
    };
}

test "prompt keys: enter/esc/ctrl+c/ctrl+n/tab/backspace/page" {
    try std.testing.expectEqual(@as(Action, .send), classify(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(@as(Action, .close), classify(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(@as(Action, .cancel), classify(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(Action, .new_thread), classify(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(Action, .focus_rail), classify(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(Action{ .edit = .backspace }, classify(.{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqual(@as(Action, .page_up), classify(.{ .codepoint = vaxis.Key.page_up }));
    try std.testing.expectEqual(@as(Action, .page_down), classify(.{ .codepoint = vaxis.Key.page_down }));
    try std.testing.expectEqual(Action{ .edit = .kill_right }, classify(.{ .codepoint = 'k', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(Action, .scroll_up), classify(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expectEqual(@as(Action, .scroll_down), classify(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(Action{ .edit = .kill_word_left }, classify(.{ .codepoint = vaxis.Key.backspace, .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(Action, .ignore), classify(.{ .codepoint = 'w', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(Action, .ignore), classify(.{ .codepoint = 'k', .mods = .{ .ctrl = true, .shift = true } }));
}

test "prompt keys: printable text is not treated as a command" {
    try std.testing.expectEqual(@as(Action, .text), classify(.{ .codepoint = 'a', .text = "a" }));
    try std.testing.expectEqual(@as(Action, .text), classify(.{ .codepoint = 0x4F60, .text = "你" }));
    try std.testing.expectEqual(@as(Action, .text), classify(.{ .codepoint = 'n', .text = "n" }));
    try std.testing.expectEqual(@as(Action, .ignore), classify(.{ .codepoint = 'a' }));
    try std.testing.expectEqual(@as(Action, .ignore), classify(.{ .codepoint = 'a', .text = "a", .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(Action, .ignore), classify(.{ .codepoint = 'z', .mods = .{ .ctrl = true } }));
}

test "rail keys: threads, tabs, new thread, focus exit" {
    try std.testing.expectEqual(RailAction.down, classifyRail(.{ .codepoint = 'j' }));
    try std.testing.expectEqual(RailAction.up, classifyRail(.{ .codepoint = 'k' }));
    try std.testing.expectEqual(RailAction.select_thread, classifyRail(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(RailAction.new_thread, classifyRail(.{ .codepoint = 'n' }));
    try std.testing.expectEqual(RailAction.new_thread, classifyRail(.{ .codepoint = '+' }));
    try std.testing.expectEqual(RailAction.tab_chat, classifyRail(.{ .codepoint = 'c' }));
    try std.testing.expectEqual(RailAction.tab_changes, classifyRail(.{ .codepoint = 'd' }));
    try std.testing.expectEqual(RailAction.tab_tools, classifyRail(.{ .codepoint = 't' }));
    try std.testing.expectEqual(RailAction.tab_terminal, classifyRail(.{ .codepoint = 'r' }));
    try std.testing.expectEqual(RailAction.focus_editor, classifyRail(.{ .codepoint = 'q' }));
    try std.testing.expectEqual(RailAction.focus_editor, classifyRail(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(RailAction.cancel, classifyRail(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(RailAction.tab_next, classifyRail(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(RailAction.tab_prev, classifyRail(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } }));
    try std.testing.expectEqual(RailAction.ignore, classifyRail(.{ .codepoint = 'x', .text = "x" }));
    try std.testing.expectEqual(RailAction.ignore, classifyRail(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
}

test "agent thread shortcuts: only unmodified Ctrl-PageUp/Down select threads" {
    try std.testing.expectEqual(RailAction.new_thread, classifyRail(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?i8, -1), threadStep(.{ .codepoint = vaxis.Key.page_up, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?i8, 1), threadStep(.{ .codepoint = vaxis.Key.page_down, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?i8, null), threadStep(.{ .codepoint = vaxis.Key.page_up }));
    try std.testing.expectEqual(@as(?i8, null), threadStep(.{ .codepoint = vaxis.Key.page_down, .mods = .{ .ctrl = true, .alt = true } }));
}
