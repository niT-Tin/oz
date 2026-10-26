//! Staged agent edits (M3b1): pure argument validation, occurrence mapping,
//! bounded diff preview and pending-review model.
//!
//! Deliberately App/vaxis/filesystem-independent: `src/app/agent_edit_ui.zig`
//! owns workspace confinement, read-only file loading, buffer application,
//! rendering and key routing. Everything here is unit-testable without an
//! editor or a terminal.
//!
//! Invariants:
//!   - an `edit_file` call never reaches the executor; the app stages a
//!     `Pending` and only a human approve mutates the in-memory buffer;
//!   - `old_string` is byte-exact; without `replace_all` it must occur
//!     exactly once (ambiguous/missing calls are real errors, never staged);
//!   - the diff preview is bounded (context windows around the changed
//!     lines) and reuses `inline_model.buildDiff`'s line-level LCS — this module
//!     does not implement a second diff engine;
//!   - the full target text is snapshotted for staleness; applying requires
//!     the buffer/file text and occurrence count to still match;
//!   - one agent edit/review may be pending at a time (checked together with
//!     the inline edit in the App);
//!   - a multi-file patch is one `Pending` with a `PendingFile` per target,
//!     one whole-set validation result, a two-phase commit helper and one
//!     cross-file undo snapshot. Single-file edits keep their historical
//!     contiguous-span/history-group behavior.
const std = @import("std");
const inline_model = @import("inline.zig");
const patch_model = @import("agent_patch.zig");
const tool_exec = @import("../ai/tool_exec.zig");

/// Maximum target file/buffer size staged for review. Bounded so one tool
/// call cannot copy an arbitrarily large file into the UI process. Shared
/// with `apply_patch` so its reconstructed result obeys the same cap.
pub const max_stage_bytes: usize = patch_model.max_stage_bytes;

/// Maximum occurrences in a `replace_all` edit. Prevents a pathological
/// `old_string` from creating an unbounded preview/application workload.
pub const max_occurrences: usize = 512;

/// Context lines included around each changed line in the preview.
pub const hunk_context_lines: u32 = 3;

/// Upper bound on previewed lines (all hunks together).
pub const max_preview_lines: u32 = 240;

/// Upper bound on separate preview hunks. More distant occurrences are
/// summarized by a truthful "N more occurrences not shown" line.
pub const max_preview_hunks: usize = 16;

pub const stale_label = "stale edit";
pub const stale_patch_label = "stale patch";

/// Which staged write produced a `Pending`. `apply_patch` is still a
/// whole-file replacement (one contiguous span, one undo group); only the
/// staging/verification rules differ.
pub const Kind = enum {
    edit_file,
    apply_patch,

    pub fn toolName(self: Kind) []const u8 {
        return switch (self) {
            .edit_file => "edit_file",
            .apply_patch => "apply_patch",
        };
    }

    pub fn staleLabel(self: Kind) []const u8 {
        return switch (self) {
            .edit_file => stale_label,
            .apply_patch => stale_patch_label,
        };
    }
};

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

pub const ArgError = error{
    OutOfMemory,
    MalformedArguments,
    MissingPath,
    PathNotString,
    MissingOldString,
    OldStringNotString,
    OldStringEmpty,
    MissingNewString,
    NewStringNotString,
    ReplaceAllNotBool,
};

pub const EditArgs = struct {
    path: []u8,
    old_string: []u8,
    new_string: []u8,
    replace_all: bool,

    pub fn deinit(self: *EditArgs, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.old_string);
        alloc.free(self.new_string);
        self.* = undefined;
    }
};

/// Parse the `edit_file` arguments exactly as advertised by
/// `ai.tools.definitions` (`path`, `old_string`, `new_string`, optional
/// `replace_all`). Unknown fields are ignored; wrong types/missing required
/// fields are typed errors (mapped to a real card error by the UI).
pub fn parseArgs(alloc: std.mem.Allocator, arguments_json: []const u8) ArgError!EditArgs {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedArguments;
    const obj = &parsed.value.object;

    const path_value = obj.get("path") orelse return error.MissingPath;
    const path = switch (path_value) {
        .string => |s| s,
        else => return error.PathNotString,
    };
    const old_value = obj.get("old_string") orelse return error.MissingOldString;
    const old_string = switch (old_value) {
        .string => |s| s,
        else => return error.OldStringNotString,
    };
    if (old_string.len == 0) return error.OldStringEmpty;
    const new_value = obj.get("new_string") orelse return error.MissingNewString;
    const new_string = switch (new_value) {
        .string => |s| s,
        else => return error.NewStringNotString,
    };
    const replace_all: bool = if (obj.get("replace_all")) |value| switch (value) {
        .bool => |b| b,
        .null => false,
        else => return error.ReplaceAllNotBool,
    } else false;

    const path_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(path_copy);
    const old_copy = try alloc.dupe(u8, old_string);
    errdefer alloc.free(old_copy);
    const new_copy = try alloc.dupe(u8, new_string);
    return .{
        .path = path_copy,
        .old_string = old_copy,
        .new_string = new_copy,
        .replace_all = replace_all,
    };
}

// ---------------------------------------------------------------------------
// Occurrence mapping / span replacement
// ---------------------------------------------------------------------------

/// Non-overlapping occurrences of `needle` (non-empty). Returns at most
/// `max_occurrences + 1` entries so callers can distinguish "too many" from
/// the exact bound.
fn collectOccurrences(alloc: std.mem.Allocator, text: []const u8, needle: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    if (needle.len == 0) return out.toOwnedSlice(alloc);
    var pos: usize = 0;
    while (pos + needle.len <= text.len) {
        const found = std.mem.indexOfPos(u8, text, pos, needle) orelse break;
        try out.append(alloc, @intCast(found));
        if (out.items.len > max_occurrences) break;
        pos = found + needle.len;
    }
    return out.toOwnedSlice(alloc);
}

