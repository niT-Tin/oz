//! macro — vim-style keyboard macros: q{reg} records, @{reg} replays
//! (count prefix and @@ supported). Recording captures keys at the
//! handleKey entry point, so cross-mode sequences (insert text, ':'
//! commands, '/' searches) replay verbatim.

const std = @import("std");
const vaxis = @import("vaxis");
const editor = @import("../editor/root.zig");
const PieceTable = @import("../buffer/root.zig").PieceTable;

const app_mod = @import("../app.zig");
const App = app_mod.App;

/// Bound on nested @ recursion (a register replaying itself, or @a/@b
/// replaying each other). vim's 'maxmapdepth' analogue, much smaller — a
/// macro nested deeper than this is a loop, not a workflow.
const max_play_depth = 16;

/// A recorded key. vaxis.Key.text has a limited lifetime (vaxis keeps it in
/// an internal ring buffer), so the text is copied into inline storage here.
/// The stored key's .text field is NOT valid while parked in the register
/// (the inline buffer moves with the struct); playbackKey() re-attaches it.
pub const RecordedKey = struct {
    key: vaxis.Key,
    text_buf: [32]u8 = undefined,
    text_len: u8 = 0,

    pub fn from(key: vaxis.Key) RecordedKey {
        var rk: RecordedKey = .{ .key = key };
        rk.key.text = null; // never keep the transient slice
        if (key.text) |t| {
            if (t.len <= rk.text_buf.len) {
                @memcpy(rk.text_buf[0..t.len], t);
                rk.text_len = @intCast(t.len);
            }
            // A single key generating >32 bytes of text is a pathological
            // multicodepoint kitty event; it records codepoint-only.
        }
        return rk;
    }

    pub fn playbackKey(self: *const RecordedKey) vaxis.Key {
        var k = self.key;
        k.text = if (self.text_len > 0) self.text_buf[0..self.text_len] else null;
        return k;
    }
};

// anyerror: execMacro → handleKey → execMacro is a recursion cycle, which
// inferred error sets cannot resolve.
pub fn execMacro(self: *App, m: editor.MacroOp) anyerror!void {
    switch (m.op) {
        .record => {
            // q arriving from playback (a recorded q) is ignored: replayed
            // keys are not user input, and re-arming recording from inside
            // a macro would capture the macro's own tail.
            if (self.macro_play_depth > 0) return;
            if (self.macro_rec != null) return; // already recording
            const idx: usize = m.reg - 'a';
            self.macro_rec = idx;
            self.macro_rec_buf.clearRetainingCapacity();
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "recording @{c}", .{m.reg}));
        },
        .play => {
            // @@ replays the register of the most recent @ command.
            const idx: usize = if (m.reg == '@') blk: {
                break :blk self.macro_last orelse {
                    try self.setMsg(try self.alloc.dupe(u8, "E748: No previously used register"));
                    return;
                };
            } else m.reg - 'a';
            const keys = self.macros[idx] orelse {
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "E748: Nothing in register {c}", .{m.reg}));
                return;
            };
            if (keys.len == 0) {
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "E748: Nothing in register {c}", .{m.reg}));
                return;
            }
            // Visual mode: vim :'<,'>normal! @{reg} — leave visual, then run
            // the macro once per line covered by the selection (visual_char
            // covers the lines of the anchor/cursor endpoints; visual_line /
            // visual_block the whole lines). The range is read BEFORE the
            // exit clears the anchor.
            if (self.isVisual()) {
                const pt = &self.cur().pt;
                const range = visualLineRange(pt, self.visual_anchor orelse self.curCursor().*, self.curCursor().*);
                self.exitVisual();
                var line = range.start;
                while (line <= range.end) : (line += 1) {
                    // The macro may change the line count (dd, o, …): the
                    // target line is re-validated every round; gone → stop.
                    if (line >= pt.lineCount()) break;
                    self.curCursor().* = @min(pt.lineStart(line), pt.len());
                    if (!try playRegister(self, idx, m.count)) break;
                }
                return;
            }
            _ = try playRegister(self, idx, m.count);
        },
    }
}

