//! M3b: embedded terminal support (PTY + VT emulation) for oz.
//!
//! This module provides:
//!   1. `layoutRect` — a pure (vaxis-free) layout function computing the
//!      rectangle for the three terminal placements: floating / bottom / right.
//!   2. `Terminal` — a thin wrapper around vaxis's `widgets.Terminal` that owns
//!      the PTY write buffer and exposes create/destroy/resize/pollEvent/
//!      sendKey/draw.
//!
//! ============================================================================
//! vaxis 0.6 `widgets/terminal/Terminal.zig` usage notes (from reading the
//! widget source: Terminal.zig, Command.zig, Pty.zig, key.zig, Screen.zig):
//! ============================================================================
//!
//! 1. init(io, allocator, argv, env, opts, write_buf) !Terminal
//!    - io        : the app's std.Io (oz: `app.io`). Linux and macOS are
//!                  supported (Pty.zig `@compileError` elsewhere).
//!    - allocator : general allocator used for the double-buffered screens.
//!    - argv      : the FULL argv, passed verbatim to execvpe — argv[0] is the
//!                  program, there is NO implicit shell. Interactive shell:
//!                  `&.{"/bin/sh", "-i"}` or `$SHELL`; one-shot command:
//!                  `&.{"/bin/sh", "-lc", cmd}`.
//!    - env       : `*const std.process.Environ.Map` (oz: `app.env_map`). It is
//!                  cloned into a PosixBlock per spawn; `PATH` is read from it
//!                  for execvpe. Ensure `TERM` is set for full-color apps.
//!    - opts      : Options{ .scrollback_size, .winsize,
//!                  .initial_working_directory } — see notes 6/7.
//!    - write_buf : []u8 for the PTY *streaming* writer. The widget stores the
//!                  slice (used on every update() flush) but never frees it and
//!                  does not own it — the CALLER must keep it alive for the
//!                  whole Terminal lifetime and free it after deinit(). The
//!                  wrapper below allocates it in create() and frees it in
//!                  destroy().
//!    - first init() stores `global_io` (used by the SIGCHLD handler).
//!
//! 2. spawn()/deinit() thread model
//!    - spawn(): Command.spawn forks (setsid, TIOCSCTTY, dup2 0/1/2 onto the
//!      tty slave, optional chdir, execvpe), registers pid in the global
//!      `global_vts` map, then starts the reader thread
//!      (`io.concurrent(run)`). `back_screen` is only assigned in spawn() —
//!      calling update()/draw() before spawn is UB (the wrapper always spawns).
//!    - Reader thread: blocking parseReader loop on the pty master; parses into
//!      the back screen (double buffering); pushes events; exits on
//!      `should_quit`. It can block on `event_queue.push` (capacity 16) or on
//!      the pty read — the app must drain tryEvent() every frame.
//!    - deinit(): sets should_quit, removes self from global_vts (deinits the
//!      map when empty), cmd.kill() → SIGTERM, writes EOT ("\x04") into the tty
//!      slave to wake the reader, then **thread.await(io)** — deinit BLOCKS
//!      until the reader thread exits — then closes the pty and frees the
//!      screens. Safe when spawn() was never called (thread == null skips the
//!      await; pid == null skips the kill).
//!    - Global state pitfalls (see "Pitfalls" below): global_io,
//!      global_vts, and a one-time SIGCHLD handler that reaps *every* child.
//!
//! 3. draw(allocator, win)
//!    - Copies back_screen → front_screen under a non-blocking tryLock (if the
//!      reader holds the lock it draws the stale front screen), then writes
//!      every front_screen cell into `win` (writeCell clips silently — win must
//!      be at least the terminal size) and finally sets the cursor shape and
//!      position via win (shell cursor). It does NOT manage scrollback: the
//!      widget never changes `scroll_offset` (0 by default); to view scrollback
//!      the app sets `term.inner.scroll_offset` under back_mutex and draw()s.
//!    - `dirty` is set by the reader when it pushes `.redraw` and cleared after
//!      a successful copyTo. draw() is cheap when nothing changed — call it
//!      every frame or at least on `.redraw` events.
//!    - Because draw() writes the cursor last, drawing the terminal after the
//!      editor overrides the editor cursor: hide the terminal cursor when it is
//!      not focused (win.hideCursor()) or draw the editor cursor afterwards.
//!
//! 4. tryEvent() — non-blocking tryPop of a fixed 16-slot queue. Events:
//!    - .exited      : child exited/was signalled. Pushed from the SIGCHLD
//!                     handler with `push(...) catch {}` — if the queue is
//!                     full the event is DROPPED. Treat as "close/recreate".
//!    - .redraw      : new output arrived (only pushed when the queue was not
//!                     dirty; tryPush). Request a frame.
//!    - .bell        : BEL (0x07) received.
//!    - .title_change: OSC 0 (shell set the title). The slice points INTO the
//!                     widget's internal buffer — valid only until the next
//!                     title change; copy it if you keep it.
//!    - .pwd_change  : OSC 7 (shell reported cwd). Same ownership caveat.
//!    - The reader uses *blocking* push for bell/title/pwd: if the queue is
//!      full the reader stalls until the app pops. Drain every frame.
//!
//! 5. update(.{ .key_press = k }) — encodes `k` and flushes it to the pty.
//!    - Encoding is always the legacy path (Screen's `csi_u_flags` defaults to
//!      0 and the widget never changes it; the kitty branch is `unreachable`).
//!    - Rules (key.zig legacy()): text set → raw bytes; no mods + codepoint
//!      ≤ 0x7F → raw byte; ctrl+[a-z] → control byte; alt+printable → \x1b+ch;
//!      ctrl+alt+[a-z] → \x1b+decimal; special keys → CSI-u/legacy sequences
//!      (enter {13,'u'}, tab {9,'u'}, backspace {127,'u'}, arrows, F-keys...).
//!    - Esc: vaxis parses a lone 0x1B as `.{ .codepoint = Key.escape }` with
//!      NO text (Parser.zig parseGround), so effective_mods == 0 and
//!      codepoint 0x1B ≤ 0x7F hit the raw-byte fast path: a lone Esc is sent
//!      to the pty as a BARE "\x1b" byte — NOT "\x1b[27u". "\x1b[27u" only
//!      appears for Esc WITH modifiers (Alt+Esc → "\x1b[27;3u",
//!      Ctrl+Esc → "\x1b[27;5u").
//!    - The app must intercept keys it needs for its own bindings (Esc to
//!      close, M-r/M-w/M-e to switch layout) BEFORE forwarding to the terminal.
//!
//! 6. resize(ws: Winsize) — Winsize{ rows, cols, x_pixel, y_pixel } (u16 each;
//!    only rows/cols matter). No-op guard when rows/cols are unchanged. Under
//!    back_mutex it reallocates the front/back screens and calls pty.setSize
//!    (TIOCSWINSZ ioctl → kernel SIGWINCH → the shell re-queries size). Safe to
//!    call every frame with the terminal's OWN rect size (from layoutRect), not
//!    the full screen size.
//!
//! 7. Options — scrollback_size (u16, default 500): extra rows in the primary
//!    back screen above the visible area; the widget never scrolls it itself.
//!    initial_working_directory: MUST be absolute (error.InvalidWorkingDirectory
//!    otherwise); null → child inherits the cwd at spawn() time. winsize: the
//!    pty's initial size — set rows/cols from the layout rect before spawn.
//!
//! 8. Command — argv/env: fork + setsid + TIOCSCTTY + dup2(0,1,2) + chdir +
//!    execvpe(argv[0]). argv[0] is exec'd directly (no shell wrapper). env is
//!    copied per spawn. `pid` is set after spawn; `kill()` sends SIGTERM.
//!
//! ============================================================================
//! Pitfalls / gotchas discovered:
//! ============================================================================
//! - write_buf lifetime: caller-owned, must outlive the Terminal; free only
//!   after deinit() (the wrapper handles this).
//! - deinit() blocks until the reader thread exits; the reader can be stuck on
//!   a full event queue (16 slots, blocking push for bell/title/pwd) — drain
//!   tryEvent() every frame or deinit can hang.
//! - Global SIGCHLD handler (installed once by the first spawn) does
//!   waitpid(-1) and reaps ALL children of the process. Any OTHER child the app
//!   spawns (git jobs etc.) is reaped by this handler; the app's own wait() on
//!   those pids then fails (ECHILD) or hangs — do not wait() on app children
//!   while a vaxis terminal is alive, or make the handler path acceptable.
//! - global_io is captured by the first init(); every Terminal must use the
//!   same io (oz: app.io) or the SIGCHLD handler's mutex lock breaks.
//! - The .exited event is dropped silently when the queue is full.
//! - Esc is forwarded as a bare "\x1b" byte; a program running inside the pty
//!   interprets it as "cancel" — never forward the app's own Esc handling to
//!   the terminal unless the terminal has input focus.
//! - draw() sets the cursor last and per-widget: with multiple widgets the last
//!   draw wins; hide the terminal cursor when unfocused.
//! - Terminal.init validates that initial_working_directory is absolute.
//! - The widget supports Linux and macOS.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

