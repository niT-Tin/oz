//! Modal editing state machine: Normal/Insert/Visual/Visual Line/Visual
//! Block/Command (DESIGN.md §6). Parses a key into an action/motion/op,
//! tracking count prefixes and pending operators. Pure logic — it never
//! touches a document; the caller executes the returned Result.
//!
//! Semantics (vim-style, M0 scope):
//! - count prefix: digits 1-9 start a count, 0-9 extend it. A bare '0' (no
//!   count pending) is the line_start_bol motion, never the start of a count
//!   ("10" is count ten, not 0+1). The same rule applies while an operator is
//!   pending, so "d0" deletes to column 0 while "d10w" is delete 10 words.
//! - operator pending: d/c/y wait for a motion; repeating the same key
//!   (dd/cc/yy) is a whole-line operation (op_motion, line-wise).
//! - motions: plain movement keys → Result.motion; f/F/t/T wait for a target
//!   char (Result.motion with args.ch) and remember (motion, ch) in
//!   state.motion_args.last for ';'/',' repeat; gg/ge come from a 'g' prefix.
//! - actions: u / . / : / i / a / o / v / ... → Result.action (':' is
//!   Result.command_mode).
//! - exclusive_end: character-wise motions (w/e/b/h/l/f/t/... ) → true,
//!   line-wise motions (gg/G/{/}/j/k/...) → false.
//! - insert mode: Esc/Ctrl-c → Result.to_normal; 'j' then 'k' → to_normal
//!   (the 'k' is NOT inserted — the caller only inserts chars reported back
//!   as `.action` with action == `.insert_char`); any other key not in the
//!   insert keymap comes back as `.action { .insert_char }`.
//! - mode transitions: emitting an insert/visual action updates state.mode;
//!   emitting to_normal sets mode = .normal; ':' sets mode = .command.
//! - '.' repeat: emitting an action/op_motion result records
//!   state.last_action / last_count (M0: emitting counts as executing).
const std = @import("std");
const vaxis = @import("vaxis");
const KeyEvent = @import("key_event.zig");
const Motion = @import("motion.zig");

pub const Mode = enum {
    normal,
    insert,
    visual_char,
    visual_line,
    visual_block,
    command,
};

/// What the caller should do after feeding one key.
pub const Result = union(enum) {
    /// Key swallowed (pending count/operator/sequence); nothing to execute.
    pending,
    /// Execute a plain action with `count` (>=1).
    ///
    /// Note: unbound insert-mode keys are reported as `.action` with action
    /// == `.insert_char` — the caller inserts the very key it fed to handle()
    /// (the caller always has it in hand). This deliberately does NOT add a
    /// new Result variant, so existing exhaustive `switch (res)` sites (e.g.
    /// main.zig) keep compiling; the insert_char semantics live in ActionId.
    action: struct { action: KeyEvent.ActionId, count: u32 },
    /// Execute a motion (bare or after operator). `exclusive_end` is true for
    /// character-wise operator targets (d/motion excludes the end char, like
    /// vim), false for line-wise motions.
    motion: struct {
        motion: Motion.Motion,
        args: Motion.Args,
        count: u32,
        exclusive_end: bool,
    },
    /// Operator + motion combo (d{motion}): apply operator over the range.
    /// Whole-line ops (dd/cc/yy) come back with motion == .line_start and
    /// exclusive_end == false — a sentinel for "count whole lines" that the
    /// caller must special-case (it is unambiguous: d0 is .line_start_bol,
    /// d^ is .line_start with exclusive_end == true).
    op_motion: struct {
        op: KeyEvent.ActionId,
        motion: Motion.Motion,
        args: Motion.Args,
        count: u32,
        exclusive_end: bool,
    },
    /// Enter command mode (from ':'), with the leading char already consumed.
    command_mode,
    /// Exit insert/visual mode back to normal (jk / Esc).
    to_normal,
};

const max_count_digits = 9; // count saturates at 999_999_999 (fits u32)

