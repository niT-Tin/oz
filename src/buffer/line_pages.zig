//! Newline ranks in an immutable or append-only byte store. One cumulative
//! count per complete 64 KiB page, and exact offsets for the last page read.
const std = @import("std");

pub const page_size = 64 * 1024;

pub const Index = struct {
    ends: std.ArrayList(u32) = .empty,
    offsets: std.ArrayList(u16) = .empty,
    cached_page: ?usize = null,
    cached_len: usize = 0,

    pub fn deinit(self: *Index, alloc: std.mem.Allocator) void {
        self.ends.deinit(alloc);
        self.offsets.deinit(alloc);
    }

    fn previous(self: *const Index, page: usize) u32 {
        return if (page == 0) 0 else self.ends.items[page - 1];
    }

    fn extend(self: *Index, alloc: std.mem.Allocator, bytes: []const u8, pages: usize, goal: u32) void {
        while (self.ends.items.len < pages and self.previous(self.ends.items.len) < goal) {
            const page = self.ends.items.len;
            const count = countNewlines(bytes[page * page_size ..][0..page_size]);
            self.ends.append(alloc, self.previous(page) + count) catch unreachable;
        }
    }

    fn local(self: *Index, alloc: std.mem.Allocator, bytes: []const u8, page: usize) []const u16 {
        const tail = bytes[page * page_size ..];
        const block = tail[0..@min(page_size, tail.len)];
        if (self.cached_page == page and self.cached_len == block.len) return self.offsets.items;
        self.offsets.clearRetainingCapacity();
        var i: usize = 0;
        const lanes = std.simd.suggestVectorLength(u8) orelse 1;
        if (lanes > 1) {
            const V = @Vector(lanes, u8);
            while (block.len - i >= lanes) : (i += lanes) {
                const v: V = block[i..][0..lanes].*;
                var hits: @Int(.unsigned, lanes) = @bitCast(v == @as(V, @splat('\n')));
                if (@import("builtin").target.cpu.arch.endian() == .big) hits = @bitReverse(hits);
                while (hits != 0) : (hits &= hits - 1)
                    self.offsets.append(alloc, @intCast(i + @ctz(hits))) catch unreachable;
            }
        }
        for (block[i..], i..) |b, n| if (b == '\n') {
            self.offsets.append(alloc, @intCast(n)) catch unreachable;
        };
        self.cached_page = page;
        self.cached_len = block.len;
        return self.offsets.items;
    }

    /// Number of LF bytes strictly before end.
    pub fn rank(self: *Index, alloc: std.mem.Allocator, bytes: []const u8, end: u32) u32 {
        const page = end / page_size;
        self.extend(alloc, bytes, page, std.math.maxInt(u32));
        const within = end % page_size;
        if (within == 0) return self.previous(page);
        const offsets = self.local(alloc, bytes, page);
        return self.previous(page) + @as(u32, @intCast(std.sort.lowerBound(u16, offsets, @as(u16, @intCast(within)), cmpU16)));
    }

    fn cmpU16(key: u16, elem: u16) std.math.Order {
        return std.math.order(key, elem);
    }
    fn cmpU32(key: u32, elem: u32) std.math.Order {
        return std.math.order(key, elem);
    }

    /// Absolute byte offset of the requested LF (one-based), before end.
    pub fn select(self: *Index, alloc: std.mem.Allocator, bytes: []const u8, end: u32, ordinal: u32) ?u32 {
        std.debug.assert(ordinal > 0);
        const pages = end / page_size;
        self.extend(alloc, bytes, pages, ordinal);
        const complete = self.ends.items[0..@min(pages, self.ends.items.len)];
        const page = std.sort.lowerBound(u32, complete, ordinal, cmpU32);
        if (page == pages and end % page_size == 0) return null;
        const local_ordinal = ordinal - self.previous(page);
        const offsets = self.local(alloc, bytes, page);
        if (local_ordinal > offsets.len) return null;
        const pos: u32 = @intCast(page * page_size + offsets[local_ordinal - 1]);
        return if (pos < end) pos else null;
    }

    pub fn advance(self: *Index, alloc: std.mem.Allocator, bytes: []const u8, pages: usize) bool {
        const total = bytes.len / page_size;
        self.extend(alloc, bytes, @min(total, self.ends.items.len + pages), std.math.maxInt(u32));
        return self.ends.items.len == total;
    }
};

pub fn countNewlines(bytes: []const u8) u32 {
    const lanes = std.simd.suggestVectorLength(u8) orelse 1;
    var n: u32 = 0;
    var i: usize = 0;
    if (lanes > 1) {
        const V = @Vector(lanes, u8);
        while (bytes.len - i >= lanes) : (i += lanes) {
            const v: V = bytes[i..][0..lanes].*;
            n += @popCount(@as(@Int(.unsigned, lanes), @bitCast(v == @as(V, @splat('\n')))));
        }
    }
    for (bytes[i..]) |b| n += @intFromBool(b == '\n');
    return n;
}