/// Replace every occurrence inside `[span_start, span_end)`. The caller has
/// verified that `occurrences` lies inside the span and does not overlap.
fn replaceInSpan(
    alloc: std.mem.Allocator,
    text: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    occurrences: []const u32,
    span_start: u32,
    span_end: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var cursor: usize = span_start;
    for (occurrences) |occ| {
        const start: usize = occ;
        if (start < cursor or start + old_string.len > span_end) continue;
        try out.appendSlice(alloc, text[cursor..start]);
        try out.appendSlice(alloc, new_string);
        cursor = start + old_string.len;
    }
    try out.appendSlice(alloc, text[cursor..span_end]);
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Bounded preview diff
// ---------------------------------------------------------------------------

const LineIndex = struct {
    starts: []u32,
    text_len: usize,

    fn init(alloc: std.mem.Allocator, text: []const u8) !LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(alloc);
        if (text.len > 0) {
            try starts.append(alloc, 0);
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\n' and i + 1 < text.len) try starts.append(alloc, @intCast(i + 1));
            }
        }
        return .{ .starts = try starts.toOwnedSlice(alloc), .text_len = text.len };
    }

    fn deinit(self: *LineIndex, alloc: std.mem.Allocator) void {
        alloc.free(self.starts);
        self.* = undefined;
    }

    fn count(self: *const LineIndex) usize {
        return self.starts.len;
    }

    fn lineOf(self: *const LineIndex, offset: usize) usize {
        if (self.count() == 0) return 0;
        var lo: usize = 0;
        var hi: usize = self.count();
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return lo;
    }

    /// End offset of line `line`, excluding its trailing newline for every
    /// non-final line. The final line may include the file's trailing
    /// newline; `inline.splitLines` ignores that phantom line.
    fn lineEnd(self: *const LineIndex, line: usize) usize {
        if (line + 1 < self.count()) return self.starts[line + 1] - 1;
        return self.text_len;
    }
};

const Window = struct { first: usize, last: usize };

fn appendWindow(alloc: std.mem.Allocator, list: *std.ArrayList(Window), first: usize, last: usize) !void {
    if (list.items.len > 0) {
        const tail = &list.items[list.items.len - 1];
        // Merge overlapping AND adjacent windows: two edits on neighboring
        // lines read much better as one hunk than as two hunks split by an
        // empty "…" separator.
        if (first <= tail.last + 1) {
            tail.last = @max(tail.last, last);
            return;
        }
    }
    try list.append(alloc, .{ .first = first, .last = last });
}

const Preview = struct {
    diff: []inline_model.DiffLine,
    removed: u32 = 0,
    added: u32 = 0,
    first_line: u32,
    last_line: u32,
    partial: bool = false,
};

fn freePreview(alloc: std.mem.Allocator, diff: []inline_model.DiffLine) void {
    for (diff) |d| alloc.free(d.text);
    if (diff.len > 0) alloc.free(diff);
}

fn appendNote(alloc: std.mem.Allocator, list: *std.ArrayList(inline_model.DiffLine), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    errdefer alloc.free(text);
    try list.append(alloc, .{ .kind = .context, .text = text });
}

/// Build the bounded review diff. Each changed line range becomes a hunk
/// with `hunk_context_lines` of context; overlapping hunks merge. When the
/// requested context would exceed the line/hunk budget it is reduced, and
/// any occurrences that still do not fit are summarized by a truthful note.
fn buildPreview(
    alloc: std.mem.Allocator,
    text: []const u8,
    occurrences: []const u32,
    old_len: usize,
    new_string: []const u8,
) !Preview {
    var index = try LineIndex.init(alloc, text);
    defer index.deinit(alloc);

    // Change ranges: [start_line, end_line] (0-based, inclusive).
    var changed: std.ArrayList(Window) = .empty;
    defer changed.deinit(alloc);
    for (occurrences) |occ| {
        const start: usize = occ;
        const last_byte = start +| old_len -| 1;
        const first_line = index.lineOf(start);
        const last_line = index.lineOf(@min(last_byte, text.len -| 1));
        try appendWindow(alloc, &changed, first_line, last_line);
    }
    if (changed.items.len == 0) return error.NotFound;

    // Reduce context until the whole preview fits the budgets.
    var windows: std.ArrayList(Window) = .empty;
    defer windows.deinit(alloc);
    var context: u32 = hunk_context_lines;
    var total_lines: u32 = 0;
    while (true) {
        windows.clearRetainingCapacity();
        total_lines = 0;
        for (changed.items) |range| {
            const first = range.first -| context;
            const last = @min(index.count() - 1, range.last + context);
            try appendWindow(alloc, &windows, first, last);
        }
        total_lines = 0;
        for (windows.items) |w| total_lines += @intCast(w.last - w.first + 1);
        if ((total_lines <= max_preview_lines and windows.items.len <= max_preview_hunks) or context == 0) break;
        context -= 1;
    }

    // Last-resort trimming: keep a prefix of hunks and report the rest.
    var partial = false;
    var kept: usize = windows.items.len;
    var kept_lines: u32 = 0;
    var k: usize = 0;
    while (k < windows.items.len) : (k += 1) {
        const lines: u32 = @intCast(windows.items[k].last - windows.items[k].first + 1);
        if (k >= max_preview_hunks or kept_lines + lines > max_preview_lines) {
            kept = k;
            partial = true;
            break;
        }
        kept_lines += lines;
    }
    if (kept == 0) {
        // A single changed line can never exceed max_preview_lines; guard
        // defensively so a malformed index never returns an empty review.
        windows.items[0].last = windows.items[0].first;
        kept = 1;
        partial = true;
    }
    if (kept < windows.items.len) partial = true;

    var out: std.ArrayList(inline_model.DiffLine) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d.text);
        out.deinit(alloc);
    }

    var removed: u32 = 0;
    var added: u32 = 0;
    var shown_occurrences: usize = 0;
    var wi: usize = 0;
    while (wi < kept) : (wi += 1) {
        const w = windows.items[wi];
        const start_off = index.starts[w.first];
        const end_off = index.lineEnd(w.last);
        const region_old = text[start_off..end_off];
        var region_new: std.ArrayList(u8) = .empty;
        defer region_new.deinit(alloc);
        {
            var cursor: usize = start_off;
            for (occurrences) |occ| {
                const occ_start: usize = occ;
                if (occ_start < start_off or occ_start + old_len > end_off) continue;
                try region_new.appendSlice(alloc, text[cursor..occ_start]);
                try region_new.appendSlice(alloc, new_string);
                cursor = occ_start + old_len;
                shown_occurrences += 1;
            }
            try region_new.appendSlice(alloc, text[cursor..end_off]);
        }

        const diff = try inline_model.buildDiff(alloc, region_old, region_new.items);
        var moved: usize = 0;
        errdefer {
            var j = moved;
            while (j < diff.len) : (j += 1) alloc.free(diff[j].text);
            alloc.free(diff);
        }
        const stats = inline_model.diffStats(diff);
        removed += stats.removed;
        added += stats.added;
        for (diff) |d| {
            try out.append(alloc, d);
            moved += 1;
        }
        alloc.free(diff);
        if (wi + 1 < kept) try appendNote(alloc, &out, "…", .{});
    }

    const omitted = occurrences.len - shown_occurrences;
    if (partial or omitted > 0) {
        if (omitted > 0) {
            try appendNote(alloc, &out, "… {d} more occurrence(s) not shown", .{omitted});
        } else {
            try appendNote(alloc, &out, "… preview truncated", .{});
        }
    }

    return .{
        .diff = try out.toOwnedSlice(alloc),
        .removed = removed,
        .added = added,
        .first_line = @intCast(windows.items[0].first + 1),
        .last_line = @intCast(windows.items[kept - 1].last + 1),
        .partial = partial or omitted > 0,
    };
}

