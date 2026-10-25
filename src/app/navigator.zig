//! Navigator tab model (DESIGN.md §18.3/§18.8, M2b1).
//!
//! Deliberately App/vaxis-independent so the tab transitions are unit-tested
//! without building an editor or a terminal. `src/app/notes.zig` owns the
//! App-facing focus/key handling; `src/app/render.zig` draws the strip.
//!
//! The three tabs are the approved left navigator: `files` (the existing
//! lazy file tree), `notes` (the markdown note list) and `agents` (a
//! navigator view of the session's real AI threads, never a second source
//! of truth).

const std = @import("std");

/// Tab order is the drawn order in the title strip.
pub const Tab = enum { files, notes, agents };

pub const count: usize = @typeInfo(Tab).@"enum".field_names.len;

pub const all = [_]Tab{ .files, .notes, .agents };

/// Position of `tab` in the strip (0-based).
pub fn index(tab: Tab) usize {
    return @backingInt(tab);
}

/// Tab at strip position `i` (wrapping, so callers cannot index out of
/// bounds when cycling).
pub fn fromIndex(i: i32) Tab {
    return all[@intCast(@mod(i, @as(i32, @intCast(count))))];
}

/// Next/previous tab with wrap-around. `delta` is +1 for Tab and -1 for
/// Shift+Tab.
pub fn next(tab: Tab, delta: i32) Tab {
    return fromIndex(@as(i32, @intCast(index(tab))) + delta);
}

/// The direct-selection digit (`1`/`2`/`3`) for a tab, or null. Plain
/// digits are free while the navigator owns the keyboard: the file tree
/// never consumed them, so this cannot shadow a vim count there.
pub fn fromDigit(cp: u21) ?Tab {
    return switch (cp) {
        '1' => .files,
        '2' => .notes,
        '3' => .agents,
        else => null,
    };
}

/// Static label drawn in the strip. Lowercase matches the rest of the
/// workspace chrome (`agents`, `chat`, `changes`) and the existing `files`
/// title the tests and neo-tree layout were built around.
pub fn label(tab: Tab) []const u8 {
    return switch (tab) {
        .files => "files",
        .notes => "notes",
        .agents => "agents",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "navigator: tab order, labels and direct digits" {
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(Tab.files, fromIndex(0));
    try std.testing.expectEqual(Tab.notes, fromIndex(1));
    try std.testing.expectEqual(Tab.agents, fromIndex(2));
    try std.testing.expectEqualStrings("files", label(.files));
    try std.testing.expectEqualStrings("notes", label(.notes));
    try std.testing.expectEqualStrings("agents", label(.agents));
    try std.testing.expectEqual(Tab.files, fromDigit('1').?);
    try std.testing.expectEqual(Tab.notes, fromDigit('2').?);
    try std.testing.expectEqual(Tab.agents, fromDigit('3').?);
    try std.testing.expectEqual(@as(?Tab, null), fromDigit('4'));
    try std.testing.expectEqual(@as(?Tab, null), fromDigit('0'));
}

test "navigator: next/prev wrap in both directions" {
    try std.testing.expectEqual(Tab.notes, next(.files, 1));
    try std.testing.expectEqual(Tab.agents, next(.notes, 1));
    try std.testing.expectEqual(Tab.files, next(.agents, 1));
    try std.testing.expectEqual(Tab.agents, next(.files, -1));
    try std.testing.expectEqual(Tab.files, next(.notes, -1));
    try std.testing.expectEqual(Tab.notes, next(.agents, -1));
    // a full cycle returns to the origin
    var t = Tab.files;
    var i: usize = 0;
    while (i < count) : (i += 1) t = next(t, 1);
    try std.testing.expectEqual(Tab.files, t);
}

test "navigator: index and wrapped fromIndex cover every tab" {
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        try std.testing.expectEqual(all[i], fromIndex(@intCast(i)));
        try std.testing.expectEqual(i, index(all[i]));
    }
    try std.testing.expectEqual(Tab.files, fromIndex(-3));
    try std.testing.expectEqual(Tab.agents, fromIndex(5));
}
