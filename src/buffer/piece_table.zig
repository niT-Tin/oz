//! PieceTable document storage.
//!
//! The initial file content lives in `origin` (read-only); every edit appends
//! its inserted bytes to the `add` buffer and rewrites the piece list, so
//! inserts never copy the document. See DESIGN.md §4.1.
//!
//! Line semantics (vim-style): lines are separated by '\n'. A trailing
//! newline counts as an extra (empty) line, so "abc\n" has 2 lines and
//! "abc" has 1. `lineStart(n)` is the byte offset of line n's first byte,
//! `lineLen(n)` excludes the trailing '\n'.
//!
//! `line_starts` is maintained incrementally: `init` builds it with a single
//! full scan, and every `replace` updates only the affected suffix — line
//! starts after the edit shift by the length delta, starts from '\n's inside
//! the inserted bytes are added, and starts that fell inside the deleted span
//! disappear — so it stays valid across edits without ever re-scanning the
//! document. `compact` never touches it because compaction leaves the
//! document content unchanged.
const std = @import("std");

pub const Piece = struct {
    source: enum { origin, add },
    start: u32, // offset into origin or add buffer
    len: u32,
};

/// Result of a replacement. `after` references bytes owned by the add buffer
/// and is only valid until the next `replace`/`compact` — record it into a
/// History (which copies) immediately.
pub const Edit = struct {
    pos: u32,
    before_len: u32,
    after: []const u8,
};

