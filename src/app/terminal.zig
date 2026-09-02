//! terminal — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const term = @import("../term.zig");

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
    return switch (tp.layout) {
        .floating => blk: {
            const w = @max(40, @min(win.width * 8 / 10, win.width));
            const h = @max(12, @min(avail_rows * 6 / 10, avail_rows));
            break :blk .{
                .x = (win.width - w) / 2,
                .y = top + (avail_rows - h) / 3,
                .w = w,
                .h = h,
            };
        },
        .bottom => .{
            .x = 0,
            .y = win.height -| status_row_count -| @max(8, @min((win.height -| status_row_count) * 3 / 10, win.height -| status_row_count)),
            .w = win.width,
            .h = @max(8, @min((win.height -| status_row_count) * 3 / 10, win.height -| status_row_count)),
        },
        .right => .{
            .x = win.width -| @max(30, @min(win.width * 4 / 10, win.width -| 1)),
            .y = top,
            .w = @max(30, @min(win.width * 4 / 10, win.width -| 1)),
            .h = avail_rows,
        },
    };
}

/// Draw the terminal overlay (bottom/right/floating all overlay the
/// buffer area; the panes do not shrink). Called on the dashboard too
/// (its early return would skip the normal path). resize() no-ops when
/// unchanged; draw() is cheap when nothing changed.
pub fn drawTerm(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    if (!term.supported) return;
    if (self.term_pane) |*tp| {
        const r = self.termRect(a);
        if (r.w > 0 and r.h > 0 and r.w <= win.width and r.h <= win.height) {
            try tp.t.resize(@intCast(r.h), @intCast(r.w));
            const sub = win.child(.{
                .x_off = @intCast(r.x),
                .y_off = @intCast(r.y),
                .width = @intCast(r.w),
                .height = @intCast(r.h),
            });
            try tp.t.draw(sub);
            if (!tp.focused) sub.hideCursor();
        }
    }
}

/// <M-r>/<M-w>/<M-e>: toggle the terminal in `layout`. The same key
/// again closes it (spec: 开关); a different layout key switches the
/// placement of the SAME session (spec: 可复用会话) and refocuses it.
pub fn toggleTerm(self: *App, layout: term.Layout) !void {
    if (!term.supported) return;
    if (self.term_pane) |*tp| {
        if (tp.layout == layout) {
            self.closeTerm();
        } else {
            tp.layout = layout;
            tp.focused = true;
        }
        return;
    }
    const shell = self.env_map.get("SHELL") orelse "/bin/sh";
    const t = term.Terminal.create(self.io, self.alloc, &.{shell}, self.env_map, .{
        .winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
        // vaxis's scrollback is a TODO (its copyTo can't render it);
        // 0 keeps the back screen the same size as the front so line
        // scrolling works
        .scrollback_size = 0,
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
            tp.focused = true;
            return;
        }
        const t = term.Terminal.create(self.io, self.alloc, &.{"lazygit"}, self.env_map, .{
            .winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
            // vaxis's scrollback is a TODO (its copyTo can't render it);
            // 0 keeps the back screen the same size as the front so line
            // scrolling works
            .scrollback_size = 0,
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