// ---------------------------------------------------------------------------
// Pending edit
// ---------------------------------------------------------------------------

pub const Meta = struct {
    thread_index: usize,
    /// Message index of this call's Chat tool card.
    card_index: usize,
    /// Canonical workspace root captured for this agent turn.
    root: []const u8,
    /// Canonical absolute target path (inside `root`).
    path: []const u8,
    /// Workspace-relative display path.
    display_path: []const u8,
    /// Full target text at staging time (buffer or disk).
    text: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
    /// Set when staged from an already-open buffer; approve then also checks
    /// this exact history revision.
    buffer_index: ?usize = null,
    revision: ?u64 = null,
};

pub const PlanError = error{
    OutOfMemory,
    OldStringEmpty,
    NotFound,
    Ambiguous,
    TooManyOccurrences,
};

/// One file in a staged review. Every file carries its own old/new snapshot,
/// buffer identity, retained patch (for re-verification) and preview diff.
pub const PendingFile = struct {
    /// Canonical absolute target path (inside `Pending.root`).
    path: []u8,
    /// Workspace-relative display path.
    display_path: []u8,
    /// Full target text at staging time (buffer or disk).
    text: []u8,
    /// Full staged result for this file.
    new_text: []u8,
    buffer_index: ?usize = null,
    revision: ?u64 = null,
    /// Parsed patch for this file (`apply_patch` only; null for `edit_file`).
    patch: ?patch_model.Patch = null,
    diff: []inline_model.DiffLine = &.{},
    removed: u32 = 0,
    added: u32 = 0,
    first_line: u32 = 1,
    last_line: u32 = 1,
    preview_partial: bool = false,

    pub fn deinit(self: *PendingFile, alloc: std.mem.Allocator) void {
        if (self.path.len > 0) alloc.free(self.path);
        if (self.display_path.len > 0) alloc.free(self.display_path);
        if (self.text.len > 0) alloc.free(self.text);
        if (self.new_text.len > 0) alloc.free(self.new_text);
        if (self.patch) |*patch| patch.deinit(alloc);
        freePreview(alloc, self.diff);
        self.* = undefined;
    }
};

/// A staged review. `files.len == 1` for `edit_file` and the historical
/// single-file `apply_patch`; 2..`patch_model.max_files` for the multi-file
/// path. The edit_file occurrence/span fields are only meaningful for
/// `kind == .edit_file` (multi-file patches never have a contiguous span).
pub const Pending = struct {
    kind: Kind = .edit_file,
    thread_index: usize,
    card_index: usize,
    root: []u8,
    files: []PendingFile,
    /// Empty for `apply_patch` (the whole text is the replacement span).
    old_string: []u8,
    new_string: []u8,
    replace_all: bool,
    /// `edit_file` only: occurrence count and contiguous span.
    occurrence_count: u32 = 0,
    span_start: u32 = 0,
    span_end: u32 = 0,
    /// Aggregate shown-hunk stats (sum over files).
    removed: u32 = 0,
    added: u32 = 0,
    preview_partial: bool = false,
    /// Set when an approve attempt found the buffer/file changed. Purely a
    /// display/lifecycle flag: apply is refused either way.
    stale: bool = false,
    /// First stale file (owned) for the multi-file review header/card.
    stale_file: ?[]u8 = null,

    pub fn deinit(self: *Pending, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        for (self.files) |*file| file.deinit(alloc);
        if (self.files.len > 0) alloc.free(self.files);
        if (self.old_string.len > 0) alloc.free(self.old_string);
        if (self.new_string.len > 0) alloc.free(self.new_string);
        if (self.stale_file) |file| alloc.free(file);
        self.* = undefined;
    }

    /// Replacement for the contiguous edit_file span (owned by the single
    /// PendingFile).
    pub fn spanReplacement(self: *const Pending) []const u8 {
        if (self.files.len != 1) return "";
        return self.files[0].new_text;
    }

    pub fn isMulti(self: *const Pending) bool {
        return self.files.len > 1;
    }

    pub fn isVisibleFor(self: *const Pending, thread_index: usize) bool {
        return self.thread_index == thread_index;
    }

    pub fn staleLabel(self: *const Pending) []const u8 {
        return self.kind.staleLabel();
    }

    /// True only when the current text is byte-identical to the staging
    /// snapshot and the exact occurrence count is unchanged. The caller
    /// still checks the buffer history revision (when the edit was staged
    /// from a buffer). For `apply_patch` the occurrence check is replaced by
    /// re-applying the retained hunks in `verifyPatch`.
    pub fn verify(self: *const Pending, current_text: []const u8) bool {
        if (self.files.len != 1) return false;
        const file = &self.files[0];
        if (!std.mem.eql(u8, file.text, current_text)) return false;
        if (self.kind == .apply_patch) return true;
        if (self.span_start > self.span_end or self.span_end > current_text.len) return false;
        var count: u32 = 0;
        var pos: usize = 0;
        while (pos + self.old_string.len <= current_text.len) {
            const found = std.mem.indexOfPos(u8, current_text, pos, self.old_string) orelse break;
            count += 1;
            if (count > self.occurrence_count) return false;
            pos = found + self.old_string.len;
        }
        return count == self.occurrence_count;
    }

    /// Re-apply the retained single-file patch to `current_text` and require
    /// the exact staged new text. Always true for `edit_file`. Kept for the
    /// historical single-file API; multi-file approval calls `verifyFile`.
    pub fn verifyPatch(self: *const Pending, alloc: std.mem.Allocator, current_text: []const u8) bool {
        if (self.kind != .apply_patch or self.files.len != 1) return true;
        return self.verifyFile(alloc, 0, current_text);
    }

    /// Full per-file staleness check: old text identity, then (for patches)
    /// re-run the hunks and require the exact staged result.
    pub fn verifyFile(self: *const Pending, alloc: std.mem.Allocator, index: usize, current_text: []const u8) bool {
        if (index >= self.files.len) return false;
        const file = &self.files[index];
        if (!std.mem.eql(u8, file.text, current_text)) return false;
        if (self.kind == .edit_file) return true;
        const patch = if (file.patch) |*p| p else return false;
        const applied = patch_model.apply(alloc, patch, current_text) catch return false;
        defer alloc.free(applied);
        return std.mem.eql(u8, applied, file.new_text);
    }

    /// First file (in patch order) whose current text no longer matches the
    /// staging snapshot, or null when the whole set is still current. The
    /// caller supplies each current text; path/buffer-index checks happen at
    /// the UI boundary.
    pub fn staleFile(
        self: *const Pending,
        alloc: std.mem.Allocator,
        current_texts: []const []const u8,
    ) ?usize {
        if (current_texts.len != self.files.len) return 0;
        for (self.files, 0..) |_, i| {
            if (!self.verifyFile(alloc, i, current_texts[i])) return i;
        }
        return null;
    }
};

