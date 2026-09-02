//! number — App method group split out of src/main.zig (physical move).

const std = @import("std");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const BlockRect = App.BlockRect;

// ---- number increment/decrement (Ctrl+a / Ctrl+x / g Ctrl+a / g Ctrl+x) ----

/// One number occurrence in the document: byte range plus parsed value.
pub const Number = struct {
    start: u32,
    end: u32, // exclusive
    value: i64,
};

pub fn isDigitByte(b: u8) bool {
    return b >= '0' and b <= '9';
}

/// Expand the digit run containing `digit_pos` into the whole number.
/// A '-' immediately before the run is included as the sign, unless it is
/// itself glued to a preceding digit ("1-5" with the cursor on 5 is the
/// number 5, while "-5" is -5). Returns null when the digits do not fit
/// i64 (the number is then left untouched).
pub fn numberAtDigit(self: *App, digit_pos: u32) ?Number {
    const pt = &self.cur().pt;
    const len = pt.len();
    var start = digit_pos;
    while (start > 0 and isDigitByte(pt.byteAt(start - 1))) start -= 1;
    if (start > 0 and pt.byteAt(start - 1) == '-' and
        (start == 1 or !isDigitByte(pt.byteAt(start - 2))))
    {
        start -= 1;
    }
    var end = digit_pos + 1;
    while (end < len and isDigitByte(pt.byteAt(end))) end += 1;
    var v: i64 = 0;
    var i = start;
    const neg = if (i < end and pt.byteAt(i) == '-') blk: {
        i += 1;
        break :blk true;
    } else false;
    while (i < end) : (i += 1) {
        const d = pt.byteAt(i) - '0';
        if (v > @divTrunc(std.math.maxInt(i64) - @as(i64, d), 10)) return null; // overflow
        v = v * 10 + @as(i64, d);
    }
    return .{ .start = start, .end = end, .value = if (neg) -v else v };
}

/// The first number at or after `pos` (vim Ctrl+a semantics): the digit
/// run under the cursor, else the next digit run (optionally '-' signed)
/// scanning forward. Returns null when no number exists at/after `pos`.
pub fn numberAtOrAfter(self: *App, pos: u32) ?Number {
    const pt = &self.cur().pt;
    const len = pt.len();
    if (pos >= len) return null;
    if (isDigitByte(pt.byteAt(pos))) return self.numberAtDigit(pos);
    var i = pos;
    while (i < len) : (i += 1) {
        const b = pt.byteAt(i);
        if (isDigitByte(b)) return self.numberAtDigit(i);
        if (b == '-' and i + 1 < len and isDigitByte(pt.byteAt(i + 1))) {
            return self.numberAtDigit(i + 1);
        }
    }
    return null;
}

/// The first number in [ls, le) (column-increment target), if any.
pub fn firstNumberInLine(self: *App, ls: u32, le: u32) ?Number {
    var p = ls;
    while (p < le) {
        const b = self.cur().pt.byteAt(p);
        if (isDigitByte(b)) return self.numberAtDigit(p);
        if (b == '-' and p + 1 < le and isDigitByte(self.cur().pt.byteAt(p + 1))) {
            return self.numberAtDigit(p + 1);
        }
        p += 1;
    }
    return null;
}

/// Replace one number with value+delta; returns the byte end of the new
/// text (the number may have grown or shrunk).
pub fn replaceNumber(self: *App, n: Number, delta: i64) !u32 {
    const new = try std.fmt.allocPrint(self.alloc, "{d}", .{n.value + delta});
    defer self.alloc.free(new);
    try self.cur().history.record(&self.cur().pt, n.start, n.end - n.start, new);
    return n.start + @as(u32, @intCast(new.len));
}

