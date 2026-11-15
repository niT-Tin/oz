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
//!      position via win (shell cursor). When the primary history viewport is
//!      scrolled up (`scroll_offset > 0`) it copies the composed
//!      history+screen viewport instead (Screen.copyViewportTo) and hides the
//!      live cursor; at offset 0 it resumes follow mode and shows it.
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
//! 7. Options — scrollback_size (u16, default 500): capacity of the bounded
//!    primary-screen local history. Rows that scroll off the top of a
//!    full-screen region are retained (cells are moved, evicted rows freed);
//!    the visible back screen stays exactly `winsize.rows` tall. The alternate
//!    screen never retains history. initial_working_directory: MUST be
//!    absolute (error.InvalidWorkingDirectory otherwise); null → child
//!    inherits the cwd at spawn() time. winsize: the pty's initial size — set
//!    rows/cols from the layout rect before spawn.
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
/// Bounded primary-screen scrollback retained by the embedded terminal.
/// 500 rows is the vaxis default; eviction frees the oldest rows' cells, so
/// memory stays bounded by (rows × width) cells + their graphemes.
pub const scrollback_lines: u16 = 500;

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
        resetLinkState(&self.inner);
        try self.inner.spawn();
        return self;
    }

    /// vaxis's `widgets/terminal/Screen.init` leaves `Cursor.uri` and
    /// `Cursor.uri_id` as `undefined` while every `Screen.print` reads them
    /// as the source slice for each cell's OSC 8 link state. On a real
    /// allocation pattern those bytes are garbage: `appendSlice` then either
    /// OOMs (logging "couldn't write uri_id" for EVERY cell — thousands of
    /// lines into the TUI) or copies from a wild pointer. The vendored
    /// terminal has no OSC 8 support, so the correct zero state is `.empty`.
    /// Resize recreates all three screens, so re-apply it there too.
    fn resetLinkState(t: *vaxis.widgets.Terminal) void {
        t.front_screen.cursor.uri = .empty;
        t.front_screen.cursor.uri_id = .empty;
        t.back_screen_pri.cursor.uri = .empty;
        t.back_screen_pri.cursor.uri_id = .empty;
        t.back_screen_alt.cursor.uri = .empty;
        t.back_screen_alt.cursor.uri_id = .empty;
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
        // A size change re-runs Screen.init for all three screens, which
        // resets the cursor link arrays to `undefined`; restore the empty
        // state afterwards. An unchanged size is a no-op and keeps the
        // arrays resetLinkState already installed in create().
        const resized = self.inner.front_screen.width != cols or
            self.inner.front_screen.height != rows;
        try self.inner.resize(.{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        if (resized) resetLinkState(&self.inner);
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

    /// Scroll the local primary-screen history by `n` rows (negative =
    /// toward the bottom). No-op on the alternate screen, with empty
    /// history, or when the program owns mouse reporting (wheel path only).
    pub fn scrollUp(self: *Terminal, n: usize) bool {
        return self.inner.scrollUp(n);
    }
    pub fn scrollDown(self: *Terminal, n: usize) bool {
        return self.inner.scrollDown(n);
    }
    pub fn wheelUp(self: *Terminal, n: usize) bool {
        return self.inner.wheelUp(n);
    }
    pub fn wheelDown(self: *Terminal, n: usize) bool {
        return self.inner.wheelDown(n);
    }
    pub fn scrollPageUp(self: *Terminal) bool {
        return self.inner.scrollPageUp();
    }
    pub fn scrollPageDown(self: *Terminal) bool {
        return self.inner.scrollPageDown();
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
    pub fn scrollUp(self: *Terminal, n: usize) bool {
        _ = self;
        _ = n;
        return false;
    }
    pub fn scrollDown(self: *Terminal, n: usize) bool {
        _ = self;
        _ = n;
        return false;
    }
    pub fn wheelUp(self: *Terminal, n: usize) bool {
        _ = self;
        _ = n;
        return false;
    }
    pub fn wheelDown(self: *Terminal, n: usize) bool {
        _ = self;
        _ = n;
        return false;
    }
    pub fn scrollPageUp(self: *Terminal) bool {
        _ = self;
        return false;
    }
    pub fn scrollPageDown(self: *Terminal) bool {
        _ = self;
        return false;
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

fn screenPrintText(s: *vaxis.widgets.Terminal.Screen, text: []const u8) !void {
    for (text) |b| try s.print(&[_]u8{b}, 1, true);
}

fn screenRowString(s: *vaxis.widgets.Terminal.Screen, row: usize, out: []u8) []const u8 {
    var w: usize = 0;
    var col: usize = 0;
    while (col < s.width and w < out.len) {
        const cell = s.buf[row * s.width + col];
        const n = @min(cell.char.items.len, out.len - w);
        @memcpy(out[w..][0..n], cell.char.items[0..n]);
        w += n;
        col += @max(cell.width, 1);
    }
    return out[0..w];
}

test "terminal screen scrollback: bounded ring, viewport and styles" {
    const Screen = vaxis.widgets.Terminal.Screen;
    const alloc = testing.allocator;

    var scr = try Screen.initWithHistory(alloc, 8, 3, 4);
    defer scr.deinit(alloc);
    // Screen.init leaves the cursor's OSC 8 link slices undefined; the app
    // adapter resets them after create/resize and so must this test.
    scr.cursor.uri = .empty;
    scr.cursor.uri_id = .empty;

    var n: usize = 0;
    while (n < 8) : (n += 1) {
        if (n == 4) {
            // Wide CJK glyph + an RGB style must survive the move into
            // history and the deep copy back into a viewport.
            scr.cursor.style.fg = .{ .rgb = .{ 0x12, 0x34, 0x56 } };
            try scr.print("第", 2, true);
            scr.cursor.style = .{};
            try screenPrintText(&scr, "4");
        } else {
            var line_buf: [8]u8 = undefined;
            try screenPrintText(&scr, try std.fmt.bufPrint(&line_buf, "L{d}", .{n}));
        }
        scr.cursor.col = 0;
        scr.cursor.pending_wrap = false;
        try scr.index();
    }

    // 8 lines in a 3-row screen: 5 scrolled off, the ring keeps the last 4.
    try testing.expectEqual(@as(usize, 4), scr.historyCount());

    var front = try Screen.init(alloc, 8, 3);
    defer front.deinit(alloc);
    var row_buf: [16]u8 = undefined;

    // Follow mode: the live screen after the last index() is L6/L7/blank.
    try scr.copyViewportTo(alloc, &front, 0);
    try testing.expectEqualStrings("L6", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));
    try testing.expectEqualStrings("L7", std.mem.trimEnd(u8, screenRowString(&front, 1, &row_buf), " "));

    // Two rows back: the oldest retained row is L2 (L0/L1 were evicted), so
    // the viewport is L4 (the colored wide line), L5, L6.
    try scr.copyViewportTo(alloc, &front, 2);
    try testing.expectEqualStrings("第4", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));
    try testing.expectEqualStrings("L5", std.mem.trimEnd(u8, screenRowString(&front, 1, &row_buf), " "));
    try testing.expectEqualStrings("L6", std.mem.trimEnd(u8, screenRowString(&front, 2, &row_buf), " "));
    try testing.expectEqualStrings("第", front.buf[0 * front.width].char.items);
    try testing.expectEqual(@as(u8, 2), front.buf[0 * front.width].width);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 0x12, 0x34, 0x56 } }, front.buf[0 * front.width].style.fg);

    // Oldest retained row; offset is clamped to the retained count.
    try scr.copyViewportTo(alloc, &front, 4);
    try testing.expectEqualStrings("L2", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));
    try scr.copyViewportTo(alloc, &front, 999);
    try testing.expectEqualStrings("L2", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));

    // Keep pushing: the ring stays bounded and evicts oldest-first
    // (16 lines -> history L10..L13, live L14/L15/blank).
    while (n < 16) : (n += 1) {
        var line_buf: [8]u8 = undefined;
        try screenPrintText(&scr, try std.fmt.bufPrint(&line_buf, "L{d}", .{n}));
        scr.cursor.col = 0;
        scr.cursor.pending_wrap = false;
        try scr.index();
    }
    try testing.expectEqual(@as(usize, 4), scr.historyCount());
    try scr.copyViewportTo(alloc, &front, 4);
    try testing.expectEqualStrings("L10", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));

    // ED3-style clear frees the ring and returns the viewport to follow mode.
    scr.clearScrollback();
    try testing.expectEqual(@as(usize, 0), scr.historyCount());
    try scr.copyViewportTo(alloc, &front, 4);
    try testing.expectEqualStrings("L14", std.mem.trimEnd(u8, screenRowString(&front, 0, &row_buf), " "));
}

