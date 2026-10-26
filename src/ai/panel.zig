//! Pure key classification for the AI workspace (M2a).
//!
//! Two modal surfaces share this module so their key contracts are
//! unit-testable without constructing an editor:
//!   - `classify`     prompt input (M1 semantics, plus Tab -> thread rail)
//!   - `classifyRail` thread-list / workbox navigation
const std = @import("std");
const vaxis = @import("vaxis");

pub const Action = enum {
    close, // Esc -> editor focus (narrow drawer closes)
    send, // Enter
    cancel, // Ctrl+c
    new_thread, // Ctrl+n
    focus_rail, // Tab
    scroll_up, // Ctrl+k
    scroll_down, // Ctrl+j
    page_up,
    page_down,
    backspace,
    /// Printable text (the caller appends key.text verbatim).
    text,
    ignore,
};

pub fn classify(key: vaxis.Key) Action {
    if (key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        switch (key.codepoint) {
            'c' => return .cancel,
            'n' => return .new_thread,
            'k' => return .scroll_up,
            'j' => return .scroll_down,
            else => return .ignore,
        }
    }
    if (key.codepoint == vaxis.Key.escape) return .close;
    if (key.codepoint == vaxis.Key.tab) return .focus_rail;
    if (key.codepoint == vaxis.Key.enter) return .send;
    if (key.codepoint == vaxis.Key.backspace) return .backspace;
    if (key.codepoint == vaxis.Key.page_up) return .page_up;
    if (key.codepoint == vaxis.Key.page_down) return .page_down;
    if (key.text) |t| {
        if (t.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) return .text;
    }
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
    try std.testing.expectEqual(Action.send, classify(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(Action.close, classify(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(Action.cancel, classify(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.new_thread, classify(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.focus_rail, classify(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(Action.backspace, classify(.{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqual(Action.page_up, classify(.{ .codepoint = vaxis.Key.page_up }));
    try std.testing.expectEqual(Action.page_down, classify(.{ .codepoint = vaxis.Key.page_down }));
    try std.testing.expectEqual(Action.scroll_up, classify(.{ .codepoint = 'k', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.scroll_down, classify(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
}

test "prompt keys: printable text is not treated as a command" {
    try std.testing.expectEqual(Action.text, classify(.{ .codepoint = 'a', .text = "a" }));
    try std.testing.expectEqual(Action.text, classify(.{ .codepoint = 0x4F60, .text = "你" }));
    try std.testing.expectEqual(Action.text, classify(.{ .codepoint = 'n', .text = "n" }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'a' }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'a', .text = "a", .mods = .{ .alt = true } }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'z', .mods = .{ .ctrl = true } }));
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