pub const State = struct {
    mode: Mode = .normal,
    count_digits: []const u8 = "", // pending count prefix (unparsed)
    pending_op: ?KeyEvent.ActionId = null, // d / c / y seen, awaiting motion
    motion_args: Motion.Args = .{}, // last find/till char for ';'/',' repeat
    /// last executed action for '.' repeat
    last_action: ?KeyEvent.ActionId = null,
    last_count: u32 = 1,
    /// insert-mode key before current (for jk detection)
    prev_insert_key: ?vaxis.Key = null,

    // ---- internal sequence state (extended beyond the skeleton) ----
    /// 'g' seen, awaiting the second key (gg → first_line, ge → word_prev_end)
    pending_g: bool = false,
    /// f/F/t/T seen, awaiting the target char (stores the find action)
    pending_find: ?KeyEvent.ActionId = null,

    /// backing storage for count_digits. The slice points into this buffer,
    /// so State must not be copied by value while a count is pending.
    count_buf: [max_count_digits]u8 = undefined,
    count_len: u8 = 0,

    pub fn init() State {
        return .{};
    }
};

/// Feed one key into the state machine. `keymap` is the keymap for the
/// *current* mode (Mode.zig does not choose it; the caller does).
pub fn handle(
    state: *State,
    key: vaxis.Key,
    keymap: KeyEvent.KeyMap,
) Result {
    return switch (state.mode) {
        .normal => handleNormal(state, key, keymap),
        .insert => handleInsert(state, key, keymap),
        .visual_char, .visual_line, .visual_block => handleVisual(state, key, keymap),
        .command => handleCommand(state, key, keymap),
    };
}

fn handleNormal(state: *State, key: vaxis.Key, keymap: KeyEvent.KeyMap) Result {
    // 1) f/F/t/T target char pending — the next key IS the target.
    if (state.pending_find) |find_action| {
        state.pending_find = null;
        if (isEscape(key)) {
            resetPending(state);
            return .pending;
        }
        if (key.codepoint == 0 or key.codepoint > 0xFF) return .pending; // not a usable target
        const motion = findMotion(find_action);
        const ch: u8 = @intCast(key.codepoint);
        state.motion_args.last = .{ .motion = motion, .ch = ch };
        return emitMotion(state, motion, .{ .ch = ch });
    }

    // 2) 'g' prefix pending (gg / ge / ...).
    if (state.pending_g) {
        state.pending_g = false;
        if (isEscape(key)) {
            resetPending(state);
            return .pending;
        }
        switch (key.codepoint) {
            'g' => return emitMotion(state, .first_line, .{}),
            // ge = end of previous word
            'e' => return emitMotion(state, .word_prev_end, .{}),
            else => {
                resetPending(state);
                return .pending;
            },
        }
    }

    // 3) count digits. A bare '0' (nothing accumulated yet) is the
    //    line_start_bol motion, never the start of a count.
    if (isPlain(key) and key.codepoint >= '0' and key.codepoint <= '9') {
        if (state.count_len == 0 and key.codepoint == '0') {
            return emitMotion(state, .line_start_bol, .{});
        }
        pushCountDigit(state, @intCast(key.codepoint));
        return .pending;
    }

    // 4) operator pending — awaiting a motion (or same-op repeat → linewise).
    if (state.pending_op) |op| {
        if (isEscape(key)) {
            resetPending(state);
            return .pending;
        }
        if (KeyEvent.lookup(keymap, key)) |action| {
            if (action == op) { // dd / cc / yy → whole-line operation
                state.pending_op = null;
                const count = countValue(state);
                resetCount(state);
                state.last_action = op;
                state.last_count = count;
                return .{
                    .op_motion = .{
                        .op = op,
                        .motion = .line_start, // linewise sentinel, see Result docs
                        .args = .{},
                        .count = count,
                        .exclusive_end = false,
                    },
                };
            }
            switch (action) {
                .find_char, .find_char_back, .till_char, .till_char_back => {
                    state.pending_find = action; // dfx: keep the op pending
                    return .pending;
                },
                else => {},
            }
            if (actionToMotion(action)) |m| {
                return emitMotion(state, m, .{});
            }
        }
        if (key.codepoint == 'g') { // dgg / dge
            state.pending_g = true;
            return .pending;
        }
        // M0: anything else cancels the pending operator.
        resetPending(state);
        return .pending;
    }

    // 5) 'g' prefix (gg / ge / ...) — handled as a sequence, not via the
    //    keymap (the table binds 'g' to .noop).
    if (key.codepoint == 'g') {
        state.pending_g = true;
        return .pending;
    }

    // 6) plain keymap lookup.
    const action = KeyEvent.lookup(keymap, key) orelse return .pending;
    return dispatchNormal(state, action);
}