/// Normal-mode Ctrl+a/x: increment the number at/after the cursor and
/// place the cursor just after it (vim). One undo step.
pub fn execNumberDeltaAtCursor(self: *App, delta: i64) !void {
    const n = self.numberAtOrAfter(self.curCursor().*) orelse return;
    self.cur().history.beginGroup();
    const new_end = try self.replaceNumber(n, delta);
    self.cur().history.endGroup();
    self.curCursor().* = new_end;
    self.markDirty();
}

/// Visual-mode Ctrl+a/x: increment every number in every line covered by
/// the selection. One undo group; edits are applied right-to-left so the
/// earlier offsets stay valid.
pub fn execSelectionNumberDelta(self: *App, delta: i64) !void {
    const anchor = self.visual_anchor orelse return;
    const s = @min(anchor, self.curCursor().*);
    const e = @max(anchor, self.curCursor().*);
    const pt = &self.cur().pt;
    const start_line = pt.lineOf(s);
    const end_line = pt.lineOf(e);
    self.cur().history.beginGroup();
    var numbers = std.ArrayList(Number).empty;
    defer numbers.deinit(self.alloc);
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        const ls = pt.lineStart(line);
        const le = ls + pt.lineLen(line);
        var p = ls;
        while (p < le) {
            const b = pt.byteAt(p);
            if (isDigitByte(b)) {
                const n = self.numberAtDigit(p) orelse {
                    p += 1;
                    continue;
                };
                try numbers.append(self.alloc, n);
                p = n.end;
            } else if (b == '-' and p + 1 < le and isDigitByte(pt.byteAt(p + 1))) {
                const n = self.numberAtDigit(p + 1) orelse {
                    p += 1;
                    continue;
                };
                try numbers.append(self.alloc, n);
                p = n.end;
            } else {
                p += 1;
            }
        }
    }
    var i = numbers.items.len;
    while (i > 0) {
        i -= 1;
        _ = try self.replaceNumber(numbers.items[i], delta);
    }
    self.cur().history.endGroup();
    self.markDirty();
}

/// Visual-mode g Ctrl+a/x (vim column increment): each selected line's
/// FIRST number gets ±(count + line offset), the i-th selected line (i
/// starting at 1) getting ±i with count 1. A visual-BLOCK selection
/// restricts the numbers to the block's column range (vim: only numbers
/// inside the block are touched). One undo group; lines are processed
/// bottom-up so earlier lines keep valid offsets.
pub fn execSelectionNumberColumn(self: *App, delta: i64) !void {
    const anchor = self.visual_anchor orelse return;
    const s = @min(anchor, self.curCursor().*);
    const e = @max(anchor, self.curCursor().*);
    const pt = &self.cur().pt;
    const start_line = pt.lineOf(s);
    const end_line = pt.lineOf(e);
    // visual block: the numbers must overlap the block's column range;
    // other visual modes take each line's first number
    const block_cols: ?BlockRect = if (self.state.mode == .visual_block) self.blockRect() else null;
    self.cur().history.beginGroup();
    var line = end_line;
    while (true) {
        const ls = pt.lineStart(line);
        const le = ls + pt.lineLen(line);
        var num: ?Number = null;
        if (block_cols) |br| {
            // first number whose digits overlap the block columns
            var p = @min(ls + br.left, le);
            const right = @min(ls + br.right + 1, le);
            while (p < right) {
                if (isDigitByte(pt.byteAt(p))) {
                    num = self.numberAtDigit(p);
                    break;
                }
                p += 1;
            }
        } else {
            num = self.firstNumberInLine(ls, le);
        }
        if (num) |n| {
            const offset: i64 = @intCast(line - start_line + 1);
            _ = try self.replaceNumber(n, delta * offset);
        }
        if (line == start_line) break;
        line -= 1;
    }
    self.cur().history.endGroup();
    self.markDirty();
}

