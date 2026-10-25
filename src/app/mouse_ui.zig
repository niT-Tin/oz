//! Mouse (feat/mouse) — App-facing half of the mouse feature.
//!
//! Pure hit-testing/scroll/mapping lives in `src/app/mouse.zig` (no App, no
//! terminal). This file owns the integration:
//!   - lifecycle: enable/disable vaxis mouse reporting (cell coordinates);
//!   - collection: every render pass while mouse is enabled registers the
//!     SAME hint targets the label overlay would register (via
//!     `hint_ui.addHintTarget`), plus mouse-only pane/separator/scroll
//!     regions;
//!   - dispatch: a left press executes the target's existing App method
//!     (`execHintAction`, `switchWindowTo`, `aiSelectThread`, …); the wheel
//!     moves the same state the keyboard scroll keys move.
//!
//! Mouse click never invents a second approve/reject/close path: hint
//! actions call `execHintAction`, which is the single mapping used by
//! `<leader>j`. Clicking an empty area is a no-op (no fake actions).
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const term = @import("../term.zig");
const editor = @import("../editor/root.zig");
const hints = @import("hints.zig");
const mouse = @import("mouse.zig");

/// Lines moved by one wheel notch over an editor pane. The renderer always
/// keeps the cursor visible, so the viewport follows: wheel = a 3-line
/// vertical cursor move (column preserved), the same operation repeated
/// `j`/`k` performs. Scrolling an unfocused split moves THAT pane's cursor
/// without stealing keyboard focus.
pub const wheel_lines: u32 = 3;

/// Lines scrolled by one wheel notch in the workbox transcript/diff.
pub const wheel_workbox_rows: i64 = 3;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Turn on vaxis mouse reporting. Force CELL coordinates: hit targets are
/// cell rectangles, so even a terminal advertising SGR pixel mode gets the
/// plain 1006 cell protocol (vaxis's `translateMouse` is not needed then).
/// Failure is non-fatal: the editor still starts and runs keyboard-only.
pub fn enableMouse(self: *App) void {
    if (self.mouse.enabled) return;
    self.vx.caps.sgr_pixels = false;
    self.vx.setMouseMode(self.tty.writer(), true) catch return;
    self.mouse.enabled = true;
}

/// Turn mouse reporting off. Idempotent and safe on every exit/error path.
/// On success clear vaxis's own flag so `Vaxis.deinit` does not emit a second
/// reset; on failure leave it set so deinit retries the reset.
pub fn disableMouse(self: *App) void {
    if (!self.mouse.enabled) return;
    self.mouse.enabled = false;
    self.mouse.collecting = false;
    self.mouse.count = 0;
    self.vx.setMouseMode(self.tty.writer(), false) catch return;
    self.vx.state.mouse = false;
}

// ---------------------------------------------------------------------------
// Collection (called from the render pass)
// ---------------------------------------------------------------------------

pub fn beginMouseFrame(self: *App, rows: u32, cols: u32) void {
    self.mouse.beginFrame(rows, cols);
}

/// True when this frame should register clickable geometry. Hint mode keeps
/// its exact behavior; mouse frames reuse the same registrations WITHOUT
/// drawing labels (the overlay is gated on `hints.active`).
pub fn mouseTargetsCollecting(self: *const App) bool {
    return self.hints.collecting or self.mouse.collecting;
}

/// Register one hint-geometry target for mouse hit-testing. Called from
/// `hint_ui.addHintTarget`, so every existing target becomes clickable with
/// no duplicated rectangles.
pub fn addMouseHintTarget(self: *App, rect: hints.Rect, action: hints.Action) void {
    self.mouse.add(.{ .row = rect.row, .col = rect.col, .width = rect.width, .height = rect.height }, .{
        .click = .{ .hint = action },
    });
}

/// A split leaf: click focuses it and places the cursor; wheel moves that
/// pane's cursor.
pub fn addMousePaneTarget(self: *App, win: usize, row: u32, col: u32, height: u32, width: u32) void {
    if (height == 0 or width == 0) return;
    self.mouse.add(.{ .row = row, .col = col, .width = width, .height = height }, .{
        .click = .{ .focus_pane = win },
    });
    self.mouse.add(.{ .row = row, .col = col, .width = width, .height = height }, .{
        .scroll = .{ .editor = win },
    });
}

/// Split separator: a click is explicitly a no-op in v1 (no resize), and the
/// 1-cell-wide target wins over the adjacent pane by area.
pub fn addMouseSeparatorTarget(self: *App, row: u32, col: u32, len: u32, horizontal: bool) void {
    if (horizontal) {
        self.mouse.add(.{ .row = row, .col = col, .width = len, .height = 1 }, .{ .click = .separator });
    } else {
        self.mouse.add(.{ .row = row, .col = col, .width = 1, .height = len }, .{ .click = .separator });
    }
}

