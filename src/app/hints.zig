//! Keyboard hints (DESIGN.md §19, M2.6a): pure label generation, target
//! collection and prefix matching.
//!
//! Deliberately App/vaxis-independent: `src/app/hint_ui.zig` owns the
//! App-facing collection, rendering and input wiring. Everything here is
//! unit-testable without constructing an editor or a terminal.
//!
//! ## Label algorithm (DESIGN.md §19.3)
//!
//! Charset `asdfghjkl` (9 cells where every label has the SAME fixed
//! length): 1 char for 1–9 targets, 2 for 10–81, 3 for 82–729; more than
//! 729 targets are truncated and the leftover count is reported as
//! `+N more`. A label is the target's row-major index rendered in base 9,
//! most-significant digit first (`aa`, `as`, … `ll`, `saa`, …), so labels
//! are unique by construction and never auto-execute on a partial prefix —
//! the caller requires `label_len` characters.
//!
//! ## Complexity
//!
//! `labelFor` is O(1) via a comptime table (no allocation, no hashing).
//! `add` is O(1) with a fixed `max_targets` array; `endFrame` sorts the
//! collected targets in place with a stable insertion sort — O(n²) worst
//! case, but n is at most 128 and targets arrive almost sorted (drawing
//! order), so it is effectively O(n). Prefix matching is O(n) per keystroke
//! (n ≤ 128). No allocation happens anywhere in this module.

const std = @import("std");
const ws = @import("../ai/workspace.zig");
const navigator = @import("navigator.zig");

pub const WorkboxTab = ws.WorkboxTab;
pub const NavigatorTab = navigator.Tab;

/// qutebrowser-style home-row charset. Every label character is one cell.
pub const charset = "asdfghjkl";

/// Longest label (3 chars covers 729 targets).
pub const max_label_len: usize = 3;

/// Fixed target capacity: 128 visible targets is far above any current
/// screen (filetree rows + tabs + threads + workbox tabs), and keeps State
/// a plain value with no allocation.
pub const max_targets: usize = 128;

/// Targets past this index are not labeled (DESIGN.md §19.3 >729 rule).
pub const max_labeled: usize = 729;

/// 9^exp for exp 0..3. Kept local so the table block is self-contained.
fn pow9(exp: usize) usize {
    var v: usize = 1;
    var i: usize = 0;
    while (i < exp) : (i += 1) v *= charset.len;
    return v;
}

/// Comptime label table: `[len-1][index]` holds the `len`-character label
/// for `index`. Static storage means the renderer can hand vaxis a slice
/// that stays alive until `vx.render()` without allocating.
const label_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [max_label_len][max_labeled][max_label_len]u8 = undefined;
    for (1..max_label_len + 1) |len| {
        var index: usize = 0;
        while (index < pow9(len)) : (index += 1) {
            var digits: [max_label_len]u8 = .{ 0, 0, 0 };
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const divisor = pow9(len - 1 - i);
                digits[i] = charset[(index / divisor) % charset.len];
            }
            table[len - 1][index] = digits;
        }
    }
    break :blk table;
};

/// Fixed label length for `count` targets: 0, 1, 2 or 3. Counts above 729
/// still use 3 (the caller truncates via `labeledCount`).
pub fn labelLenFor(count: usize) usize {
    if (count == 0) return 0;
    if (count <= 9) return 1;
    if (count <= 81) return 2;
    return 3;
}

/// Number of targets that actually receive a label (≤ 729).
pub fn labeledCount(count: usize) usize {
    return @min(count, max_labeled);
}

/// `+N more` count for an oversized target set.
pub fn overflowCount(count: usize) usize {
    return count -| max_labeled;
}

/// Static label for `index` with fixed `len`. Returns "" for an invalid
/// (len, index) pair instead of panicking — a display routine must never
/// take the app down on a stale/out-of-range target.
pub fn labelFor(index: usize, len: usize) []const u8 {
    if (len == 0 or len > max_label_len) return "";
    if (index >= pow9(len)) return "";
    return label_table[len - 1][index][0..len];
}

