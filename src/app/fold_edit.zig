//! Fold-state bookkeeping for every text-edit entry point.
//!
//! Closed folds are per-buffer editorial state (App.Buffer.folds). They used
//! to be dropped wholesale on every edit because line numbers drift; the
//! state now carries an explicit anchor + header signature and is transformed
//! through each edit (see editor/fold.zig):
//!
//! - `recordEdit` / `recordEditBuffer` wrap EVERY `History.record` call, so
//!   normal-mode operators, paste, substitute, completion, block insert,
//!   multi-cursor edits, LSP/agent incremental edits and undo/redo all pass
//!   through one transform.
//! - `historyApply` runs the transform against a scratch copy of the document
//!   in the same order the history transaction applies its edits, so
//!   multi-edit groups are handled with the exact intermediate line structure.
//! - a WHOLE-document replacement (agent patch / LSP workspace edit / whole
//!   `:%s`) has no meaningful byte anchors, so folds are re-matched by header
//!   text instead (`reanchorAfterDirectReplace` covers the direct-replace
//!   path that bypasses History).
//!
//! The transform never clears folds for an unrelated edit: a fold is dropped
//! only when its header/structure really disappeared or its body no longer
//! opens one.
const std = @import("std");
const buffer = @import("../buffer/root.zig");
const history_mod = @import("../buffer/history.zig");
const fold = @import("../editor/fold.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

/// Record one edit against the current buffer (the common entry point).
pub fn recordEdit(self: *App, pos: u32, before_len: u32, after: []const u8) !void {
    try recordEditBuffer(self, self.cur(), pos, before_len, after);
}

/// Record one edit against `buf`: apply it to the history and transform the
/// buffer's closed folds through exactly that edit.
pub fn recordEditBuffer(self: *App, buf: *App.Buffer, pos: u32, before_len: u32, after: []const u8) !void {
    // No closed folds → no state to carry; skip the pre-edit newline scan
    // (this is the overwhelmingly common case for typing and large pastes).
    const pre_len = buf.pt.len();
    const inserted: u32 = @intCast(after.len);
    const fold_span: ?fold.EditSpan = if (buf.folds.items.len == 0) null else .{
        .pos = pos,
        .removed = before_len,
        .inserted = inserted,
        // Removed-byte newline count must be taken BEFORE the edit is applied.
        .removed_newlines = fold.newlinesIn(&buf.pt, pos, before_len),
        .inserted_newlines = fold.countNewlines(after),
    };
    try buf.history.record(&buf.pt, pos, before_len, after);
    buf.search_index.afterEdit(&buf.pt, buf.history.revision, pos, pos + before_len, pos + inserted);
    const span = fold_span orelse return;
    if (fold.isWholeDocument(span, pre_len)) {
        fold.reanchor(self.alloc, &buf.folds, &buf.pt) catch buf.folds.clearRetainingCapacity();
    } else {
        fold.transformFolds(&buf.folds, span, &buf.pt);
    }
}

/// Carry folds through one direct whole-buffer replacement that bypasses
/// `History` (agent patch undo/redo on buffers opened after the patch). Call
/// AFTER the piece table has been replaced; the old fold entries still hold
/// their pre-replacement header signatures/line positions.
pub fn reanchorAfterDirectReplace(self: *App, buf: *App.Buffer) void {
    fold.reanchor(self.alloc, &buf.folds, &buf.pt) catch buf.folds.clearRetainingCapacity();
}

/// Apply the top undo/redo group to `buf`, transforming its closed folds
/// through the same edit sequence first. Runs the transform against a scratch
/// copy of the document so a multi-edit group sees the exact intermediate
/// line structure; the real history transaction then produces the same final
/// bytes.
pub fn historyApply(self: *App, buf: *App.Buffer, kind: history_mod.UndoKind) history_mod.UndoResult {
    const group = switch (kind) {
        .undo => buf.history.topUndoGroup(),
        .redo => buf.history.topRedoGroup(),
    } orelse return .{ .changed = false, .kind = kind, .revision = buf.history.revision };
    if (buf.folds.items.len > 0) transformThroughHistory(self, buf, group, kind);
    const pre_len = buf.pt.len();
    const result = switch (kind) {
        .undo => buf.history.undoResult(&buf.pt),
        .redo => buf.history.redoResult(&buf.pt),
    };
    if (result.changed) {
        // Outside the group's changed range the suffix has identical bytes.
        const old_end = pre_len - (buf.pt.len() - result.change_end);
        buf.search_index.afterEdit(&buf.pt, result.revision, result.change_start, old_end, result.change_end);
    }
    return result;
}

fn transformThroughHistory(
    self: *App,
    buf: *App.Buffer,
    group: *const history_mod.Group,
    kind: history_mod.UndoKind,
) void {
    const text = self.alloc.alloc(u8, buf.pt.len()) catch {
        buf.folds.clearRetainingCapacity();
        return;
    };
    buf.pt.copyRange(0, text);
    // initOwned takes the snapshot (and frees it on failure).
    var scratch = buffer.PieceTable.initOwned(self.alloc, text) catch {
        buf.folds.clearRetainingCapacity();
        return;
    };
    defer scratch.deinit();
    switch (kind) {
        .undo => {
            // Undo applies the group's inverses in reverse recording order.
            var i = group.edits.items.len;
            while (i > 0) {
                i -= 1;
                const e = group.edits.items[i];
                applyStep(self, buf, &scratch, .{
                    .pos = e.pos,
                    .removed = @intCast(e.after.len),
                    .inserted = @intCast(e.before.len),
                    .removed_newlines = fold.countNewlines(e.after),
                    .inserted_newlines = fold.countNewlines(e.before),
                }, e.before);
            }
        },
        .redo => {
            for (group.edits.items) |e| {
                applyStep(self, buf, &scratch, .{
                    .pos = e.pos,
                    .removed = @intCast(e.before.len),
                    .inserted = @intCast(e.after.len),
                    .removed_newlines = fold.countNewlines(e.before),
                    .inserted_newlines = fold.countNewlines(e.after),
                }, e.after);
            }
        },
    }
}

fn applyStep(
    self: *App,
    buf: *App.Buffer,
    scratch: *buffer.PieceTable,
    span: fold.EditSpan,
    inserted: []const u8,
) void {
    const pre_len = scratch.len();
    const whole = fold.isWholeDocument(span, pre_len);
    _ = scratch.replace(span.pos, span.removed, inserted) catch unreachable;
    if (whole) {
        fold.reanchor(self.alloc, &buf.folds, scratch) catch buf.folds.clearRetainingCapacity();
    } else {
        fold.transformFolds(&buf.folds, span, scratch);
    }
}