/// Region that the wheel scrolls.
pub fn addMouseScrollTarget(self: *App, row: u32, col: u32, width: u32, height: u32, scroll: mouse.Scroll) void {
    if (height == 0 or width == 0) return;
    self.mouse.add(.{ .row = row, .col = col, .width = width, .height = height }, .{ .scroll = scroll });
}

// ---------------------------------------------------------------------------
// Event handling (run loop)
// ---------------------------------------------------------------------------

/// Handle one vaxis mouse event. Returns true when something changed and the
/// run loop should render. Motion/drag/release events and unbound buttons
/// return false: they must not cause frames or steal terminal selection.
pub fn handleMouse(self: *App, m: vaxis.Mouse) !bool {
    if (!self.mouse.enabled) return false;
    // Plain Shift-drag is the terminal's own text-selection escape hatch;
    // if a terminal still reports a Shift-modified mouse event, leave it to
    // the terminal instead of acting on a target under the drag.
    if (m.mods.shift) return false;
    const win = self.vx.window();
    if (win.width == 0 or win.height == 0) return false;
    // Targets are collected from the last rendered frame. After a resize the
    // screen size no longer matches them — ignore until the next render so a
    // click cannot be mapped through stale geometry.
    if (self.mouse.rows != win.height or self.mouse.cols != win.width) return false;
    if (m.col < 0 or m.row < 0) return false;
    if (@as(i64, m.col) >= @as(i64, win.width) or @as(i64, m.row) >= @as(i64, win.height)) return false;
    const col: u32 = @intCast(m.col);
    const row: u32 = @intCast(m.row);

    switch (m.button) {
        .wheel_up => {
            if (m.type != .press) return false;
            return try handleWheel(self, col, row, -1);
        },
        .wheel_down => {
            if (m.type != .press) return false;
            return try handleWheel(self, col, row, 1);
        },
        .left => {
            if (m.type != .press) return false;
            return try handleLeftClick(self, col, row);
        },
        // Middle/right/wheel-left/right and high buttons are intentionally
        // unbound in this first version.
        else => return false,
    }
}

/// Modal surfaces own their interaction: a click/wheel behind a picker,
/// list, prompt, command line or hint overlay must never reach a hidden
/// target. Dashboard has no targets (no-op by construction).
fn mouseBlocked(self: *App) bool {
    if (self.hints.active) return true;
    if (self.picker_active or self.diag_list_active or self.nav_list_active) return true;
    if (self.git_preview != null) return true;
    if (self.inlinePromptOpen()) return true;
    if (self.state.mode == .command) return true;
    return false;
}

/// Top-left column of the open AI rail, when it is drawn. The drawer mode
/// overlays the editor, so clicks/wheel over its body must not fall through
/// to the pane targets registered underneath it.
fn openRailCol(self: *App) ?u32 {
    if (!self.ai.rail_open) return null;
    const lay = self.aiLayout();
    if (lay.mode == .hidden) return null;
    return lay.rail_col;
}

fn railContains(self: *App, col: u32, row: u32) bool {
    if (!self.ai.rail_open) return false;
    const lay = self.aiLayout();
    if (lay.mode == .hidden) return false;
    const win = self.vx.window();
    if (row + app_mod.status_row_count >= win.height) return false;
    return col >= lay.rail_col and col < lay.rail_col + lay.rail_width;
}

/// Terminal pane cell test (the terminal is drawn as an overlay, so it is
/// hit-tested before the pane/scroll registry).
fn terminalContains(self: *App, col: u32, row: u32) bool {
    if (!term.supported) return false;
    if (self.term_pane == null) return false;
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const r = self.termRect(arena.allocator());
    if (r.w == 0 or r.h == 0) return false;
    return col >= r.x and col < r.x + r.w and row >= r.y and row < r.y + r.h;
}