/// One on-screen cell rectangle. Only `row`/`col` anchor the label; width
/// and height are used to clamp the target to the screen when registered.
pub const Rect = struct {
    row: u32,
    col: u32,
    width: u32,
    height: u32,
};

/// Clamp `rect` to a `rows`×`cols` screen. Returns null when the rect is
/// entirely off-screen or empty (such targets are not registered at all).
pub fn clampRect(rect: Rect, rows: u32, cols: u32) ?Rect {
    if (rows == 0 or cols == 0) return null;
    if (rect.width == 0 or rect.height == 0) return null;
    if (rect.row >= rows or rect.col >= cols) return null;
    return .{
        .row = rect.row,
        .col = rect.col,
        .width = @min(rect.width, cols - rect.col),
        .height = @min(rect.height, rows - rect.row),
    };
}

/// What activating a target does. Payloads are indices/slots, not copies of
/// business state: `src/app/hint_ui.zig` maps each variant onto the SAME App
/// method the keyboard path uses (no duplicated logic).
pub const Action = union(enum) {
    /// Select a filetree row without activating it (API completeness; M2.6a
    /// registers `filetree_activate` for rows, which also selects).
    filetree_select: usize,
    /// Select + focus the tree + Enter semantics (open a file / toggle a dir).
    filetree_activate: usize,
    /// Switch to the buffer in this slot (same as clicking / `[b`).
    buffer_select: usize,
    /// Close the buffer at this slot via the SAME path as `:bd` /
    /// `<leader>bk` (`closeBufferAt`). The last remaining buffer is never
    /// registered: closing it is a no-op, so no dead target exists.
    buffer_close: usize,
    /// Attach to the agent thread (Enter in the thread list).
    agent_thread_select: usize,
    /// Switch the Workbox tab.
    workbox_tab: WorkboxTab,
    /// New agent thread (`n` / `+`).
    agent_new,
    /// Focus the AI prompt row.
    agent_prompt_focus,
    /// Switch the left navigator tab (M2b1). Activating focuses the navigator.
    navigator_tab: NavigatorTab,
    /// Close the compact (<90 col) navigator peek overlay and return the
    /// keyboard to the editor. The icon rail stays visible.
    navigator_peek_close,
    /// Open the note at this index in the cached Notes list (Enter semantics).
    note_open: usize,
    /// Approve the pending inline edit (same path as `a`/Enter in Changes).
    inline_approve,
    /// Reject the pending inline edit (same path as `r`/`d` in Changes).
    inline_reject,
    /// Approve the staged agent edit (same path as `a`/Enter in Changes).
    agent_approve,
    /// Reject the staged agent edit (same path as `r`/`d` in Changes).
    agent_reject,
    /// Select the file at this index in a multi-file staged patch review
    /// (same path as `j`/`k` in Changes).
    agent_patch_file: usize,
    /// Allow the staged terminal command (same path as `a`/Enter on the
    /// Terminal tab). Never auto-executes: the human must activate this.
    agent_terminal_allow,
    /// Deny the staged terminal command (same path as `r`/`d`).
    agent_terminal_deny,
    /// Toggle the expanded result view of the tool card at this message
    /// index in the active thread (M3a). A real action: no new control is
    /// invented, and only visible Chat cards register.
    tool_card_toggle: usize,
};

pub const Target = struct {
    rect: Rect,
    action: Action,
};

/// One target that needs a label this frame.
pub const KeyResult = union(enum) {
    /// Not a hint character (or hint mode is not active) — ignore the key.
    ignored,
    /// Prefix/flash/backspace state changed; keep hint mode active.
    updated,
    /// A complete label was typed: execute `action` (the caller exits hint
    /// mode before running it).
    activate: Action,
};

