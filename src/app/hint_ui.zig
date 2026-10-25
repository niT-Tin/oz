//! Keyboard hints (M2.6a) — App-facing half of DESIGN.md §19.
//!
//! Pure label/target logic lives in `src/app/hints.zig` (no App, no vaxis).
//! This file owns the three integration points:
//!   - collection: `drawAiRail` / `renderFiletree` / the tab bar call
//!     `addHintTarget` while they draw, only on hint-mode frames;
//!   - rendering: one final overlay pass after the status bar (labels +
//!     the compact `HINTS · N targets · Esc cancel` indicator);
//!   - input: `handleKey` routes every key here first while hint mode is
//!     active, and `execHintAction` maps each target action onto the SAME
//!     App method the keyboard path already uses (no duplicated logic).
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");
const hints = @import("hints.zig");

/// `<leader>j` (or `<leader>j` from the thread list): enter hint mode. The
/// current focus is preserved; the next render pass collects every visible
/// target and draws the labels (the run loop renders after every key).
pub fn beginHintMode(self: *App) void {
    self.hints.beginMode();
    // Hint mode is a fresh modal command: no editor-side pending sequence
    // may fire when it exits.
    self.pending_window = false;
    self.pending_replace = null;
    self.ai.rail_pending_leader = false;
}

/// Register one visible target. Cheap no-op unless this frame is collecting,
/// so ordinary frames cannot pay O(targets) here.
pub fn addHintTarget(self: *App, rect: hints.Rect, action: hints.Action) void {
    self.hints.add(rect, action);
}

/// Final overlay pass: labels at each target's top-left, then the status
/// indicator. Called after the status bar / rail / workbox are drawn and
/// immediately before `vx.render()`, so labels are topmost. All coordinates
/// come from the clamped target rects; the status row is never painted.
pub fn drawHintOverlay(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    _ = a;
    if (!self.hints.active) return;
    self.hints.endFrame();
    const rows: u32 = win.height;
    const cols: u32 = win.width;
    if (rows == 0 or cols == 0) return;

    const labeled = self.hints.labeled();
    var i: usize = 0;
    while (i < labeled) : (i += 1) {
        const target = self.hints.targets[i];
        // Content rows only: the status bar owns the last row and must stay
        // readable (the hint indicator is drawn there by this same pass).
        if (target.rect.row >= rows -| 1) continue;
        const label = self.hints.labelAt(i);
        if (label.len == 0) continue;
        // Clamp the label so it never paints the terminal's last column:
        // one-cell targets at the right edge (the rail's "+" button) would
        // otherwise overhang into the rail's panel edge. Screen bounds are
        // checked by the target registration; this is the display clamp.
        if (label.len + 1 > cols) continue;
        const max_start = cols - 1 - @as(u32, @intCast(label.len));
        const col = @min(target.rect.col, max_start);
        // Matching labels keep the accent tint; labels outside the typed
        // prefix dim so the next keystroke's choices stand out. Static
        // charset slices stay valid until vx.render() (no allocation).
        const style: vaxis.Style = if (self.hints.matches(i))
            .{ .fg = .{ .rgb = self.theme.bg }, .bg = .{ .rgb = self.theme.accent }, .bold = true }
        else
            .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_status } };
        const seg = [_]vaxis.Segment{.{ .text = label, .style = style }};
        _ = win.print(&seg, .{
            .row_offset = @intCast(target.rect.row),
            .col_offset = @intCast(col),
            .wrap = .none,
        });
    }

    // Compact modal indicator, right-aligned on the status bar (the AI
    // status block is suppressed while hint mode is active — this replaces
    // it). Dashboard frames have no status bar content but still reserve the
    // bottom row, so the same placement works there.
    const text = self.hints.statusText();
    if (text.len == 0) return;
    const cells: u32 = @intCast(autil.cellWidth(win, text));
    const col: u32 = if (cells < cols) cols - cells else 0;
    const style: vaxis.Style = if (self.hints.flash)
        .{ .fg = .{ .rgb = self.theme.diag_error }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true }
    else
        .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true };
    const seg = [_]vaxis.Segment{.{ .text = text, .style = style }};
    _ = win.print(&seg, .{ .row_offset = @intCast(rows - 1), .col_offset = @intCast(col), .wrap = .none });
}

/// Hint-mode key routing. Only label characters, Backspace and Esc have an
/// effect; every other key is consumed without side effects (modal for its
/// keys only — the run loop keeps draining AI streams and background jobs).
pub fn handleHintKey(self: *App, key: vaxis.Key) !void {
    if (!self.hints.active) return;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.codepoint == vaxis.Key.escape) {
        self.hints.cancel();
        return;
    }
    if (key.codepoint == vaxis.Key.backspace) {
        _ = self.hints.backspace();
        return;
    }
    // vaxis reports ASCII label keys as their codepoint; anything else
    // (CJK text, function keys, …) is ignored.
    if (key.codepoint > 0x7f) return;
    switch (self.hints.typeChar(@intCast(key.codepoint))) {
        .ignored, .updated => {},
        .activate => |action| {
            // Exit BEFORE running the action so the action's focus policy is
            // the only one in effect and a failing action cannot leave hint
            // mode half-alive.
            self.hints.cancel();
            self.execHintAction(action) catch |err| {
                const text = std.fmt.allocPrint(self.alloc, "hint action failed: {s}", .{@errorName(err)}) catch return;
                self.setMsg(text) catch self.alloc.free(text);
            };
        },
    }
}

/// Map a hint action onto the existing App method for that target. Payloads
/// are bounds-checked first: a stale target (the layout changed between
/// collection and activation) exits hint mode without touching state.
pub fn execHintAction(self: *App, action: hints.Action) !void {
    switch (action) {
        .filetree_select => |idx| {
            if (idx >= self.filetree_rows.items.len) return;
            self.filetree_sel = idx;
            self.focus = .filetree;
        },
        .filetree_activate => |idx| {
            if (idx >= self.filetree_rows.items.len) return;
            self.filetree_sel = idx;
            self.focus = .filetree;
            try self.activateFiletreeSelection();
        },
        .buffer_select => |idx| {
            if (idx >= self.buffers.items.len) return;
            // Same as clicking the tab / the buffer picker: the focused
            // editor shows that buffer.
            self.focus = .buffer;
            self.switchTo(idx);
        },
        .agent_thread_select => |idx| {
            if (idx >= self.ai.threads.items.items.len) return;
            // Enter in the thread list: attach, focus the prompt, show Chat.
            self.aiSelectThread(idx);
        },
        .workbox_tab => |tab| {
            self.aiSetWorkboxTab(tab);
        },
        .agent_new => try self.aiNewThread(),
        .agent_prompt_focus => try self.aiFocusPrompt(),
    }
}