/// Owned undo snapshot for one multi-file patch set. The existing undo
/// history is per buffer; a multi-file apply is one explicit cross-file undo
/// unit. `applied` flips on undo/redo so the same entry can drive both.
pub const UndoEntry = struct {
    path: []u8,
    old_text: []u8,
    new_text: []u8,
    buffer_index: ?usize = null,
    /// True when the buffer was already open at apply time, so the apply's
    /// one history group exists in that buffer. A file opened later is
    /// disk-only; the cross-file undo refuses rather than discard its
    /// unsaved buffer state.
    open_at_apply: bool = false,
    /// Buffer history revision after the most recent apply/undo, when open.
    revision: ?u64 = null,

    pub fn deinit(self: *UndoEntry, alloc: std.mem.Allocator) void {
        if (self.path.len > 0) alloc.free(self.path);
        if (self.old_text.len > 0) alloc.free(self.old_text);
        if (self.new_text.len > 0) alloc.free(self.new_text);
        self.* = undefined;
    }
};

pub const UndoSet = struct {
    files: []UndoEntry,
    /// Captured workspace root for confinement checks on a later undo.
    root: []u8,
    /// True after apply (new text is live), false after undo (old text).
    applied: bool = true,

    pub fn deinit(self: *UndoSet, alloc: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(alloc);
        if (self.files.len > 0) alloc.free(self.files);
        if (self.root.len > 0) alloc.free(self.root);
        self.* = undefined;
    }

    /// Text currently on disk/buffer for this file.
    pub fn liveText(self: *const UndoSet, index: usize) []const u8 {
        const file = &self.files[index];
        return if (self.applied) file.new_text else file.old_text;
    }

    /// Text an undo (or redo) must write for this file.
    pub fn targetText(self: *const UndoSet, index: usize) []const u8 {
        const file = &self.files[index];
        return if (self.applied) file.old_text else file.new_text;
    }
};

/// Build a pending edit from already-validated metadata. Duplicates every
/// slice so the caller keeps ownership of its staging buffers.
pub fn createPending(alloc: std.mem.Allocator, meta: Meta) PlanError!Pending {
    if (meta.old_string.len == 0) return error.OldStringEmpty;

    const occurrences = try collectOccurrences(alloc, meta.text, meta.old_string);
    defer alloc.free(occurrences);
    if (occurrences.len == 0) return error.NotFound;
    if (!meta.replace_all and occurrences.len > 1) return error.Ambiguous;
    if (occurrences.len > max_occurrences) return error.TooManyOccurrences;

    const span_start = occurrences[0];
    const span_end = occurrences[occurrences.len - 1] + @as(u32, @intCast(meta.old_string.len));
    const replacement = try replaceInSpan(
        alloc,
        meta.text,
        meta.old_string,
        meta.new_string,
        occurrences,
        span_start,
        span_end,
    );
    errdefer alloc.free(replacement);

    const preview = try buildPreview(
        alloc,
        meta.text,
        occurrences,
        meta.old_string.len,
        meta.new_string,
    );
    var diff_owned = true;
    errdefer if (diff_owned) freePreview(alloc, preview.diff);

    const files = try alloc.alloc(PendingFile, 1);
    errdefer alloc.free(files);
    var file = PendingFile{
        .path = &.{},
        .display_path = &.{},
        .text = &.{},
        .new_text = &.{},
        .buffer_index = meta.buffer_index,
        .revision = meta.revision,
        .diff = &.{},
        .removed = preview.removed,
        .added = preview.added,
        .first_line = preview.first_line,
        .last_line = preview.last_line,
        .preview_partial = preview.partial,
    };
    var replacement_owned = true;
    errdefer if (replacement_owned) alloc.free(replacement);
    errdefer file.deinit(alloc);
    file.path = try alloc.dupe(u8, meta.path);
    file.display_path = try alloc.dupe(u8, meta.display_path);
    file.text = try alloc.dupe(u8, meta.text);
    file.new_text = replacement;
    replacement_owned = false;
    file.diff = preview.diff;
    diff_owned = false;
    files[0] = file;

    return .{
        .thread_index = meta.thread_index,
        .card_index = meta.card_index,
        .root = try alloc.dupe(u8, meta.root),
        .files = files,
        .old_string = try alloc.dupe(u8, meta.old_string),
        .new_string = try alloc.dupe(u8, meta.new_string),
        .replace_all = meta.replace_all,
        .occurrence_count = @intCast(occurrences.len),
        .span_start = span_start,
        .span_end = span_end,
        .removed = preview.removed,
        .added = preview.added,
        .preview_partial = preview.partial,
    };
}

pub const PatchFileMeta = struct {
    path: []const u8,
    display_path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    buffer_index: ?usize = null,
    revision: ?u64 = null,
    /// Parsed patch. Ownership moves into the returned `Pending` on success;
    /// on error the caller still owns every patch and must free the set.
    patch: *patch_model.Patch,
};

pub const PatchSetMeta = struct {
    thread_index: usize,
    card_index: usize,
    root: []const u8,
    files: []const PatchFileMeta,
};

pub const PatchPlanError = error{OutOfMemory};

