//! Key representation and compile-time keymap tables (DESIGN.md §4.4, §10).
//! Uses vaxis.Key as the canonical key type (kitty-protocol aware).
//!
//! vaxis.Key is a plain struct (not a tagged union): `codepoint: u21` plus
//! optional `text` / `shifted_codepoint` / `base_layout_codepoint` and a packed
//! `mods: Modifiers` field. Special keys are u21 *constants* on the type
//! (`vaxis.Key.escape`, `vaxis.Key.tab`, ...), not struct fields. Key itself
//! has no `.eql` method — `Modifiers` has one, and `Key` offers the matching
//! helpers `matches` / `matchExact` / ...; lookup uses `matchExact`
//! (codepoint + modifiers, caps/num lock ignored), which is the right
//! semantics for a compile-time table.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Key = vaxis.Key;
pub const Mods = vaxis.Key.Modifiers;

/// Canonical M0 action ids. Grows with each milestone.
pub const ActionId = enum {
    // movement
    move_left,
    move_down,
    move_up,
    move_right,
    word_next, // w
    word_next_end, // e
    word_prev, // b
    word_prev_end, // ge
    line_start, // ^ (first non-blank)
    line_start_bol, // 0 (column 0)
    line_end, // $ (last non-newline char)
    goto_first_line, // gg
    goto_last_line, // G
    paragraph_prev, // {
    paragraph_next, // }
    match_pair, // %
    page_up, // ctrl-b
    page_down, // ctrl-f
    half_page_up, // ctrl-u
    half_page_down, // ctrl-d
    // find/till (f F t T carry the target char via mode args)
    find_char,
    find_char_back,
    till_char,
    till_char_back,
    repeat_find, // ;
    repeat_find_back, // ,
    // editing
    insert_mode, // i
    insert_before, // I
    insert_line_after, // o
    insert_line_before, // O
    append, // a
    append_end, // A
    /// Unbound insert-mode key: the caller inserts the key it fed to
    /// Mode.handle (delivered as Result.action; see mode.zig Result docs).
    insert_char,
    visual_char, // v
    visual_line, // V
    visual_block, // ctrl-v
    delete, // d (operator)
    change, // c (operator)
    yank, // y (operator)
    undo, // u
    redo, // ctrl-r
    repeat_last, // .
    paste, // p
    paste_before, // P
    easymotion, // s — EasyMotion jump (DESIGN.md §1.2)
    leader_find, // <leader>f — EasyMotion across windows (M1: same as s)
    leader, // space — leader prefix
    toggle_comment_line, // gcc — comment/uncomment the current line
    mc_add, // Ctrl+n — multi-cursor: select word / add next match
    picker_file, // <leader>sf — fuzzy file picker
    enter_command_mode, // :
    normal_mode, // esc / ctrl-c
    insert_exit, // jk special-cased by Mode
    noop,
};

pub const KeyMapEntry = struct {
    key: Key,
    action: ActionId,
};

pub const KeyMap = []const KeyMapEntry;

/// Exact match lookup (key + modifiers). vaxis.Key has no `.eql`; we use
/// `matchExact`, which compares codepoint and modifiers (ignoring caps_lock /
/// num_lock, mirroring vaxis's own shortcut matching). Returns null when
/// unbound.
pub fn lookup(map: KeyMap, key: Key) ?ActionId {
    for (map) |e| {
        if (e.key.matchExact(key.codepoint, key.mods)) return e.action;
    }
    return null;
}

test "lookup: exact key + modifier matching" {
    const map: KeyMap = &.{
        .{ .key = .{ .codepoint = 'h' }, .action = .move_left },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .action = .half_page_up },
        .{ .key = .{ .codepoint = vaxis.Key.escape }, .action = .normal_mode },
    };
    try std.testing.expectEqual(.move_left, lookup(map, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(.half_page_up, lookup(map, .{ .codepoint = 'u', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(.normal_mode, lookup(map, .{ .codepoint = vaxis.Key.escape }).?);
    // modifiers are part of the match: plain 'u' must not hit the ctrl-u entry
    try std.testing.expectEqual(@as(?ActionId, null), lookup(map, .{ .codepoint = 'u' }));
    // caps/num lock are ignored (matchExact semantics)
    try std.testing.expectEqual(.move_left, lookup(map, .{ .codepoint = 'h', .mods = .{ .caps_lock = true } }).?);
    // unbound
    try std.testing.expectEqual(@as(?ActionId, null), lookup(map, .{ .codepoint = 'x' }));
}