pub const PieceTable = struct {
    allocator: std.mem.Allocator,
    origin: []u8, // initial content (owned copy, or a read-only file mapping)
    /// When non-null, `origin` aliases this read-only mmap of the loaded file
    /// and deinit must munmap it instead of freeing (see `initMapped`).
    origin_mapping: ?[]align(std.heap.page_size_min) u8 = null,
    add: std.ArrayList(u8), // append-only edit bytes
    pieces: std.ArrayList(Piece), // ordered pieces covering the whole doc
    line_starts: std.ArrayList(u32), // cached; line_starts[0] == 0

    // --- internal bookkeeping (not part of the public contract) ---
    /// Cached logical document length so that `len()` is O(1). Maintained by
    /// `replace`; equal to the sum of `pieces[].len` at all times.
    doc_len: u32,
    /// Always valid in the steady state: `init` builds the cache and `replace`
    /// maintains it incrementally (see header note). Cleared only if the
    /// incremental update runs out of memory, in which case the line* queries
    /// lazily rebuild the cache from scratch.
    line_starts_valid: bool,
    /// Persistent scratch for rebuilding `pieces` in `replace`. Capacity is
    /// retained across edits, so the common case performs no allocation; the
    /// rebuilt list is swapped into `pieces` on commit.
    scratch: std.ArrayList(Piece),
    /// Hint for `byteAt`: the index of the last piece it resolved plus that
    /// piece's document offset, so sequential access starts the scan there.
    /// Stale after `replace`/`compact` (which reset it to 0).
    byte_hint_index: usize,
    byte_hint_offset: u32,

    /// Create a table from initial content (copied). O(n).
    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !PieceTable {
        var self = PieceTable{
            .allocator = allocator,
            .origin = try allocator.dupe(u8, initial),
            .add = .empty,
            .pieces = .empty,
            .line_starts = .empty,
            .doc_len = @intCast(initial.len),
            .line_starts_valid = false,
            .scratch = .empty,
            .byte_hint_index = 0,
            .byte_hint_offset = 0,
        };
        errdefer self.deinit();
        if (initial.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .origin,
                .start = 0,
                .len = @intCast(initial.len),
            });
        }
        self.ensureLineStarts();
        return self;
    }

    /// Create a table whose origin is a read-only file mapping (zero-copy
    /// load path: the file bytes are never copied into the heap). The
    /// mapping must stay alive for the table's lifetime; `deinit` munmaps
    /// it. Only used for regular files where mmap succeeds — the load path
    /// falls back to `init` (read + copy) otherwise.
    pub fn initMapped(allocator: std.mem.Allocator, mapping: []align(std.heap.page_size_min) u8) !PieceTable {
        var self = PieceTable{
            .allocator = allocator,
            .origin = mapping, // []align(page) u8 coerces to []u8
            .origin_mapping = mapping,
            .add = .empty,
            .pieces = .empty,
            .line_starts = .empty,
            .doc_len = @intCast(mapping.len),
            .line_starts_valid = false,
        };
        errdefer self.deinit();
        if (mapping.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .origin,
                .start = 0,
                .len = @intCast(mapping.len),
            });
        }
        self.ensureLineStarts();
        return self;
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.origin_mapping) |m| {
            std.posix.munmap(m);
        } else {
            self.allocator.free(self.origin);
        }
        self.add.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    /// Logical document length in bytes. O(1).
    pub fn len(self: *const PieceTable) u32 {
        return self.doc_len;
    }

    /// Byte at logical offset `pos`. O(pieces), but sequential access is
    /// O(1) amortized via the `byte_hint` (last resolved piece). Out of range
    /// is a bug (debug assert).
    pub fn byteAt(self: *const PieceTable, pos: u32) u8 {
        std.debug.assert(pos < self.doc_len);
        // Start the scan from the last piece this query resolved: pieces are
        // contiguous and ordered, so for any pos at/after that piece's start
        // the containing piece lies at/after the hint index.
        var start_i: usize = 0;
        var offset: u32 = 0;
        if (self.byte_hint_index < self.pieces.items.len and pos >= self.byte_hint_offset) {
            start_i = self.byte_hint_index;
            offset = self.byte_hint_offset;
        }
        for (self.pieces.items[start_i..], start_i..) |p, i| {
            if (pos < offset + p.len) {
                const src: []const u8 = if (p.source == .origin) self.origin else self.add.items;
                // Benign interior mutation (same pattern as ensureLineStarts).
                const s: *PieceTable = @constCast(self);
                s.byte_hint_index = i;
                s.byte_hint_offset = offset;
                return src[@as(usize, p.start) + (pos - offset)];
            }
            offset += p.len;
        }
        unreachable; // pos was asserted in range
    }

    /// Copy `out.len` bytes starting at `pos` into `out` (caller's buffer).
    /// Caller guarantees the range fits. O(pieces + out.len).
    pub fn copyRange(self: *const PieceTable, pos: u32, out: []u8) void {
        const start: usize = pos;
        const end: usize = start + out.len;
        std.debug.assert(end <= self.doc_len);
        if (out.len == 0) return;
        var doc_off: usize = 0;
        var out_off: usize = 0;
        for (self.pieces.items) |p| {
            const plen: usize = p.len;
            const piece_end = doc_off + plen;
            if (piece_end <= start) {
                doc_off = piece_end;
                continue;
            }
            if (doc_off >= end) break;
            const src: []const u8 = if (p.source == .origin) self.origin else self.add.items;
            const skip: usize = if (start > doc_off) start - doc_off else 0;
            const n: usize = @min(@min(plen - skip, end - doc_off), out.len - out_off);
            @memcpy(out[out_off .. out_off + n], src[@as(usize, p.start) + skip .. @as(usize, p.start) + skip + n]);
            out_off += n;
            doc_off = piece_end;
            if (out_off == out.len) break;
        }
        std.debug.assert(out_off == out.len); // caller guaranteed the range fits
    }

    /// Replace [pos, pos+del_len) with `bytes`. Returns an Edit describing the
    /// change (for undo recording). The `after` slice references the add
    /// buffer and is invalidated by later edits/compaction.
    ///
    /// The piece list is rebuilt into the persistent `scratch` list (capacity
    /// retained across edits) before the add buffer is touched, so an
    /// allocation failure leaves the table completely unchanged (the `after`
    /// bytes are only appended on success). The line index is then updated
    /// incrementally, so no per-edit full-document scan is ever needed.
    pub fn replace(self: *PieceTable, pos: u32, del_len: u32, bytes: []const u8) !Edit {
        const doc_len = self.doc_len;
        std.debug.assert(@as(u64, pos) + del_len <= doc_len);

        // No-op: nothing changes, so the line cache stays valid.
        if (del_len == 0 and bytes.len == 0) {
            return .{ .pos = pos, .before_len = 0, .after = self.add.items[self.add.items.len..] };
        }

        const del_end: u64 = @as(u64, pos) + del_len;
        // Where the inserted bytes will live in the add buffer. Computed now;
        // the append happens after the piece list is built, and add is
        // append-only, so this offset stays valid.
        const add_start: u32 = @intCast(self.add.items.len);

        const scratch = &self.scratch;
        scratch.clearRetainingCapacity();

        const add_piece = Piece{ .source = .add, .start = add_start, .len = @intCast(bytes.len) };
        var add_inserted = false;

        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            const piece_start = offset;
            const piece_end = offset + p.len;
            offset = piece_end;

            // The inserted bytes belong at document offset `pos`: right before
            // the first piece that starts at or after `pos`...
            if (!add_inserted and bytes.len > 0 and piece_start >= pos) {
                try scratch.append(self.allocator, add_piece);
                add_inserted = true;
            }

            if (piece_end <= pos) {
                // Entirely before the edit region.
                try scratch.append(self.allocator, p);
            } else if (piece_start >= del_end) {
                // Entirely after the edit region.
                try scratch.append(self.allocator, p);
            } else {
                // Overlaps the edit region: keep the prefix and suffix of the
                // piece, drop the deleted middle, and put the new bytes in
                // between them.
                if (piece_start < pos) {
                    try scratch.append(self.allocator, .{
                        .source = p.source,
                        .start = p.start,
                        .len = pos - piece_start,
                    });
                }
                if (!add_inserted and bytes.len > 0) {
                    try scratch.append(self.allocator, add_piece);
                    add_inserted = true;
                }
                if (del_end < piece_end) {
                    const cut: u32 = @intCast(del_end - piece_start);
                    try scratch.append(self.allocator, .{
                        .source = p.source,
                        .start = p.start + cut,
                        .len = piece_end - @as(u32, @intCast(del_end)),
                    });
                }
            }
        }
        // Append-at-end (or empty doc): no piece started at/after `pos`.
        if (!add_inserted and bytes.len > 0) {
            try scratch.append(self.allocator, add_piece);
        }

        // The piece list is ready; now record the inserted bytes in the add
        // buffer (append-only, atomic on failure) and take the `after` slice.
        if (bytes.len > 0) {
            try self.add.appendSlice(self.allocator, bytes);
        }
        const after = self.add.items[@as(usize, add_start)..];

        // Commit: adopt the new piece list (the old list becomes the scratch
        // for the next edit, keeping its capacity), then update the cached
        // line index incrementally.
        std.mem.swap(std.ArrayList(Piece), &self.pieces, scratch);
        self.doc_len = @intCast(@as(u64, doc_len) + @as(u64, bytes.len) - @as(u64, del_len));
        self.byte_hint_index = 0;
        self.byte_hint_offset = 0;
        if (self.line_starts_valid) {
            self.updateLineStarts(pos, del_len, bytes) catch {
                // Out of memory on the read-path cache: fall back to the lazy
                // full rebuild on the next line* query.
                self.line_starts_valid = false;
            };
        }

        return .{ .pos = pos, .before_len = del_len, .after = after };
    }

    /// Incrementally update `line_starts` for the edit replacing
    /// [pos, pos+del_len) with `bytes`. Requires `line_starts` valid on entry
    /// (it is, in the steady state) and leaves it valid.
    ///
    /// Line starts before the edited line are unchanged. The deleted span
    /// removes the starts strictly inside it (a start at `pos + del_len` came
    /// from a '\n' that was deleted, so it is gone too). Every '\n' at index k
    /// of `bytes` yields a new start at absolute offset `pos + k + 1` (sorted
    /// ascending; a trailing '\n' yields the start at `pos + bytes.len`).
    /// Starts after the span shift by `delta = bytes.len - del_len`, and since
    /// `starts[le] + delta > pos + bytes.len` while every new start is
    /// `<= pos + bytes.len`, the new starts slot in sorted position before
    /// the shifted suffix.
    fn updateLineStarts(self: *PieceTable, pos: u32, del_len: u32, bytes: []const u8) !void {
        const starts = &self.line_starts;
        const li: usize = self.lineOf(pos); // line_starts is valid here
        const del_end: u64 = @as(u64, pos) + del_len;

        // First line start strictly after the deleted span. O(deleted lines).
        var le: usize = li + 1;
        while (le < starts.items.len and starts.items[le] <= del_end) le += 1;

        // Shift the untouched suffix by the length delta (values only; the
        // removed and inserted slots are handled by the replaceRange below).
        const delta: i64 = @as(i64, @intCast(bytes.len)) - @as(i64, del_len);
        if (delta != 0) {
            for (starts.items[le..]) |*s| {
                s.* = @intCast(@as(i64, s.*) + delta);
            }
        }

        // Old starts in [li+1, le) disappeared; the '\n's in `bytes` replace
        // them (possibly zero of either).
        const n_new = std.mem.count(u8, bytes, "\n");
        if (n_new > 0) {
            const tmp = try self.allocator.alloc(u32, n_new);
            defer self.allocator.free(tmp);
            var k: usize = 0;
            for (bytes, 0..) |b, i| {
                if (b == '\n') {
                    tmp[k] = pos + @as(u32, @intCast(i)) + 1;
                    k += 1;
                }
            }
            try starts.replaceRange(self.allocator, li + 1, le - li - 1, tmp);
        } else if (le > li + 1) {
            try starts.replaceRange(self.allocator, li + 1, le - li - 1, &[_]u32{});
        }
    }

    /// Number of lines (vim semantics, see header). O(1) via line_starts.
    pub fn lineCount(self: *const PieceTable) u32 {
        self.ensureLineStarts();
        return @intCast(self.line_starts.items.len);
    }

    /// Byte offset of the first byte of `line`. Assumes line < lineCount.
    pub fn lineStart(self: *const PieceTable, line: u32) u32 {
        self.ensureLineStarts();
        std.debug.assert(line < self.line_starts.items.len);
        return self.line_starts.items[@as(usize, line)];
    }

    /// Byte length of `line`, excluding its trailing '\n' (if any).
    pub fn lineLen(self: *const PieceTable, line: u32) u32 {
        self.ensureLineStarts();
        const starts = self.line_starts.items;
        std.debug.assert(line < starts.len);
        const s = starts[@as(usize, line)];
        if (line + 1 < starts.len) {
            // The next line start is preceded by '\n' (it is a line start),
            // so this line's content is [s, next) minus that '\n'.
            return starts[@as(usize, line) + 1] - s - 1;
        }
        return self.doc_len - s;
    }

    /// Line containing byte offset `pos`. `pos == len` maps to the last line.
    pub fn lineOf(self: *const PieceTable, pos: u32) u32 {
        std.debug.assert(pos <= self.doc_len);
        self.ensureLineStarts();
        const starts = self.line_starts.items;
        // Greatest index with starts[i] <= pos (binary search).
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        // starts[0] == 0 <= pos, so lo >= 1.
        std.debug.assert(lo >= 1);
        return @intCast(lo - 1);
    }

    /// Merge adjacent pieces that are contiguous in the same source buffer.
    /// Called after many edits to bound piece count. Content is unchanged, so
    /// the line cache stays valid; the byteAt hint is reset because piece
    /// indices shifted.
    pub fn compact(self: *PieceTable) void {
        mergeAdjacent(&self.pieces);
        self.byte_hint_index = 0;
        self.byte_hint_offset = 0;
    }

    /// In-place merge of adjacent pieces that are contiguous in the same
    /// source buffer (doc-adjacent means their buffer offsets are contiguous).
    fn mergeAdjacent(pieces: *std.ArrayList(Piece)) void {
        if (pieces.items.len < 2) return;
        var w: usize = 1;
        var i: usize = 1;
        while (i < pieces.items.len) : (i += 1) {
            const p = pieces.items[i];
            const prev = &pieces.items[w - 1];
            if (prev.source == p.source and
                @as(u64, prev.start) + prev.len == @as(u64, p.start))
            {
                prev.len += p.len;
            } else {
                pieces.items[w] = p;
                w += 1;
            }
        }
        pieces.shrinkRetainingCapacity(w);
    }

    pub const Iterator = struct {
        table: *const PieceTable,
        index: usize,

        pub fn next(self: *Iterator) ?Piece {
            if (self.index >= self.table.pieces.items.len) return null;
            const p = self.table.pieces.items[self.index];
            self.index += 1;
            return p;
        }
    };

    /// Iterate pieces in document order (for rendering).
    pub fn iterator(self: *const PieceTable) Iterator {
        return .{ .table = self, .index = 0 };
    }

    /// (Re)build the `line_starts` cache with a full scan of the document.
    /// Called from `init`, and lazily from the line* queries when the cache is
    /// dirty (only possible if an incremental update ran out of memory; the
    /// steady state never re-scans). The queries are `*const`, so the cache
    /// update goes through @constCast — a benign interior mutation.
    /// `catch unreachable`: the query API has no error return, and allocation
    /// failure on a read path is not recoverable here; std.testing.allocator
    /// never fails, and in production an OOM in the editor is fatal anyway.
    fn ensureLineStarts(self: *const PieceTable) void {
        if (self.line_starts_valid) return;
        const s: *PieceTable = @constCast(self);
        s.line_starts.clearRetainingCapacity();
        // line_starts[0] is always 0; every '\n' starts a new line after it.
        s.line_starts.append(s.allocator, 0) catch unreachable;
        var doc_off: u32 = 0;
        for (s.pieces.items) |p| {
            const src: []const u8 = if (p.source == .origin) s.origin else s.add.items;
            const bytes = src[@as(usize, p.start) .. @as(usize, p.start) + p.len];
            for (bytes, 0..) |b, k| {
                if (b == '\n') {
                    s.line_starts.append(s.allocator, doc_off + @as(u32, @intCast(k)) + 1) catch unreachable;
                }
            }
            doc_off += p.len;
        }
        s.line_starts_valid = true;
    }
};