/// Hint-mode state. A plain value field on App: no allocation, no deinit.
pub const State = struct {
    active: bool = false,
    /// True while the current render pass is collecting targets. `add` is a
    /// no-op outside it, so normal (non-hint) frames pay one boolean test.
    collecting: bool = false,
    count: usize = 0,
    targets: [max_targets]Target = undefined,
    prefix: [max_label_len]u8 = .{ 0, 0, 0 },
    prefix_len: u8 = 0,
    /// Last prefix was not a label prefix: the renderer shows "no match"
    /// until the next hint keystroke. Hint mode stays active.
    flash: bool = false,
    clamp_rows: u32 = 0,
    clamp_cols: u32 = 0,
    /// Target count at the last completed frame. If it changes (resize, rail
    /// open/close, stream settling layout), a stale typed prefix is cleared
    /// instead of silently pointing at a relabeled target.
    last_count: usize = 0,
    overflow: usize = 0,
    /// Scratch space for `statusText`. The returned slice must stay valid
    /// until `vx.render()` (vaxis cells reference the text), so it cannot
    /// live in the drawing function's stack frame; an App/State-owned buffer
    /// also keeps the overlay allocation-free.
    status_buf: [96]u8 = undefined,

    /// `<leader>j`: enter hint mode with a clean prefix. Collection starts on
    /// the next render pass.
    pub fn beginMode(self: *State) void {
        self.active = true;
        self.collecting = false;
        self.count = 0;
        self.prefix_len = 0;
        self.flash = false;
        self.last_count = 0;
        self.overflow = 0;
    }

    /// Esc / activation teardown. No side effects beyond hint state.
    pub fn cancel(self: *State) void {
        self.active = false;
        self.collecting = false;
        self.count = 0;
        self.prefix_len = 0;
        self.flash = false;
        self.last_count = 0;
        self.overflow = 0;
    }

    /// Start a frame's target collection. No-op (one branch) when inactive:
    /// normal frames never touch the target array.
    pub fn beginFrame(self: *State, rows: u32, cols: u32) void {
        if (!self.active) {
            self.collecting = false;
            return;
        }
        self.collecting = true;
        self.count = 0;
        self.clamp_rows = rows;
        self.clamp_cols = cols;
    }

    /// Register one visible target. Clamped to the screen; off-screen/empty
    /// rects and targets past capacity are dropped. Cheap no-op when not
    /// collecting.
    pub fn add(self: *State, rect: Rect, action: Action) void {
        if (!self.collecting or self.count >= max_targets) return;
        const r = clampRect(rect, self.clamp_rows, self.clamp_cols) orelse return;
        self.targets[self.count] = .{ .rect = r, .action = action };
        self.count += 1;
    }

    /// Finish collection: row-major sort (top→bottom, left→right; stable for
    /// equal positions so registration order breaks ties) and bookkeeping.
    pub fn endFrame(self: *State) void {
        self.collecting = false;
        if (!self.active) return;
        sortTargets(self.targets[0..self.count]);
        self.overflow = overflowCount(self.count);
        if (self.count != self.last_count) {
            // The label set may have changed under a partly-typed prefix.
            self.prefix_len = 0;
            self.flash = false;
            self.last_count = self.count;
        }
    }

    pub fn labelLen(self: *const State) usize {
        return labelLenFor(labeledCount(self.count));
    }

    pub fn labeled(self: *const State) usize {
        return labeledCount(self.count);
    }

    /// Static label for the target at `index` (empty for unlabeled indices).
    pub fn labelAt(self: *const State, index: usize) []const u8 {
        if (index >= labeledCount(self.count)) return "";
        return labelFor(index, self.labelLen());
    }

    /// True when the target's label starts with the typed prefix (all labels
    /// match while the prefix is empty).
    pub fn matches(self: *const State, index: usize) bool {
        if (index >= labeledCount(self.count)) return false;
        if (self.prefix_len == 0) return true;
        const label = self.labelAt(index);
        if (label.len == 0) return false;
        return std.mem.startsWith(u8, label, self.prefix[0..self.prefix_len]);
    }

    pub fn matchedCount(self: *const State) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < labeledCount(self.count)) : (i += 1) {
            if (self.matches(i)) n += 1;
        }
        return n;
    }

    /// Feed one printable character. Chars outside the charset are ignored
    /// (they never disturb a typo). A character that leaves every label
    /// unmatched clears the prefix and sets `flash`; hint mode stays active.
    /// Only a COMPLETE label activates — a unique prefix never auto-fires.
    pub fn typeChar(self: *State, ch: u8) KeyResult {
        if (!self.active) return .ignored;
        const len = self.labelLen();
        if (len == 0 or self.prefix_len >= len) return .ignored;
        if (std.mem.indexOfScalar(u8, charset, ch) == null) return .ignored;
        var candidate: [max_label_len]u8 = .{ 0, 0, 0 };
        @memcpy(candidate[0..self.prefix_len], self.prefix[0..self.prefix_len]);
        candidate[self.prefix_len] = ch;
        const candidate_len: usize = @as(usize, self.prefix_len) + 1;

        var match: ?usize = null;
        var i: usize = 0;
        while (i < labeledCount(self.count)) : (i += 1) {
            const label = self.labelAt(i);
            if (label.len == 0) continue;
            if (std.mem.startsWith(u8, label, candidate[0..candidate_len])) {
                match = i;
                break;
            }
        }
        if (match == null) {
            self.prefix_len = 0;
            self.flash = true;
            return .updated;
        }
        if (candidate_len == len) {
            return .{ .activate = self.targets[match.?].action };
        }
        @memcpy(self.prefix[0..candidate_len], candidate[0..candidate_len]);
        self.prefix_len = @intCast(candidate_len);
        self.flash = false;
        return .updated;
    }

    /// Backspace: drop the last prefix character. At an empty prefix there is
    /// nothing to edit (the key is still consumed by hint mode).
    pub fn backspace(self: *State) bool {
        if (!self.active or self.prefix_len == 0) return false;
        self.prefix_len -= 1;
        self.flash = false;
        return true;
    }

    /// Compact status-bar text. Writes into `buf` (no allocation) and never
    /// fails visibly: the "HINTS" fallback still tells the user where they are.
    pub fn statusText(self: *State) []const u8 {
        if (!self.active) return "";
        const buf = &self.status_buf;
        if (self.count == 0) {
            return std.fmt.bufPrint(buf, "HINTS · no targets", .{}) catch "HINTS";
        }
        if (self.flash) {
            return std.fmt.bufPrint(buf, "HINTS · no match · Esc cancel", .{}) catch "HINTS";
        }
        if (self.overflow > 0) {
            return std.fmt.bufPrint(buf, "HINTS · {d} targets (+{d} more) · Esc cancel", .{
                labeledCount(self.count), self.overflow,
            }) catch "HINTS";
        }
        return std.fmt.bufPrint(buf, "HINTS · {d} targets · Esc cancel", .{self.count}) catch "HINTS";
    }
};

