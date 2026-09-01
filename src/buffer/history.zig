//! Undo/redo history: linear stacks of edit groups, byte-copied edits.
//! DESIGN.md §4.3. Depends on PieceTable for document access.
const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;

/// One reversible edit. `before`/`after` bytes are owned by the History
/// (allocated copies) — safe to hold across document edits.
pub const Edit = struct {
    pos: u32,
    before: []u8,
    after: []u8,
};

pub const Group = struct {
    edits: std.ArrayList(Edit),

    pub fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        for (self.edits.items) |e| {
            allocator.free(e.before);
            allocator.free(e.after);
        }
        self.edits.deinit(allocator);
    }
};

/// Piece-list compaction cadence: every this many recorded edits the piece
/// table merges adjacent pieces, keeping byteAt/copyRange scans bounded.
const compact_interval = 64;

pub const History = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(Group),
    redo_stack: std.ArrayList(Group),
    /// non-null while a group is open (between beginGroup/endGroup)
    open: ?Group,
    /// Monotonic counter bumped on every document mutation (record/undo/
    /// redo). Syntax highlighting polls it to detect text changes between
    /// parses.
    revision: u64 = 0,
    /// The most recent edit applied via `record` (null after undo/redo — the
    /// change then has no single-edit description). The stored value shares
    /// `before`/`after` with the group's Edit entries (History owns them).
    last_record: ?Edit = null,
    /// Edit counter driving periodic piece-table compaction (see `record`).
    edits_since_compact: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .allocator = allocator,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .open = null,
        };
    }

    pub fn deinit(self: *History) void {
        // Free every owned group: undo stack, redo stack, and any still-open
        // group (a group left open by the caller is still ours to free).
        for (self.undo_stack.items) |*g| g.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*g| g.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        if (self.open) |*g| g.deinit(self.allocator);
    }

    /// Start a new undo group (start of a user operation). If a group is
    /// already open it is left alone (nested begin is a no-op).
    pub fn beginGroup(self: *History) void {
        if (self.open == null) self.open = .{ .edits = .empty };
    }

    /// Record one edit and apply it to the document. `before_len` bytes are
    /// read from the piece table at `pos` (the pre-edit state), then the edit
    /// is applied with `pt.replace(pos, before_len, after)` and the resulting
    /// (before, after) pair is stored in the current group. Callers invoke
    /// only `record` — never `pt.replace` separately. If no group is open,
    /// opens and immediately closes one (so the edit is still undoable).
    pub fn record(self: *History, pt: *PieceTable, pos: u32, before_len: u32, after: []const u8) !void {
        // With no open group, wrap this single edit in an auto-opened group so
        // it remains undoable as one unit (and becomes a new branch). Any error
        // below closes it again (it is empty and will be dropped).
        const auto_group = (self.open == null);
        if (auto_group) self.beginGroup();
        errdefer if (auto_group) self.endGroup();

        // Snapshot the deleted bytes from the current (pre-edit) document
        // state — the range [pos, pos+before_len) is guaranteed to fit.
        const before = try self.allocator.alloc(u8, before_len);
        errdefer self.allocator.free(before);
        if (before_len > 0) pt.copyRange(pos, before);

        // `after` may reference the piece table's add buffer, which later
        // edits/compaction can invalidate — copy it now (History owns bytes).
        const after_copy = try self.allocator.dupe(u8, after);
        errdefer self.allocator.free(after_copy);

        // Reserve the slot up front so the append below cannot fail: record
        // either applies the edit AND stores it, or fails with the document
        // untouched (pt.replace is atomic on failure).
        try self.open.?.edits.ensureUnusedCapacity(self.allocator, 1);

        // Apply the edit to the document (this is the only mutation).
        _ = try pt.replace(pos, before_len, after);

        // Cannot fail: capacity was ensured above.
        self.open.?.edits.appendAssumeCapacity(.{
            .pos = pos,
            .before = before,
            .after = after_copy,
        });
        self.last_record = .{ .pos = pos, .before = before, .after = after_copy };
        self.revision += 1;

        // Bound piece-list growth from long edit streams: merge adjacent
        // pieces every so often. Content-neutral — document bytes, the line
        // index, and History-owned copies are all unaffected by compaction.
        self.edits_since_compact += 1;
        if (self.edits_since_compact >= compact_interval) {
            self.edits_since_compact = 0;
            pt.compact();
        }

        if (auto_group) self.endGroup();
    }

    /// Finish the current group and push it onto the undo stack.
    /// Clears the redo stack (new branch). Empty groups are dropped.
    pub fn endGroup(self: *History) void {
        var g = self.open orelse return;
        self.open = null;

        // A group with no edits is a no-op user action: discard it and leave
        // the redo branch untouched (no new branch was created).
        if (g.edits.items.len == 0) {
            g.deinit(self.allocator);
            return;
        }

        // Pushing can only fail on OOM. Dropping the group loses history but
        // leaks nothing; the editor treats OOM as fatal anyway (see
        // piece_table.zig), so this path is effectively unreachable.
        self.undo_stack.append(self.allocator, g) catch {
            g.deinit(self.allocator);
            return;
        };

        // New branch: any redo history is now invalid.
        for (self.redo_stack.items) |*r| r.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Undo the top group; applies inverse edits in reverse order.
    /// Returns false when the undo stack is empty.
    pub fn undo(self: *History, pt: *PieceTable) bool {
        const g = self.undo_stack.pop() orelse return false;
        // Apply the inverse of each edit (replace back the `before` bytes),
        // in reverse recording order.
        var i = g.edits.items.len;
        while (i > 0) {
            i -= 1;
            const e = g.edits.items[i];
            // The API has no error channel and the doc must stay consistent;
            // a failing replace mid-group is unrecoverable — OOM is fatal in
            // this codebase (see piece_table.zig's `catch unreachable`).
            _ = pt.replace(e.pos, @intCast(e.after.len), e.before) catch unreachable;
        }
        self.redo_stack.append(self.allocator, g) catch unreachable;
        self.revision += 1;
        self.last_record = null; // undo has no single-edit description
        return true;
    }

    /// Redo the top redo group. Returns false when empty.
    pub fn redo(self: *History, pt: *PieceTable) bool {
        const g = self.redo_stack.pop() orelse return false;
        // Replay the edits in forward order (replace back the `after` bytes).
        for (g.edits.items) |e| {
            _ = pt.replace(e.pos, @intCast(e.before.len), e.after) catch unreachable;
        }
        self.undo_stack.append(self.allocator, g) catch unreachable;
        self.revision += 1;
        self.last_record = null;
        return true;
    }

    pub fn canUndo(self: *const History) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.redo_stack.items.len > 0;
    }
};