/// p / P: put the unnamed register exactly like nvim. A LINEWISE register
/// (yy, dd, V{y,d}, yG, …) puts whole lines below (p) / above (P) the
/// cursor line and leaves the cursor on the first non-blank of the first
/// pasted line. A charwise register (yw, vey, …) pastes inline after (p)
/// / at (P) the cursor and leaves the cursor on the last pasted char.
/// `count` pastes that many times (vim 5p), one undo group.
pub fn pasteBuffer(self: *App, before: bool, count: u32) !void {
    const buf = self.yank_buffer orelse {
        try self.setMsg(try self.alloc.dupe(u8, "E353: Nothing in register"));
        return;
    };
    if (buf.len == 0 and !self.yank_linewise) return;
    const pt = &self.cur().pt;
    const n = @max(count, 1);
    if (self.yank_linewise) {
        // normalize: the register must end with '\n' so every copy lands
        // as complete lines (yy on a final line without a trailing
        // newline yanks none; yy on an empty line yanks zero bytes —
        // both paste as one empty line).
        var norm = try self.alloc.alloc(u8, buf.len + 1);
        defer self.alloc.free(norm);
        @memcpy(norm[0..buf.len], buf);
        const text: []const u8 = if (buf.len == 0) blk: {
            norm[0] = '\n';
            break :blk norm[0..1];
        } else if (buf[buf.len - 1] == '\n') norm[0..buf.len] else blk: {
            norm[buf.len] = '\n';
            break :blk norm;
        };
        const line = pt.lineOf(self.curCursor().*);
        self.cur().history.beginGroup();
        var content_start: u32 = undefined; // first pasted byte (for the cursor)
        if (before) {
            var pos = pt.lineStart(line);
            content_start = pos;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try self.cur().history.record(pt, pos, 0, text);
                pos += @intCast(text.len);
            }
        } else if (line + 1 < pt.lineCount()) {
            var pos = pt.lineStart(line + 1);
            content_start = pos;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try self.cur().history.record(pt, pos, 0, text);
                pos += @intCast(text.len);
            }
        } else {
            // cursor on the last line: terminate it first when the buffer
            // doesn't end with a newline, then the copies follow as
            // whole lines
            var pos = pt.len();
            if (pos > 0 and pt.byteAt(pos - 1) != '\n') {
                try self.cur().history.record(pt, pos, 0, "\n");
                pos += 1;
            }
            content_start = pos;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try self.cur().history.record(pt, pos, 0, text);
                pos += @intCast(text.len);
            }
        }
        self.cur().history.endGroup();
        // cursor on the first non-blank of the first pasted line (an
        // all-blank line leaves it at the line start)
        var c = content_start;
        while (c < pt.len() and (pt.byteAt(c) == ' ' or pt.byteAt(c) == '\t')) c += 1;
        if (c < pt.len() and pt.byteAt(c) == '\n') c = content_start;
        self.curCursor().* = c;
    } else {
        var pos = self.curCursor().*;
        if (!before) {
            // p: after the character under the cursor (or at line end)
            const line = pt.lineOf(self.curCursor().*);
            const line_end = pt.lineStart(line) + pt.lineLen(line);
            if (self.curCursor().* < line_end) {
                var i = self.curCursor().* + 1;
                while (i < line_end and (pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                pos = i;
            }
        }
        self.cur().history.beginGroup();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try self.cur().history.record(pt, pos, 0, buf);
            pos += @as(u32, @intCast(buf.len));
        }
        self.cur().history.endGroup();
        // nvim: the cursor lands ON the last pasted character (not past
        // it) — back up over UTF-8 continuation bytes
        var c = pos - 1;
        const paste_begin = pos - @as(u32, @intCast(buf.len));
        while (c > paste_begin and (pt.byteAt(c) & 0xC0) == 0x80) c -= 1;
        self.curCursor().* = c;
    }
    // markDirty is the single entry point for dirty flag / edit_seq /
    // LSP didChange / inlay invalidation — paste must go through it or
    // the server keeps an outdated document and hints stay stale.
    self.markDirty();
}