fn targetLess(a: Target, b: Target) bool {
    if (a.rect.row != b.rect.row) return a.rect.row < b.rect.row;
    return a.rect.col < b.rect.col;
}

/// Stable insertion sort over at most `max_targets`=128 entries: no
/// allocation, deterministic, and equal screen positions keep registration
/// order.
fn sortTargets(items: []Target) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and targetLess(key, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

/// Decode a label back to its index (test invariant only).
fn decodeLabel(label: []const u8) ?usize {
    if (label.len == 0 or label.len > max_label_len) return null;
    var value: usize = 0;
    for (label) |ch| {
        const digit = std.mem.indexOfScalar(u8, charset, ch) orelse return null;
        value = value * charset.len + digit;
    }
    return value;
}

// ---------------------------------------------------------------------------
// Unit tests (DESIGN.md §19.7)
// ---------------------------------------------------------------------------

test "hints: label length boundaries 0/1/9/10/81/82/729/overflow" {
    const cases = [_]struct { count: usize, len: usize }{
        .{ .count = 0, .len = 0 },
        .{ .count = 1, .len = 1 },
        .{ .count = 9, .len = 1 },
        .{ .count = 10, .len = 2 },
        .{ .count = 81, .len = 2 },
        .{ .count = 82, .len = 3 },
        .{ .count = 729, .len = 3 },
        .{ .count = 730, .len = 3 },
        .{ .count = 10_000, .len = 3 },
    };
    for (cases) |c| try std.testing.expectEqual(c.len, labelLenFor(c.count));

    try std.testing.expectEqual(@as(usize, 0), overflowCount(0));
    try std.testing.expectEqual(@as(usize, 0), overflowCount(729));
    try std.testing.expectEqual(@as(usize, 1), overflowCount(730));
    try std.testing.expectEqual(@as(usize, 729), labeledCount(730));
    try std.testing.expectEqual(@as(usize, 729), labeledCount(10_000));
}

test "hints: labels are fixed length, unique and deterministic" {
    for ([_]usize{ 1, 9, 10, 81, 82, 729 }) |count| {
        const len = labelLenFor(count);
        var seen: [max_labeled]bool = @splat(false);
        var i: usize = 0;
        while (i < labeledCount(count)) : (i += 1) {
            const label = labelFor(i, len);
            try std.testing.expectEqual(len, label.len);
            const decoded = decodeLabel(label) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(i, decoded);
            try std.testing.expect(!seen[decoded]);
            seen[decoded] = true;
            // generation is deterministic
            try std.testing.expectEqualStrings(label, labelFor(i, len));
        }
    }
}

test "hints: first/last labels of each length" {
    try std.testing.expectEqualStrings("a", labelFor(0, 1));
    try std.testing.expectEqualStrings("l", labelFor(8, 1));
    try std.testing.expectEqualStrings("aa", labelFor(0, 2));
    try std.testing.expectEqualStrings("as", labelFor(1, 2));
    try std.testing.expectEqualStrings("sa", labelFor(9, 2));
    try std.testing.expectEqualStrings("ll", labelFor(80, 2));
    try std.testing.expectEqualStrings("aaa", labelFor(0, 3));
    try std.testing.expectEqualStrings("aas", labelFor(1, 3));
    try std.testing.expectEqualStrings("lll", labelFor(728, 3));
    // invalid selectors are empty, never a panic
    try std.testing.expectEqualStrings("", labelFor(0, 0));
    try std.testing.expectEqualStrings("", labelFor(0, 4));
    try std.testing.expectEqualStrings("", labelFor(729, 3));
}

test "hints: 729 labels generated in one O(n) pass" {
    var sum: usize = 0;
    var i: usize = 0;
    while (i < max_labeled) : (i += 1) {
        const label = labelFor(i, 3);
        try std.testing.expectEqual(@as(usize, 3), label.len);
        sum += decodeLabel(label) orelse return error.TestUnexpectedResult;
    }
    // 0+1+...+728: a closed-form check that every index appeared exactly once
    // (uniqueness + completeness without allocating a hash set).
    try std.testing.expectEqual(@as(usize, 728 * 729 / 2), sum);
}

test "hints: row-major ordering and stable same-position ties" {
    var st = State{};
    st.beginMode();
    st.beginFrame(24, 80);
    st.add(.{ .row = 5, .col = 10, .width = 4, .height = 1 }, .{ .buffer_select = 50 });
    st.add(.{ .row = 1, .col = 20, .width = 4, .height = 1 }, .{ .buffer_select = 20 });
    st.add(.{ .row = 1, .col = 5, .width = 4, .height = 1 }, .{ .buffer_select = 5 });
    // same cell twice: registration order breaks the tie
    st.add(.{ .row = 1, .col = 5, .width = 4, .height = 1 }, .{ .buffer_select = 6 });
    st.add(.{ .row = 0, .col = 0, .width = 4, .height = 1 }, .{ .buffer_select = 0 });
    st.endFrame();

    try std.testing.expectEqual(@as(usize, 5), st.count);
    try std.testing.expectEqual(@as(usize, 0), st.targets[0].action.buffer_select);
    try std.testing.expectEqual(@as(usize, 5), st.targets[1].action.buffer_select);
    try std.testing.expectEqual(@as(usize, 6), st.targets[2].action.buffer_select);
    try std.testing.expectEqual(@as(usize, 20), st.targets[3].action.buffer_select);
    try std.testing.expectEqual(@as(usize, 50), st.targets[4].action.buffer_select);
    try std.testing.expectEqualStrings("a", st.labelAt(0));
    try std.testing.expectEqualStrings("s", st.labelAt(1));
}

test "hints: prefix matching, backspace and invalid prefix" {
    var st = State{};
    st.beginMode();
    st.beginFrame(24, 80);
    var i: usize = 0;
    while (i < 10) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    try std.testing.expectEqual(@as(usize, 2), st.labelLen());
    try std.testing.expectEqual(@as(usize, 10), st.matchedCount());

    // 'a' narrows to the nine labels starting with 'a'
    switch (st.typeChar('a')) {
        .updated => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u8, 1), st.prefix_len);
    try std.testing.expectEqual(@as(usize, 9), st.matchedCount());
    try std.testing.expect(st.matches(0));
    try std.testing.expect(!st.matches(9)); // "sa"

    // backspace returns to the full set
    try std.testing.expect(st.backspace());
    try std.testing.expectEqual(@as(u8, 0), st.prefix_len);
    try std.testing.expectEqual(@as(usize, 10), st.matchedCount());
    try std.testing.expect(!st.backspace()); // empty prefix: no change

    // non-charset characters are ignored, not flashed
    switch (st.typeChar('x')) {
        .ignored => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!st.flash);

    // "ss" matches no label: clear + flash, stay in hint mode
    _ = st.typeChar('s');
    switch (st.typeChar('s')) {
        .updated => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(st.flash);
    try std.testing.expectEqual(@as(u8, 0), st.prefix_len);
    try std.testing.expect(st.active);

    // a complete label activates (only on the full length)
    switch (st.typeChar('a')) {
        .updated => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!st.flash);
    const second = st.typeChar('a');
    switch (second) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 0), a.buffer_select),
        else => return error.TestUnexpectedResult,
    }
}