// =============================== tests ======================================

/// Compare the piece table's whole content against an expected string.
fn expectDoc(pt: *PieceTable, allocator: std.mem.Allocator, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), pt.len());
    const buf = try allocator.alloc(u8, expected.len);
    defer allocator.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualSlices(u8, expected, buf);
}

/// Compare the piece table's content against a mirror ArrayList(u8).
fn expectMirror(pt: *PieceTable, mirror_doc: *const std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(u32, @intCast(mirror_doc.items.len)), pt.len());
    const buf = try allocator.alloc(u8, mirror_doc.items.len);
    defer allocator.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualSlices(u8, mirror_doc.items, buf);
}

fn randomBytes(rng: std.Random, allocator: std.mem.Allocator, alphabet: []const u8) ![]u8 {
    const len = rng.uintLessThan(usize, 8); // 0..7 bytes, sometimes empty
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
    return buf;
}

test "single edit: record → undo → redo round-trip" {
    var pt = try PieceTable.init(std.testing.allocator, "hello world");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    // record without an explicit group auto-opens/closes one; it snapshots
    // `before` from the pre-edit document and applies the edit itself.
    try hist.record(&pt, 5, 0, " cruel");
    try expectDoc(&pt, std.testing.allocator, "hello cruel world");
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(!hist.canRedo());

    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello world");
    try std.testing.expect(!hist.canUndo());
    try std.testing.expect(hist.canRedo());

    try std.testing.expect(hist.redo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello cruel world");
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(!hist.canRedo());

    // deletion round-trip: before bytes are snapshotted by record()
    try hist.record(&pt, 5, 6, ""); // delete "cruel" (applied by record)
    try expectDoc(&pt, std.testing.allocator, "hello world");
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello cruel world");
    try std.testing.expect(hist.redo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello world");
}

test "group: multiple edits undo/redo atomically" {
    var pt = try PieceTable.init(std.testing.allocator, "abcd");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.beginGroup();
    try hist.record(&pt, 0, 0, ">"); // ">abcd"
    try hist.record(&pt, 5, 0, "<"); // ">abcd<"
    try hist.record(&pt, 2, 2, ""); // delete "bc" -> ">ad<"
    hist.endGroup();
    try expectDoc(&pt, std.testing.allocator, ">ad<");
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(!hist.canRedo());

    // one undo reverts all three edits at once
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "abcd");
    try std.testing.expect(!hist.canUndo());
    try std.testing.expect(hist.canRedo());

    // one redo replays all three
    try std.testing.expect(hist.redo(&pt));
    try expectDoc(&pt, std.testing.allocator, ">ad<");
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(!hist.canRedo());

    // nested beginGroup is a no-op: one group, undone in one step
    hist.beginGroup();
    hist.beginGroup();
    try hist.record(&pt, 4, 0, "!"); // ">ad<!"
    hist.endGroup();
    hist.endGroup(); // second end with no open group: no-op
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, ">ad<");
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "abcd");
    try std.testing.expect(!hist.canUndo());
}

