//! Multi-cursor (DESIGN.md §1.3): a sorted set of cursors with synchronized
//! editing. Pure logic; the UI (Ctrl+n selection, visual-block fan-out) is
//! wired in the app.
//!
//! Contract adjustment (wordAt -> wordRange): a slice into the piece table's
//! origin/add buffers is invalidated by the very next edit, so the word under
//! a cursor is returned as byte offsets instead. Offsets stay valid until the
//! caller edits; callers that must persist the bytes copy them out with
//! `PieceTable.copyRange`.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// Word characters, mirroring motion.zig's classification: [a-zA-Z0-9_]
/// plus any non-ASCII byte (so multibyte CJK text stays one word).
fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80;
}

/// Half-open byte range of a word occurrence.
pub const Range = struct {
    start: u32,
    end: u32, // exclusive
};

pub const MultiCursor = struct {
    allocator: std.mem.Allocator,
    cursors: std.ArrayList(u32), // sorted, deduplicated byte offsets
    main: usize = 0, // index of the main cursor into `cursors`

    pub fn init(allocator: std.mem.Allocator) MultiCursor {
        return .{ .allocator = allocator, .cursors = .empty };
    }

    pub fn deinit(self: *MultiCursor) void {
        self.cursors.deinit(self.allocator);
    }

    pub fn len(self: *const MultiCursor) usize {
        return self.cursors.items.len;
    }

    /// First index with `items[i] >= pos` (binary search lower bound).
    fn lowerBound(items: []const u32, pos: u32) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Insert a cursor position (sorted, deduped). Returns true if added.
    /// `main` stays an index into `cursors`: it is bumped when a cursor is
    /// inserted at or before it; the very first cursor becomes the main one.
    pub fn add(self: *MultiCursor, pos: u32) !bool {
        const i = lowerBound(self.cursors.items, pos);
        if (i < self.cursors.items.len and self.cursors.items[i] == pos) return false;
        try self.cursors.insert(self.allocator, i, pos);
        if (self.cursors.items.len == 1) {
            self.main = 0;
        } else if (i <= self.main) {
            self.main += 1;
        }
        return true;
    }

    /// Remove a cursor position. Returns true if it was present. `main` is
    /// kept valid: it shifts down when a cursor before it is removed and
    /// otherwise points at the cursor that slid into its slot.
    pub fn remove(self: *MultiCursor, pos: u32) bool {
        const i = lowerBound(self.cursors.items, pos);
        if (i >= self.cursors.items.len or self.cursors.items[i] != pos) return false;
        _ = self.cursors.orderedRemove(i);
        if (self.cursors.items.len == 0) {
            self.main = 0;
        } else if (i < self.main) {
            self.main -= 1;
        } else if (i == self.main and self.main >= self.cursors.items.len) {
            self.main = self.cursors.items.len - 1;
        }
        return true;
    }

    pub fn clear(self: *MultiCursor) void {
        self.cursors.clearRetainingCapacity();
        self.main = 0;
    }

    /// The word under `pos`, as byte offsets (start inclusive, end exclusive).
    /// `pos` not on a word byte (whitespace, punctuation, end of document)
    /// yields an empty range {pos, pos}.
    ///
    /// Contract note: this replaced `wordAt` (which returned a slice into the
    /// piece table's buffers). A slice cannot survive the next edit, so the
    /// range is returned instead and callers copy the bytes they need via
    /// `PieceTable.copyRange` — no allocation here.
    pub fn wordRange(self: *const MultiCursor, pt: *const PieceTable, pos: u32) Range {
        _ = self;
        const doc_len = pt.len();
        if (pos >= doc_len) return .{ .start = pos, .end = pos };
        if (!isWordByte(pt.byteAt(pos))) return .{ .start = pos, .end = pos };
        var start = pos;
        while (start > 0 and isWordByte(pt.byteAt(start - 1))) start -= 1;
        var end = pos + 1;
        while (end < doc_len and isWordByte(pt.byteAt(end))) end += 1;
        return .{ .start = start, .end = end };
    }

    /// Ctrl+n: add the next occurrence of the main cursor's word after the
    /// last cursor; returns false when no further occurrence exists.
    ///
    /// Candidates must be word starts and the whole word must match
    /// byte-for-byte (case-sensitive, so "abc" never matches inside "abcd").
    /// Returns false if the main cursor is not on a word or any cursor is not
    /// on the main word (e.g. the text was edited since the cursors were
    /// placed). The new cursor is appended; `main` is left untouched.
    pub fn addNextMatch(self: *MultiCursor, pt: *const PieceTable) !bool {
        if (self.cursors.items.len == 0) return false;
        const main_range = self.wordRange(pt, self.cursors.items[self.main]);
        if (main_range.start == main_range.end) return false;
        // Every cursor must be on an occurrence of the same word (different
        // occurrences have different byte ranges, so compare by content).
        for (self.cursors.items) |c| {
            const r = self.wordRange(pt, c);
            if (!rangesEqual(pt, main_range, r)) return false;
        }
        const last = self.cursors.items[self.cursors.items.len - 1];
        const doc_len = pt.len();
        if (last >= doc_len) return false;
        var p = last + 1;
        while (p < doc_len) : (p += 1) {
            if (!isWordByte(pt.byteAt(p))) continue;
            if (p > 0 and isWordByte(pt.byteAt(p - 1))) continue; // not a word start
            const r = self.wordRange(pt, p);
            if (r.start != p or r.end - r.start != main_range.end - main_range.start) continue;
            if (!rangesEqual(pt, main_range, r)) continue;
            return self.add(p);
        }
        return false;
    }

    /// Insert `text` at every cursor (applied right-to-left so earlier
    /// positions stay valid); returns the number of edits applied.
    ///
    /// Cursors are updated to stay on the text: every cursor at or after an
    /// insertion point moves forward by `text.len`. On an allocation failure
    /// partway through, the already-processed (higher) cursors are edited and
    /// moved and the error is propagated with the partial state.
    pub fn applyInsert(self: *MultiCursor, pt: *PieceTable, text: []const u8) !usize {
        if (text.len == 0) return 0;
        var count: usize = 0;
        var i = self.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.cursors.items[i];
            _ = try pt.replace(pos, 0, text);
            count += 1;
            const shift: u32 = @intCast(text.len);
            for (self.cursors.items[i..]) |*c| c.* += shift;
        }
        return count;
    }

    /// Delete `del_len` bytes before every cursor (applied right-to-left).
    /// A cursor at `pos` deletes [pos-del_len, pos) — clamped to the document
    /// start when fewer bytes are available — and lands on `pos-del_len`;
    /// cursors swallowed by a deletion range clamp to its start (this can
    /// leave equal positions when ranges overlap; re-add to re-dedup).
    /// Returns the number of edits applied.
    pub fn applyDelete(self: *MultiCursor, pt: *PieceTable, del_len: u32) !usize {
        if (del_len == 0) return 0;
        var count: usize = 0;
        var i = self.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.cursors.items[i];
            if (pos == 0) continue;
            const start: u32 = if (pos < del_len) 0 else pos - del_len;
            const del = pos - start; // actual bytes removed (<= del_len)
            _ = try pt.replace(start, del, "");
            count += 1;
            // Positions > start are affected: those >= pos shift back by
            // `del`, those inside (start, pos) clamp to `start`.
            var j = lowerBound(self.cursors.items, start);
            while (j < self.cursors.items.len and self.cursors.items[j] == start) : (j += 1) {}
            while (j < self.cursors.items.len) : (j += 1) {
                const c = self.cursors.items[j];
                self.cursors.items[j] = if (c >= pos) c - del else start;
            }
        }
        // overlapping deletes can clamp several cursors onto the same
        // position — dedupe (the list stays sorted) so typed text isn't
        // inserted multiple times at one spot.
        if (self.cursors.items.len > 1) {
            var write: usize = 1;
            var prev = self.cursors.items[0];
            var di: usize = 1;
            while (di < self.cursors.items.len) : (di += 1) {
                const c = self.cursors.items[di];
                if (c != prev) {
                    self.cursors.items[write] = c;
                    write += 1;
                    prev = c;
                }
            }
            self.cursors.shrinkRetainingCapacity(write);
        }
        return count;
    }
};

