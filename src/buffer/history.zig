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

pub const UndoKind = enum { undo, redo };

/// Result of one undo/redo transaction. All positions are byte offsets in the
/// document AFTER the operation (so they can be installed directly), except
/// `revision`, which is the history revision after the operation.
///
///   anchor        suggested cursor: change start for undo, change end for
///                 redo. Callers clamp to a UTF-8 boundary / line end.
///   change_start  union start of every restored/removed span
///   change_end    union end (exclusive)
///
/// Empty stacks return `changed = false` with `revision` unchanged: callers
/// must not mark the buffer dirty or invalidate LSP state in that case.
pub const UndoResult = struct {
    changed: bool = false,
    kind: UndoKind = .undo,
    anchor: u32 = 0,
    change_start: u32 = 0,
    change_end: u32 = 0,
    revision: u64 = 0,
};

/// Transform one coordinate through a replace transaction that removes
/// `old_len` bytes at `pos` and inserts `new_len` bytes. Coordinates inside
/// the removed span collapse to its start; `is_end` selects the collapse
/// point for a range end (start of the replacement for a start anchor, end
/// of the replacement for an end anchor).
fn transformPos(pos: u32, old_len: u32, new_len: u32, at: u32, is_end: bool) u32 {
    const old_end = pos + old_len;
    const delta = @as(i64, new_len) - @as(i64, old_len);
    if (at >= old_end) {
        const moved = @as(i64, at) + delta;
        return if (moved < 0) 0 else @intCast(moved);
    }
    if (at >= pos) return if (is_end) pos + new_len else pos;
    return at;
}

/// Merge the changed span of one applied edit into the running union.
fn unionSpan(start: *u32, end: *u32, has: *bool, pos: u32, old_len: u32, new_len: u32) void {
    const new_start = transformPos(pos, old_len, new_len, start.*, false);
    const new_end = transformPos(pos, old_len, new_len, end.*, true);
    if (!has.*) {
        start.* = pos;
        end.* = pos + new_len;
        has.* = true;
        return;
    }
    start.* = @min(new_start, pos);
    end.* = @max(new_end, pos + new_len);
}

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

        // Both the edit and its eventual group commit must fit before the
        // document changes. Empty groups don't need an undo slot.
        try self.open.?.edits.ensureUnusedCapacity(self.allocator, 1);
        if (self.open.?.edits.items.len == 0)
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);

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

        self.undo_stack.appendAssumeCapacity(g);

        // New branch: any redo history is now invalid.
        for (self.redo_stack.items) |*r| r.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Undo the top group and report the transaction span/cursor anchor.
    /// Applies inverse edits in reverse order. An empty stack returns
    /// `changed = false` and leaves the revision untouched.
    pub fn undoResult(self: *History, pt: *PieceTable) UndoResult {
        const g = self.undo_stack.pop() orelse return .{
            .changed = false,
            .kind = .undo,
            .revision = self.revision,
        };
        var start: u32 = 0;
        var end: u32 = 0;
        var has = false;
        var i = g.edits.items.len;
        while (i > 0) {
            i -= 1;
            const e = g.edits.items[i];
            // This step removes `after` and restores `before` at e.pos.
            unionSpan(&start, &end, &has, e.pos, @intCast(e.after.len), @intCast(e.before.len));
            _ = pt.replace(e.pos, @intCast(e.after.len), e.before) catch unreachable;
        }
        self.redo_stack.append(self.allocator, g) catch unreachable;
        self.revision += 1;
        self.last_record = null; // undo has no single-edit description
        if (!has) {
            start = 0;
            end = 0;
        }
        return .{
            .changed = true,
            .kind = .undo,
            .anchor = start,
            .change_start = start,
            .change_end = end,
            .revision = self.revision,
        };
    }

    /// Undo the top group; applies inverse edits in reverse order.
    /// Returns false when the undo stack is empty.
    pub fn undo(self: *History, pt: *PieceTable) bool {
        return self.undoResult(pt).changed;
    }

    /// Redo the top redo group and report the transaction span/cursor anchor.
    /// An empty stack returns `changed = false` and leaves the revision
    /// untouched.
    pub fn redoResult(self: *History, pt: *PieceTable) UndoResult {
        const g = self.redo_stack.pop() orelse return .{
            .changed = false,
            .kind = .redo,
            .revision = self.revision,
        };
        var start: u32 = 0;
        var end: u32 = 0;
        var has = false;
        for (g.edits.items) |e| {
            // This step removes `before` and re-inserts `after` at e.pos.
            unionSpan(&start, &end, &has, e.pos, @intCast(e.before.len), @intCast(e.after.len));
            _ = pt.replace(e.pos, @intCast(e.before.len), e.after) catch unreachable;
        }
        self.undo_stack.append(self.allocator, g) catch unreachable;
        self.revision += 1;
        self.last_record = null;
        if (!has) {
            start = 0;
            end = 0;
        }
        return .{
            .changed = true,
            .kind = .redo,
            // Redo lands after the re-inserted text, like vim's Ctrl-R.
            .anchor = end,
            .change_start = start,
            .change_end = end,
            .revision = self.revision,
        };
    }

    /// Redo the top redo group. Returns false when empty.
    pub fn redo(self: *History, pt: *PieceTable) bool {
        return self.redoResult(pt).changed;
    }

    pub fn canUndo(self: *const History) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Borrow the group that `undoResult` would apply. Used by the inlay-hint
    /// transform, which must map anchors through the SAME edits before the
    /// document changes. Valid until the next History mutation.
    pub fn topUndoGroup(self: *const History) ?*const Group {
        const n = self.undo_stack.items.len;
        return if (n == 0) null else &self.undo_stack.items[n - 1];
    }

    /// Borrow the group that `redoResult` would replay.
    pub fn topRedoGroup(self: *const History) ?*const Group {
        const n = self.redo_stack.items.len;
        return if (n == 0) null else &self.redo_stack.items[n - 1];
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

fn checkRecordFailure(allocator: std.mem.Allocator) !void {
    var pt = try PieceTable.init(std.testing.allocator, "abc");
    defer pt.deinit();
    var hist = History.init(allocator);
    defer hist.deinit();
    hist.record(&pt, 0, 1, "Z") catch |err| {
        try expectDoc(&pt, std.testing.allocator, "abc");
        try std.testing.expect(hist.open == null and !hist.canUndo() and hist.last_record == null);
        try std.testing.expectEqual(@as(u64, 0), hist.revision);
        return err;
    };
    try expectDoc(&pt, std.testing.allocator, "Zbc");
    try std.testing.expect(hist.canUndo());
}

test "history: failure reserving an auto group's undo slot leaves the document untouched" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRecordFailure, .{});
}