test "branch semantics: new edit after undo clears redo" {
    var pt = try PieceTable.init(std.testing.allocator, "base");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    try hist.record(&pt, 4, 0, "!"); // "base!"
    try hist.record(&pt, 4, 0, "?"); // "base!?" (two auto groups)
    try std.testing.expect(!hist.canRedo());

    try std.testing.expect(hist.undo(&pt)); // "base!"
    try std.testing.expect(hist.undo(&pt)); // "base"
    try std.testing.expect(!hist.canUndo());
    try std.testing.expect(hist.canRedo());

    // editing at the branch point must invalidate the redo branch
    try hist.record(&pt, 4, 0, "X"); // "baseX"
    try expectDoc(&pt, std.testing.allocator, "baseX");
    try std.testing.expect(!hist.canRedo());
    try std.testing.expect(hist.canUndo());

    // undo goes to "base" (the branch point), not back to "base!" — the old
    // branch (G1/G2) is gone from the undo stack, so only the new edit's group
    // is undoable, and it becomes redoable again.
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "base");
    try std.testing.expect(hist.canRedo());
    try std.testing.expect(!hist.canUndo()); // old branch is not reachable

    // the cleared branch never comes back: redo only replays the new edit
    try std.testing.expect(hist.redo(&pt));
    try expectDoc(&pt, std.testing.allocator, "baseX");
    try std.testing.expect(!hist.canRedo());
}

test "empty group dropped; undo/redo on empty history return false" {
    var pt = try PieceTable.init(std.testing.allocator, "hello");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    // nothing recorded yet
    try std.testing.expect(!hist.canUndo());
    try std.testing.expect(!hist.canRedo());
    try std.testing.expect(!hist.undo(&pt));
    try std.testing.expect(!hist.redo(&pt));

    // begin+end with no edits: dropped, no new branch, still nothing to undo
    hist.beginGroup();
    hist.endGroup();
    try std.testing.expect(!hist.canUndo());
    try std.testing.expect(!hist.undo(&pt));

    // an edit, then a dropped empty group, then undo: the empty group must not
    // have disturbed the history (it neither adds nor clears).
    try hist.record(&pt, 5, 0, "!");
    try expectDoc(&pt, std.testing.allocator, "hello!");
    try std.testing.expect(hist.canUndo());
    hist.beginGroup();
    hist.endGroup();
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello");
    try std.testing.expect(!hist.canUndo());

    // undo/redo across multiple auto groups
    try hist.record(&pt, 5, 0, "!");
    try hist.record(&pt, 6, 0, "?");
    try expectDoc(&pt, std.testing.allocator, "hello!?");
    try std.testing.expect(hist.undo(&pt));
    try std.testing.expect(hist.undo(&pt));
    try std.testing.expect(!hist.undo(&pt));
    try std.testing.expect(hist.redo(&pt));
    try std.testing.expect(hist.redo(&pt));
    try std.testing.expect(!hist.redo(&pt));
    try expectDoc(&pt, std.testing.allocator, "hello!?");
}

