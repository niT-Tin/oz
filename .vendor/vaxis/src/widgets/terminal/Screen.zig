const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../../main.zig");

const ansi = @import("ansi.zig");

const log = std.log.scoped(.vaxis_terminal);

const Screen = @This();

pub const Cell = struct {
    char: std.ArrayList(u8) = .empty,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    width: u8 = 1,

    wrapped: bool = false,
    dirty: bool = true,

    pub fn erase(self: *Cell, allocator: std.mem.Allocator, bg: vaxis.Color) void {
        self.char.clearRetainingCapacity();
        self.char.append(allocator, ' ') catch unreachable; // we never completely free this list
        self.style = .{};
        self.style.bg = bg;
        self.uri.clearRetainingCapacity();
        self.uri_id.clearRetainingCapacity();
        self.width = 1;
        self.wrapped = false;
        self.dirty = true;
    }

    pub fn copyFrom(self: *Cell, allocator: std.mem.Allocator, src: Cell) !void {
        self.char.clearRetainingCapacity();
        try self.char.appendSlice(allocator, src.char.items);
        self.style = src.style;
        self.uri.clearRetainingCapacity();
        try self.uri.appendSlice(allocator, src.uri.items);
        self.uri_id.clearRetainingCapacity();
        try self.uri_id.appendSlice(allocator, src.uri_id.items);
        self.width = src.width;
        self.wrapped = src.wrapped;

        self.dirty = true;
    }
};

pub const Cursor = struct {
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    col: u16 = 0,
    row: u16 = 0,
    pending_wrap: bool = false,
    shape: vaxis.Cell.CursorShape = .default,
    visible: bool = true,

    pub fn isOutsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return self.row < sr.top or
            self.row > sr.bottom or
            self.col < sr.left or
            self.col > sr.right;
    }

    pub fn isInsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return !self.isOutsideScrollingRegion(sr);
    }
};

/// Copy the rendered part of one cell (grapheme, style, width) into `dst`.
/// OSC 8 URI metadata is intentionally not part of local scrollback.
fn copyCellInto(dst: *Cell, allocator: std.mem.Allocator, src: *const Cell) !void {
    dst.char.clearRetainingCapacity();
    try dst.char.appendSlice(allocator, src.char.items);
    dst.style = src.style;
    dst.width = src.width;
    dst.wrapped = src.wrapped;
    dst.dirty = true;
}

fn blankCellInto(dst: *Cell, allocator: std.mem.Allocator) !void {
    dst.char.clearRetainingCapacity();
    try dst.char.append(allocator, ' ');
    dst.style = .{};
    dst.width = 1;
    dst.wrapped = false;
    dst.dirty = true;
}

/// Bounded ring of primary-screen rows that scrolled off the top. Cells are
/// MOVED out of the screen row (zero-copy text buffers) and the source cells
/// are reset; eviction frees the oldest row's cell buffers, so memory is
/// bounded by `capacity * width` cells plus those cells' graphemes.
pub const History = struct {
    allocator: std.mem.Allocator = undefined,
    width: u16 = 0,
    slots: []?[]Cell = &.{},
    /// Ring position of the oldest retained row.
    start: usize = 0,
    /// Number of retained rows (<= slots.len).
    len: usize = 0,
    /// Monotonic count of rows ever pushed. Readers use deltas to keep a
    /// scrolled viewport anchored while output continues.
    pushes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: u16, cap: u16) !History {
        const slots = try allocator.alloc(?[]Cell, cap);
        @memset(slots, null);
        return .{ .allocator = allocator, .width = width, .slots = slots };
    }

    pub fn deinit(self: *History) void {
        if (self.slots.len == 0) {
            self.* = .{};
            return;
        }
        self.clear();
        self.allocator.free(self.slots);
        self.* = .{};
    }

    pub fn count(self: *const History) usize {
        return self.len;
    }

    pub fn capacity(self: *const History) usize {
        return self.slots.len;
    }

    /// Drop every retained row and free its cell buffers (the ring stays
    /// allocated and reusable).
    pub fn clear(self: *History) void {
        for (self.slots) |slot| {
            if (slot) |row| {
                for (row) |*cell| {
                    cell.char.deinit(self.allocator);
                    cell.uri.deinit(self.allocator);
                    cell.uri_id.deinit(self.allocator);
                    cell.* = .{};
                }
                self.allocator.free(row);
            }
        }
        @memset(self.slots, null);
        self.start = 0;
        self.len = 0;
    }

    /// Move one full screen row into the ring, evicting the oldest row when
    /// full. The source row's cells are reset to empty owned cells.
    pub fn push(self: *History, src: []Cell) !void {
        if (self.slots.len == 0 or src.len == 0) return;
        var idx: usize = undefined;
        if (self.len < self.slots.len) {
            idx = (self.start + self.len) % self.slots.len;
            self.len += 1;
            if (self.slots[idx] == null) {
                const row = try self.allocator.alloc(Cell, self.width);
                for (row) |*cell| cell.* = .{};
                self.slots[idx] = row;
            }
        } else {
            idx = self.start;
            self.start = (self.start + 1) % self.slots.len;
            const row = self.slots[idx].?;
            for (row) |*cell| {
                cell.char.deinit(self.allocator);
                cell.uri.deinit(self.allocator);
                cell.uri_id.deinit(self.allocator);
                cell.* = .{};
            }
        }
        const dst = self.slots[idx].?;
        const n = @min(src.len, dst.len);
        for (dst[0..n], src[0..n]) |*d, *s| {
            d.* = s.*;
            s.* = .{};
        }
        self.pushes += 1;
    }

    /// Deep-copy retained row `index` (0 = oldest) into `dst`.
    pub fn copyRow(self: *History, row_index: usize, allocator: std.mem.Allocator, dst: []Cell) !void {
        if (row_index >= self.len) {
            for (dst) |*cell| try blankCellInto(cell, allocator);
            return;
        }
        const row = self.slots[(self.start + row_index) % self.slots.len].?;
        const n = @min(row.len, dst.len);
        for (row[0..n], dst[0..n]) |*src, *out| try copyCellInto(out, allocator, src);
        for (dst[n..]) |*cell| try blankCellInto(cell, allocator);
    }
};