test "history: an explicit group can commit with all further allocations disabled" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var hist = History.init(failing.allocator());
    defer hist.deinit();
    var pt = try PieceTable.init(std.testing.allocator, "abc");
    defer pt.deinit();
    hist.beginGroup();
    try hist.record(&pt, 0, 1, "Z");
    try hist.record(&pt, 1, 1, "Y");
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    hist.endGroup();
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expect(hist.undo(&pt));
    try expectDoc(&pt, std.testing.allocator, "abc");
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

// ---- UndoResult transaction contract (issue 7) ----------------------------

test "undoResult: single insert reports changed span and start anchor" {
    var pt = try PieceTable.init(std.testing.allocator, "hello world");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    const rev_before = hist.revision;
    try hist.record(&pt, 5, 0, " cruel");
    const res = hist.undoResult(&pt);
    try std.testing.expect(res.changed);
    try std.testing.expectEqual(UndoKind.undo, res.kind);
    try std.testing.expectEqual(@as(u32, 5), res.anchor);
    try std.testing.expectEqual(@as(u32, 5), res.change_start);
    try std.testing.expectEqual(@as(u32, 5), res.change_end);
    try std.testing.expectEqual(rev_before + 2, res.revision);
    try std.testing.expectEqual(rev_before + 2, hist.revision);
    try expectDoc(&pt, std.testing.allocator, "hello world");

    const redo = hist.redoResult(&pt);
    try std.testing.expect(redo.changed);
    try std.testing.expectEqual(UndoKind.redo, redo.kind);
    try std.testing.expectEqual(@as(u32, 11), redo.anchor);
    try std.testing.expectEqual(@as(u32, 5), redo.change_start);
    try std.testing.expectEqual(@as(u32, 11), redo.change_end);
    try expectDoc(&pt, std.testing.allocator, "hello cruel world");
}