// =============================== tests ======================================

fn expectDoc(pt: *PieceTable, allocator: std.mem.Allocator, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), pt.len());
    // byteAt on every position must agree with the mirror.
    for (expected, 0..) |b, i| {
        try std.testing.expectEqual(b, pt.byteAt(@intCast(i)));
    }
    // full copyRange must agree with the mirror.
    const buf = try allocator.alloc(u8, expected.len);
    defer allocator.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualSlices(u8, expected, buf);
}

fn pieceBytes(pt: *const PieceTable, p: Piece) []const u8 {
    return if (p.source == .origin)
        pt.origin[@as(usize, p.start) .. @as(usize, p.start) + p.len]
    else
        pt.add.items[@as(usize, p.start) .. @as(usize, p.start) + p.len];
}

fn randomBytes(rng: std.Random, allocator: std.mem.Allocator, alphabet: []const u8) ![]u8 {
    const len = rng.uintLessThan(usize, 10); // 0..9 bytes, sometimes empty
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
    return buf;
}

/// Assert every document invariant against a mirror (ArrayList) of the
/// expected content: total length, piece-length sum, full copyRange, line
/// index vs a line-by-line scan, lineOf for every byte offset, and iterator
/// coverage.
fn checkInvariants(pt: *PieceTable, expected: *const std.ArrayList(u8)) !void {
    const alloc = pt.allocator;
    const doc_len: u32 = @intCast(expected.items.len);

    // Total length == piece-length sum == mirror length.
    var sum: u32 = 0;
    for (pt.pieces.items) |p| sum += p.len;
    try std.testing.expectEqual(doc_len, pt.len());
    try std.testing.expectEqual(doc_len, sum);

    // Full copyRange == mirror.
    const buf = try alloc.alloc(u8, expected.items.len);
    defer alloc.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualSlices(u8, expected.items, buf);

    // Line index == line-by-line scan of the mirror.
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(alloc);
    try starts.append(alloc, 0);
    for (expected.items, 0..) |b, i| {
        if (b == '\n') try starts.append(alloc, @intCast(i + 1));
    }

    try std.testing.expectEqual(@as(u32, @intCast(starts.items.len)), pt.lineCount());
    for (starts.items, 0..) |s, li| {
        try std.testing.expectEqual(s, pt.lineStart(@intCast(li)));
        const line_len: u32 = if (li + 1 < starts.items.len)
            starts.items[li + 1] - s - 1
        else
            doc_len - s;
        try std.testing.expectEqual(line_len, pt.lineLen(@intCast(li)));
    }

    // lineOf for every byte offset, including pos == len (last line).
    for (0..expected.items.len + 1) |p| {
        const pos: u32 = @intCast(p);
        var lo: usize = 0;
        var hi: usize = starts.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts.items[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        try std.testing.expectEqual(@as(u32, @intCast(lo - 1)), pt.lineOf(pos));
    }

    // Iterator covers the document exactly once, in order.
    var it = pt.iterator();
    var covered: u32 = 0;
    while (it.next()) |p| covered += p.len;
    try std.testing.expectEqual(doc_len, covered);
}

test "copyRange partial copies with skip across pieces" {
    // regression: copyRange must clamp `n` to the out buffer, not just the
    // document range (a skip>0 partial copy used to overflow `out`)
    var pt = try PieceTable.init(std.testing.allocator, "abcd efgh ijkl");
    defer pt.deinit();

    // mid-line slice (skip > 0 within one piece)
    var buf: [4]u8 = undefined;
    pt.copyRange(2, &buf);
    try std.testing.expectEqualSlices(u8, "cd e", &buf);

    // slice spanning a piece boundary after an edit
    _ = try pt.replace(5, 1, "XX"); // "abcd XXfgh ijkl"
    var buf2: [6]u8 = undefined;
    pt.copyRange(3, &buf2);
    try std.testing.expectEqualSlices(u8, "d XXfg", &buf2);

    // line slice (render-style: lineStart/lineLen then copyRange)
    var pt2 = try PieceTable.init(std.testing.allocator, "line one\nline two\nline three\n");
    defer pt2.deinit();
    const ls = pt2.lineStart(1);
    const ll = pt2.lineLen(1);
    const line_buf = try std.testing.allocator.alloc(u8, ll);
    defer std.testing.allocator.free(line_buf);
    pt2.copyRange(ls, line_buf);
    try std.testing.expectEqualSlices(u8, "line two", line_buf);
}

test "init: content copied, len/byteAt/copyRange correct" {
    var pt = try PieceTable.init(std.testing.allocator, "hello\nworld");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 11), pt.len());
    try std.testing.expectEqual(@as(u8, 'h'), pt.byteAt(0));
    try std.testing.expectEqual(@as(u8, '\n'), pt.byteAt(5));
    try std.testing.expectEqual(@as(u8, 'd'), pt.byteAt(10));
    var full: [11]u8 = undefined;
    pt.copyRange(0, &full);
    try std.testing.expectEqualStrings("hello\nworld", &full);
    var tail: [5]u8 = undefined;
    pt.copyRange(6, &tail);
    try std.testing.expectEqualStrings("world", &tail);
}

