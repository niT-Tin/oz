//! terminal — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const term = @import("../term.zig");
const theme_mod = @import("../theme.zig");
const chrome = @import("chrome.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const status_row_count = app_mod.status_row_count;

/// Embedded terminal pane (Linux only; `void` elsewhere so the App field
/// and all references compile on every platform). The vaxis widget's reader
/// thread holds a *Terminal for its whole life, so the pane lives at a
/// stable address — a plain App field, never a reallocating list.
pub const TermPane = if (term.supported) struct {
    t: *term.Terminal,
    layout: term.Layout = .floating,
    /// The pane is drawn and receives pointer hits only while visible. The
    /// session itself (child, cwd, env, history, jobs) stays alive while
    /// hidden, and `focused` must be false whenever `visible` is false.
    visible: bool = true,
    focused: bool = false,
    /// Duped from .title_change events (widget events borrow its own
    /// buffer, unsafe across frames).
    title: ?[]u8 = null,
} else void;

// ---- M3b embedded terminal (<M-r> float / <M-w> bottom / <M-e> right) ----

/// Absolute cwd for a new terminal session: the current buffer's
/// directory, or null (inherit oz's cwd) when the buffer has no path.
pub fn termCwd(self: *App) ?[]const u8 {
    if (!term.supported) return null;
    const path = if (self.buffers.items.len > 0) self.cur().path else null;
    if (path) |p| {
        if (std.fs.path.dirname(p)) |d| return d;
    }
    return null;
}

/// Rectangle of the current terminal layout. Sizes are proportions of
/// the full area (independent of the pane layout / tab-bar rows) so
/// every geometry consumer can compute them without recursion; the
/// terminal OVERLAYS the buffer area (drawn after the panes), it does
/// not squeeze them.
pub fn termRect(self: *App, a: std.mem.Allocator) term.Rect {
    if (!term.supported) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const win = self.vx.window();
    const top = self.contentTop(a);
    const avail_rows = win.height -| status_row_count -| top;
    const tp = &self.term_pane.?;
    const r: term.Rect = switch (tp.layout) {
        .floating => blk: {
            // The minimums are caps too: a narrow window must not compute a
            // rect wider/taller than the screen (the old @max(40, ...) made
            // every sub-40-column float skip drawing entirely).
            const w = @min(win.width, @max(40, win.width * 8 / 10));
            const h = @min(avail_rows, @max(12, avail_rows * 6 / 10));
            break :blk .{
                .x = (win.width - w) / 2,
                .y = top + (avail_rows - h) / 3,
                .w = w,
                .h = h,
            };
        },
        .bottom => blk: {
            const h = @min(avail_rows, @max(8, (win.height -| status_row_count) * 3 / 10));
            break :blk .{
                .x = 0,
                .y = win.height -| status_row_count -| h,
                .w = win.width,
                .h = h,
            };
        },
        .right => blk: {
            const w = @min(win.width, @max(30, win.width * 4 / 10));
            break :blk .{
                .x = win.width - w,
                .y = top,
                .w = w,
                .h = avail_rows,
            };
        },
    };
    // Too small to hold a border plus even one PTY cell: callers skip it
    // (drawTerm then leaves the editor untouched rather than painting a
    // zero/negative-size child).
    if (r.w < 3 or r.h < 3) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return r;
}

/// Draw the themed outer frame around the terminal's rect. The frame is the
/// visual boundary of the float/strip: a `bg_float` plate, a focus-aware
/// border and an `oz terminal` title. The child grid is drawn afterwards
/// into the interior, so the border never covers PTY content.
fn drawTermFrame(self: *App, win: vaxis.Window, r: term.Rect, focused: bool) !void {
    const t = self.theme;
    const bg: vaxis.Color = .{ .rgb = t.bg_float };
    const outer = win.child(.{
        .x_off = @intCast(r.x),
        .y_off = @intCast(r.y),
        .width = @intCast(r.w),
        .height = @intCast(r.h),
    });
    outer.fill(.{ .style = .{ .bg = bg } });
    const border = chrome.panelBorderStyle(t, focused, bg);
    const title_style: vaxis.Style = .{
        .fg = .{ .rgb = if (focused) t.accent else t.fg_dim },
        .bg = bg,
        .bold = focused,
    };
    const cell = struct {
        fn at(grapheme: []const u8, style: vaxis.Style) vaxis.Cell {
            return .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style };
        }
    }.at;

    const w = outer.width;
    const h = outer.height;
    if (w < 3 or h < 3) return;
    // Top edge: `╭─ oz terminal ────╮` when the title fits, a plain rule
    // otherwise (40-column layouts still get a complete box).
    const title = "oz terminal";
    const title_len: u16 = @intCast(title.len);
    outer.writeCell(0, 0, cell("╭", border));
    outer.writeCell(w - 1, 0, cell("╮", border));
    var col: u16 = 1;
    while (col + 1 < w) : (col += 1) outer.writeCell(col, 0, cell("─", border));
    if (w >= title_len + 6) {
        outer.writeCell(1, 0, cell("─", border));
        outer.writeCell(2, 0, cell(" ", title_style));
        var i: u16 = 0;
        while (i < title_len) : (i += 1) {
            outer.writeCell(3 + i, 0, cell(title[i .. i + 1], title_style));
        }
        outer.writeCell(3 + title_len, 0, cell(" ", title_style));
    }
    // Sides + bottom edge.
    var row: u16 = 1;
    while (row + 1 < h) : (row += 1) {
        outer.writeCell(0, row, cell("│", border));
        outer.writeCell(w - 1, row, cell("│", border));
    }
    outer.writeCell(0, h - 1, cell("╰", border));
    outer.writeCell(w - 1, h - 1, cell("╯", border));
    col = 1;
    while (col + 1 < w) : (col += 1) outer.writeCell(col, h - 1, cell("─", border));
}