test "hints: no activation on a unique partial prefix" {
    var st = State{};
    st.beginMode();
    st.beginFrame(24, 80);
    var i: usize = 0;
    while (i < 10) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    // "s" matches only "sa" (target 9) but must NOT fire yet
    switch (st.typeChar('s')) {
        .updated => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), st.matchedCount());
    switch (st.typeChar('a')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 9), a.buffer_select),
        else => return error.TestUnexpectedResult,
    }
}

test "hints: action payloads survive collection and activation" {
    var st = State{};
    st.beginMode();
    st.beginFrame(30, 120);
    st.add(.{ .row = 0, .col = 0, .width = 3, .height = 1 }, .{ .filetree_select = 7 });
    st.add(.{ .row = 0, .col = 4, .width = 3, .height = 1 }, .{ .filetree_activate = 8 });
    st.add(.{ .row = 0, .col = 8, .width = 3, .height = 1 }, .{ .buffer_select = 2 });
    st.add(.{ .row = 0, .col = 12, .width = 3, .height = 1 }, .{ .agent_thread_select = 1 });
    st.add(.{ .row = 0, .col = 16, .width = 3, .height = 1 }, .{ .workbox_tab = .tools });
    st.add(.{ .row = 0, .col = 20, .width = 3, .height = 1 }, .agent_new);
    st.add(.{ .row = 0, .col = 24, .width = 3, .height = 1 }, .agent_prompt_focus);
    st.add(.{ .row = 0, .col = 28, .width = 3, .height = 1 }, .{ .navigator_tab = .notes });
    st.add(.{ .row = 0, .col = 32, .width = 3, .height = 1 }, .{ .note_open = 4 });
    st.endFrame();
    try std.testing.expectEqual(@as(usize, 1), st.labelLen());
    try std.testing.expectEqual(@as(usize, 9), st.count);

    switch (st.typeChar('a')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 7), a.filetree_select),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('s')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 8), a.filetree_activate),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('d')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 2), a.buffer_select),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('f')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 1), a.agent_thread_select),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('g')) {
        .activate => |a| try std.testing.expectEqual(WorkboxTab.tools, a.workbox_tab),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('h')) {
        .activate => |a| try std.testing.expect(std.meta.eql(a, Action.agent_new)),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('j')) {
        .activate => |a| try std.testing.expect(std.meta.eql(a, Action.agent_prompt_focus)),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('k')) {
        .activate => |a| try std.testing.expectEqual(NavigatorTab.notes, a.navigator_tab),
        else => return error.TestUnexpectedResult,
    }
    switch (st.typeChar('l')) {
        .activate => |a| try std.testing.expectEqual(@as(usize, 4), a.note_open),
        else => return error.TestUnexpectedResult,
    }
}