/// Replay register `idx` `count` times. Returns false when playback aborted
/// early — a key errored (vim: an error aborts the remaining playback) or
/// the recursion bound tripped — so the per-line visual loop stops too.
fn playRegister(self: *App, idx: usize, count: u32) !bool {
    if (self.macro_play_depth >= max_play_depth) {
        try self.setMsg(try self.alloc.dupe(u8, "macro recursion too deep"));
        return false;
    }
    const keys = self.macros[idx].?; // non-null, non-empty: checked by caller
    self.macro_last = idx;
    self.macro_play_depth += 1;
    defer self.macro_play_depth -= 1;
    var i: u32 = 0;
    outer: while (i < count) : (i += 1) {
        for (keys) |*rk| {
            // vim: an error aborts the remaining playback. OOM is the
            // exception — it is not a macro failure, propagate.
            self.handleKey(rk.playbackKey()) catch |err| {
                if (err == error.OutOfMemory) return err;
                break :outer;
            };
        }
    }
    return true;
}

/// Line range covered by a visual selection, either direction (anchor may
/// sit below the cursor). visual_char's partial lines count as covered,
/// matching :'<,'>normal semantics.
pub fn visualLineRange(pt: *const PieceTable, anchor: u32, cursor: u32) struct { start: u32, end: u32 } {
    return .{
        .start = pt.lineOf(@min(anchor, cursor)),
        .end = pt.lineOf(@max(anchor, cursor)),
    };
}

/// Stop recording (the bare-'q' interception in handleKey): the capture
/// buffer becomes the register's content. The stop key itself never entered
/// the buffer — the interception runs before capture.
pub fn macroStopRecord(self: *App) !void {
    const idx = self.macro_rec orelse return;
    self.macro_rec = null;
    const keys = try self.macro_rec_buf.toOwnedSlice(self.alloc);
    if (self.macros[idx]) |old| self.alloc.free(old);
    self.macros[idx] = keys;
    // drop the "recording @x" message; the status line indicator already
    // disappears with macro_rec == null
    if (self.msg) |msg| {
        self.alloc.free(msg);
        self.msg = null;
    }
}

test "RecordedKey copies the transient text into inline storage" {
    var backing = [_]u8{ 'h', 'i' };
    const rk = RecordedKey.from(.{ .codepoint = 'h', .text = backing[0..1] });
    // mutating the source slice must not affect the recording
    backing[0] = 'X';
    const k = rk.playbackKey();
    try std.testing.expectEqualStrings("h", k.text.?);
    try std.testing.expectEqual(@as(u21, 'h'), k.codepoint);

    // a text-less key (arrows, Esc, …) replays text-less
    const rk2 = RecordedKey.from(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(@as(?[]const u8, null), rk2.playbackKey().text);
}

test "visualLineRange: cross-line, single-line and reversed selections" {
    const testing = std.testing;
    // lines: 0="aaa" 1="bbb" 2="ccc" (4 bytes each incl. '\n')
    var pt = try PieceTable.init(testing.allocator, "aaa\nbbb\nccc\n");
    defer pt.deinit();

    // visual_char forward, line 0 col 1 → line 1 col 2: lines 0..1
    const r1 = visualLineRange(&pt, 1, 6);
    try testing.expectEqual(@as(u32, 0), r1.start);
    try testing.expectEqual(@as(u32, 1), r1.end);

    // reversed (anchor below the cursor): same range
    const r2 = visualLineRange(&pt, 6, 1);
    try testing.expectEqual(@as(u32, 0), r2.start);
    try testing.expectEqual(@as(u32, 1), r2.end);

    // single-line selection: both endpoints on line 2
    const r3 = visualLineRange(&pt, 9, 10);
    try testing.expectEqual(@as(u32, 2), r3.start);
    try testing.expectEqual(@as(u32, 2), r3.end);

    // cursor at the last byte (the trailing '\n' of line 2)
    const r4 = visualLineRange(&pt, 8, 11);
    try testing.expectEqual(@as(u32, 2), r4.start);
    try testing.expectEqual(@as(u32, 2), r4.end);
}