test "init with empty content" {
    var pt = try PieceTable.init(std.testing.allocator, "");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 0), pt.len());
    try std.testing.expectEqual(@as(u32, 1), pt.lineCount()); // vim: empty buffer = 1 line
    try std.testing.expectEqual(@as(u32, 0), pt.lineStart(0));
    try std.testing.expectEqual(@as(u32, 0), pt.lineLen(0));
    try std.testing.expectEqual(@as(u32, 0), pt.lineOf(0));
    try std.testing.expectEqual(@as(u32, 0), pt.lineOf(pt.len())); // pos == len -> last line
}

test "insert, delete, replace mixed" {
    var pt = try PieceTable.init(std.testing.allocator, "hello world");
    defer pt.deinit();

    // insert in the middle
    var e = try pt.replace(5, 0, " cruel");
    try std.testing.expectEqual(@as(u32, 5), e.pos);
    try std.testing.expectEqual(@as(u32, 0), e.before_len);
    try std.testing.expectEqualStrings(" cruel", e.after);
    try expectDoc(&pt, std.testing.allocator, "hello cruel world");

    // delete what we just inserted
    e = try pt.replace(5, 6, "");
    try std.testing.expectEqual(@as(u32, 6), e.before_len);
    try std.testing.expectEqual(@as(usize, 0), e.after.len);
    try expectDoc(&pt, std.testing.allocator, "hello world");

    // replace at the start
    e = try pt.replace(0, 5, "goodbye");
    try std.testing.expectEqual(@as(u32, 5), e.before_len);
    try std.testing.expectEqualStrings("goodbye", e.after);
    try expectDoc(&pt, std.testing.allocator, "goodbye world");

    // insert at end of document
    e = try pt.replace(13, 0, "!");
    try std.testing.expectEqualStrings("!", e.after);
    try expectDoc(&pt, std.testing.allocator, "goodbye world!");

    // delete the whole document
    e = try pt.replace(0, 14, "");
    try std.testing.expectEqual(@as(u32, 14), e.before_len);
    try expectDoc(&pt, std.testing.allocator, "");
    try std.testing.expectEqual(@as(u32, 1), pt.lineCount());

    // grow from the empty document again
    _ = try pt.replace(0, 0, "back");
    try expectDoc(&pt, std.testing.allocator, "back");
}