/// The three terminal placements (M3b).
pub const Layout = enum {
    /// Centered floating window over the content area (below the tab bar,
    /// above the status bar): 80% wide / 60% tall, min 40x12.
    floating,
    /// Full-width horizontal strip at the top of the content area, 30% of the
    /// content rows tall, min 8 rows.
    bottom,
    /// Full-height vertical strip at the right edge of the screen, 40% of the
    /// screen width, min 30 cols.
    right,
};

/// A screen rectangle (cells), content-area coordinates.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// `num`/`den` percent of `n` computed in u64 to avoid overflow, floored.
fn pct(n: u32, num: u32, den: u32) u32 {
    return @intCast((@as(u64, n) * num) / den);
}

/// Compute the terminal rectangle for `layout` inside the editor content area.
///
/// Parameters:
///   - content_top   : row where the editor content starts (tab-bar row count;
///                     oz: `app.contentTop(a)`). The terminal panels start at
///                     this row so they never cover the tab bar.
///   - content_rows  : rows available for content (screen height minus tab bar
///                     minus status bar; oz: `height - status_row_count -
///                     tabBarRows`). `screen_h` is used only as a safety clamp.
///   - screen_w/h    : full screen size in cells. Panels never exceed the
///                     screen (nor the content area vertically).
///
/// Returns:
///   - .floating: centered within the content area; w = max(80% of screen_w,
///     40) capped at screen_w; h = max(60% of content rows, 12) capped at the
///     content rows.
///   - .bottom  : x = 0, y = content_top, w = screen_w, h = max(30% of content
///     rows, 8) capped at content rows. (Anchored at the content top per spec —
///     "y starts at the tab-bar row count"; the editor renders below it. To
///     anchor at the bottom edge instead use y = content_top + content_rows -
///     h.)
///   - .right   : y = content_top, h = content rows (full height), w = max(40%
///     of screen_w, 30) capped at screen_w, x = screen_w - w (right edge).
///
/// A zero w or h means the screen is too small — the caller should skip
/// creating/drawing the terminal in that case.
pub fn layoutRect(layout: Layout, content_top: u32, content_rows: u32, screen_w: u32, screen_h: u32) Rect {
    // Vertically we never extend past the screen, even if content_rows was
    // computed loosely.
    const avail_rows = @min(content_rows, screen_h -| content_top);
    switch (layout) {
        .floating => {
            const w = @min(@max(pct(screen_w, 4, 5), 40), screen_w);
            const h = @min(@max(pct(avail_rows, 3, 5), 12), avail_rows);
            return .{
                .x = (screen_w - w) / 2,
                .y = content_top + (avail_rows - h) / 2,
                .w = w,
                .h = h,
            };
        },
        .bottom => {
            const h = @min(@max(pct(avail_rows, 3, 10), 8), avail_rows);
            return .{ .x = 0, .y = content_top, .w = screen_w, .h = h };
        },
        .right => {
            const w = @min(@max(pct(screen_w, 2, 5), 30), screen_w);
            return .{ .x = screen_w - w, .y = content_top, .w = w, .h = avail_rows };
        },
    }
}

