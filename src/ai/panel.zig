//! Pure key classification for the modal AI chat panel (M1).
//!
//! Kept separate from App so the panel's key contract is unit-testable
//! without constructing an editor.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Action = enum {
    close, // Esc
    send, // Enter
    cancel, // Ctrl+c
    clear, // Ctrl+n
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
            'n' => return .clear,
            'k' => return .scroll_up,
            'j' => return .scroll_down,
            else => return .ignore,
        }
    }
    if (key.codepoint == vaxis.Key.escape) return .close;
    if (key.codepoint == vaxis.Key.enter) return .send;
    if (key.codepoint == vaxis.Key.backspace) return .backspace;
    if (key.codepoint == vaxis.Key.page_up) return .page_up;
    if (key.codepoint == vaxis.Key.page_down) return .page_down;
    if (key.text) |t| {
        if (t.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) return .text;
    }
    return .ignore;
}

test "panel keys: enter/esc/ctrl+c/ctrl+n/backspace/page" {
    try std.testing.expectEqual(Action.send, classify(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(Action.close, classify(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(Action.cancel, classify(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.clear, classify(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.backspace, classify(.{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqual(Action.page_up, classify(.{ .codepoint = vaxis.Key.page_up }));
    try std.testing.expectEqual(Action.page_down, classify(.{ .codepoint = vaxis.Key.page_down }));
    try std.testing.expectEqual(Action.scroll_up, classify(.{ .codepoint = 'k', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.scroll_down, classify(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
}

test "panel keys: printable text is not treated as a command" {
    try std.testing.expectEqual(Action.text, classify(.{ .codepoint = 'a', .text = "a" }));
    try std.testing.expectEqual(Action.text, classify(.{ .codepoint = 0x4F60, .text = "你" }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'a' }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'a', .text = "a", .mods = .{ .alt = true } }));
    try std.testing.expectEqual(Action.ignore, classify(.{ .codepoint = 'z', .mods = .{ .ctrl = true } }));
}