fn handleLeftClick(self: *App, col: u32, row: u32) !bool {
    if (mouseBlocked(self)) return false;
    const in_rail = railContains(self, col, row);

    // Z-order: the terminal overlay is drawn above the panes/filetree but
    // BELOW the AI rail, so a point covered by the rail belongs to the rail.
    // Elsewhere a terminal hit focuses the child; any other click returns
    // keyboard focus to the editor.
    if (!in_rail and terminalContains(self, col, row)) {
        if (self.term_pane) |*tp| tp.focused = true;
        // A terminal click takes over the keyboard; an AI prompt must not
        // resume owning keys when the terminal loses focus later.
        self.ai.focus = .editor;
        return true;
    }
    if (term.supported) {
        if (self.term_pane) |*tp| tp.focused = false;
    }

    const hit = self.mouse.hitClick(col, row) orelse return false;
    // Drawer rail overlays the editor: only targets inside the rail may
    // receive this click; hitting the rail body is a no-op.
    if (in_rail) {
        if (openRailCol(self)) |rail_col| {
            if (hit.target.rect.col < rail_col) return false;
        }
    }
    switch (hit.target.action) {
        .click => |click| switch (click) {
            .hint => |action| {
                prepareMouseAction(self);
                if (hintActionFocusesEditor(action)) self.ai.focus = .editor;
                self.execHintAction(action) catch |err| {
                    const text = std.fmt.allocPrint(self.alloc, "mouse action failed: {s}", .{@errorName(err)}) catch return true;
                    self.setMsg(text) catch self.alloc.free(text);
                };
                return true;
            },
            .focus_pane => |win| {
                if (win >= self.windows.items.len) return false;
                prepareMouseAction(self);
                try focusPaneFromClick(self, win, hit.target.rect, col, row);
                return true;
            },
            // Explicit v1 no-op: separators are not draggable/resizable.
            .separator => return false,
        },
        .scroll => return false,
    }
}

/// Hint actions that navigate the editorial surface (buffer/tree/notes)
/// return keyboard focus to the editor when invoked by a POINTER while the
/// AI prompt/rail owns the keys. AI-surface actions (threads, workbox tabs,
/// prompt) and approvals keep their own focus policy.
fn hintActionFocusesEditor(action: hints.Action) bool {
    return switch (action) {
        .buffer_select, .buffer_close, .filetree_select, .filetree_activate, .navigator_tab, .note_open => true,
        else => false,
    };
}

/// A mouse click is a fresh normal-mode navigation gesture. An active insert
/// session is finalized first (text kept, one undo boundary) so a click can
/// never leave a half-open insert group behind; pending leader/operator/
/// replace/multi-cursor state is cleared so the next key cannot act on a
/// stale target. No new business logic: this is the same teardown Esc uses.
fn prepareMouseAction(self: *App) void {
    if (self.state.mode == .insert) self.exitInsert();
    self.pending_window = false;
    self.pending_replace = null;
    self.ai.rail_pending_leader = false;
    if (self.mc_active) {
        self.mc.clear();
        self.mc_active = false;
    }
    if (self.msg) |m| {
        self.alloc.free(m);
        self.msg = null;
    }
    self.visual_anchor = null;
}

fn handleWheel(self: *App, col: u32, row: u32, dir: i64) !bool {
    if (mouseBlocked(self)) return false;
    // The embedded terminal owns the wheel while it has focus; vaxis's
    // terminal widget has no mouse forwarding, so the safe behavior is
    // no-op (never scroll the editor behind it).
    if (term.supported and self.term_pane != null and self.term_pane.?.focused) return false;
    const in_rail = railContains(self, col, row);
    // The rail is drawn above the terminal, so its rect wins when covered;
    // elsewhere wheel over the terminal is a no-op.
    if (!in_rail and terminalContains(self, col, row)) return false;
    const hit = self.mouse.hitScroll(col, row) orelse return false;
    // Same overlay rule as clicks: the drawer rail's body owns its wheel;
    // only scroll regions inside the rail are eligible.
    if (in_rail) {
        if (openRailCol(self)) |rail_col| {
            if (hit.target.rect.col < rail_col) return false;
        }
    }
    switch (hit.target.action) {
        .scroll => |s| switch (s) {
            .editor => |win| {
                if (win >= self.windows.items.len) return false;
                scrollPaneBy(self, win, dir * @as(i64, wheel_lines));
                return true;
            },
            .navigator_files, .navigator_notes, .navigator_agents => {
                self.navigatorScrollBy(@intCast(dir));
                return true;
            },
            .ai_threads => {
                self.aiMoveThreadCursor(@intCast(dir));
                return true;
            },
            .ai_workbox => {
                self.aiScrollWheel(dir * wheel_workbox_rows);
                return true;
            },
        },
        .click => return false,
    }
}

// ---------------------------------------------------------------------------
// Editor pane focus / cursor placement
// ---------------------------------------------------------------------------

fn focusPaneFromClick(self: *App, win: usize, rect: mouse.Rect, col: u32, row: u32) !void {
    if (panePositionAt(self, win, rect, col, row) catch null) |pos| {
        self.windows.items[win].cursor = pos;
        self.clearHover();
    }
    // Focus switches run the normal activation policy (buffer/LSP retarget,
    // inlay/diag/hover invalidation, visual/mode reset) — no second path.
    self.switchWindowTo(win);
    self.focus = .buffer;
    self.ai.focus = .editor;
}