test "hints: rect clamping and off-screen/empty targets" {
    var st = State{};
    st.beginMode();
    st.beginFrame(24, 80);
    try std.testing.expectEqual(@as(usize, 0), st.count);

    // clipped at the right/bottom edge
    st.add(.{ .row = 23, .col = 79, .width = 5, .height = 3 }, .agent_new);
    try std.testing.expectEqual(@as(usize, 1), st.count);
    try std.testing.expectEqual(@as(u32, 1), st.targets[0].rect.width);
    try std.testing.expectEqual(@as(u32, 1), st.targets[0].rect.height);

    // fully off-screen / zero-size / empty screen are dropped
    st.add(.{ .row = 24, .col = 0, .width = 2, .height = 1 }, .agent_new);
    st.add(.{ .row = 0, .col = 80, .width = 2, .height = 1 }, .agent_new);
    st.add(.{ .row = 0, .col = 0, .width = 0, .height = 1 }, .agent_new);
    st.add(.{ .row = 0, .col = 0, .width = 1, .height = 0 }, .agent_new);
    try std.testing.expectEqual(@as(usize, 1), st.count);

    // over-wide rect is clamped to the screen width
    st.add(.{ .row = 0, .col = 10, .width = 500, .height = 1 }, .agent_new);
    try std.testing.expectEqual(@as(u32, 70), st.targets[1].rect.width);

    try std.testing.expectEqual(@as(?Rect, null), clampRect(.{ .row = 0, .col = 0, .width = 1, .height = 1 }, 0, 0));
}