/// Draw the terminal overlay (bottom/right/floating all overlay the
/// buffer area; the panes do not shrink). Called on the dashboard too
/// (its early return would skip the normal path). resize() no-ops when
/// unchanged; draw() is cheap when nothing changed. Hidden sessions are
/// not drawn, but the app loop keeps polling their events.
pub fn drawTerm(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    if (!term.supported) return;
    if (self.term_pane) |*tp| {
        if (!tp.visible) return;
        const r = self.termRect(a);
        const inner = term.frameInnerRect(r);
        if (r.w == 0 or r.h == 0) return;
        if (inner.w == 0 or inner.h == 0) return;
        try tp.t.resize(@intCast(inner.h), @intCast(inner.w));
        try drawTermFrame(self, win, r, tp.focused);
        const sub = win.child(.{
            .x_off = @intCast(inner.x),
            .y_off = @intCast(inner.y),
            .width = @intCast(inner.w),
            .height = @intCast(inner.h),
        });
        try tp.t.draw(sub);
        restyleTerm(sub, self.theme);
        if (!tp.focused) sub.hideCursor();
    }
}

/// Map one cell color to the theme: .default → the given theme slot RGB; ANSI index 0-15 → the theme's terminal palette; RGB and 256-color (index 16+)
/// escape colors pass through untouched.
fn mapTermColor(c: vaxis.Color, default_rgb: [3]u8, pal: [16]theme_mod.Rgb) vaxis.Color {
    return switch (c) {
        .default => .{ .rgb = default_rgb },
        .index => |n| if (n < 16) .{ .rgb = pal[n] } else c,
        .rgb => c,
    };
}

/// Restyle the just-drawn terminal pane cells to the active theme: the shell's default fg/bg follow the theme and the classic ANSI colors map
/// onto theme-derived RGB, so the embedded terminal blends into the editor instead of leaking the host terminal's palette.
fn restyleTerm(sub: vaxis.Window, t: theme_mod.Theme) void {
    const pal = theme_mod.ansi16(t);
    var row: u16 = 0;
    while (row < sub.height) : (row += 1) {
        var col: u16 = 0;
        while (col < sub.width) {
            const cell = sub.readCell(col, row) orelse break;
            var c = cell;
            c.style.fg = mapTermColor(c.style.fg, t.fg, pal);
            c.style.bg = mapTermColor(c.style.bg, t.bg, pal);
            c.style.ul = mapTermColor(c.style.ul, t.fg, pal);
            sub.writeCell(col, row, c);
            col += @max(cell.char.width, 1);
        }
    }
}

