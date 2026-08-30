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
    goto_view_top, // H — first visible line of the focused window
    goto_view_middle, // M — middle visible line
    goto_view_bottom, // L — last visible line
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
    delete_char, // x — delete the character under the cursor (= dl)
    delete_char_before, // X — delete the char before the cursor (= dh)
    delete_to_eol, // D — delete to end of line (= d$)
    change_to_eol, // C — change to end of line (= c$)
    change_line, // S — change the whole line (= cc)
    replace_char, // r — replace the char under the cursor
    toggle_case, // ~ — toggle the case of the char under the cursor
    join_lines, // J — join the current line with the next
    indent_line, // >> — indent the current line
    dedent_line, // << — dedent the current line
    undo, // u
    redo, // ctrl-r
    repeat_last, // .
    paste, // p
    paste_before, // P
    easymotion, // s — EasyMotion jump (DESIGN.md §1.2)
    leader_find, // <leader>f — EasyMotion across windows (M1: same as s)
    leader, // space — leader prefix
    toggle_comment_line, // gcc — comment/uncomment the current line
    increment, // Ctrl+a — add 1 to the number at/after the cursor (or every number in a visual selection)
    decrement, // Ctrl+x — subtract 1 from the number at/after the cursor (or every number in a visual selection)
    increment_visual, // g Ctrl+a — visual column increment: each line's first number +i (i = 1-based line offset)
    decrement_visual, // g Ctrl+x — visual column decrement: each line's first number -i
    mc_add, // Ctrl+n — multi-cursor: select word / add next match
    picker_file, // <leader>sf — fuzzy file picker
    picker_grep, // <leader>st — grep picker
    picker_buffers, // <leader>sb — buffer picker
    picker_recent, // <leader>sr — recent files picker
    picker_keymaps, // <leader>sk — keymap search picker
    picker_themes, // <leader>sp — theme picker (live preview)
    close_buffer, // <leader>bk — close current buffer
    buffer_to_left_win, // <leader>bh — move current buffer to the left window
    buffer_to_right_win, // <leader>bl — move current buffer to the right window
    filetree_toggle, // <leader>e — toggle file tree
    // M2 LSP actions
    diagnostic_next, // ]d — next diagnostic
    diagnostic_prev, // [d — previous diagnostic
    diagnostic_line, // gl — diagnostics for the cursor line
    diagnostics_list, // <leader>sd — diagnostics list
    // M2 semantic navigation
    hover, // K — hover docs
    definition, // gd — go to definition
    declaration, // gD — go to declaration
    references, // gr — references
    implementation, // gI — implementations
    signature_help, // gs — signature help
    rename_symbol, // <leader>rn — LSP rename symbol
    format_document, // <leader>lf — LSP format document
    inlay_hints, // <leader>ti — LSP inlay hints
    document_outline, // <leader>o — LSP document symbols outline
    filetree_locate, // <leader>E — locate current file in tree
    next_buffer, // gt — next tab
    prev_buffer, // gT — previous tab
    enter_command_mode, // :
    search_forward, // / — buffer search via the cmdline (DESIGN.md §6.7)
    search_backward, // ?
    search_next, // n — repeat last search in the same direction
    search_prev, // N — repeat last search in the opposite direction
    normal_mode, // esc / ctrl-c
    insert_exit, // jk special-cased by Mode
    flip_visual, // visual 'o': swap anchor and cursor
    scroll_cursor_center, // zz — scroll the cursor line to the window middle
    scroll_cursor_top, // zt — scroll the cursor line to the window top
    scroll_cursor_bottom, // zb — scroll the cursor line to the window bottom
    // folds (indent-based, see editor/fold.zig)
    fold_toggle, // za — toggle the fold under the cursor
    fold_open, // zo — open the innermost closed fold under the cursor
    fold_close, // zc — close the innermost open fold under the cursor
    fold_open_all, // zR — open every fold in the buffer
    fold_close_all, // zM — close every fold in the buffer
    // M3 git
    hunk_next, // ]c — next git hunk
    hunk_prev, // [c — previous git hunk
    hunk_stage, // <leader>hs — stage the hunk under the cursor
    hunk_reset, // <leader>hr — reset the hunk under the cursor
    hunk_preview, // <leader>hp — preview the hunk under the cursor (float)
    blame_toggle, // <leader>tb — toggle inline blame
    git_lazygit, // <leader>lg — launch lazygit in an external terminal
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
