//! clipboard — App method group: system clipboard interop (nvim
//! clipboard=unnamedplus). Every write to the unnamed register is pushed
//! to the system clipboard; p/P read it back when it holds content the
//! register doesn't (an external copy).

const std = @import("std");
const builtin = @import("builtin");

const app_mod = @import("../app.zig");
const App = app_mod.App;

/// Native clipboard tool pair, probed once at startup. `.none` covers
/// headless/SSH sessions: yanks still go out via OSC52 alone, and p/P use
/// only the internal register.
pub const ClipTool = enum { pbcopy, wl, xclip, xsel, none };

/// Read cap for the paste path — a clipboard holding a huge selection
/// must not balloon the editor's memory on every p.
const read_max_bytes = 64 * 1024 * 1024;

/// `command -v` through /bin/sh: true when `name` resolves on PATH.
fn binAvailable(io: std.Io, name: []const u8) bool {
    var buf: [160]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "command -v {s} >/dev/null 2>&1", .{name}) catch return false;
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const status = child.wait(io) catch return false;
    return switch (status) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Startup probe (called once from App.create). macOS: pbcopy/pbpaste are
/// part of the base system. Linux: wl-clipboard only in a real Wayland
/// session — an installed-but-unusable wl-copy under X11 would fail
/// silently at runtime and shadow the working xclip/xsel below it.
pub fn detectClipboardTool(self: *App) void {
    self.clip_tool = switch (builtin.os.tag) {
        .macos => if (binAvailable(self.io, "pbcopy")) .pbcopy else .none,
        .linux => blk: {
            const wayland = if (self.env_map.get("WAYLAND_DISPLAY")) |v| v.len > 0 else false;
            if (wayland and binAvailable(self.io, "wl-copy") and binAvailable(self.io, "wl-paste"))
                break :blk .wl;
            if (binAvailable(self.io, "xclip")) break :blk .xclip;
            if (binAvailable(self.io, "xsel")) break :blk .xsel;
            break :blk .none;
        },
        else => .none,
    };
}

/// Push an unnamed-register write to the system clipboard. Two channels,
/// both best-effort (failures are swallowed — a clipboard hiccup must
/// never disturb an edit):
///   - OSC52 always: works over SSH; terminals without support ignore it
///   - the probed native tool: covers terminals that drop OSC52 writes
///     (Terminal.app) so a yank still reaches the real pasteboard
pub fn pushSystemClipboard(self: *App, text: []const u8) void {
    self.vx.copyToSystemClipboard(self.tty.writer(), text, self.alloc) catch {};
    const argv: []const []const u8 = switch (self.clip_tool) {
        .pbcopy => &.{"pbcopy"},
        .wl => &.{"wl-copy"},
        .xclip => &.{ "xclip", "-selection", "clipboard" },
        .xsel => &.{ "xsel", "--clipboard", "--input" },
        .none => return,
    };
    var child = std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // wait() reaps the child. wl-copy/xclip fork into the background to
    // keep owning the selection; the spawned parent exits as soon as
    // stdin is consumed, so this never blocks on the daemon half.
    defer _ = child.wait(self.io) catch {};
    if (child.stdin) |in| {
        std.Io.File.writeStreamingAll(in, self.io, text) catch {};
        // close our write end so the child sees EOF, then null the handle
        // so wait()'s cleanup doesn't double-close it (EBADF → panic)
        std.Io.File.close(in, self.io);
        child.stdin = null;
    }
}

/// Synchronously read the system clipboard for p/P. Returns an owned copy
/// of the contents, or null when no tool exists (SSH/headless), the tool
/// errors (wl-paste exits non-zero on an empty selection), or the content
/// is empty/over the cap — the caller then falls back to the unnamed
/// register, exactly like nvim with a missing clipboard provider.
pub fn readSystemClipboard(self: *App) ?[]u8 {
    const argv: []const []const u8 = switch (self.clip_tool) {
        .pbcopy => &.{"pbpaste"},
        // NOT --no-newline: the trailing '\n' decides linewise vs charwise
        .wl => &.{"wl-paste"},
        .xclip => &.{ "xclip", "-selection", "clipboard", "-o" },
        .xsel => &.{ "xsel", "--clipboard", "--output" },
        .none => return null,
    };
    var child = std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var reaped = false; // kill()/wait() reap; a wait() after either asserts
    defer if (!reaped) {
        _ = child.wait(self.io) catch {};
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(self.alloc);
    var tmp: [8192]u8 = undefined;
    // drain to EOF BEFORE waiting — waiting first deadlocks once the
    // kernel pipe buffer fills (same discipline as runGrep). A read error
    // — including the EndOfStream readStreaming returns AT eof — just ends
    // the loop; the exit status below decides whether the data is usable.
    while (out.items.len < read_max_bytes) {
        const n = child.stdout.?.readStreaming(self.io, &.{&tmp}) catch break;
        if (n == 0) break;
        out.appendSlice(self.alloc, tmp[0..n]) catch return null;
    }
    if (out.items.len >= read_max_bytes) {
        _ = child.kill(self.io);
        reaped = true;
        return null;
    }
    const status = child.wait(self.io) catch {
        reaped = true; // state uncertain after a failed wait; don't retry
        return null;
    };
    reaped = true;
    switch (status) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    // an empty clipboard must not shadow the register (yy of an empty
    // line pushes an empty clipboard; p still puts the empty line)
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(self.alloc) catch null;
}