test "no-op replace leaves everything intact" {
    var pt = try PieceTable.init(std.testing.allocator, "abc");
    defer pt.deinit();
    const e = try pt.replace(1, 0, "");
    try std.testing.expectEqual(@as(u32, 0), e.before_len);
    try std.testing.expectEqual(@as(usize, 0), e.after.len);
    try expectDoc(&pt, std.testing.allocator, "abc");
    try std.testing.expectEqual(@as(u32, 1), pt.lineCount());
}

test "line semantics: vim-style counting" {
    // "abc\n" has 2 lines (trailing newline = extra empty line)
    var pt = try PieceTable.init(std.testing.allocator, "abc\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 2), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.lineStart(0));
    try std.testing.expectEqual(@as(u32, 3), pt.lineLen(0));
    try std.testing.expectEqual(@as(u32, 4), pt.lineStart(1));
    try std.testing.expectEqual(@as(u32, 0), pt.lineLen(1));
    // lineOf boundaries
    try std.testing.expectEqual(@as(u32, 0), pt.lineOf(0));
    try std.testing.expectEqual(@as(u32, 0), pt.lineOf(2));
    try std.testing.expectEqual(@as(u32, 0), pt.lineOf(3)); // the '\n' belongs to line 0
    try std.testing.expectEqual(@as(u32, 1), pt.lineOf(4)); // pos == len -> last line

    // "abc" has 1 line
    var pt2 = try PieceTable.init(std.testing.allocator, "abc");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(u32, 1), pt2.lineCount());
    try std.testing.expectEqual(@as(u32, 3), pt2.lineLen(0));
    try std.testing.expectEqual(@as(u32, 0), pt2.lineOf(3)); // pos == len -> last line
}