pub const ScrollingRegion = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,

    pub fn contains(self: ScrollingRegion, col: usize, row: usize) bool {
        return col >= self.left and
            col <= self.right and
            row >= self.top and
            row <= self.bottom;
    }
};

allocator: std.mem.Allocator,

width: u16 = 0,
height: u16 = 0,

scrolling_region: ScrollingRegion,

buf: []Cell = undefined,

cursor: Cursor = .{},

csi_u_flags: vaxis.Key.KittyFlags = @bitCast(@as(u5, 0)),

/// Primary-screen local scrollback (capacity 0 = disabled). The visible
/// `buf` always stays exactly `height` rows tall; off-screen rows live here.
history: History = .{},

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Screen {
    return initWithHistory(alloc, w, h, 0);
}

/// Like `init`, but retains up to `scrollback` scrolled-off rows when this
/// screen is used as the primary back screen. Only full-screen scrolling
/// regions feed the history; the alt screen is always created with 0.
pub fn initWithHistory(alloc: std.mem.Allocator, w: u16, h: u16, scrollback: u16) !Screen {
    var screen = Screen{
        .allocator = alloc,
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
        .scrolling_region = .{
            .top = 0,
            .bottom = h - 1,
            .left = 0,
            .right = w - 1,
        },
        .width = w,
        .height = h,
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try .initCapacity(alloc, 1),
        };
        try screen.buf[i].char.append(alloc, ' ');
    }
    if (scrollback > 0) screen.history = try History.init(alloc, w, scrollback);
    return screen;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit(alloc);
        self.buf[i].uri.deinit(alloc);
        self.buf[i].uri_id.deinit(alloc);
    }

    alloc.free(self.buf);
    self.history.deinit();
}

/// copies the visible area to the destination screen
pub fn copyTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen) !void {
    dst.cursor = self.cursor;
    for (self.buf, 0..) |cell, i| {
        if (!cell.dirty) continue;
        self.buf[i].dirty = false;
        const grapheme = cell.char.items;
        dst.buf[i].char.clearRetainingCapacity();
        try dst.buf[i].char.appendSlice(allocator, grapheme);
        dst.buf[i].width = cell.width;
        dst.buf[i].style = cell.style;
    }
}

/// Compose the visible grid for a history viewport: `offset` rows above the
/// live bottom (0 = live screen, follow mode). The oldest retained history
/// row is at offset `history.count()`. Clears the source dirty flags for the
/// live rows copied so a later `copyTo` stays incremental.
pub fn copyViewportTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen, offset: usize) !void {
    std.debug.assert(dst.width == self.width and dst.height == self.height);
    const hist = self.history.count();
    const off = @min(offset, hist);
    const top = hist - off;
    var row: usize = 0;
    while (row < self.height) : (row += 1) {
        const virtual = top + row;
        const dst_row = dst.buf[row * self.width ..][0..self.width];
        if (virtual < hist) {
            try self.history.copyRow(virtual, allocator, dst_row);
        } else {
            const src = self.buf[(virtual - hist) * self.width ..][0..self.width];
            for (src, dst_row) |*cell, *out| {
                try copyCellInto(out, allocator, cell);
                cell.dirty = false;
            }
        }
    }
    dst.cursor = self.cursor;
}