fn dispatchNormal(state: *State, action: KeyEvent.ActionId) Result {
    return switch (action) {
        // movements → motions
        .move_left => emitMotion(state, .left, .{}),
        .move_down => emitMotion(state, .down, .{}),
        .move_up => emitMotion(state, .up, .{}),
        .move_right => emitMotion(state, .right, .{}),
        .word_next => emitMotion(state, .word_next, .{}),
        .word_next_end => emitMotion(state, .word_next_end, .{}),
        .word_prev => emitMotion(state, .word_prev, .{}),
        // ActionId.word_prev_end exists but no keymap key produces it in M0
        // (ge is handled by the 'g' prefix) and Motion has no such member.
        .word_prev_end => .pending,
        .line_start => emitMotion(state, .line_start, .{}),
        .line_start_bol => emitMotion(state, .line_start_bol, .{}),
        .line_end => emitMotion(state, .line_end, .{}),
        .goto_first_line => emitMotion(state, .first_line, .{}),
        .goto_last_line => emitMotion(state, .last_line, .{}),
        .paragraph_prev => emitMotion(state, .paragraph_prev, .{}),
        .paragraph_next => emitMotion(state, .paragraph_next, .{}),
        .match_pair => emitMotion(state, .match_pair, .{}),
        .page_up => emitMotion(state, .page_up, .{}),
        .page_down => emitMotion(state, .page_down, .{}),
        .half_page_up => emitMotion(state, .half_page_up, .{}),
        .half_page_down => emitMotion(state, .half_page_down, .{}),
        // find/till → wait for the target char
        .find_char, .find_char_back, .till_char, .till_char_back => blk: {
            state.pending_find = action;
            break :blk .pending;
        },
        // ';'/',' repeat the last find/till (reversed for ',')
        .repeat_find => if (state.motion_args.last) |last|
            emitMotion(state, last.motion, .{ .ch = last.ch })
        else
            .pending,
        .repeat_find_back => if (state.motion_args.last) |last|
            emitMotion(state, reverseFind(last.motion), .{ .ch = last.ch })
        else
            .pending,
        // operators → pending until a motion arrives
        .delete, .change, .yank => blk: {
            state.pending_op = action;
            break :blk .pending;
        },
        // mode entries
        .insert_mode, .insert_before, .insert_line_after, .insert_line_before, .append, .append_end => blk: {
            state.mode = .insert;
            state.prev_insert_key = null;
            break :blk emitAction(state, action);
        },
        .visual_char => blk: {
            state.mode = .visual_char;
            break :blk emitAction(state, action);
        },
        .visual_line => blk: {
            state.mode = .visual_line;
            break :blk emitAction(state, action);
        },
        .visual_block => blk: {
            state.mode = .visual_block;
            break :blk emitAction(state, action);
        },
        .enter_command_mode => blk: {
            resetPending(state);
            state.mode = .command;
            break :blk .command_mode;
        },
        // Esc with nothing pending: swallow
        .normal_mode => blk: {
            resetPending(state);
            break :blk .pending;
        },
        .undo => emitAction(state, .undo),
        .redo => emitAction(state, .redo),
        .repeat_last => emitAction(state, .repeat_last),
        // never produced by the keymap tables
        .insert_char, .insert_exit, .noop => .pending,
    };
}