test "record periodically compacts the piece list" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "");
    defer pt.deinit();
    var hist = History.init(alloc);
    defer hist.deinit();

    // 3x the compact interval of single-byte appends: without compaction the
    // piece list would hold one piece per edit.
    var i: usize = 0;
    while (i < 3 * compact_interval) : (i += 1) {
        try hist.record(&pt, pt.len(), 0, "x");
    }
    const expected = try alloc.alloc(u8, 3 * compact_interval);
    defer alloc.free(expected);
    @memset(expected, 'x');
    try expectDoc(&pt, alloc, expected);
    try std.testing.expect(pt.pieces.items.len <= compact_interval + 2);

    // Undo/redo still work across the compacted piece list.
    while (hist.undo(&pt)) {}
    try expectDoc(&pt, alloc, "");
    while (hist.redo(&pt)) {}
    try expectDoc(&pt, alloc, expected);
}

/// Independent naive model of the History semantics, built directly on
/// ArrayList(u8)/byte copies — used to cross-check History + PieceTable.
const MirrorEdit = struct {
    pos: usize,
    before: []u8,
    after: []u8,
};

const MirrorGroup = std.ArrayList(MirrorEdit);

fn mirrorGroupDeinit(g: *MirrorGroup, allocator: std.mem.Allocator) void {
    for (g.items) |e| {
        allocator.free(e.before);
        allocator.free(e.after);
    }
    g.deinit(allocator);
}

const Mirror = struct {
    alloc: std.mem.Allocator,
    doc: std.ArrayList(u8),
    undo: std.ArrayList(MirrorGroup),
    redo: std.ArrayList(MirrorGroup),
    open: ?MirrorGroup,

    fn init(allocator: std.mem.Allocator, initial: []const u8) !Mirror {
        var self = Mirror{
            .alloc = allocator,
            .doc = .empty,
            .undo = .empty,
            .redo = .empty,
            .open = null,
        };
        errdefer self.deinit();
        try self.doc.appendSlice(allocator, initial);
        return self;
    }

    fn deinit(self: *Mirror) void {
        self.doc.deinit(self.alloc);
        for (self.undo.items) |*g| mirrorGroupDeinit(g, self.alloc);
        self.undo.deinit(self.alloc);
        for (self.redo.items) |*g| mirrorGroupDeinit(g, self.alloc);
        self.redo.deinit(self.alloc);
        if (self.open) |*g| mirrorGroupDeinit(g, self.alloc);
    }

    fn beginGroup(self: *Mirror) void {
        if (self.open == null) self.open = .empty;
    }

    fn endGroup(self: *Mirror) void {
        var g = self.open orelse return;
        self.open = null;
        if (g.items.len == 0) {
            mirrorGroupDeinit(&g, self.alloc);
            return;
        }
        self.undo.append(self.alloc, g) catch unreachable;
        for (self.redo.items) |*r| mirrorGroupDeinit(r, self.alloc);
        self.redo.clearRetainingCapacity();
    }

    fn record(self: *Mirror, pos: usize, before_len: usize, after: []const u8) !void {
        const auto = (self.open == null);
        if (auto) self.beginGroup();
        const before = try self.alloc.dupe(u8, self.doc.items[pos .. pos + before_len]);
        errdefer self.alloc.free(before);
        const after_copy = try self.alloc.dupe(u8, after);
        errdefer self.alloc.free(after_copy);
        self.open.?.append(self.alloc, .{ .pos = pos, .before = before, .after = after_copy }) catch |err| {
            if (auto) self.endGroup();
            return err;
        };
        if (auto) self.endGroup();
    }

    fn undoStep(self: *Mirror) bool {
        const g = self.undo.pop() orelse return false;
        var i = g.items.len;
        while (i > 0) {
            i -= 1;
            const e = g.items[i];
            self.doc.replaceRange(self.alloc, e.pos, e.after.len, e.before) catch unreachable;
        }
        self.redo.append(self.alloc, g) catch unreachable;
        return true;
    }

    fn redoStep(self: *Mirror) bool {
        const g = self.redo.pop() orelse return false;
        for (g.items) |e| {
            self.doc.replaceRange(self.alloc, e.pos, e.before.len, e.after) catch unreachable;
        }
        self.undo.append(self.alloc, g) catch unreachable;
        return true;
    }
};