test "hints: fixed capacity truncates extra targets" {
    var st = State{};
    st.beginMode();
    st.beginFrame(100, 100);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        st.add(.{ .row = @intCast(i / 100), .col = @intCast(i % 100), .width = 1, .height = 1 }, .{ .buffer_select = i });
    }
    try std.testing.expectEqual(max_targets, st.count);
    st.endFrame();
    try std.testing.expectEqual(@as(usize, 3), st.labelLen());
}

test "hints: inactive frames collect nothing and status text is stable" {
    var st = State{};
    try std.testing.expectEqualStrings("", st.statusText());

    st.beginFrame(24, 80);
    st.add(.{ .row = 0, .col = 0, .width = 1, .height = 1 }, .agent_new);
    try std.testing.expectEqual(@as(usize, 0), st.count); // inactive: no-op

    st.beginMode();
    try std.testing.expectEqualStrings("HINTS · no targets", st.statusText());

    st.beginFrame(24, 80);
    var i: usize = 0;
    while (i < 12) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    try std.testing.expectEqualStrings("HINTS · 12 targets · Esc cancel", st.statusText());

    st.cancel();
    st.beginMode();
    st.beginFrame(24, 80);
    i = 0;
    while (i < 10) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    _ = st.typeChar('s');
    _ = st.typeChar('s'); // "ss" matches nothing
    try std.testing.expectEqualStrings("HINTS · no match · Esc cancel", st.statusText());

    st.count = 729;
    st.overflow = 3;
    st.flash = false;
    try std.testing.expectEqualStrings("HINTS · 729 targets (+3 more) · Esc cancel", st.statusText());
}

test "hints: target count change clears a stale prefix" {
    var st = State{};
    st.beginMode();
    st.beginFrame(24, 80);
    var i: usize = 0;
    while (i < 10) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    switch (st.typeChar('a')) {
        .updated => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u8, 1), st.prefix_len);

    // Next frame has one more target: the typed prefix is dropped instead of
    // silently matching a different label.
    st.beginFrame(24, 80);
    i = 0;
    while (i < 11) : (i += 1) st.add(.{ .row = 0, .col = @intCast(i), .width = 1, .height = 1 }, .{ .buffer_select = i });
    st.endFrame();
    try std.testing.expectEqual(@as(u8, 0), st.prefix_len);
    try std.testing.expectEqual(@as(usize, 11), st.count);
}