fn handleInsert(state: *State, key: vaxis.Key, keymap: KeyEvent.KeyMap) Result {
    // Esc / Ctrl-c (via the insert keymap) → back to normal.
    if (KeyEvent.lookup(keymap, key)) |action| {
        if (action == .normal_mode) {
            state.mode = .normal;
            state.prev_insert_key = null;
            return .to_normal;
        }
    }
    // 'j' followed by plain 'k' exits to normal; that 'k' must NOT be
    // inserted (the caller inserts only `.action` results whose action is
    // `.insert_char`).
    if (isPlain(key)) {
        if (key.codepoint == 'k' and state.prev_insert_key != null and
            state.prev_insert_key.?.codepoint == 'j')
        {
            state.mode = .normal;
            state.prev_insert_key = null;
            return .to_normal;
        }
        state.prev_insert_key = key;
    } else {
        state.prev_insert_key = null; // modified keys break the jk chain
    }
    return emitAction(state, .insert_char);
}

fn handleVisual(state: *State, key: vaxis.Key, keymap: KeyEvent.KeyMap) Result {
    // Esc / Ctrl-c → back to normal.
    if (isEscape(key) or isCtrlC(key)) {
        state.mode = .normal;
        resetPending(state);
        return .to_normal;
    }
    // M0: visual shares the normal-mode parser (motions, operators, count).
    return handleNormal(state, key, keymap);
}

fn handleCommand(state: *State, key: vaxis.Key, keymap: KeyEvent.KeyMap) Result {
    _ = keymap;
    // M0: the command-line widget owns input after ':'; we only exit.
    if (isEscape(key) or isCtrlC(key)) {
        state.mode = .normal;
        return .to_normal;
    }
    return .pending;
}

// ---- helpers ----

fn emitMotion(state: *State, motion: Motion.Motion, args: Motion.Args) Result {
    const count = countValue(state);
    const exclusive_end = !isLinewise(motion);
    resetCount(state);
    if (state.pending_op) |op| {
        state.pending_op = null;
        state.last_action = op; // d{motion} is repeatable via '.'
        state.last_count = count;
        return .{ .op_motion = .{
            .op = op,
            .motion = motion,
            .args = args,
            .count = count,
            .exclusive_end = exclusive_end,
        } };
    }
    return .{ .motion = .{
        .motion = motion,
        .args = args,
        .count = count,
        .exclusive_end = exclusive_end,
    } };
}

fn emitAction(state: *State, action: KeyEvent.ActionId) Result {
    const count = countValue(state);
    resetCount(state);
    // '.' repeat snapshot (M0: emitting counts as executing). Undo/redo and
    // '.' itself are not repeatable via '.', mirroring vim; insert_char is
    // per-key, not a top-level command.
    switch (action) {
        .undo, .redo, .repeat_last, .normal_mode, .insert_char => {},
        else => {
            state.last_action = action;
            state.last_count = count;
        },
    }
    return .{ .action = .{ .action = action, .count = count } };
}

/// Character-wise motions exclude the end char for operators (vim 'exclusive'
/// motions); line-wise motions include whole lines.
fn isLinewise(motion: Motion.Motion) bool {
    return switch (motion) {
        .down, .up, .first_line, .last_line, .paragraph_prev, .paragraph_next, .page_up, .page_down, .half_page_up, .half_page_down => true,
        else => false,
    };
}

fn actionToMotion(action: KeyEvent.ActionId) ?Motion.Motion {
    return switch (action) {
        .move_left => .left,
        .move_down => .down,
        .move_up => .up,
        .move_right => .right,
        .word_next => .word_next,
        .word_next_end => .word_next_end,
        .word_prev => .word_prev,
        .line_start => .line_start,
        .line_start_bol => .line_start_bol,
        .line_end => .line_end,
        .goto_first_line => .first_line,
        .goto_last_line => .last_line,
        .paragraph_prev => .paragraph_prev,
        .paragraph_next => .paragraph_next,
        .match_pair => .match_pair,
        .page_up => .page_up,
        .page_down => .page_down,
        .half_page_up => .half_page_up,
        .half_page_down => .half_page_down,
        else => null,
    };
}