test "random ops: mirror-consistent undo/redo (fixed seed)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xABCD_1234);
    const rng = prng.random();

    const initial = "alpha\nbeta\ngamma\n";
    var pt = try PieceTable.init(alloc, initial);
    defer pt.deinit();
    var hist = History.init(alloc);
    defer hist.deinit();
    var mirror = try Mirror.init(alloc, initial);
    defer mirror.deinit();

    // Alphabet includes '\n' so inserts exercise the line index too.
    const alphabet = "abcxyz \n\t09";

    var step: usize = 0;
    while (step < 400) : (step += 1) {
        const op = rng.uintLessThan(u8, 10);
        switch (op) {
            0...3 => { // insert
                const pos = rng.uintLessThan(usize, mirror.doc.items.len + 1);
                const s = try randomBytes(rng, alloc, alphabet);
                defer alloc.free(s);
                // record() snapshots `before` from the pre-edit document and
                // applies the edit itself.
                try hist.record(&pt, @intCast(pos), 0, s);
                try mirror.record(pos, 0, s);
                mirror.doc.insertSlice(alloc, pos, s) catch unreachable;
            },
            4...6 => { // delete
                const pos = rng.uintLessThan(usize, mirror.doc.items.len + 1);
                const del = rng.uintLessThan(usize, mirror.doc.items.len - pos + 1);
                try hist.record(&pt, @intCast(pos), @intCast(del), "");
                try mirror.record(pos, del, "");
                mirror.doc.replaceRange(alloc, pos, del, "") catch unreachable;
            },
            7 => { // begin group
                hist.beginGroup();
                mirror.beginGroup();
            },
            8 => { // end group
                hist.endGroup();
                mirror.endGroup();
            },
            else => { // 9: undo or redo (mirror must agree on return value)
                // Usage rule (vim behaves the same): never undo/redo while a
                // group is open — edit positions inside an open group are
                // relative to the document evolving through that group alone.
                // Close any open group first on both sides.
                hist.endGroup();
                mirror.endGroup();
                if (rng.boolean()) {
                    const real = hist.undo(&pt);
                    try std.testing.expectEqual(mirror.undoStep(), real);
                } else {
                    const real = hist.redo(&pt);
                    try std.testing.expectEqual(mirror.redoStep(), real);
                }
            },
        }
        try expectMirror(&pt, &mirror.doc, alloc);
        try std.testing.expectEqual(mirror.undo.items.len > 0, hist.canUndo());
        try std.testing.expectEqual(mirror.redo.items.len > 0, hist.canRedo());
        // Periodic compaction must not disturb history (content unchanged).
        if (step % 60 == 59) pt.compact();
    }

    // Close any still-open group on both sides before the round-trip.
    hist.endGroup();
    mirror.endGroup();

    // Capture the "latest" content (state just before the undo-all phase).
    const final_doc = try alloc.dupe(u8, mirror.doc.items);
    defer alloc.free(final_doc);
    try expectMirror(&pt, &mirror.doc, alloc);

    // Undo everything -> back to the initial content.
    var undo_count: usize = 0;
    while (hist.undo(&pt)) : (undo_count += 1) {
        try std.testing.expectEqual(true, mirror.undoStep());
        try expectMirror(&pt, &mirror.doc, alloc);
    }
    try std.testing.expectEqual(false, mirror.undoStep());
    try std.testing.expect(undo_count > 0);
    try expectMirror(&pt, &mirror.doc, alloc);
    const buf = try alloc.alloc(u8, initial.len);
    defer alloc.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualSlices(u8, initial, buf);
    try std.testing.expectEqualSlices(u8, initial, mirror.doc.items);

    // Redo everything -> back to the latest content.
    var redo_count: usize = 0;
    while (hist.redo(&pt)) : (redo_count += 1) {
        try std.testing.expectEqual(true, mirror.redoStep());
        try expectMirror(&pt, &mirror.doc, alloc);
    }
    try std.testing.expectEqual(false, mirror.redoStep());
    try std.testing.expect(redo_count > 0);
    try expectMirror(&pt, &mirror.doc, alloc);
    const final_check = try alloc.alloc(u8, final_doc.len);
    defer alloc.free(final_check);
    pt.copyRange(0, final_check);
    try std.testing.expectEqualSlices(u8, final_doc, final_check);
}