/// Byte-for-byte equality of two ranges.
fn rangesEqual(pt: *const PieceTable, a: Range, b: Range) bool {
    const a_len = a.end - a.start;
    if (a_len != b.end - b.start) return false;
    var k: u32 = 0;
    while (k < a_len) : (k += 1) {
        if (pt.byteAt(a.start + k) != pt.byteAt(b.start + k)) return false;
    }
    return true;
}

// ================================= tests =====================================

const testing = std.testing;

fn docBytes(pt: *const PieceTable, allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, pt.len());
    pt.copyRange(0, buf);
    return buf;
}

test "multicursor: add/remove/clear keep a sorted, deduplicated set" {
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();

    try testing.expectEqual(@as(usize, 0), mc.len());
    try testing.expect(try mc.add(5));
    try testing.expect(try mc.add(3));
    try testing.expect(try mc.add(7));
    try testing.expect(try mc.add(1));
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 7 }, mc.cursors.items);
    try testing.expectEqual(@as(usize, 4), mc.len());

    // duplicates are rejected, order is preserved
    try testing.expect(!try mc.add(3));
    try testing.expect(!try mc.add(5));
    try testing.expect(try mc.add(6)); // slot between 5 and 7
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 6, 7 }, mc.cursors.items);

    // remove
    try testing.expect(mc.remove(3));
    try testing.expect(!mc.remove(3));
    try testing.expectEqualSlices(u32, &.{ 1, 5, 6, 7 }, mc.cursors.items);
    try testing.expect(mc.remove(1));
    try testing.expect(mc.remove(7));
    try testing.expect(mc.remove(6));
    try testing.expect(mc.remove(5));
    try testing.expectEqual(@as(usize, 0), mc.len());

    // clear
    _ = try mc.add(2);
    _ = try mc.add(9);
    mc.clear();
    try testing.expectEqual(@as(usize, 0), mc.len());
    try testing.expect(try mc.add(4));
    try testing.expectEqualSlices(u32, &.{4}, mc.cursors.items);
}