fn findMotion(action: KeyEvent.ActionId) Motion.Motion {
    return switch (action) {
        .find_char => .find,
        .find_char_back => .find_back,
        .till_char => .till,
        .till_char_back => .till_back,
        else => unreachable,
    };
}

fn reverseFind(motion: Motion.Motion) Motion.Motion {
    return switch (motion) {
        .find => .find_back,
        .find_back => .find,
        .till => .till_back,
        .till_back => .till,
        else => motion,
    };
}

fn isPlain(key: vaxis.Key) bool {
    return key.mods.eql(.{});
}

fn isEscape(key: vaxis.Key) bool {
    return key.codepoint == vaxis.Key.escape;
}

fn isCtrlC(key: vaxis.Key) bool {
    return key.codepoint == 'c' and key.mods.eql(.{ .ctrl = true });
}

fn pushCountDigit(state: *State, digit: u8) void {
    if (state.count_len >= max_count_digits) return; // saturate
    state.count_buf[state.count_len] = digit;
    state.count_len += 1;
    state.count_digits = state.count_buf[0..state.count_len];
}

fn resetCount(state: *State) void {
    state.count_len = 0;
    state.count_digits = "";
}

fn countValue(state: *const State) u32 {
    var v: u32 = 0;
    for (state.count_digits) |d| {
        v = v * 10 + (d - '0');
    }
    return if (v == 0) 1 else v;
}

fn resetPending(state: *State) void {
    state.pending_op = null;
    state.pending_g = false;
    state.pending_find = null;
    resetCount(state);
}

// ---- tests (parser-level; no document / cursor involved) ----

const testing = std.testing;
const Keymaps = @import("keymaps.zig");

fn press(cp: u8) vaxis.Key {
    return .{ .codepoint = cp };
}

fn esc() vaxis.Key {
    return .{ .codepoint = vaxis.Key.escape };
}

fn tag(r: Result) std.meta.Tag(Result) {
    return std.meta.activeTag(r);
}

test "count prefix: 5j → motion down with count 5" {
    var s = State.init();
    try testing.expectEqual(.pending, tag(handle(&s, press('5'), Keymaps.normal)));
    const r = handle(&s, press('j'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r));
    try testing.expectEqual(Motion.Motion.down, r.motion.motion);
    try testing.expectEqual(@as(u32, 5), r.motion.count);
}

test "count: 10 is count ten, not 0+1" {
    var s = State.init();
    _ = handle(&s, press('1'), Keymaps.normal);
    _ = handle(&s, press('0'), Keymaps.normal);
    try testing.expectEqualStrings("10", s.count_digits);
    const r = handle(&s, press('j'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r));
    try testing.expectEqual(@as(u32, 10), r.motion.count);
}

test "bare 0 → line_start_bol motion" {
    var s = State.init();
    const r = handle(&s, press('0'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r));
    try testing.expectEqual(Motion.Motion.line_start_bol, r.motion.motion);
}

test "3dw → op_motion(delete, word_next, count 3)" {
    var s = State.init();
    _ = handle(&s, press('3'), Keymaps.normal);
    _ = handle(&s, press('d'), Keymaps.normal);
    const r = handle(&s, press('w'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r));
    try testing.expectEqual(KeyEvent.ActionId.delete, r.op_motion.op);
    try testing.expectEqual(Motion.Motion.word_next, r.op_motion.motion);
    try testing.expectEqual(@as(u32, 3), r.op_motion.count);
    try testing.expect(r.op_motion.exclusive_end); // charwise
}