/// Build one pending review for a validated 1..max_files patch set. Every
/// file keeps its own old/new text and retained hunks; all fallible work
/// happens before ownership of the caller's patches moves.
pub fn createPatchSetPending(alloc: std.mem.Allocator, meta: PatchSetMeta) PatchPlanError!Pending {
    if (meta.files.len == 0 or meta.files.len > patch_model.max_files) return error.OutOfMemory;

    const files = try alloc.alloc(PendingFile, meta.files.len);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(alloc);
        alloc.free(files);
    }

    // Historical single-file behavior is preserved exactly: the preview is
    // the bounded 240-line/16-hunk display and the stats count shown lines.
    // Multi-file sets use the global patch budgets instead (complete per-file
    // diff + exact whole-file stats).
    const single = meta.files.len == 1;
    var removed_total: u32 = 0;
    var added_total: u32 = 0;
    var partial_total = false;
    for (meta.files, 0..) |file_meta, i| {
        const preview = if (single)
            patch_model.buildPreview(alloc, file_meta.patch) catch return error.OutOfMemory
        else
            patch_model.buildPreviewWithLimits(
                alloc,
                file_meta.patch,
                @intCast(patch_model.max_hunk_lines),
                patch_model.max_hunks,
            ) catch return error.OutOfMemory;
        const stats = if (single)
            patch_model.Stats{ .removed = preview.removed, .added = preview.added }
        else
            file_meta.patch.stats();
        files[i] = initPendingFile(alloc, file_meta, stats, preview) catch |e| {
            freePreview(alloc, preview.lines);
            return e;
        };
        initialized += 1;
        removed_total +|= stats.removed;
        added_total +|= stats.added;
        partial_total = partial_total or preview.partial;
    }

    var pending = Pending{
        .kind = .apply_patch,
        .thread_index = meta.thread_index,
        .card_index = meta.card_index,
        .root = try alloc.dupe(u8, meta.root),
        .files = files,
        .old_string = &.{},
        .new_string = &.{},
        .replace_all = false,
        .removed = removed_total,
        .added = added_total,
        .preview_partial = partial_total,
    };
    // Historical single-file API: the patch is the whole-file span. Multi
    // applies are not a contiguous span (each file is written separately).
    if (meta.files.len == 1) {
        pending.span_start = 0;
        pending.span_end = @intCast(meta.files[0].old_text.len);
    }
    // Ownership of every patch moves only after all duplication/previews
    // succeeded, so a failed call never consumes the caller's set.
    for (meta.files, 0..) |file_meta, i| {
        pending.files[i].patch = file_meta.patch.*;
        // Leave a safely deinitializable placeholder: a caller that still
        // owns the set can free it after a successful move.
        file_meta.patch.* = .{ .path = &.{}, .hunks = &.{} };
    }
    return pending;
}

fn initPendingFile(
    alloc: std.mem.Allocator,
    meta: PatchFileMeta,
    stats: patch_model.Stats,
    preview: patch_model.Preview,
) !PendingFile {
    var file = PendingFile{
        .path = &.{},
        .display_path = &.{},
        .text = &.{},
        .new_text = &.{},
        .buffer_index = meta.buffer_index,
        .revision = meta.revision,
        .diff = preview.lines,
        .removed = stats.removed,
        .added = stats.added,
        .first_line = preview.first_line,
        .last_line = preview.last_line,
        .preview_partial = preview.partial,
    };
    errdefer {
        if (file.path.len > 0) alloc.free(file.path);
        if (file.display_path.len > 0) alloc.free(file.display_path);
        if (file.text.len > 0) alloc.free(file.text);
        if (file.new_text.len > 0) alloc.free(file.new_text);
    }
    file.path = try alloc.dupe(u8, meta.path);
    file.display_path = try alloc.dupe(u8, meta.display_path);
    file.text = try alloc.dupe(u8, meta.old_text);
    file.new_text = try alloc.dupe(u8, meta.new_text);
    return file;
}

pub const PatchMeta = struct {
    thread_index: usize,
    card_index: usize,
    root: []const u8,
    /// Canonical absolute target path (inside `root`).
    path: []const u8,
    /// Workspace-relative display path.
    display_path: []const u8,
    /// Full target text at staging time (buffer or disk).
    old_text: []const u8,
    /// Full text produced by applying every hunk in order.
    new_text: []const u8,
    buffer_index: ?usize = null,
    revision: ?u64 = null,
    /// Parsed patch. Ownership moves into the returned `Pending` on success;
    /// on error the caller still owns it and must free it.
    patch: *patch_model.Patch,
};

/// Single-file compatibility wrapper around `createPatchSetPending`.
pub fn createPatchPending(alloc: std.mem.Allocator, meta: PatchMeta) PatchPlanError!Pending {
    return createPatchSetPending(alloc, .{
        .thread_index = meta.thread_index,
        .card_index = meta.card_index,
        .root = meta.root,
        .files = &.{.{
            .path = meta.path,
            .display_path = meta.display_path,
            .old_text = meta.old_text,
            .new_text = meta.new_text,
            .buffer_index = meta.buffer_index,
            .revision = meta.revision,
            .patch = meta.patch,
        }},
    });
}

/// One file in a disk write transaction. `old_text` is the rollback source
/// (the exact bytes on disk before this apply).
pub const CommitFile = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

pub const CommitStatus = enum {
    committed,
    /// A temp write failed: no target was renamed.
    write_failed,
    /// A rename failed after earlier files were committed; those were
    /// restored from their in-memory old text.
    rename_failed,
};

pub const CommitOutcome = struct {
    status: CommitStatus,
    failed_index: usize = 0,
    /// Number of already-renamed files a failed commit attempted to restore.
    rolled_back: usize = 0,
    /// True when at least one rollback write/rename failed. The caller must
    /// report the partially-applied set truthfully (never claim rollback).
    rollback_failed: bool = false,
};

/// Two-phase multi-file write: every new text is first staged into a sibling
/// temp file (phase 1, no target touched), then each temp is renamed over its
/// target (phase 2). A phase-1 failure leaves every target unchanged. A
/// phase-2 failure restores already-renamed targets from `old_text` and
/// reports any rollback failure. This is *not* a filesystem-wide atomic
/// multi-file commit; the guarantee is "no target changes before all temps
/// exist" plus best-effort rollback with honest reporting.
///
/// `sink` is compile-time-injected so unit tests can simulate write/rename
/// failures without touching the filesystem:
///   writeTemp(index, text) !void, renameTemp(index) !void,
///   abortTemp(index) void, restore(index, old_text) !void
pub fn commitFiles(files: []const CommitFile, sink: anytype) CommitOutcome {
    var written: usize = 0;
    for (files, 0..) |file, i| {
        sink.writeTemp(i, file.new_text) catch {
            sink.abortTemp(i);
            var j: usize = 0;
            while (j < written) : (j += 1) sink.abortTemp(j);
            return .{ .status = .write_failed, .failed_index = i };
        };
        written += 1;
    }

    var renamed: usize = 0;
    for (files, 0..) |_, i| {
        sink.renameTemp(i) catch {
            // Drop every temp that was not renamed yet (including this one).
            var j = i;
            while (j < written) : (j += 1) sink.abortTemp(j);
            var rollback_failed = false;
            var k = renamed;
            while (k > 0) {
                k -= 1;
                sink.restore(k, files[k].old_text) catch {
                    rollback_failed = true;
                };
            }
            return .{
                .status = .rename_failed,
                .failed_index = i,
                .rolled_back = renamed,
                .rollback_failed = rollback_failed,
            };
        };
        renamed += 1;
    }
    return .{ .status = .committed };
}