test "line semantics: multi-line and empty lines" {
    var pt = try PieceTable.init(std.testing.allocator, "ab\n\ncd\ne");
    defer pt.deinit();
    // "ab", "", "cd", "e" -> 4 lines
    try std.testing.expectEqual(@as(u32, 4), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.lineStart(0));
    try std.testing.expectEqual(@as(u32, 2), pt.lineLen(0));
    try std.testing.expectEqual(@as(u32, 3), pt.lineStart(1));
    try std.testing.expectEqual(@as(u32, 0), pt.lineLen(1));
    try std.testing.expectEqual(@as(u32, 4), pt.lineStart(2));
    try std.testing.expectEqual(@as(u32, 2), pt.lineLen(2));
    try std.testing.expectEqual(@as(u32, 7), pt.lineStart(3));
    try std.testing.expectEqual(@as(u32, 1), pt.lineLen(3));
    try std.testing.expectEqual(@as(u32, 2), pt.lineOf(5)); // inside "cd"
    try std.testing.expectEqual(@as(u32, 3), pt.lineOf(8)); // pos == len -> last line
}

test "line index follows edits (lazy rebuild stays correct)" {
    var pt = try PieceTable.init(std.testing.allocator, "one\ntwo\nthree");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.lineCount());

    // split line 0 in two by inserting a newline
    _ = try pt.replace(3, 0, "\n");
    try expectDoc(&pt, std.testing.allocator, "one\n\ntwo\nthree");
    try std.testing.expectEqual(@as(u32, 4), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 4), pt.lineStart(1)); // the new empty line
    try std.testing.expectEqual(@as(u32, 0), pt.lineLen(1));

    // join lines by deleting the two newlines
    _ = try pt.replace(3, 2, "");
    try expectDoc(&pt, std.testing.allocator, "onetwo\nthree");
    try std.testing.expectEqual(@as(u32, 2), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 6), pt.lineLen(0));

    // delete the last newline -> one line
    _ = try pt.replace(6, 1, "");
    try expectDoc(&pt, std.testing.allocator, "onetwothree");
    try std.testing.expectEqual(@as(u32, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 11), pt.lineLen(0));

    // append a trailing newline -> two lines, last one empty
    _ = try pt.replace(11, 0, "\n");
    try std.testing.expectEqual(@as(u32, 2), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.lineLen(1));
    try std.testing.expectEqual(@as(u32, 1), pt.lineOf(12)); // pos == len -> last line
}