test "multicursor: main index stays valid across add/remove" {
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(10); // first cursor becomes main (index 0)
    _ = try mc.add(20);
    _ = try mc.add(30);
    try testing.expectEqual(@as(usize, 0), mc.main);
    _ = try mc.add(5); // inserted before main -> main shifts to 1
    try testing.expectEqual(@as(usize, 1), mc.main);
    try testing.expectEqual(@as(u32, 10), mc.cursors.items[mc.main]);
    _ = try mc.add(15); // inserted after main -> main unchanged
    try testing.expectEqual(@as(usize, 1), mc.main);
    try testing.expectEqual(@as(u32, 10), mc.cursors.items[mc.main]);
    try testing.expect(mc.remove(5)); // removed before main -> main shifts down
    try testing.expectEqual(@as(usize, 0), mc.main);
    try testing.expectEqual(@as(u32, 10), mc.cursors.items[mc.main]);
    try testing.expect(mc.remove(10)); // removing the main cursor keeps main valid
    try testing.expectEqual(@as(u32, 15), mc.cursors.items[mc.main]);
}

test "multicursor: wordRange returns byte bounds, empty range off-word" {
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();

    // plain words and whitespace
    var pt = try PieceTable.init(testing.allocator, "hello world");
    defer pt.deinit();
    try testing.expectEqual(Range{ .start = 0, .end = 5 }, mc.wordRange(&pt, 0));
    try testing.expectEqual(Range{ .start = 0, .end = 5 }, mc.wordRange(&pt, 3)); // mid-word
    try testing.expectEqual(Range{ .start = 6, .end = 11 }, mc.wordRange(&pt, 10));
    try testing.expectEqual(Range{ .start = 5, .end = 5 }, mc.wordRange(&pt, 5)); // space
    try testing.expectEqual(Range{ .start = 11, .end = 11 }, mc.wordRange(&pt, 11)); // doc end

    // punctuation is a non-word boundary
    var pt2 = try PieceTable.init(testing.allocator, "abc.def");
    defer pt2.deinit();
    try testing.expectEqual(Range{ .start = 0, .end = 3 }, mc.wordRange(&pt2, 0));
    try testing.expectEqual(Range{ .start = 3, .end = 3 }, mc.wordRange(&pt2, 3)); // '.'
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, mc.wordRange(&pt2, 6));

    // CJK: every non-ASCII byte is a word byte, so a run forms one word
    var pt3 = try PieceTable.init(testing.allocator, "中文 ab");
    defer pt3.deinit();
    try testing.expectEqual(Range{ .start = 0, .end = 6 }, mc.wordRange(&pt3, 0));
    try testing.expectEqual(Range{ .start = 0, .end = 6 }, mc.wordRange(&pt3, 5)); // inside a UTF-8 seq
    try testing.expectEqual(Range{ .start = 6, .end = 6 }, mc.wordRange(&pt3, 6)); // space
    try testing.expectEqual(Range{ .start = 7, .end = 9 }, mc.wordRange(&pt3, 8));
    try testing.expectEqual(Range{ .start = 9, .end = 9 }, mc.wordRange(&pt3, 9)); // doc end
}

test "multicursor: addNextMatch finds the next exact word after the last cursor" {
    // "foo" at 0, 8, 12; "foofoo" at 20 is a different word and must not match.
    var pt = try PieceTable.init(testing.allocator, "foo bar foo foo baz foofoo");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(0);
    try testing.expect(try mc.addNextMatch(&pt));
    try testing.expectEqualSlices(u32, &.{ 0, 8 }, mc.cursors.items);
    try testing.expect(try mc.addNextMatch(&pt));
    try testing.expectEqualSlices(u32, &.{ 0, 8, 12 }, mc.cursors.items);
    try testing.expect(!try mc.addNextMatch(&pt)); // exhausted
    try testing.expectEqualSlices(u32, &.{ 0, 8, 12 }, mc.cursors.items);
}