test "terminal scrollback adversarial: deleting a live row is not history" {
    var scr = try vaxis.widgets.Terminal.Screen.initWithHistory(testing.allocator, 12, 4, 5);
    defer scr.deinit(testing.allocator);
    for ([_][]const u8{ "KEEP_TOP", "DELETE_ME", "KEEP_MID", "KEEP_LAST" }, 0..) |line, row| {
        scr.cursor.row = @intCast(row);
        scr.cursor.col = 0;
        try screenPrintText(&scr, line);
    }
    scr.cursor.row = 1;
    scr.cursor.col = 0;
    try scr.deleteLine(1);
    // DL is an in-place edit, not output scrolling off the viewport.
    try testing.expectEqual(@as(usize, 0), scr.historyCount());
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("KEEP_TOP", std.mem.trimEnd(u8, screenRowString(&scr, 0, &buf), " "));
    try testing.expectEqualStrings("KEEP_MID", std.mem.trimEnd(u8, screenRowString(&scr, 1, &buf), " "));
    try testing.expectEqualStrings("KEEP_LAST", std.mem.trimEnd(u8, screenRowString(&scr, 2, &buf), " "));
}

test "terminal scrollback adversarial: only full-screen scrolling retains rows" {
    var scr = try vaxis.widgets.Terminal.Screen.initWithHistory(testing.allocator, 12, 4, 5);
    defer scr.deinit(testing.allocator);
    for ([_][]const u8{ "ROW_ZERO", "ROW_ONE", "ROW_TWO", "ROW_THREE" }, 0..) |line, row| {
        scr.cursor.row = @intCast(row);
        scr.cursor.col = 0;
        try screenPrintText(&scr, line);
    }
    scr.cursor.row = 2;
    scr.cursor.col = 3;
    try scr.scrollUp(2);
    try testing.expectEqual(@as(usize, 2), scr.historyCount());
    try testing.expectEqual(@as(u16, 2), scr.cursor.row);
    try testing.expectEqual(@as(u16, 3), scr.cursor.col);
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("ROW_TWO", std.mem.trimEnd(u8, screenRowString(&scr, 0, &buf), " "));
    scr.scrolling_region = .{ .top = 1, .bottom = 3, .left = 0, .right = 11 };
    scr.cursor.row = 3;
    try scr.index();
    // A subregion must not add the application's interior rows to history.
    try testing.expectEqual(@as(usize, 2), scr.historyCount());
}
