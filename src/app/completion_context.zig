//! Identity of one insert-mode completion request context.
//!
//! A completion response may only open/refresh the menu when the complete
//! context it was requested for is still current. Movement (even back to the
//! same byte), closing/accepting, leaving insert, buffer/window switches and
//! focus changes all invalidate the context: `epoch` records every observed
//! transition, so returning to an identical cursor/mode cannot revive an old
//! response. The remaining fields are the fast, explicit rejectors.
//!
//! This module is pure (no App/vaxis imports) so the matching rules are
//! unit-testable in L1.
const std = @import("std");

pub const Context = struct {
    epoch: u64,
    /// App.current (buffers.items index).
    buffer: usize,
    /// App.current_win (windows.items index).
    window: usize,
    /// Byte cursor (insert point; may equal the line text end).
    cursor: u32,
    /// Monotonic document mutation counter at request time.
    edit_seq: u64,
    /// Insert session counter (Esc / re-enter produces a new session).
    insert_session: u64,
    mode: u8,
    focus: u8,
    ai_focus: u8,
    agent_focus: bool,
    terminal_focus: bool,

    pub fn matches(self: Context, other: Context) bool {
        return self.epoch == other.epoch and self.sameWithoutEpoch(other);
    }

    /// Field equality without the epoch. Used by the event guard to decide
    /// whether a new key changed the context (and therefore must bump the
    /// epoch). Kept public so tests can pin the exact identity fields.
    pub fn sameWithoutEpoch(self: Context, other: Context) bool {
        return self.buffer == other.buffer and
            self.window == other.window and
            self.cursor == other.cursor and
            self.edit_seq == other.edit_seq and
            self.insert_session == other.insert_session and
            self.mode == other.mode and
            self.focus == other.focus and
            self.ai_focus == other.ai_focus and
            self.agent_focus == other.agent_focus and
            self.terminal_focus == other.terminal_focus;
    }
};

test "completion context: epoch and every identity field reject a late response" {
    const base = Context{
        .epoch = 7,
        .buffer = 1,
        .window = 0,
        .cursor = 12,
        .edit_seq = 30,
        .insert_session = 4,
        .mode = 1,
        .focus = 0,
        .ai_focus = 0,
        .agent_focus = false,
        .terminal_focus = false,
    };
    try std.testing.expect(base.matches(base));
    try std.testing.expect(base.sameWithoutEpoch(base));

    // Bumping only the epoch (the "moved away and back" case) still rejects.
    var evolved: [11]Context = undefined;
    for (&evolved) |*e| e.* = base;
    evolved[0].epoch += 1;
    evolved[1].buffer += 1;
    evolved[2].window += 1;
    evolved[3].cursor += 1;
    evolved[4].edit_seq += 1;
    evolved[5].insert_session += 1;
    evolved[6].mode ^= 1;
    evolved[7].focus += 1;
    evolved[8].ai_focus += 1;
    evolved[9].agent_focus = true;
    evolved[10].terminal_focus = true;
    for (evolved) |ctx| {
        try std.testing.expect(!base.matches(ctx));
    }
    // Only the epoch differs for the first one; every other field differs too.
    for (evolved[1..]) |ctx| try std.testing.expect(!base.sameWithoutEpoch(ctx));
}

test "completion context: unchanged context keeps matching across refreshes" {
    const a = Context{
        .epoch = 3,
        .buffer = 2,
        .window = 1,
        .cursor = 0,
        .edit_seq = 9,
        .insert_session = 1,
        .mode = 1,
        .focus = 0,
        .ai_focus = 0,
        .agent_focus = false,
        .terminal_focus = false,
    };
    const b = a;
    try std.testing.expect(a.matches(b));
    try std.testing.expect(a.sameWithoutEpoch(b));
}