/// <M-r>/<M-w>/<M-e>: toggle the terminal in `layout`. Visibility/focus/
/// layout changes never destroy the session: the same shell (cwd/env/
/// history/jobs) is hidden, shown or moved. Only `<M-r>` on a visible,
/// focused pane hides it; a layout key moves the same session; from the
/// editor a visible-but-unfocused pane is refocused. `closeTerm` remains the
/// explicit destroy path (child exit / app shutdown).
pub fn toggleTerm(self: *App, layout: term.Layout) !void {
    if (!term.supported) return;
    if (self.term_pane) |*tp| {
        switch (term.toggleAction(true, tp.visible, tp.focused, tp.layout == layout)) {
            .create => unreachable,
            .relayout => {
                tp.layout = layout;
                tp.visible = true;
                tp.focused = true;
            },
            .show => {
                tp.visible = true;
                tp.focused = true;
            },
            .hide => {
                // Keep the child + reader draining; only the presentation
                // and keyboard focus go away.
                tp.visible = false;
                tp.focused = false;
            },
            .focus => {
                tp.visible = true;
                tp.focused = true;
            },
        }
        return;
    }
    const shell = self.env_map.get("SHELL") orelse "/bin/sh";
    const t = term.Terminal.create(self.io, self.alloc, &.{shell}, self.env_map, .{
        .winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
        // Bounded primary-screen history rendered by the terminal viewport
        // (wheel / Shift+PageUp&Dn); the visible back screen stays rows tall.
        .scrollback_size = term.scrollback_lines,
        .initial_working_directory = self.termCwd(),
    }) catch |e| {
        const m = std.fmt.allocPrint(self.alloc, "terminal: {s}", .{@errorName(e)}) catch return;
        try self.setMsg(m);
        return;
    };
    self.term_pane = .{ .t = t, .layout = layout, .focused = true };
}

/// Destroy the terminal session (kills the child, joins the reader
/// thread, closes the pty).
pub fn closeTerm(self: *App) void {
    if (!term.supported) return;
    if (self.term_pane) |*tp| {
        tp.t.destroy();
        if (tp.title) |x| self.alloc.free(x);
        self.term_pane = null;
    }
}

/// Keys while the terminal has focus: Esc returns to Normal (the pty
/// never sees it — a lone Esc would encode as a bare \x1b and cancel
/// whatever the child is doing); Alt+r/w/e switch/close the terminal
/// (spec: 终端内 <M-r> 等同一键位可直接退回 Normal/关闭); everything
/// else is forwarded to the child.
pub fn handleTerminalKey(self: *App, key: vaxis.Key) !void {
    if (!term.supported) return;
    const tp = &self.term_pane.?;
    if (key.codepoint == vaxis.Key.escape) {
        tp.focused = false;
        return;
    }
    // Shift+PageUp/Down are local terminal-history shortcuts: they never go
    // to the child as input. PageUp/PageDown without Shift still belong to
    // the program/shell.
    if (key.mods.shift) {
        switch (key.codepoint) {
            vaxis.Key.page_up => {
                _ = tp.t.scrollPageUp();
                return;
            },
            vaxis.Key.page_down => {
                _ = tp.t.scrollPageDown();
                return;
            },
            else => {},
        }
    }
    if (key.mods.alt) {
        switch (key.codepoint) {
            'r' => return self.toggleTerm(.floating),
            'w' => return self.toggleTerm(.bottom),
            'e' => return self.toggleTerm(.right),
            else => {},
        }
    }
    try tp.t.sendKey(key);
}

/// <leader>lg — run lazygit in the embedded FLOATING terminal (spec:
/// lazygit 直接跑在浮动终端里). An open session is re-floated and
/// focused; otherwise a fresh lazygit session starts.
pub fn launchLazygit(self: *App) void {
    // Linux: run lazygit in the embedded floating terminal. Other
    // platforms fall back to the external $TERMINAL window below.
    if (term.supported) {
        if (self.term_pane) |*tp| {
            tp.layout = .floating;
            tp.visible = true;
            tp.focused = true;
            return;
        }
        const t = term.Terminal.create(self.io, self.alloc, &.{"lazygit"}, self.env_map, .{
            .winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
            .scrollback_size = term.scrollback_lines,
            .initial_working_directory = self.termCwd(),
        }) catch |e| {
            const m = std.fmt.allocPrint(self.alloc, "lazygit: {s}", .{@errorName(e)}) catch return;
            self.setMsg(m) catch {};
            return;
        };
        self.term_pane = .{ .t = t, .layout = .floating, .focused = true };
        return;
    }
    // non-Linux fallback: external terminal (historical behavior)
    const term_bin = self.env_map.get("TERMINAL") orelse "x-terminal-emulator";
    var proc = std.process.spawn(self.io, .{
        .argv = &.{ term_bin, "-e", "lazygit" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        const m = std.fmt.allocPrint(self.alloc, "lazygit: {s}", .{@errorName(e)}) catch return;
        self.setMsg(m) catch {};
        return;
    };
    const t2 = std.Thread.spawn(.{}, struct {
        fn reap(io: std.Io, p: std.process.Child) void {
            var c = p;
            _ = c.wait(io) catch {};
        }
    }.reap, .{ self.io, proc }) catch {
        proc.kill(self.io);
        return;
    };
    t2.detach();
}