/// Wrapper around `vaxis.widgets.Terminal` (PTY + VT emulation + scrollback).
///
/// Owns the PTY write buffer: create() allocates it, destroy() frees it after
/// the widget deinit (which awaits the reader thread). All methods must be
/// called from the main thread; `pollEvent` must be drained every frame (see
/// module notes). `inner` is exposed for advanced use (e.g. scrollback via
/// `inner.scroll_offset` under `inner.back_mutex`).
/// Platforms with a working PTY backend (vaxis widgets/terminal). Linux was
/// the first; macOS joined via the posix_openpt path in patches/vaxis-Pty.zig.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub const Terminal = if (supported) struct {
    inner: vaxis.widgets.Terminal,
    /// Buffer for the PTY streaming writer — owned by this wrapper.
    write_buf: []u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Size of the PTY write buffer (key presses are tiny; 4 KiB is plenty).
    pub const default_write_buf_size: usize = 4096;

    /// Initialize the widget AND spawn the child process. Returns a HEAP
    /// pointer: the widget's reader thread captures `&self.inner` at spawn
    /// and keeps using it for the terminal's whole life, so the Terminal
    /// must live at a stable address (a value return would dangle the
    /// reader's pointer into the caller's stack frame). destroy() frees it.
    ///
    /// `argv[0]` is exec'd directly (no implicit shell) — e.g.
    /// `&.{"/bin/sh", "-lc", cmd}` for a command, or `$SHELL -i` from
    /// `env` for an interactive shell. `opts.winsize.rows/cols` should come
    /// from layoutRect (min 1x1). On failure everything is cleaned up
    /// (including killing a half-spawned child).
    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env: *const std.process.Environ.Map,
        opts: vaxis.widgets.Terminal.Options,
    ) !*Terminal {
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);
        self.* = .{ .inner = undefined, .write_buf = &.{}, .allocator = allocator, .io = io };
        self.write_buf = try allocator.alloc(u8, default_write_buf_size);
        errdefer allocator.free(self.write_buf);
        self.inner = try vaxis.widgets.Terminal.init(io, allocator, argv, env, opts, self.write_buf);
        errdefer self.inner.deinit();
        try self.inner.spawn();
        return self;
    }

    /// Stop the child (SIGTERM), await the reader thread, free everything
    /// (including this Terminal). Blocks until the reader thread exits —
    /// keep draining pollEvent() every frame so the event queue (16 slots)
    /// never stays full. Once-only: the caller must not use the Terminal
    /// afterwards.
    pub fn destroy(self: *Terminal) void {
        self.inner.deinit();
        self.allocator.free(self.write_buf);
        self.allocator.destroy(self);
    }

    /// Resize the terminal (screen + pty winsize). No-op when unchanged; safe
    /// to call every frame. Pass the terminal's OWN size from layoutRect
    /// (rows/cols), not the full screen size. The pty's SIGWINCH tells the
    /// shell to re-query its size.
    pub fn resize(self: *Terminal, rows: u16, cols: u16) !void {
        try self.inner.resize(.{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        });
    }

    /// Non-blocking event poll (maps to `inner.tryEvent`). Returns null when
    /// no event is pending. Drain every frame — the reader thread blocks on
    /// push when the queue (16) is full, and `.exited` is dropped silently
    /// when full.
    pub fn pollEvent(self: *Terminal) !?vaxis.widgets.Terminal.Event {
        return try self.inner.tryEvent();
    }

    /// Forward a key press to the child (maps to `inner.update`). See module
    /// notes on encoding — in particular a lone Esc becomes a bare "\x1b"
    /// byte. Intercept app-owned bindings before calling this.
    pub fn sendKey(self: *Terminal, key: vaxis.Key) !void {
        try self.inner.update(.{ .key_press = key });
    }

    /// Forward raw text (bracketed paste) to the child, bypassing key
    /// encoding — the widget's update() only accepts key presses.
    pub fn sendText(self: *Terminal, text: []const u8) !void {
        const w = self.inner.get_pty_writer();
        try w.writeAll(text);
        try w.flush();
    }

    /// Draw the terminal into `win`. `win` must be at least the terminal's
    /// size (use `vx.window().child(.{ .x_off, .y_off, .width, .height })`
    /// from a layoutRect Rect; cells are clipped silently otherwise). Because
    /// this sets the screen cursor last, hide the terminal cursor when it is
    /// not focused or draw the editor cursor afterwards. Cheap when nothing
    /// changed — call every frame or on `.redraw` events.
    pub fn draw(self: *Terminal, win: vaxis.Window) !void {
        try self.inner.draw(self.allocator, win);
    }
} else struct {
    // Unsupported-platform stub: keeps this module compileable everywhere
    // (tests.zig runs refAllDecls); every call fails at runtime with
    // UnsupportedPlatform. The embedded terminal cannot be opened there.
    pub const default_write_buf_size: usize = 4096;

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env: *const std.process.Environ.Map,
        opts: vaxis.widgets.Terminal.Options,
    ) !*Terminal {
        _ = io;
        _ = allocator;
        _ = argv;
        _ = env;
        _ = opts;
        return error.UnsupportedPlatform;
    }
    pub fn destroy(self: *Terminal) void {
        _ = self;
    }
    pub fn resize(self: *Terminal, rows: u16, cols: u16) !void {
        _ = self;
        _ = rows;
        _ = cols;
        return error.UnsupportedPlatform;
    }
    pub fn pollEvent(self: *Terminal) !?vaxis.widgets.Terminal.Event {
        _ = self;
        return null;
    }
    pub fn sendKey(self: *Terminal, key: vaxis.Key) !void {
        _ = self;
        _ = key;
        return error.UnsupportedPlatform;
    }
    pub fn sendText(self: *Terminal, text: []const u8) !void {
        _ = self;
        _ = text;
        return error.UnsupportedPlatform;
    }
    pub fn draw(self: *Terminal, win: vaxis.Window) !void {
        _ = self;
        _ = win;
        return error.UnsupportedPlatform;
    }
};