/// Move one pane's cursor `delta` lines (fold-aware, column preserved) — the
/// same operation as repeated j/k, without touching keyboard focus.
fn scrollPaneBy(self: *App, win: usize, delta: i64) void {
    if (win >= self.windows.items.len) return;
    const w = &self.windows.items[win];
    if (w.buf >= self.buffers.items.len) return;
    const buf = &self.buffers.items[w.buf];
    const line_count = buf.pt.lineCount();
    var line = buf.pt.lineOf(@min(w.cursor, buf.pt.len()));
    var i: i64 = 0;
    while (i < delta) : (i += 1) {
        if (line + 1 >= line_count) break;
        line = App.foldNextLine(buf, line);
    }
    i = 0;
    while (i > delta) : (i -= 1) {
        if (line == 0) break;
        line = App.foldPrevLine(buf, line);
    }
    w.cursor = editor.Motion.toLineKeepCol(&buf.pt, w.cursor, line);
    if (win == self.current_win) self.clearHover();
}

/// Screen cell → buffer byte for one split leaf, accounting for the
/// relative-number gutter, view_top, folds, soft wrap and inlay hints.
/// Returns null when the click is below the last visible line (the "~"
/// filler area): the pane is focused but the cursor stays put.
fn panePositionAt(self: *App, win_idx: usize, rect: mouse.Rect, col: u32, row: u32) !?u32 {
    if (win_idx >= self.windows.items.len) return null;
    const w = &self.windows.items[win_idx];
    if (w.buf >= self.buffers.items.len) return null;
    const buf = &self.buffers.items[w.buf];
    const line_count = buf.pt.lineCount();
    if (line_count == 0) return null;
    if (row < rect.row or row >= rect.row + rect.height) return null;

    const win = self.vx.window();
    const gutter = self.gutterWidth(line_count);
    const content_width: u32 = @max(rect.width -| gutter, 1);
    const dr = row - rect.row;

    var line = @min(w.view_top, line_count - 1);
    var rem = dr;
    var target_line: u32 = line;
    var chunk: u32 = 0;
    var found = false;
    while (true) {
        const rows = self.lineDisplayRows(win, buf, w.buf, line, content_width);
        if (rem < rows) {
            target_line = line;
            chunk = rem;
            found = true;
            break;
        }
        rem -= rows;
        if (line + 1 >= line_count) break;
        line = App.foldNextLine(buf, line);
    }
    if (!found) return null;

    const line_start = buf.pt.lineStart(target_line);
    const line_len = buf.pt.lineTextLen(target_line);
    const clicked_cell = col -| rect.col;
    // Anywhere left of the text area is the gutter/line-number zone: place
    // the cursor at the line start (vim's "click margin" behavior).
    if (clicked_cell < gutter) return line_start;
    const text_col = clicked_cell - gutter;
    const target_cell: i64 = @as(i64, @intCast(chunk)) * @as(i64, @intCast(content_width)) +
        @as(i64, @intCast(text_col));

    // Bounded line copy for the cell/byte walk. A >256 KiB line maps within
    // its first 256 KiB (explicit limitation, DESIGN §21); typical code
    // lines are far below this.
    const cap: u32 = 256 * 1024;
    const copy_len = @min(line_len, cap);
    const text = try self.alloc.alloc(u8, copy_len);
    defer self.alloc.free(text);
    buf.pt.copyRange(line_start, text);

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var hint_at = std.ArrayList(u32).empty;
    var hint_width = std.ArrayList(u32).empty;
    // Match the renderer's hint filter: only this window's buffer hints are
    // spliced when they belong to the focused buffer's accepted response.
    if (!self.inlay_stale and self.inlay_buf == w.buf and self.inlay_hints.items.len > 0) {
        const hs = try self.lineHints(a, target_line);
        for (hs) |hint| {
            try hint_at.append(a, hint.character);
            try hint_width.append(a, self.textWidth(win, hint.label));
        }
    }

    var byte = mouse.cellToByteWithHints(
        text,
        target_cell,
        app_mod.tab_width,
        self.vx.caps.widthMethod(),
        hint_at.items,
        hint_width.items,
    );
    if (byte >= line_len) byte = line_len;
    // Never leave the cursor on a UTF-8 continuation byte (possible only at
    // the bounded-prefix edge or after a defensive clamp).
    while (byte > 0 and byte < text.len and (text[byte] & 0xC0) == 0x80) byte -= 1;
    // Normal-mode clicks past the end of the text land on the last
    // character (like `$`), not one cell past it.
    if (self.state.mode != .insert and byte == line_len and line_len > 0 and copy_len == line_len) {
        byte = @intCast(mouse.prevCodepointStart(text, @intCast(line_len)));
    }
    return line_start + byte;
}