test "undoResult: empty stacks do not change the revision and keep the anchor" {
    var pt = try PieceTable.init(std.testing.allocator, "abc");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    const u = hist.undoResult(&pt);
    try std.testing.expect(!u.changed);
    try std.testing.expectEqual(@as(u64, 0), u.revision);
    try std.testing.expectEqual(@as(u32, 0), u.anchor);
    const r = hist.redoResult(&pt);
    try std.testing.expect(!r.changed);
    try std.testing.expectEqual(@as(u64, 0), r.revision);
    try expectDoc(&pt, std.testing.allocator, "abc");
}

test "undoResult: multi-edit group reports the union in the post-op document" {
    var pt = try PieceTable.init(std.testing.allocator, "abcd");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.beginGroup();
    try hist.record(&pt, 1, 0, "X"); // aXbcd
    try hist.record(&pt, 3, 0, "Y"); // aXbYcd
    hist.endGroup();
    try expectDoc(&pt, std.testing.allocator, "aXbYcd");

    const res = hist.undoResult(&pt);
    try std.testing.expect(res.changed);
    try expectDoc(&pt, std.testing.allocator, "abcd");
    // Touched region spans from the first restore point through the shifted
    // second one; both endpoints lie on the final document.
    try std.testing.expectEqual(@as(u32, 1), res.anchor);
    try std.testing.expectEqual(@as(u32, 1), res.change_start);
    try std.testing.expectEqual(@as(u32, 2), res.change_end);
    try std.testing.expect(res.change_start <= res.change_end);
    try std.testing.expect(res.change_end <= pt.len());

    const redo = hist.redoResult(&pt);
    try std.testing.expect(redo.changed);
    try expectDoc(&pt, std.testing.allocator, "aXbYcd");
    try std.testing.expectEqual(@as(u32, 4), redo.anchor);
    try std.testing.expectEqual(@as(u32, 1), redo.change_start);
    try std.testing.expectEqual(@as(u32, 4), redo.change_end);
    try std.testing.expect(redo.change_end <= pt.len());
}

test "undoResult: deletion undo anchor is the restore start; redo anchor its end" {
    var pt = try PieceTable.init(std.testing.allocator, "one two three");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    try hist.record(&pt, 4, 3, ""); // delete "two" -> "one  three"
    try expectDoc(&pt, std.testing.allocator, "one  three");

    const undo = hist.undoResult(&pt);
    try std.testing.expect(undo.changed);
    try std.testing.expectEqual(@as(u32, 4), undo.anchor);
    try std.testing.expectEqual(@as(u32, 4), undo.change_start);
    try std.testing.expectEqual(@as(u32, 7), undo.change_end);
    try expectDoc(&pt, std.testing.allocator, "one two three");

    const redo = hist.redoResult(&pt);
    try std.testing.expect(redo.changed);
    try std.testing.expectEqual(@as(u32, 4), redo.anchor);
    try std.testing.expectEqual(@as(u32, 4), redo.change_start);
    try std.testing.expectEqual(@as(u32, 4), redo.change_end);
    try expectDoc(&pt, std.testing.allocator, "one  three");
}

test "undoResult: UTF-8 bytes stay whole and anchors are byte offsets" {
    var pt = try PieceTable.init(std.testing.allocator, "a中b");
    defer pt.deinit();
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    // Insert an emoji (4 bytes) after 中: "a中🙂b".
    try hist.record(&pt, 4, 0, "🙂");
    const undo = hist.undoResult(&pt);
    try std.testing.expectEqual(@as(u32, 4), undo.anchor);
    try std.testing.expectEqual(@as(u32, 4), undo.change_end);
    try expectDoc(&pt, std.testing.allocator, "a中b");
    const redo = hist.redoResult(&pt);
    try std.testing.expectEqual(@as(u32, 8), redo.anchor);
    try std.testing.expectEqual(@as(u32, 8), redo.change_end);
    try expectDoc(&pt, std.testing.allocator, "a中🙂b");
}