// ---------------------------------------------------------------------------
// Tests (pure layout math — no vaxis needed; run with `zig test src/term.zig`
// or wire into src/tests.zig by importing this file).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "layoutRect bottom: full width, 30% of content rows, y at content_top" {
    const r = layoutRect(.bottom, 1, 35, 100, 40);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 100, .h = 10 }, r);
}

test "layoutRect bottom: min 8 rows kicks in" {
    // 30% of 20 rows = 6 < 8 → floor of 8.
    const r = layoutRect(.bottom, 1, 20, 80, 24);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 80, .h = 8 }, r);
}

test "layoutRect bottom: never exceeds content rows" {
    // Tiny screen: floor of 8 clamped to the 5 content rows.
    const r = layoutRect(.bottom, 1, 5, 30, 8);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 30, .h = 5 }, r);
}

test "layoutRect bottom: zero content rows gives zero height" {
    const r = layoutRect(.bottom, 1, 0, 100, 40);
    try testing.expectEqual(@as(u32, 0), r.h);
}

test "layoutRect right: 40% width at the right edge, full content height" {
    const r = layoutRect(.right, 1, 35, 100, 40);
    try testing.expectEqual(Rect{ .x = 60, .y = 1, .w = 40, .h = 35 }, r);
}

test "layoutRect right: min 30 cols kicks in" {
    // 40% of 50 = 20 < 30 → floor of 30.
    const r = layoutRect(.right, 1, 12, 50, 15);
    try testing.expectEqual(Rect{ .x = 20, .y = 1, .w = 30, .h = 12 }, r);
}