pub fn historyCount(self: *const Screen) usize {
    return self.history.count();
}

pub fn clearScrollback(self: *Screen) void {
    self.history.clear();
}

pub fn readCell(self: *Screen, col: usize, row: usize) ?vaxis.Cell {
    if (self.width < col) {
        // column out of bounds
        return null;
    }
    if (self.height < row) {
        // height out of bounds
        return null;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    const cell = self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.items, .width = cell.width },
        .style = cell.style,
    };
}

/// returns true if the current cursor position is within the scrolling region
pub fn withinScrollingRegion(self: Screen) bool {
    return self.scrolling_region.contains(self.cursor.col, self.cursor.row);
}

/// writes a cell to a location. 0 indexed
pub fn print(
    self: *Screen,
    grapheme: []const u8,
    width: u8,
    wrap: bool,
) !void {
    if (self.cursor.pending_wrap) {
        try self.index();
        self.cursor.col = self.scrolling_region.left;
    }
    if (self.cursor.col >= self.width) return;
    if (self.cursor.row >= self.height) return;
    const col = self.cursor.col;
    const row = self.cursor.row;

    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(self.allocator, grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(self.allocator, self.cursor.uri.items) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(self.allocator, self.cursor.uri_id.items) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = self.cursor.style;
    self.buf[i].width = width;
    self.buf[i].dirty = true;

    if (wrap and self.cursor.col >= self.width - 1) self.cursor.pending_wrap = true;
    self.cursor.col += width;
}

/// IND
pub fn index(self: *Screen) !void {
    self.cursor.pending_wrap = false;

    if (self.cursor.isOutsideScrollingRegion(self.scrolling_region)) {
        // Outside, we just move cursor down one
        self.cursor.row = @min(self.height - 1, self.cursor.row + 1);
        return;
    }
    // We are inside the scrolling region
    if (self.cursor.row == self.scrolling_region.bottom) {
        // Inside scrolling region *and* at bottom of screen, we scroll contents up and insert a
        // blank line
        // TODO: scrollback if scrolling region is entire visible screen
        try self.deleteLine(1);
        return;
    }
    self.cursor.row += 1;
}

pub fn sgr(self: *Screen, seq: ansi.CSI) void {
    if (seq.params.len == 0) {
        self.cursor.style = .{};
        return;
    }

    var iter = seq.iterator(u8);
    while (iter.next()) |ps| {
        switch (ps) {
            0 => self.cursor.style = .{},
            1 => self.cursor.style.bold = true,
            2 => self.cursor.style.dim = true,
            3 => self.cursor.style.italic = true,
            4 => {
                const kind: vaxis.Style.Underline = if (iter.next_is_sub)
                    @enumFromInt(iter.next() orelse 1)
                else
                    .single;
                self.cursor.style.ul_style = kind;
            },
            5 => self.cursor.style.blink = true,
            7 => self.cursor.style.reverse = true,
            8 => self.cursor.style.invisible = true,
            9 => self.cursor.style.strikethrough = true,
            21 => self.cursor.style.ul_style = .double,
            22 => {
                self.cursor.style.bold = false;
                self.cursor.style.dim = false;
            },
            23 => self.cursor.style.italic = false,
            24 => self.cursor.style.ul_style = .off,
            25 => self.cursor.style.blink = false,
            27 => self.cursor.style.reverse = false,
            28 => self.cursor.style.invisible = false,
            29 => self.cursor.style.strikethrough = false,
            30...37 => self.cursor.style.fg = .{ .index = ps - 30 },
            38 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.fg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.fg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            39 => self.cursor.style.fg = .default,
            40...47 => self.cursor.style.bg = .{ .index = ps - 40 },
            48 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.bg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.bg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            49 => self.cursor.style.bg = .default,
            90...97 => self.cursor.style.fg = .{ .index = ps - 90 + 8 },
            100...107 => self.cursor.style.bg = .{ .index = ps - 100 + 8 },
            else => continue,
        }
    }
}

pub fn cursorUp(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.row = @max(
            self.cursor.row -| n,
            self.scrolling_region.top,
        )
    else
        self.cursor.row -|= n;
}

pub fn cursorLeft(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @max(
            self.cursor.col -| n,
            self.scrolling_region.left,
        )
    else
        self.cursor.col = self.cursor.col -| n;
}

pub fn cursorRight(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @min(
            self.cursor.col + n,
            self.scrolling_region.right,
        )
    else
        self.cursor.col = @min(
            self.cursor.col + n,
            self.width - 1,
        );
}

pub fn cursorDown(self: *Screen, n: usize) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.row = @min(
            self.scrolling_region.bottom,
            self.cursor.row + n,
        )
    else
        self.cursor.row = @min(
            self.height -| 1,
            self.cursor.row + n,
        );
}