/// One-review policy shared with the inline assistant: a new agent stage is
/// refused while any inline prompt/stream/pending is active, and inline
/// start is refused while an agent edit is pending.
pub fn canStage(agent_pending: bool, inline_busy: bool) bool {
    return !agent_pending and !inline_busy;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeArgs(alloc: std.mem.Allocator, json: []const u8) !EditArgs {
    return parseArgs(alloc, json);
}

fn testMeta(
    thread: usize,
    card: usize,
    text: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) Meta {
    return .{
        .thread_index = thread,
        .card_index = card,
        .root = "/workspace",
        .path = "/workspace/a.txt",
        .display_path = "a.txt",
        .text = text,
        .old_string = old_string,
        .new_string = new_string,
        .replace_all = replace_all,
    };
}

test "agent_edit: parses the advertised edit_file schema" {
    const alloc = testing.allocator;
    var args = try makeArgs(alloc,
        \\{"path":"src/a.zig","old_string":"x","new_string":"y","replace_all":true}
    );
    defer args.deinit(alloc);
    try testing.expectEqualStrings("src/a.zig", args.path);
    try testing.expectEqualStrings("x", args.old_string);
    try testing.expectEqualStrings("y", args.new_string);
    try testing.expect(args.replace_all);

    var defaults = try makeArgs(alloc, "{\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"\"}");
    defer defaults.deinit(alloc);
    try testing.expect(!defaults.replace_all);
    try testing.expectEqual(@as(usize, 0), defaults.new_string.len);

    try testing.expectError(error.MissingOldString, makeArgs(alloc, "{\"path\":\"a\",\"new_string\":\"y\"}"));
    try testing.expectError(error.OldStringEmpty, makeArgs(alloc, "{\"path\":\"a\",\"old_string\":\"\",\"new_string\":\"y\"}"));
    try testing.expectError(error.MissingPath, makeArgs(alloc, "{\"old_string\":\"x\",\"new_string\":\"y\"}"));
    try testing.expectError(error.MalformedArguments, makeArgs(alloc, "not json"));
    try testing.expectError(error.PathNotString, makeArgs(alloc, "{\"path\":1,\"old_string\":\"x\",\"new_string\":\"y\"}"));
    try testing.expectError(error.ReplaceAllNotBool, makeArgs(alloc, "{\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"y\",\"replace_all\":\"yes\"}"));
}

test "agent_edit: unique old_string stages a real diff and span replacement" {
    const alloc = testing.allocator;
    const text = "alpha one\nbeta two\ngamma three\n";
    var pending = try createPending(alloc, testMeta(2, 7, text, "beta two", "BETA TWO", false));
    defer pending.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), pending.thread_index);
    try testing.expectEqual(@as(usize, 7), pending.card_index);
    try testing.expectEqualStrings("a.txt", pending.files[0].display_path);
    try testing.expectEqual(@as(u32, 1), pending.occurrence_count);
    try testing.expectEqual(@as(u32, 1), pending.removed);
    try testing.expectEqual(@as(u32, 1), pending.added);
    try testing.expect(!pending.preview_partial);
    try testing.expectEqualStrings("BETA TWO", pending.spanReplacement());
    try testing.expectEqual(@as(u32, 10), pending.span_start);
    try testing.expectEqual(@as(u32, 18), pending.span_end);
    try testing.expect(pending.verify(text));
    try testing.expect(!pending.verify("alpha one\nbeta TWO\ngamma three\n"));

    // The preview is a line diff with context, not a fabricated unified blob.
    var saw_removed = false;
    var saw_added = false;
    for (pending.files[0].diff) |d| switch (d.kind) {
        .removed => {
            saw_removed = true;
            try testing.expectEqualStrings("beta two", d.text);
        },
        .added => {
            saw_added = true;
            try testing.expectEqualStrings("BETA TWO", d.text);
        },
        .context => {},
    };
    try testing.expect(saw_removed and saw_added);
}

test "agent_edit: missing and ambiguous old_string are real errors" {
    const alloc = testing.allocator;
    const text = "same\nsame\n";
    try testing.expectError(error.NotFound, createPending(alloc, testMeta(0, 0, text, "absent", "x", false)));
    try testing.expectError(error.Ambiguous, createPending(alloc, testMeta(0, 0, text, "same", "x", false)));
    var all = try createPending(alloc, testMeta(0, 0, text, "same", "x", true));
    defer all.deinit(alloc);
    try testing.expectEqual(@as(u32, 2), all.occurrence_count);
    try testing.expectEqualStrings("x\nx", all.spanReplacement());
}

test "agent_edit: replace_all is one span and a single undo unit" {
    const alloc = testing.allocator;
    const text = "one\ntwo alpha\nthree alpha\nfour\n";
    var pending = try createPending(alloc, testMeta(0, 0, text, "alpha", "ALPHA", true));
    defer pending.deinit(alloc);
    try testing.expectEqual(@as(u32, 2), pending.occurrence_count);
    try testing.expectEqualStrings("ALPHA\nthree ALPHA", pending.spanReplacement());
    // The span starts at the first occurrence and ends after the last one.
    try testing.expectEqual(@as(u32, 8), pending.span_start);
    try testing.expectEqual(@as(u32, 25), pending.span_end);
    try testing.expect(pending.verify(text));
    // Changing only one occurrence makes the count/text differ -> stale.
    try testing.expect(!pending.verify("one\ntwo ALPHA\nthree alpha\nfour\n"));
    try testing.expect(!pending.verify("one\ntwo alpha\nthree alpha\nfour\nfive\n"));
}