test "layoutRect right: narrow screen clamps to full width" {
    // 40% of 30 = 12 < 30 → 30, capped at screen_w = 30 → x = 0.
    const r = layoutRect(.right, 1, 5, 30, 8);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 30, .h = 5 }, r);
}

test "layoutRect floating: 80%x60% centered in content area" {
    const r = layoutRect(.floating, 1, 35, 100, 40);
    // w = 80, x = 10; h = 21, y = 1 + (35-21)/2 = 8.
    try testing.expectEqual(Rect{ .x = 10, .y = 8, .w = 80, .h = 21 }, r);
}

test "layoutRect floating: min 40x12" {
    // 80% of 50 = 40, 60% of 12 = 7 < 12 → 12.
    const r = layoutRect(.floating, 1, 12, 50, 15);
    try testing.expectEqual(Rect{ .x = 5, .y = 1, .w = 40, .h = 12 }, r);
}

test "layoutRect floating: clamped to screen, fills content height when small" {
    // w = max(24, 40) = 40 → capped at 30; h = max(3, 12) = 12 → capped at 5.
    const r = layoutRect(.floating, 1, 5, 30, 8);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 30, .h = 5 }, r);
}

test "layoutRect floating: screen_h clamps a loose content_rows" {
    // content_top(4) + content_rows(50) would exceed screen_h(40) → 36 rows.
    const r = layoutRect(.floating, 4, 50, 120, 40);
    // h = max(60% of 36 = 21, 12) = 21; y = 4 + (36-21)/2 = 11.
    try testing.expectEqual(Rect{ .x = 12, .y = 11, .w = 96, .h = 21 }, r);
}