test "compact merges adjacent add pieces without changing content" {
    var pt = try PieceTable.init(std.testing.allocator, "hello\nworld");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 2), pt.lineCount());

    _ = try pt.replace(11, 0, "!"); // "hello\nworld!"
    _ = try pt.replace(12, 0, "?"); // "hello\nworld!?"
    _ = try pt.replace(5, 0, " "); // "hello \nworld!?"
    // pieces: origin"hello", add" ", origin"\nworld", add"!", add"?"
    try std.testing.expectEqual(@as(usize, 5), pt.pieces.items.len);
    try expectDoc(&pt, std.testing.allocator, "hello \nworld!?");

    pt.compact();
    // origin"hello", add" ", origin"\nworld", add"!?"  (the two add pieces merged)
    try std.testing.expectEqual(@as(usize, 4), pt.pieces.items.len);
    try expectDoc(&pt, std.testing.allocator, "hello \nworld!?");
    try std.testing.expectEqual(@as(u32, 2), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 6), pt.lineLen(0)); // "hello " before '\n'
}

test "compact does not merge origin pieces separated by deleted bytes" {
    var pt = try PieceTable.init(std.testing.allocator, "abcdef");
    defer pt.deinit();
    _ = try pt.replace(2, 2, ""); // delete "cd" -> "abef"
    try expectDoc(&pt, std.testing.allocator, "abef");
    // origin[0..2] and origin[4..6] are not contiguous in origin -> no merge
    try std.testing.expectEqual(@as(usize, 2), pt.pieces.items.len);
    pt.compact();
    try std.testing.expectEqual(@as(usize, 2), pt.pieces.items.len);
    try expectDoc(&pt, std.testing.allocator, "abef");
}