test "agent_edit: distant occurrences produce multiple hunks with context" {
    const alloc = testing.allocator;
    const text = "x\n" ++
        "a1\na2\na3\na4\na5\na6\na7\na8\na9\na10\n" ++
        "a11\na12\na13\na14\na15\na16\na17\na18\na19\na20\n" ++
        "x\n";
    var pending = try createPending(alloc, testMeta(0, 0, text, "x", "Y", true));
    defer pending.deinit(alloc);
    try testing.expectEqual(@as(u32, 2), pending.occurrence_count);
    var removed: u32 = 0;
    var added: u32 = 0;
    var separators: usize = 0;
    for (pending.files[0].diff) |d| switch (d.kind) {
        .removed => removed += 1,
        .added => added += 1,
        .context => if (std.mem.eql(u8, d.text, "…")) {
            separators += 1;
        },
    };
    try testing.expectEqual(@as(u32, 2), removed);
    try testing.expectEqual(@as(u32, 2), added);
    try testing.expectEqual(@as(usize, 1), separators);
    try testing.expect(!pending.preview_partial);
}

test "agent_edit: preview is bounded and summarizes omitted occurrences" {
    const alloc = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        if (i % 10 == 0) {
            try text.appendSlice(alloc, "needle line\n");
        } else {
            const line = try std.fmt.allocPrint(alloc, "filler {d}\n", .{i});
            defer alloc.free(line);
            try text.appendSlice(alloc, line);
        }
    }
    var pending = try createPending(alloc, testMeta(0, 0, text.items, "needle", "NEEDLE", true));
    defer pending.deinit(alloc);
    try testing.expect(pending.preview_partial);
    var note_found = false;
    for (pending.files[0].diff) |d| {
        if (std.mem.indexOf(u8, d.text, "more occurrence(s) not shown") != null) note_found = true;
    }
    try testing.expect(note_found);
    try testing.expect(pending.files[0].diff.len <= max_preview_lines + max_preview_hunks + 2);
}

test "agent_edit: pending is thread-scoped and one review at a time" {
    const alloc = testing.allocator;
    var pending = try createPending(alloc, testMeta(3, 0, "a\n", "a", "b", false));
    defer pending.deinit(alloc);
    try testing.expect(pending.isVisibleFor(3));
    try testing.expect(!pending.isVisibleFor(4));
    try testing.expect(canStage(false, false));
    try testing.expect(!canStage(true, false));
    try testing.expect(!canStage(false, true));
    try testing.expect(!canStage(true, true));
}

test "agent_edit: patch pending is one whole-file span and re-verifies exactly" {
    const alloc = testing.allocator;
    var patch = try patch_model.parse(alloc,
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,3 @@
        \\ alpha
        \\-beta
        \\+BETA
        \\ gamma
        \\
    );
    const old_text = "alpha\nbeta\ngamma\n";
    const new_text = try patch_model.apply(alloc, &patch, old_text);
    defer alloc.free(new_text);

    var pending = try createPatchPending(alloc, .{
        .thread_index = 2,
        .card_index = 5,
        .root = "/workspace",
        .path = "/workspace/a.txt",
        .display_path = "a.txt",
        .old_text = old_text,
        .new_text = new_text,
        .patch = &patch,
    });
    defer pending.deinit(alloc);

    try testing.expectEqual(Kind.apply_patch, pending.kind);
    try testing.expectEqualStrings("apply_patch", pending.kind.toolName());
    try testing.expectEqualStrings(stale_patch_label, pending.staleLabel());
    try testing.expectEqual(@as(u32, 0), pending.span_start);
    try testing.expectEqual(@as(u32, @intCast(old_text.len)), pending.span_end);
    try testing.expectEqualStrings(new_text, pending.spanReplacement());
    try testing.expectEqual(@as(u32, 1), pending.removed);
    try testing.expectEqual(@as(u32, 1), pending.added);
    try testing.expectEqual(@as(u32, 1), pending.files[0].first_line);
    try testing.expectEqual(@as(u32, 3), pending.files[0].last_line);
    try testing.expect(!pending.preview_partial);
    try testing.expect(pending.isVisibleFor(2));

    // Full-text snapshots must be byte-identical; the retained patch is then
    // re-applied to prove it still produces the staged result.
    try testing.expect(pending.verify(old_text));
    try testing.expect(pending.verifyPatch(alloc, old_text));
    try testing.expect(!pending.verify("alpha\nBETA\ngamma\n"));
    try testing.expect(!pending.verifyPatch(alloc, "alpha\nBETA\ngamma\n"));
    try testing.expect(!pending.verifyPatch(alloc, "alpha\nbeta\n"));
}

test "agent_edit: patch pending from an empty file and preview truncation" {
    const alloc = testing.allocator;
    var patch = try patch_model.parse(alloc,
        \\--- a/empty.txt
        \\+++ b/empty.txt
        \\@@ -0,0 +1,2 @@
        \\+first
        \\+second
        \\
    );
    const new_text = try patch_model.apply(alloc, &patch, "");
    defer alloc.free(new_text);
    try testing.expectEqualStrings("first\nsecond\n", new_text);

    var pending = try createPatchPending(alloc, .{
        .thread_index = 0,
        .card_index = 0,
        .root = "/workspace",
        .path = "/workspace/empty.txt",
        .display_path = "empty.txt",
        .old_text = "",
        .new_text = new_text,
        .patch = &patch,
    });
    defer pending.deinit(alloc);
    try testing.expect(pending.verify(""));
    try testing.expect(pending.verifyPatch(alloc, ""));
    try testing.expectEqual(@as(u32, 0), pending.removed);
    try testing.expectEqual(@as(u32, 2), pending.added);
    try testing.expect(!pending.verify("x\n"));
}

const FakeCommitSink = struct {
    targets: [2][]const u8,
    temps: [2][]const u8 = .{ "", "" },
    fail_write: ?usize = null,
    fail_rename: ?usize = null,
    restore_fails: bool = false,
    writes: usize = 0,
    renames: usize = 0,
    aborts: usize = 0,
    restores: usize = 0,

    pub fn writeTemp(self: *FakeCommitSink, index: usize, text: []const u8) !void {
        if (self.fail_write == index) return error.DiskFull;
        self.temps[index] = text;
        self.writes += 1;
    }

    pub fn renameTemp(self: *FakeCommitSink, index: usize) !void {
        if (self.fail_rename == index) return error.AccessDenied;
        self.targets[index] = self.temps[index];
        self.temps[index] = "";
        self.renames += 1;
    }

    pub fn abortTemp(self: *FakeCommitSink, index: usize) void {
        self.temps[index] = "";
        self.aborts += 1;
    }

    pub fn restore(self: *FakeCommitSink, index: usize, old_text: []const u8) !void {
        if (self.restore_fails) return error.AccessDenied;
        self.targets[index] = old_text;
        self.restores += 1;
    }
};