test "dd/yy → line-wise op_motion" {
    var s = State.init();
    _ = handle(&s, press('d'), Keymaps.normal);
    const r = handle(&s, press('d'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r));
    try testing.expectEqual(KeyEvent.ActionId.delete, r.op_motion.op);
    try testing.expect(!r.op_motion.exclusive_end); // whole-line

    var s2 = State.init();
    _ = handle(&s2, press('y'), Keymaps.normal);
    const r2 = handle(&s2, press('y'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r2));
    try testing.expectEqual(KeyEvent.ActionId.yank, r2.op_motion.op);
    try testing.expect(!r2.op_motion.exclusive_end);
}

test "operator + count after op: d2w" {
    var s = State.init();
    _ = handle(&s, press('d'), Keymaps.normal);
    _ = handle(&s, press('2'), Keymaps.normal);
    const r = handle(&s, press('w'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r));
    try testing.expectEqual(@as(u32, 2), r.op_motion.count);
}

test "d0 deletes to column 0 (0 is a motion, not a count)" {
    var s = State.init();
    _ = handle(&s, press('d'), Keymaps.normal);
    const r = handle(&s, press('0'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r));
    try testing.expectEqual(Motion.Motion.line_start_bol, r.op_motion.motion);
    try testing.expect(r.op_motion.exclusive_end);
}

test "f + x → motion find with args.ch='x'; ;/, repeat via last" {
    var s = State.init();
    _ = handle(&s, press('f'), Keymaps.normal);
    const r = handle(&s, press('x'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r));
    try testing.expectEqual(Motion.Motion.find, r.motion.motion);
    try testing.expectEqual(@as(u8, 'x'), r.motion.args.ch);

    // ';' repeats the same find
    const r2 = handle(&s, press(';'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r2));
    try testing.expectEqual(Motion.Motion.find, r2.motion.motion);
    try testing.expectEqual(@as(u8, 'x'), r2.motion.args.ch);

    // ',' repeats backwards
    const r3 = handle(&s, press(','), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r3));
    try testing.expectEqual(Motion.Motion.find_back, r3.motion.motion);
    try testing.expectEqual(@as(u8, 'x'), r3.motion.args.ch);
}

test "dfx: operator + find motion" {
    var s = State.init();
    _ = handle(&s, press('d'), Keymaps.normal);
    _ = handle(&s, press('f'), Keymaps.normal);
    const r = handle(&s, press('x'), Keymaps.normal);
    try testing.expectEqual(.op_motion, tag(r));
    try testing.expectEqual(Motion.Motion.find, r.op_motion.motion);
    try testing.expectEqual(@as(u8, 'x'), r.op_motion.args.ch);
}

test "gg → goto_first_line; ge → word_prev_end; G → goto_last_line" {
    var s = State.init();
    _ = handle(&s, press('g'), Keymaps.normal);
    const r = handle(&s, press('g'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r));
    try testing.expectEqual(Motion.Motion.first_line, r.motion.motion);

    // ge = end of previous word
    var s2 = State.init();
    _ = handle(&s2, press('g'), Keymaps.normal);
    const r2 = handle(&s2, press('e'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r2));
    try testing.expectEqual(Motion.Motion.word_prev_end, r2.motion.motion);

    var s3 = State.init();
    const r3 = handle(&s3, press('G'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r3));
    try testing.expectEqual(Motion.Motion.last_line, r3.motion.motion);
}

test ": → command_mode; u → action undo; . → repeat_last" {
    var s = State.init();
    const r = handle(&s, press(':'), Keymaps.normal);
    try testing.expectEqual(.command_mode, tag(r));
    try testing.expectEqual(Mode.command, s.mode);

    var s2 = State.init();
    const r2 = handle(&s2, press('u'), Keymaps.normal);
    try testing.expectEqual(.action, tag(r2));
    try testing.expectEqual(KeyEvent.ActionId.undo, r2.action.action);
    // undo is not a "change" (vim: '.' does not repeat it) → not recorded
    try testing.expectEqual(@as(?KeyEvent.ActionId, null), s2.last_action);

    const r3 = handle(&s2, press('.'), Keymaps.normal);
    try testing.expectEqual(.action, tag(r3));
    try testing.expectEqual(KeyEvent.ActionId.repeat_last, r3.action.action);
    // '.' must not overwrite the recorded action either
    try testing.expectEqual(@as(?KeyEvent.ActionId, null), s2.last_action);

    // a repeatable action IS recorded for '.' replay
    var s3 = State.init();
    const r4 = handle(&s3, press('i'), Keymaps.normal);
    try testing.expectEqual(.action, tag(r4));
    try testing.expectEqual(KeyEvent.ActionId.insert_mode, r4.action.action);
    try testing.expectEqual(KeyEvent.ActionId.insert_mode, s3.last_action.?);
}