pub fn eraseRight(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const end = (self.cursor.row * self.width) + (self.width);
    var i = (self.cursor.row * self.width) + self.cursor.col;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLeft(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.cursor.row * self.width;
    const end = start + self.cursor.col + 1;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLine(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const start = self.cursor.row * self.width;
    const end = start + self.width;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

/// delete n lines from the bottom of the scrolling region
pub fn deleteLine(self: *Screen, n: usize) !void {
    if (n == 0) return;

    // Don't delete if outside scroll region
    if (!self.withinScrollingRegion()) return;

    self.cursor.pending_wrap = false;

    // Number of rows from here to bottom of scroll region or n
    const cnt = @min(self.scrolling_region.bottom - self.cursor.row + 1, n);
    const stride = (self.width) * cnt;

    // Local scrollback: before the shift overwrites them, move the rows that
    // leave the top of a FULL-SCREEN scrolling region into the bounded
    // primary-screen history. Alt screens / partial regions have capacity 0.
    if (self.history.capacity() > 0 and
        self.scrolling_region.top == 0 and
        self.scrolling_region.bottom == self.height - 1 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.width - 1)
    {
        var r: usize = 0;
        while (r < cnt) : (r += 1) {
            try self.history.push(self.buf[r * self.width .. (r + 1) * self.width]);
        }
    }

    var row: usize = self.scrolling_region.top;
    while (row <= self.scrolling_region.bottom) : (row += 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            if (row + cnt > self.scrolling_region.bottom)
                self.buf[i].erase(self.allocator, self.cursor.style.bg)
            else
                try self.buf[i].copyFrom(self.allocator, self.buf[i + stride]);
        }
    }
}

/// insert n lines at the top of the scrolling region
pub fn insertLine(self: *Screen, n: usize) !void {
    if (n == 0) return;

    self.cursor.pending_wrap = false;
    // Don't insert if outside scroll region
    if (!self.withinScrollingRegion()) return;

    const adjusted_n = @min(self.scrolling_region.bottom - self.cursor.row, n);
    const stride = (self.width) * adjusted_n;

    var row: usize = self.scrolling_region.bottom;
    while (row >= self.scrolling_region.top + adjusted_n) : (row -|= 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            try self.buf[i].copyFrom(self.allocator, self.buf[i - stride]);
        }
    }

    row = self.scrolling_region.top;
    while (row < self.scrolling_region.top + adjusted_n) : (row += 1) {
        var col: usize = self.scrolling_region.left;
        while (col <= self.scrolling_region.right) : (col += 1) {
            const i = (row * self.width) + col;
            self.buf[i].erase(self.allocator, self.cursor.style.bg);
        }
    }
}

pub fn eraseBelow(self: *Screen) void {
    self.eraseRight();
    // start is the first column of the row below us
    const start = (self.cursor.row * self.width) + (self.width);
    var i = start;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAbove(self: *Screen) void {
    self.eraseLeft();
    // start is the first column of the row below us
    const start: usize = 0;
    const end = self.cursor.row * self.width;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAll(self: *Screen) void {
    var i: usize = 0;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn deleteCharacters(self: *Screen, n: usize) !void {
    if (!self.withinScrollingRegion()) return;

    self.cursor.pending_wrap = false;
    var col = self.cursor.col;
    while (col <= self.scrolling_region.right) : (col += 1) {
        if (col + n <= self.scrolling_region.right)
            try self.buf[col].copyFrom(self.allocator, self.buf[col + n])
        else
            self.buf[col].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn reverseIndex(self: *Screen) !void {
    if (self.cursor.row != self.scrolling_region.top or
        self.cursor.col < self.scrolling_region.left or
        self.cursor.col > self.scrolling_region.right)
        self.cursorUp(1)
    else
        try self.scrollDown(1);
}

pub fn scrollDown(self: *Screen, n: usize) !void {
    const cur_row = self.cursor.row;
    const cur_col = self.cursor.col;
    const wrap = self.cursor.pending_wrap;
    defer {
        self.cursor.row = cur_row;
        self.cursor.col = cur_col;
        self.cursor.pending_wrap = wrap;
    }
    self.cursor.col = self.scrolling_region.left;
    self.cursor.row = self.scrolling_region.top;
    try self.insertLine(n);
}