test "agent_edit: commitFiles is all-or-nothing before renames and rolls back" {
    const files = [_]CommitFile{
        .{ .path = "a", .old_text = "old-a", .new_text = "new-a" },
        .{ .path = "b", .old_text = "old-b", .new_text = "new-b" },
    };

    {
        var sink = FakeCommitSink{ .targets = .{ "old-a", "old-b" } };
        const outcome = commitFiles(&files, &sink);
        try testing.expectEqual(CommitStatus.committed, outcome.status);
        try testing.expectEqualStrings("new-a", sink.targets[0]);
        try testing.expectEqualStrings("new-b", sink.targets[1]);
        try testing.expectEqual(@as(usize, 2), sink.renames);
    }

    // Temp-write failure: no target is touched; staged temps are removed.
    {
        var sink = FakeCommitSink{ .targets = .{ "old-a", "old-b" }, .fail_write = 1 };
        const outcome = commitFiles(&files, &sink);
        try testing.expectEqual(CommitStatus.write_failed, outcome.status);
        try testing.expectEqual(@as(usize, 1), outcome.failed_index);
        try testing.expectEqualStrings("old-a", sink.targets[0]);
        try testing.expectEqualStrings("old-b", sink.targets[1]);
        try testing.expectEqual(@as(usize, 0), sink.renames);
        try testing.expect(sink.aborts >= 2);
    }

    // Rename failure after the first target: the already-renamed file is
    // restored from its in-memory old text.
    {
        var sink = FakeCommitSink{ .targets = .{ "old-a", "old-b" }, .fail_rename = 1 };
        const outcome = commitFiles(&files, &sink);
        try testing.expectEqual(CommitStatus.rename_failed, outcome.status);
        try testing.expectEqual(@as(usize, 1), outcome.failed_index);
        try testing.expectEqual(@as(usize, 1), outcome.rolled_back);
        try testing.expect(!outcome.rollback_failed);
        try testing.expectEqualStrings("old-a", sink.targets[0]);
        try testing.expectEqualStrings("old-b", sink.targets[1]);
        try testing.expectEqual(@as(usize, 1), sink.restores);
    }

    // A failed rollback is reported, never hidden.
    {
        var sink = FakeCommitSink{
            .targets = .{ "old-a", "old-b" },
            .fail_rename = 1,
            .restore_fails = true,
        };
        const outcome = commitFiles(&files, &sink);
        try testing.expectEqual(CommitStatus.rename_failed, outcome.status);
        try testing.expect(outcome.rollback_failed);
        try testing.expectEqualStrings("new-a", sink.targets[0]);
    }
}

test "agent_edit: multi-file patch pending keeps per-file snapshots and totals" {
    const alloc = testing.allocator;
    var set = try patch_model.parseSet(alloc,
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1,2 +1,2 @@
        \\ keep b
        \\-old b
        \\+new b
        \\
    );
    defer set.deinit(alloc);
    const old_a = "old a\n";
    const old_b = "keep b\nold b\n";
    const new_a = try patch_model.apply(alloc, &set.files[0], old_a);
    defer alloc.free(new_a);
    const new_b = try patch_model.apply(alloc, &set.files[1], old_b);
    defer alloc.free(new_b);

    const metas = [_]PatchFileMeta{
        .{
            .path = "/workspace/a.txt",
            .display_path = "a.txt",
            .old_text = old_a,
            .new_text = new_a,
            .patch = &set.files[0],
        },
        .{
            .path = "/workspace/b.txt",
            .display_path = "b.txt",
            .old_text = old_b,
            .new_text = new_b,
            .patch = &set.files[1],
        },
    };
    var pending = try createPatchSetPending(alloc, .{
        .thread_index = 4,
        .card_index = 9,
        .root = "/workspace",
        .files = &metas,
    });
    defer pending.deinit(alloc);

    try testing.expect(pending.isMulti());
    try testing.expectEqual(@as(usize, 2), pending.files.len);
    try testing.expectEqualStrings("a.txt", pending.files[0].display_path);
    try testing.expectEqualStrings("b.txt", pending.files[1].display_path);
    try testing.expectEqual(@as(u32, 2), pending.removed);
    try testing.expectEqual(@as(u32, 2), pending.added);
    try testing.expect(pending.verifyFile(alloc, 0, old_a));
    try testing.expect(pending.verifyFile(alloc, 1, old_b));
    try testing.expect(!pending.verifyFile(alloc, 0, "changed\n"));
    try testing.expect(!pending.verify(old_a));

    const current = [_][]const u8{ old_a, "stale b\n" };
    try testing.expectEqual(@as(usize, 1), pending.staleFile(alloc, &current).?);
    // The set's patches moved into the pending review; the outer set is now
    // safely empty (and the deferred deinit above remains valid).
    try testing.expectEqual(@as(usize, 0), set.files[0].hunks.len);
    try testing.expectEqual(@as(usize, 0), set.files[1].hunks.len);
}

test "agent_edit: undo set swaps every file's live and target text" {
    const alloc = testing.allocator;
    const entries = try alloc.alloc(UndoEntry, 2);
    entries[0] = .{
        .path = try alloc.dupe(u8, "/workspace/a.txt"),
        .old_text = try alloc.dupe(u8, "old a\n"),
        .new_text = try alloc.dupe(u8, "new a\n"),
    };
    entries[1] = .{
        .path = try alloc.dupe(u8, "/workspace/b.txt"),
        .old_text = try alloc.dupe(u8, "old b\n"),
        .new_text = try alloc.dupe(u8, "new b\n"),
    };
    var set = UndoSet{
        .files = entries,
        .root = try alloc.dupe(u8, "/workspace"),
        .applied = true,
    };
    defer set.deinit(alloc);

    try testing.expectEqualStrings("new a\n", set.liveText(0));
    try testing.expectEqualStrings("old a\n", set.targetText(0));
    try testing.expectEqualStrings("new b\n", set.liveText(1));
    try testing.expectEqualStrings("old b\n", set.targetText(1));

    set.applied = false;
    try testing.expectEqualStrings("old a\n", set.liveText(0));
    try testing.expectEqualStrings("new a\n", set.targetText(0));
    try testing.expectEqualStrings("old b\n", set.liveText(1));
    try testing.expectEqualStrings("new b\n", set.targetText(1));
}
