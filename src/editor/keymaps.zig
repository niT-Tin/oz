//! Compile-time keymaps (DESIGN.md §10: 配置即代码). One table per mode.
//! M0 minimal set — grows with each milestone.
//!
//! vaxis.Key literal notes: Key is a plain struct — write
//! `.{ .codepoint = 'h' }` and add modifiers as `.{ .mods = .{ .ctrl = true } }`.
//! Special keys are u21 constants on the type, NOT struct fields:
//! `.{ .codepoint = vaxis.Key.escape }` (there is no `.{ .escape = {} }`).
const std = @import("std");
const vaxis = @import("vaxis");
const KeyEvent = @import("key_event.zig");

const KeyMap = KeyEvent.KeyMap;
const A = KeyEvent.ActionId;

fn act(k: vaxis.Key, action: KeyEvent.ActionId) KeyEvent.KeyMapEntry {
    return .{ .key = k, .action = action };
}

/// Normal mode keymap (M0 subset). Digits 1-9 are handled by the Mode state
/// machine as count prefixes, not bound here; '0' is bound because a bare '0'
/// is the line_start_bol motion.
pub const normal: KeyMap = &.{
    // movement
    act(.{ .codepoint = 'h' }, .move_left),
    act(.{ .codepoint = 'j' }, .move_down),
    act(.{ .codepoint = 'k' }, .move_up),
    act(.{ .codepoint = 'l' }, .move_right),
    act(.{ .codepoint = 'w' }, .word_next),
    act(.{ .codepoint = 'e' }, .word_next_end),
    act(.{ .codepoint = 'b' }, .word_prev),
    act(.{ .codepoint = '^' }, .line_start),
    act(.{ .codepoint = '0' }, .line_start_bol),
    act(.{ .codepoint = '$' }, .line_end),
    act(.{ .codepoint = '{' }, .paragraph_prev),
    act(.{ .codepoint = '}' }, .paragraph_next),
    act(.{ .codepoint = '%' }, .match_pair),
    act(.{ .codepoint = ';' }, .repeat_find),
    act(.{ .codepoint = ',' }, .repeat_find_back),
    // mode entry
    act(.{ .codepoint = 'i' }, .insert_mode),
    act(.{ .codepoint = 'I' }, .insert_before),
    act(.{ .codepoint = 'a' }, .append),
    act(.{ .codepoint = 'A' }, .append_end),
    act(.{ .codepoint = 'o' }, .insert_line_after),
    act(.{ .codepoint = 'O' }, .insert_line_before),
    act(.{ .codepoint = 'v' }, .visual_char),
    act(.{ .codepoint = 'V' }, .visual_line),
    act(.{ .codepoint = 's' }, .easymotion),
    act(.{ .codepoint = ' ' }, .leader),
    act(.{ .codepoint = ':' }, .enter_command_mode),
    // buffer search (cmdline variant, DESIGN.md §6.7): / forward, ? backward,
    // n/N repeat in the same / opposite direction
    act(.{ .codepoint = '/' }, .search_forward),
    act(.{ .codepoint = '?' }, .search_backward),
    act(.{ .codepoint = 'n' }, .search_next),
    act(.{ .codepoint = 'N' }, .search_prev),
    act(.{ .codepoint = vaxis.Key.escape }, .normal_mode),
    // editing
    act(.{ .codepoint = 'u' }, .undo),
    act(.{ .codepoint = '.' }, .repeat_last),
    act(.{ .codepoint = 'p' }, .paste),
    act(.{ .codepoint = 'P' }, .paste_before),
    act(.{ .codepoint = 'd' }, .delete),
    act(.{ .codepoint = 'c' }, .change),
    act(.{ .codepoint = 'y' }, .yank),
    act(.{ .codepoint = 'x' }, .delete_char),
    act(.{ .codepoint = 'X' }, .delete_char_before),
    act(.{ .codepoint = 'D' }, .delete_to_eol),
    act(.{ .codepoint = 'C' }, .change_to_eol),
    act(.{ .codepoint = 'S' }, .change_line),
    act(.{ .codepoint = 'r' }, .replace_char),
    act(.{ .codepoint = '~' }, .toggle_case),
    act(.{ .codepoint = 'J' }, .join_lines),
    act(.{ .codepoint = '>' }, .indent_line),
    act(.{ .codepoint = '<' }, .dedent_line),
    act(.{ .codepoint = 'g' }, .noop), // prefix: gg / ge — handled by Mode as sequence
    act(.{ .codepoint = 'G' }, .goto_last_line),
    act(.{ .codepoint = 'f' }, .find_char),
    act(.{ .codepoint = 'F' }, .find_char_back),
    act(.{ .codepoint = 't' }, .till_char),
    act(.{ .codepoint = 'T' }, .till_char_back),
    act(.{ .codepoint = 'K' }, .hover), // K — LSP hover
    // ctrl keys
    act(.{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .half_page_up),
    act(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .half_page_down),
    act(.{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .page_up),
    act(.{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .page_down),
    act(.{ .codepoint = 'r', .mods = .{ .ctrl = true } }, .redo),
    act(.{ .codepoint = 'v', .mods = .{ .ctrl = true } }, .visual_block),
    act(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }, .mc_add),
    act(.{ .codepoint = 'a', .mods = .{ .ctrl = true } }, .increment),
    act(.{ .codepoint = 'x', .mods = .{ .ctrl = true } }, .decrement),
};

/// Insert mode keymap (M0 minimal: everything not bound is reported back to
/// the caller as action `.insert_char`; Esc/Ctrl-c exit).
pub const insert: KeyMap = &.{
    act(.{ .codepoint = vaxis.Key.escape }, .normal_mode),
    act(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, .normal_mode),
};

/// Command mode keymap (M0: Escape/Ctrl-c cancel; Enter executes — handled by
/// the command line widget, not this table).
pub const command: KeyMap = &.{};

test "normal keymap covers the M0 key set" {
    const L = KeyEvent.lookup;
    try std.testing.expectEqual(.move_left, L(normal, .{ .codepoint = 'h' }));
    try std.testing.expectEqual(.move_down, L(normal, .{ .codepoint = 'j' }));
    try std.testing.expectEqual(.move_up, L(normal, .{ .codepoint = 'k' }));
    try std.testing.expectEqual(.move_right, L(normal, .{ .codepoint = 'l' }));
    try std.testing.expectEqual(.word_next, L(normal, .{ .codepoint = 'w' }));
    try std.testing.expectEqual(.word_next_end, L(normal, .{ .codepoint = 'e' }));
    try std.testing.expectEqual(.word_prev, L(normal, .{ .codepoint = 'b' }));
    try std.testing.expectEqual(.line_start, L(normal, .{ .codepoint = '^' }));
    try std.testing.expectEqual(.line_start_bol, L(normal, .{ .codepoint = '0' }));
    try std.testing.expectEqual(.line_end, L(normal, .{ .codepoint = '$' }));
    try std.testing.expectEqual(.paragraph_prev, L(normal, .{ .codepoint = '{' }));
    try std.testing.expectEqual(.paragraph_next, L(normal, .{ .codepoint = '}' }));
    try std.testing.expectEqual(.match_pair, L(normal, .{ .codepoint = '%' }));
    try std.testing.expectEqual(.goto_last_line, L(normal, .{ .codepoint = 'G' }));
    try std.testing.expectEqual(.find_char, L(normal, .{ .codepoint = 'f' }));
    try std.testing.expectEqual(.find_char_back, L(normal, .{ .codepoint = 'F' }));
    try std.testing.expectEqual(.till_char, L(normal, .{ .codepoint = 't' }));
    try std.testing.expectEqual(.till_char_back, L(normal, .{ .codepoint = 'T' }));
    try std.testing.expectEqual(.repeat_find, L(normal, .{ .codepoint = ';' }));
    try std.testing.expectEqual(.repeat_find_back, L(normal, .{ .codepoint = ',' }));
    try std.testing.expectEqual(.undo, L(normal, .{ .codepoint = 'u' }));
    try std.testing.expectEqual(.repeat_last, L(normal, .{ .codepoint = '.' }));
    try std.testing.expectEqual(.delete, L(normal, .{ .codepoint = 'd' }));
    try std.testing.expectEqual(.change, L(normal, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(.yank, L(normal, .{ .codepoint = 'y' }));
    try std.testing.expectEqual(.insert_mode, L(normal, .{ .codepoint = 'i' }));
    try std.testing.expectEqual(.append, L(normal, .{ .codepoint = 'a' }));
    try std.testing.expectEqual(.insert_line_after, L(normal, .{ .codepoint = 'o' }));
    try std.testing.expectEqual(.visual_char, L(normal, .{ .codepoint = 'v' }));
    try std.testing.expectEqual(.enter_command_mode, L(normal, .{ .codepoint = ':' }));
    try std.testing.expectEqual(.normal_mode, L(normal, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(.half_page_up, L(normal, .{ .codepoint = 'u', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.half_page_down, L(normal, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.page_up, L(normal, .{ .codepoint = 'b', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.page_down, L(normal, .{ .codepoint = 'f', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.redo, L(normal, .{ .codepoint = 'r', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.visual_block, L(normal, .{ .codepoint = 'v', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.increment, L(normal, .{ .codepoint = 'a', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(.decrement, L(normal, .{ .codepoint = 'x', .mods = .{ .ctrl = true } }));
    // 'g' is the gg/ge prefix (bound to noop; Mode interprets the sequence)
    try std.testing.expectEqual(.noop, L(normal, .{ .codepoint = 'g' }));
    // editing keys
    try std.testing.expectEqual(.delete_char, L(normal, .{ .codepoint = 'x' }));
    try std.testing.expectEqual(.delete_char_before, L(normal, .{ .codepoint = 'X' }));
    try std.testing.expectEqual(.delete_to_eol, L(normal, .{ .codepoint = 'D' }));
    try std.testing.expectEqual(.change_to_eol, L(normal, .{ .codepoint = 'C' }));
    try std.testing.expectEqual(.change_line, L(normal, .{ .codepoint = 'S' }));
    try std.testing.expectEqual(.replace_char, L(normal, .{ .codepoint = 'r' }));
    try std.testing.expectEqual(.toggle_case, L(normal, .{ .codepoint = '~' }));
    try std.testing.expectEqual(.join_lines, L(normal, .{ .codepoint = 'J' }));
    try std.testing.expectEqual(.indent_line, L(normal, .{ .codepoint = '>' }));
    try std.testing.expectEqual(.dedent_line, L(normal, .{ .codepoint = '<' }));
    // unbound keys / wrong modifiers → null
    try std.testing.expectEqual(@as(?KeyEvent.ActionId, null), L(normal, .{ .codepoint = 'h', .mods = .{ .ctrl = true } }));
}

test "insert keymap binds only exit keys" {
    const L = KeyEvent.lookup;
    try std.testing.expectEqual(.normal_mode, L(insert, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(.normal_mode, L(insert, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    // everything else is unbound → Mode reports it back as insert_char
    try std.testing.expectEqual(@as(?KeyEvent.ActionId, null), L(insert, .{ .codepoint = 'j' }));
    try std.testing.expectEqual(@as(?KeyEvent.ActionId, null), L(insert, .{ .codepoint = 'k' }));
    try std.testing.expectEqual(@as(?KeyEvent.ActionId, null), L(insert, .{ .codepoint = 'x' }));
}