test "i → insert mode; unbound insert key → insert_char" {
    var s = State.init();
    const r = handle(&s, press('i'), Keymaps.normal);
    try testing.expectEqual(.action, tag(r));
    try testing.expectEqual(KeyEvent.ActionId.insert_mode, r.action.action);
    try testing.expectEqual(Mode.insert, s.mode);

    const r2 = handle(&s, press('x'), Keymaps.insert);
    try testing.expectEqual(.action, tag(r2));
    try testing.expectEqual(KeyEvent.ActionId.insert_char, r2.action.action);
}

test "insert: Esc → to_normal" {
    var s = State.init();
    s.mode = .insert;
    const r = handle(&s, esc(), Keymaps.insert);
    try testing.expectEqual(.to_normal, tag(r));
    try testing.expectEqual(Mode.normal, s.mode);
}

test "insert: j then k → to_normal (k is not inserted)" {
    var s = State.init();
    s.mode = .insert;
    const r1 = handle(&s, press('j'), Keymaps.insert);
    try testing.expectEqual(.action, tag(r1));
    try testing.expectEqual(KeyEvent.ActionId.insert_char, r1.action.action);
    const r2 = handle(&s, press('k'), Keymaps.insert);
    try testing.expectEqual(.to_normal, tag(r2));
    try testing.expectEqual(Mode.normal, s.mode);

    // a lone 'k' (not after 'j') is inserted
    var s2 = State.init();
    s2.mode = .insert;
    const r3 = handle(&s2, press('k'), Keymaps.insert);
    try testing.expectEqual(.action, tag(r3));
    try testing.expectEqual(KeyEvent.ActionId.insert_char, r3.action.action);
}

test "insert: Ctrl-c → to_normal" {
    var s = State.init();
    s.mode = .insert;
    const r = handle(&s, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }, Keymaps.insert);
    try testing.expectEqual(.to_normal, tag(r));
    try testing.expectEqual(Mode.normal, s.mode);
}

test "visual: v → visual_char; h → motion with exclusive_end" {
    var s = State.init();
    const r = handle(&s, press('v'), Keymaps.normal);
    try testing.expectEqual(.action, tag(r));
    try testing.expectEqual(KeyEvent.ActionId.visual_char, r.action.action);
    try testing.expectEqual(Mode.visual_char, s.mode);

    const r2 = handle(&s, press('h'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r2));
    try testing.expectEqual(Motion.Motion.left, r2.motion.motion);
    try testing.expect(r2.motion.exclusive_end);
}

test "Esc cancels pending count and pending operator" {
    var s = State.init();
    _ = handle(&s, press('5'), Keymaps.normal);
    _ = handle(&s, esc(), Keymaps.normal);
    const r = handle(&s, press('j'), Keymaps.normal);
    try testing.expectEqual(@as(u32, 1), r.motion.count);

    var s2 = State.init();
    _ = handle(&s2, press('d'), Keymaps.normal);
    _ = handle(&s2, esc(), Keymaps.normal);
    const r2 = handle(&s2, press('j'), Keymaps.normal);
    try testing.expectEqual(.motion, tag(r2)); // not op_motion
}

test "command mode: Esc exits to normal" {
    var s = State.init();
    _ = handle(&s, press(':'), Keymaps.normal);
    const r = handle(&s, esc(), Keymaps.normal);
    try testing.expectEqual(.to_normal, tag(r));
    try testing.expectEqual(Mode.normal, s.mode);
}