test "multicursor: addNextMatch respects word boundaries and case" {
    // "abc" at 0, 9, 17; "abcd" at 4 and "Abc" at 13 must be skipped.
    var pt = try PieceTable.init(testing.allocator, "abc abcd abc Abc abc");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(0);
    try testing.expect(try mc.addNextMatch(&pt)); // skips "abcd", -> 9
    try testing.expectEqualSlices(u32, &.{ 0, 9 }, mc.cursors.items);
    try testing.expect(try mc.addNextMatch(&pt)); // skips "Abc", -> 17
    try testing.expectEqualSlices(u32, &.{ 0, 9, 17 }, mc.cursors.items);
    try testing.expect(!try mc.addNextMatch(&pt));
}

test "multicursor: addNextMatch fails when no word or a cursor drifted" {
    var pt = try PieceTable.init(testing.allocator, "foo bar");
    defer pt.deinit();

    // main cursor on whitespace
    var mc1 = MultiCursor.init(testing.allocator);
    defer mc1.deinit();
    _ = try mc1.add(3); // the space
    try testing.expect(!try mc1.addNextMatch(&pt));

    // a non-main cursor is no longer on the main word (e.g. edited text)
    var mc2 = MultiCursor.init(testing.allocator);
    defer mc2.deinit();
    _ = try mc2.add(0); // "foo"
    _ = try mc2.add(5); // inside "bar" — a different word
    try testing.expect(!try mc2.addNextMatch(&pt));

    // no cursors at all
    var mc3 = MultiCursor.init(testing.allocator);
    defer mc3.deinit();
    try testing.expect(!try mc3.addNextMatch(&pt));

    // main cursor at the end of the document
    var mc4 = MultiCursor.init(testing.allocator);
    defer mc4.deinit();
    _ = try mc4.add(7); // doc end
    try testing.expect(!try mc4.addNextMatch(&pt));
}

test "multicursor: applyInsert inserts at every cursor and moves them" {
    var pt = try PieceTable.init(testing.allocator, "abc");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(0);
    _ = try mc.add(1);
    _ = try mc.add(2);
    try testing.expectEqual(@as(usize, 3), try mc.applyInsert(&pt, "Z"));
    const out = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ZaZbZc", out);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, mc.cursors.items);
}

test "multicursor: applyInsert with multibyte text shifts by bytes" {
    var pt = try PieceTable.init(testing.allocator, "x y");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(1); // before 'y'
    _ = try mc.add(3); // end of document
    try testing.expectEqual(@as(usize, 2), try mc.applyInsert(&pt, "中")); // 3 bytes
    const out = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x中 y中", out);
    try testing.expectEqualSlices(u32, &.{ 4, 9 }, mc.cursors.items);
}

test "multicursor: applyDelete removes del_len bytes before every cursor" {
    var pt = try PieceTable.init(testing.allocator, "aXbXcX");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(2);
    _ = try mc.add(4);
    _ = try mc.add(6);
    try testing.expectEqual(@as(usize, 3), try mc.applyDelete(&pt, 1));
    const out = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc", out);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, mc.cursors.items);
}

test "multicursor: applyDelete clamps when fewer bytes than del_len are available" {
    var pt = try PieceTable.init(testing.allocator, "ab");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(2);
    try testing.expectEqual(@as(usize, 1), try mc.applyDelete(&pt, 5)); // deletes [0,2)
    const out = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
    try testing.expectEqualSlices(u32, &.{0}, mc.cursors.items);

    // a cursor at 0 has nothing before it: no edit
    var pt2 = try PieceTable.init(testing.allocator, "ab");
    defer pt2.deinit();
    var mc2 = MultiCursor.init(testing.allocator);
    defer mc2.deinit();
    _ = try mc2.add(0);
    try testing.expectEqual(@as(usize, 0), try mc2.applyDelete(&pt2, 1));
}

test "multicursor: insert then delete restores content and cursor positions" {
    var pt = try PieceTable.init(testing.allocator, "a\nb\nc");
    defer pt.deinit();
    var mc = MultiCursor.init(testing.allocator);
    defer mc.deinit();
    _ = try mc.add(1);
    _ = try mc.add(3);
    _ = try mc.add(5); // end of document

    _ = try mc.applyInsert(&pt, "X"); // "aX\nbX\ncX", cursors [2,5,8]
    const out = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aX\nbX\ncX", out);
    try testing.expectEqualSlices(u32, &.{ 2, 5, 8 }, mc.cursors.items);

    _ = try mc.applyDelete(&pt, 1); // back to "a\nb\nc", cursors [1,3,5]
    const out2 = try docBytes(&pt, testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("a\nb\nc", out2);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, mc.cursors.items);
}