test "iterator walks pieces in document order and then returns null" {
    var pt = try PieceTable.init(std.testing.allocator, "hello");
    defer pt.deinit();
    _ = try pt.replace(0, 0, ">"); // [add ">", origin "hello"]
    _ = try pt.replace(6, 0, " world"); // [add ">", origin "hello", add " world"]
    try expectDoc(&pt, std.testing.allocator, ">hello world");

    var it = pt.iterator();
    const p0 = it.next().?;
    try std.testing.expectEqual(.add, p0.source);
    try std.testing.expectEqualStrings(">", pieceBytes(&pt, p0));
    const p1 = it.next().?;
    try std.testing.expectEqual(.origin, p1.source);
    try std.testing.expectEqualStrings("hello", pieceBytes(&pt, p1));
    const p2 = it.next().?;
    try std.testing.expectEqual(.add, p2.source);
    try std.testing.expectEqualStrings(" world", pieceBytes(&pt, p2));
    try std.testing.expectEqual(@as(?Piece, null), it.next());

    // pieces are contiguous and cover the whole document
    var covered: u32 = 0;
    var it2 = pt.iterator();
    while (it2.next()) |p| covered += p.len;
    try std.testing.expectEqual(pt.len(), covered);
}

test "random edits preserve all invariants (fixed seed)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0BAD_F00D);
    const rng = prng.random();

    var pt = try PieceTable.init(alloc, "alpha\nbeta\ngamma\n\n");
    defer pt.deinit();

    // Mirror of the logical document.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);
    try expected.appendSlice(alloc, "alpha\nbeta\ngamma\n\n");

    // Alphabet includes '\n' so edits exercise the line index too.
    const alphabet = "abc\nXYZ 012\t";
    var step: usize = 0;
    while (step < 500) : (step += 1) {
        const op = rng.uintLessThan(u8, 10);
        const ipos: usize = rng.uintLessThan(usize, expected.items.len + 1);
        const pos: u32 = @intCast(ipos);
        switch (op) {
            0...3 => {
                // insert
                const s = try randomBytes(rng, alloc, alphabet);
                defer alloc.free(s);
                const e = try pt.replace(pos, 0, s);
                try std.testing.expectEqual(@as(u32, 0), e.before_len);
                try std.testing.expectEqualSlices(u8, s, e.after);
                try expected.insertSlice(alloc, pos, s);
            },
            4...6 => {
                // delete
                const del_len: u32 = @intCast(rng.uintLessThan(usize, expected.items.len - ipos + 1));
                const e = try pt.replace(pos, del_len, "");
                try std.testing.expectEqual(del_len, e.before_len);
                try std.testing.expectEqual(@as(usize, 0), e.after.len);
                try expected.replaceRange(alloc, pos, del_len, "");
            },
            else => {
                // replace (delete + insert)
                const del_len: u32 = @intCast(rng.uintLessThan(usize, expected.items.len - ipos + 1));
                const s = try randomBytes(rng, alloc, alphabet);
                defer alloc.free(s);
                const e = try pt.replace(pos, del_len, s);
                try std.testing.expectEqual(del_len, e.before_len);
                try std.testing.expectEqualSlices(u8, s, e.after);
                try expected.replaceRange(alloc, pos, del_len, s);
            },
        }
        try checkInvariants(&pt, &expected);
        // periodically compact; invariants must hold across compaction too
        if (step % 40 == 39) pt.compact();
    }

    // Final state still matches the mirror.
    try expectDoc(&pt, alloc, expected.items);
}
