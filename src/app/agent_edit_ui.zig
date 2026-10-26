//! Staged agent edits (M3b1) — App-facing half.
//!
//! Pure argument/occurrence/preview/pending logic lives in
//! `src/app/agent_edit.zig`. This file owns:
//!   - workspace confinement + read-only target loading at stage time;
//!   - the one-pending interaction with the inline assistant;
//!   - approve (open buffer if needed, stale checks) and reject (no
//!     buffer/history/file change). Single-file edits/patches remain
//!     buffer-only (ONE history group; `:w` writes). Multi-file patches are
//!     one explicit whole-set disk transaction with a cross-file undo unit;
//!   - the Changes review rendering (shared single-file renderer plus the
//!     multi-file file list/active diff) and the `agent_approve` /
//!     `agent_reject` / `agent_patch_file` hint actions;
//!   - thread-scoped visibility: a pending edit is only reviewable/applicable
//!     from the thread that staged it.
//!
//! No tool execution happens here: the executor is never asked to write. A
//! multi-file approve writes the validated set itself (temp+rename); a
//! single-file approve still edits the in-memory buffer only and leaves
//! `:w` as the user's separate action.
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const ai = @import("../ai/root.zig");
const ws = @import("../ai/workspace.zig");
const agent = @import("../ai/agent.zig");
const tool_exec = @import("../ai/tool_exec.zig");
const autil = @import("util.zig");
const inline_ui = @import("inline_ui.zig");
const model = @import("agent_edit.zig");
const patch_model = @import("agent_patch.zig");
const hints = @import("hints.zig");

pub const Session = struct {
    /// At most one staged agent edit (session-wide). Thread-scoped by
    /// `Pending.thread_index`; switching threads hides it but never frees it.
    pending: ?model.Pending = null,
    /// First visible diff line in the Changes body (single-file path).
    scroll: u32 = 0,
    /// Active file in a multi-file review, and one scroll offset per file.
    active_file: usize = 0,
    file_scrolls: [patch_model.max_files]u32 = @splat(0),
    /// Last successful multi-file apply: one explicit cross-file undo unit.
    patch_undo: ?model.UndoSet = null,
};

pub const StageResult = union(enum) {
    staged: struct {
        removed: u32,
        added: u32,
        files: usize,
        /// Owned by the caller; Chat card detail row.
        summary: []u8,
        /// Owned by the caller; truthful `role:"tool"` result text.
        api_text: []u8,
    },
    /// Another review (agent or inline) is already pending/prompting.
    busy,
    /// Owned error text, already prefixed with "error: ".
    failed: []u8,
    oom,
};

pub fn deinitAgentEdit(self: *App) void {
    clearPending(self);
    if (self.agent_edit.patch_undo) |*undo| undo.deinit(self.alloc);
    self.agent_edit.patch_undo = null;
}

pub fn agentEditAnyPending(self: *App) bool {
    return self.agent_edit.pending != null;
}

/// True when the staged edit belongs to the active thread. The Changes badge
/// and review surface use this, so another thread's pending edit is hidden
/// (but preserved).
pub fn agentEditVisible(self: *App) bool {
    const p = if (self.agent_edit.pending) |*pp| pp else return false;
    return p.isVisibleFor(self.ai.threads.active);
}

pub fn agentEditPendingCount(self: *App) u32 {
    return if (agentEditVisible(self)) 1 else 0;
}

/// Workbox badge: one shared review surface for inline and agent edits.
pub fn reviewPendingCount(self: *App) u32 {
    if (self.agentEditVisible() or self.inlinePendingCount() > 0) return 1;
    return 0;
}

fn agentEditMsg(self: *App, text: []const u8) void {
    const copy = self.alloc.dupe(u8, text) catch return;
    self.setMsg(copy) catch self.alloc.free(copy);
}

fn agentEditMsgFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    self.setMsg(text) catch self.alloc.free(text);
}

fn clearPending(self: *App) void {
    if (self.agent_edit.pending) |*p| p.deinit(self.alloc);
    self.agent_edit.pending = null;
    self.agent_edit.scroll = 0;
    self.agent_edit.active_file = 0;
    self.agent_edit.file_scrolls = @splat(0);
}

fn failFmt(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) StageResult {
    const text = std.fmt.allocPrint(alloc, "error: " ++ fmt, args) catch return .oom;
    return .{ .failed = text };
}

fn argFailure(alloc: std.mem.Allocator, e: model.ArgError) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.MalformedArguments => failFmt(alloc, "edit_file arguments are not valid JSON", .{}),
        error.MissingPath => failFmt(alloc, "edit_file requires a path", .{}),
        error.PathNotString => failFmt(alloc, "edit_file argument path must be a string", .{}),
        error.MissingOldString => failFmt(alloc, "edit_file requires old_string", .{}),
        error.OldStringNotString => failFmt(alloc, "edit_file argument old_string must be a string", .{}),
        error.OldStringEmpty => failFmt(alloc, "edit_file argument old_string must not be empty", .{}),
        error.MissingNewString => failFmt(alloc, "edit_file requires new_string", .{}),
        error.NewStringNotString => failFmt(alloc, "edit_file argument new_string must be a string", .{}),
        error.ReplaceAllNotBool => failFmt(alloc, "edit_file argument replace_all must be a boolean", .{}),
    };
}

fn pathFailure(alloc: std.mem.Allocator, raw: []const u8, e: tool_exec.WorkspacePathError) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.Empty => failFmt(alloc, "edit_file requires a non-empty path", .{}),
        error.TooLong => failFmt(alloc, "path is too long (max 4096 bytes)", .{}),
        error.Nul => failFmt(alloc, "path contains a NUL byte", .{}),
        error.Absolute => failFmt(alloc, "absolute paths are not allowed: {s}", .{raw}),
        error.Parent => failFmt(alloc, "path must stay inside the workspace (no '..'): {s}", .{raw}),
    };
}

fn patchArgFailure(alloc: std.mem.Allocator, e: patch_model.ArgError) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.MalformedArguments => failFmt(alloc, "apply_patch arguments are not valid JSON", .{}),
        error.MissingPatch => failFmt(alloc, "apply_patch requires a patch", .{}),
        error.PatchNotString => failFmt(alloc, "apply_patch argument patch must be a string", .{}),
        error.EmptyPatch => failFmt(alloc, "apply_patch requires a non-empty patch", .{}),
    };
}

fn patchParseFailure(alloc: std.mem.Allocator, e: patch_model.ParseError) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.EmptyPatch => failFmt(alloc, "empty patch", .{}),
        error.PatchTooLarge => failFmt(alloc, "patch too large (max {d} KiB)", .{patch_model.max_patch_bytes / 1024}),
        error.NulByte => failFmt(alloc, "patch contains a NUL byte", .{}),
        error.NotUtf8 => failFmt(alloc, "patch is not valid UTF-8", .{}),
        error.MissingPath => failFmt(alloc, "patch has no file path (missing ---/+++ or diff --git)", .{}),
        error.MultiFile => failFmt(alloc, "multi-file patches are not supported; stage one file at a time", .{}),
        error.TooManyFiles => failFmt(alloc, "too many files in one patch (max {d})", .{patch_model.max_files}),
        error.DuplicatePath => failFmt(alloc, "patch contains the same file more than once", .{}),
        error.AddDeleteFile => failFmt(alloc, "creating or deleting files is not supported", .{}),
        error.BinaryPatch => failFmt(alloc, "binary patches are not supported", .{}),
        error.RenameOrCopy => failFmt(alloc, "renames and copies are not supported", .{}),
        error.ModeChange => failFmt(alloc, "file mode changes are not supported", .{}),
        error.MalformedHeader => failFmt(alloc, "malformed patch header", .{}),
        error.MalformedHunk => failFmt(alloc, "malformed patch hunk", .{}),
        error.MalformedCounts => failFmt(alloc, "malformed patch hunk counts", .{}),
        error.NoHunks => failFmt(alloc, "patch has no hunks", .{}),
        error.TooManyHunks => failFmt(alloc, "too many hunks to stage (max {d})", .{patch_model.max_hunks}),
        error.TooManyLines => failFmt(alloc, "too many patch lines (max {d})", .{patch_model.max_hunk_lines}),
        error.PathEmpty => failFmt(alloc, "patch path is empty", .{}),
        error.PathTooLong => failFmt(alloc, "patch path is too long (max 4096 bytes)", .{}),
        error.PathNul => failFmt(alloc, "patch path contains a NUL byte", .{}),
        error.PathAbsolute => failFmt(alloc, "absolute paths are not allowed in patches", .{}),
        error.PathParent => failFmt(alloc, "patch path must stay inside the workspace (no '..')", .{}),
        error.PathMismatch => failFmt(alloc, "patch header paths disagree", .{}),
    };
}

fn patchApplyFailure(alloc: std.mem.Allocator, e: patch_model.ApplyError, rel: []const u8) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.NulByte => failFmt(alloc, "not a text file: {s}", .{rel}),
        error.ContextMismatch => failFmt(alloc, "patch context does not match {s}", .{rel}),
        error.NoNewlineMismatch => failFmt(alloc, "patch newline marker does not match {s}", .{rel}),
        error.OutOfRange => failFmt(alloc, "patch hunk is out of range for {s}", .{rel}),
        error.MalformedHunk => failFmt(alloc, "malformed patch hunk", .{}),
        error.TooLarge => failFmt(alloc, "patched result is too large to stage (max {d} KiB)", .{model.max_stage_bytes / 1024}),
        error.NoChanges => failFmt(alloc, "patch does not change {s}", .{rel}),
    };
}

fn applyFailureReason(alloc: std.mem.Allocator, e: patch_model.ApplyError, rel: []const u8) ![]u8 {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NulByte => std.fmt.allocPrint(alloc, "not a text file: {s}", .{rel}),
        error.ContextMismatch => std.fmt.allocPrint(alloc, "patch context does not match {s}", .{rel}),
        error.NoNewlineMismatch => std.fmt.allocPrint(alloc, "patch newline marker does not match {s}", .{rel}),
        error.OutOfRange => std.fmt.allocPrint(alloc, "patch hunk is out of range for {s}", .{rel}),
        error.MalformedHunk => alloc.dupe(u8, "malformed patch hunk"),
        error.TooLarge => std.fmt.allocPrint(alloc, "patched result is too large to stage (max {d} KiB)", .{model.max_stage_bytes / 1024}),
        error.NoChanges => std.fmt.allocPrint(alloc, "patch does not change {s}", .{rel}),
    };
}

fn issueText(alloc: std.mem.Allocator, path: []const u8, message: []const u8) ![]u8 {
    const detail = if (std.mem.startsWith(u8, message, "error: ")) message["error: ".len..] else message;
    if (std.mem.indexOf(u8, detail, path) != null) return alloc.dupe(u8, detail);
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ path, detail });
}

/// `error: N file(s) rejected: a.txt: reason; b.txt: reason` — every failing
/// file is named, so a multi-file set never collapses into an anonymous error.
fn formatIssueList(alloc: std.mem.Allocator, issues: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "error: ");
    try out.print(alloc, "{d} file(s) rejected: ", .{issues.len});
    for (issues, 0..) |issue, i| {
        if (i > 0) try out.appendSlice(alloc, "; ");
        try out.appendSlice(alloc, issue);
    }
    return out.toOwnedSlice(alloc);
}

fn truncatePath(alloc: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    if (text.len <= max_bytes) return alloc.dupe(u8, text);
    var len = max_bytes;
    // Never split a UTF-8 sequence (paths are validated UTF-8 by parse).
    while (len > 0 and (text[len] & 0xC0) == 0x80) len -= 1;
    return std.fmt.allocPrint(alloc, "{s}…", .{text[0..len]});
}

/// Bounded file list for card text: at most `max_names` names (each capped
/// with an explicit ellipsis when long) plus an explicit `+N more`. There is
/// never a silent cut that could look like a complete list.
fn formatFileList(alloc: std.mem.Allocator, p: *const model.Pending, max_names: usize, max_path_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const shown = @min(max_names, p.files.len);
    for (p.files[0..shown], 0..) |file, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        const name = try truncatePath(alloc, file.display_path, max_path_bytes);
        defer alloc.free(name);
        try out.appendSlice(alloc, name);
    }
    if (shown < p.files.len) {
        try out.print(alloc, " +{d} more", .{p.files.len - shown});
    }
    return out.toOwnedSlice(alloc);
}

/// Chat-card detail + truthful tool result for a freshly staged review.
fn stagedResult(self: *App) StageResult {
    const p = if (self.agent_edit.pending) |*pp| pp else return .oom;
    if (!p.isMulti()) {
        const summary = std.fmt.allocPrint(
            self.alloc,
            "-{d} +{d} · staged · review in Changes",
            .{ p.removed, p.added },
        ) catch return .oom;
        errdefer self.alloc.free(summary);
        const api_text = std.fmt.allocPrint(
            self.alloc,
            "approval required: {s} staged for review; not applied",
            .{p.kind.toolName()},
        ) catch {
            self.alloc.free(summary);
            return .oom;
        };
        return .{ .staged = .{
            .removed = p.removed,
            .added = p.added,
            .files = p.files.len,
            .summary = summary,
            .api_text = api_text,
        } };
    }

    const list = formatFileList(self.alloc, p, 2, 24) catch return .oom;
    defer self.alloc.free(list);
    const summary = std.fmt.allocPrint(
        self.alloc,
        "{d} files · -{d} +{d} · {s}",
        .{ p.files.len, p.removed, p.added, list },
    ) catch return .oom;
    errdefer self.alloc.free(summary);
    const api_list = formatFileList(self.alloc, p, p.files.len, 48) catch {
        self.alloc.free(summary);
        return .oom;
    };
    defer self.alloc.free(api_list);
    const api_text = std.fmt.allocPrint(
        self.alloc,
        "approval required: apply_patch ({d} files: {s}) staged for review; not applied",
        .{ p.files.len, api_list },
    ) catch {
        self.alloc.free(summary);
        return .oom;
    };
    return .{ .staged = .{
        .removed = p.removed,
        .added = p.added,
        .files = p.files.len,
        .summary = summary,
        .api_text = api_text,
    } };
}

fn findBufferByPath(self: *App, path: []const u8) ?usize {
    for (self.buffers.items, 0..) |buf, i| {
        if (buf.path) |got| {
            if (std.mem.eql(u8, got, path)) return i;
        }
    }
    return null;
}

fn bufferTextEquals(self: *App, idx: usize, expected: []const u8) bool {
    if (idx >= self.buffers.items.len) return false;
    const pt = &self.buffers.items[idx].pt;
    if (pt.len() != expected.len) return false;
    const actual = self.alloc.alloc(u8, expected.len) catch return false;
    defer self.alloc.free(actual);
    if (actual.len > 0) pt.copyRange(0, actual);
    return std.mem.eql(u8, actual, expected);
}

fn readDiskText(self: *App, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(model.max_stage_bytes));
}

const ResolvedTarget = struct {
    canonical_root: []u8,
    canonical_path: []u8,
    rel: []u8,

    fn deinit(self: *ResolvedTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.canonical_root);
        alloc.free(self.canonical_path);
        alloc.free(self.rel);
        self.* = undefined;
    }
};

fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: []u8,
        oom,
    };
}

const ResolveOutcome = Outcome(ResolvedTarget);

fn failOutcome(comptime T: type, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Outcome(T) {
    const text = std.fmt.allocPrint(alloc, "error: " ++ fmt, args) catch return .oom;
    return .{ .failed = text };
}

/// Format the failure message first (it may name `rel`), then release the
/// resolution buffers and the path. Freeing before formatting would make the
/// `{s}` argument a use-after-free.
fn failResolved(
    self: *App,
    rel: []u8,
    canonical_root: ?[]u8,
    canonical: ?[]u8,
    comptime fmt: []const u8,
    args: anytype,
) ResolveOutcome {
    const outcome = failOutcome(ResolvedTarget, self.alloc, fmt, args);
    if (canonical) |path| self.alloc.free(path);
    if (canonical_root) |root| self.alloc.free(root);
    self.alloc.free(rel);
    return outcome;
}

/// Resolve a tool-supplied path inside the agent turn's captured workspace
/// root using the shared `tool_exec` confinement rules. Read-only: the file is
/// canonicalized and stat'ed, never opened or written.
fn resolveTarget(self: *App, thread_index: usize, raw_path: []const u8) ResolveOutcome {
    const rel = tool_exec.normalizeWorkspacePath(self.alloc, raw_path) catch |e| {
        return switch (pathFailure(self.alloc, raw_path, e)) {
            .failed => |text| .{ .failed = text },
            .oom => .oom,
            else => unreachable,
        };
    };

    // The agent turn's captured workspace root, not the visible workspace
    // (switching workspaces must not retarget an in-flight turn).
    if (thread_index >= self.ai.tool_states.items.len) {
        return failResolved(self, rel, null, null, "workspace root unavailable", .{});
    }
    const root = self.ai.tool_states.items[thread_index].root orelse {
        return failResolved(self, rel, null, null, "workspace root unavailable", .{});
    };

    const canonical_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.alloc) catch |e| switch (e) {
        error.OutOfMemory => {
            self.alloc.free(rel);
            return .oom;
        },
        else => {
            self.alloc.free(rel);
            return failOutcome(ResolvedTarget, self.alloc, "workspace root unavailable", .{});
        },
    };

    if (std.mem.eql(u8, rel, ".")) {
        return failResolved(self, rel, canonical_root, null, "not a regular file: {s}", .{rel});
    }
    const joined = std.fs.path.join(self.alloc, &.{ canonical_root, rel }) catch {
        self.alloc.free(rel);
        self.alloc.free(canonical_root);
        return .oom;
    };
    defer self.alloc.free(joined);

    const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, self.alloc) catch |e| switch (e) {
        error.OutOfMemory => {
            self.alloc.free(rel);
            self.alloc.free(canonical_root);
            return .oom;
        },
        error.FileNotFound, error.NotDir => return failResolved(self, rel, canonical_root, null, "not found: {s}", .{rel}),
        error.AccessDenied, error.PermissionDenied => return failResolved(self, rel, canonical_root, null, "unreadable: {s}", .{rel}),
        else => return failResolved(self, rel, canonical_root, null, "cannot resolve: {s}", .{rel}),
    };

    if (!tool_exec.isWithin(canonical_root, canonical)) {
        return failResolved(self, rel, canonical_root, canonical, "path escapes workspace: {s}", .{rel});
    }

    const stat = std.Io.Dir.cwd().statFile(self.io, canonical, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return failResolved(self, rel, canonical_root, canonical, "not found: {s}", .{rel}),
        error.AccessDenied, error.PermissionDenied => return failResolved(self, rel, canonical_root, canonical, "unreadable: {s}", .{rel}),
        else => return failResolved(self, rel, canonical_root, canonical, "cannot stat: {s}", .{rel}),
    };
    if (stat.kind != .file) {
        return failResolved(self, rel, canonical_root, canonical, "not a regular file: {s}", .{rel});
    }

    return .{ .ok = .{
        .canonical_root = canonical_root,
        .canonical_path = canonical,
        .rel = rel,
    } };
}

const LoadedText = struct {
    text: []u8,
    buffer_index: ?usize,
    revision: ?u64,

    fn deinit(self: *LoadedText, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

const TextOutcome = Outcome(LoadedText);

/// Read the target read-only: the already-open buffer (including unsaved
/// edits) if there is one, otherwise the file on disk. Neither path opens a
/// buffer or touches the dirty flag.
fn loadTargetText(self: *App, canonical: []const u8, rel: []const u8) TextOutcome {
    if (findBufferByPath(self, canonical)) |idx| {
        const pt = &self.buffers.items[idx].pt;
        if (pt.len() > model.max_stage_bytes) {
            return failOutcome(LoadedText, self.alloc, "file too large to stage (max {d} KiB)", .{model.max_stage_bytes / 1024});
        }
        const copy = self.alloc.alloc(u8, pt.len()) catch return .oom;
        if (copy.len > 0) pt.copyRange(0, copy);
        return .{ .ok = .{
            .text = copy,
            .buffer_index = idx,
            .revision = self.buffers.items[idx].history.revision,
        } };
    }

    const text = readDiskText(self, canonical) catch |e| switch (e) {
        error.OutOfMemory => return .oom,
        error.StreamTooLong => return failOutcome(LoadedText, self.alloc, "file too large to stage (max {d} KiB)", .{model.max_stage_bytes / 1024}),
        error.FileNotFound, error.NotDir => return failOutcome(LoadedText, self.alloc, "not found: {s}", .{rel}),
        error.AccessDenied, error.PermissionDenied => return failOutcome(LoadedText, self.alloc, "unreadable: {s}", .{rel}),
        else => return failOutcome(LoadedText, self.alloc, "cannot read: {s}", .{rel}),
    };

    if (std.mem.indexOfScalar(u8, text, 0) != null) {
        self.alloc.free(text);
        return failOutcome(LoadedText, self.alloc, "not a text file: {s}", .{rel});
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        self.alloc.free(text);
        return failOutcome(LoadedText, self.alloc, "not valid UTF-8 text: {s}", .{rel});
    }
    return .{ .ok = .{
        .text = text,
        .buffer_index = null,
        .revision = null,
    } };
}

fn openReviewSurface(self: *App) void {
    // Show the review surface exactly like the inline assistant: rail open,
    // Changes tab, badge 1. The buffer and the file remain untouched.
    self.ensureAi() catch {};
    self.ai.rail_open = true;
    self.ai.tab = .changes;
    self.ai.focus = .rail;
    self.ai.rail_pending_leader = false;
    self.ai.thread_cursor = self.ai.threads.active;
    self.pending_window = false;
    self.pending_replace = null;
}

fn reviewInlineBusy(self: *App) bool {
    return self.inline_edit.pending != null or
        self.inline_edit.prompt_open or
        self.inline_edit.request_active;
}

/// Stage one `edit_file` call. On success the diff review is open and the
/// caller owns formatting the tool card. The target file is only read — never
/// written, never opened as a buffer here (approve does that).
pub fn stageToolCall(
    self: *App,
    thread_index: usize,
    card_index: usize,
    call: ai.tools.ToolCall,
) StageResult {
    // One review at a time, including an inline prompt/stream that has not
    // completed yet. This is what prevents two pending surfaces coexisting.
    if (!model.canStage(self.agentEditAnyPending(), reviewInlineBusy(self))) return .busy;

    var args = model.parseArgs(self.alloc, call.arguments_json) catch |e| return argFailure(self.alloc, e);
    defer args.deinit(self.alloc);

    var target = switch (resolveTarget(self, thread_index, args.path)) {
        .ok => |t| t,
        .failed => |text| return .{ .failed = text },
        .oom => return .oom,
    };
    defer target.deinit(self.alloc);

    var loaded = switch (loadTargetText(self, target.canonical_path, target.rel)) {
        .ok => |t| t,
        .failed => |text| return .{ .failed = text },
        .oom => return .oom,
    };
    defer loaded.deinit(self.alloc);

    const pending = model.createPending(self.alloc, .{
        .thread_index = thread_index,
        .card_index = card_index,
        .root = target.canonical_root,
        .path = target.canonical_path,
        .display_path = target.rel,
        .text = loaded.text,
        .old_string = args.old_string,
        .new_string = args.new_string,
        .replace_all = args.replace_all,
        .buffer_index = loaded.buffer_index,
        .revision = loaded.revision,
    }) catch |e| switch (e) {
        error.OutOfMemory => return .oom,
        error.OldStringEmpty => return failFmt(self.alloc, "old_string must not be empty", .{}),
        error.NotFound => return failFmt(self.alloc, "old_string was not found in {s}", .{target.rel}),
        error.Ambiguous => return failFmt(self.alloc, "old_string occurs more than once in {s}; set replace_all or use a unique string", .{target.rel}),
        error.TooManyOccurrences => return failFmt(self.alloc, "too many occurrences to stage (max {d})", .{model.max_occurrences}),
    };

    self.agent_edit.pending = pending;
    self.agent_edit.scroll = 0;
    self.agent_edit.active_file = 0;
    self.agent_edit.file_scrolls = @splat(0);
    openReviewSurface(self);
    return stagedResult(self);
}

/// Stage one `apply_patch` call. One file keeps the historical whole-file
/// buffer-replacement behavior; 2..max_files files stage one multi-file
/// review and, after approval, write the whole set to disk. Parsing, path
/// confinement, target loading and hunk application are all read-only; the
/// buffer, its history, the dirty flag and every file are untouched until a
/// human approve.
pub fn stagePatchToolCall(
    self: *App,
    thread_index: usize,
    card_index: usize,
    call: ai.tools.ToolCall,
) StageResult {
    if (!model.canStage(self.agentEditAnyPending(), reviewInlineBusy(self))) return .busy;

    var args = patch_model.parseArgs(self.alloc, call.arguments_json) catch |e| {
        return patchArgFailure(self.alloc, e);
    };
    defer args.deinit(self.alloc);

    var set = patch_model.parseSet(self.alloc, args.patch) catch |e| {
        return patchParseFailure(self.alloc, e);
    };
    if (set.files.len == 1) {
        var patch = set.takeFile(0);
        set.deinit(self.alloc);
        return stageOnePatch(self, thread_index, card_index, &patch);
    }
    return stageMultiPatch(self, thread_index, card_index, &set);
}

fn stageOnePatch(
    self: *App,
    thread_index: usize,
    card_index: usize,
    patch: *patch_model.Patch,
) StageResult {
    var target = switch (resolveTarget(self, thread_index, patch.path)) {
        .ok => |t| t,
        .failed => |text| {
            patch.deinit(self.alloc);
            return .{ .failed = text };
        },
        .oom => {
            patch.deinit(self.alloc);
            return .oom;
        },
    };
    defer target.deinit(self.alloc);

    var loaded = switch (loadTargetText(self, target.canonical_path, target.rel)) {
        .ok => |t| t,
        .failed => |text| {
            patch.deinit(self.alloc);
            return .{ .failed = text };
        },
        .oom => {
            patch.deinit(self.alloc);
            return .oom;
        },
    };
    defer loaded.deinit(self.alloc);

    const new_text = patch_model.apply(self.alloc, patch, loaded.text) catch |e| {
        patch.deinit(self.alloc);
        return patchApplyFailure(self.alloc, e, target.rel);
    };
    defer self.alloc.free(new_text);

    const pending = model.createPatchPending(self.alloc, .{
        .thread_index = thread_index,
        .card_index = card_index,
        .root = target.canonical_root,
        .path = target.canonical_path,
        .display_path = target.rel,
        .old_text = loaded.text,
        .new_text = new_text,
        .buffer_index = loaded.buffer_index,
        .revision = loaded.revision,
        .patch = patch,
    }) catch |e| {
        patch.deinit(self.alloc);
        return switch (e) {
            error.OutOfMemory => .oom,
        };
    };

    self.agent_edit.pending = pending;
    self.agent_edit.scroll = 0;
    self.agent_edit.active_file = 0;
    self.agent_edit.file_scrolls = @splat(0);
    openReviewSurface(self);
    return stagedResult(self);
}

fn applyErrorShort(e: patch_model.ApplyError) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out of memory",
        error.NulByte => "not a text file",
        error.ContextMismatch => "patch context mismatch",
        error.NoNewlineMismatch => "newline marker mismatch",
        error.OutOfRange => "hunk out of range",
        error.MalformedHunk => "malformed hunk",
        error.TooLarge => "patched result too large",
        error.NoChanges => "patch would not change the file",
    };
}

/// Stage a validated 2..max_files set. Every target is resolved, loaded and
/// hunk-applied before the review is created; any failure collects a per-file
/// reason list and stages nothing. `set` is consumed on failure and its
/// patches move into the pending review on success.
fn stageMultiPatch(
    self: *App,
    thread_index: usize,
    card_index: usize,
    set: *patch_model.PatchSet,
) StageResult {
    var set_owned = true;
    defer if (set_owned) set.deinit(self.alloc);

    const n = set.files.len;
    const alloc = self.alloc;
    const targets = alloc.alloc(ResolvedTarget, n) catch return .oom;
    var target_count: usize = 0;
    defer {
        for (targets[0..target_count]) |*target| target.deinit(alloc);
        alloc.free(targets);
    }
    const loaded = alloc.alloc(LoadedText, n) catch return .oom;
    var loaded_count: usize = 0;
    defer {
        for (loaded[0..loaded_count]) |*text| text.deinit(alloc);
        alloc.free(loaded);
    }
    var issues: std.ArrayList([]u8) = .empty;
    defer {
        for (issues.items) |issue| alloc.free(issue);
        issues.deinit(alloc);
    }

    for (set.files) |*file| {
        const target = switch (resolveTarget(self, thread_index, file.path)) {
            .ok => |t| t,
            .failed => |text| {
                defer alloc.free(text);
                issues.append(alloc, issueText(alloc, file.path, text) catch return .oom) catch return .oom;
                continue;
            },
            .oom => return .oom,
        };
        var duplicate = false;
        for (targets[0..target_count]) |*previous| {
            if (std.mem.eql(u8, previous.canonical_path, target.canonical_path)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            var owned = target;
            owned.deinit(alloc);
            issues.append(alloc, std.fmt.allocPrint(
                alloc,
                "{s}: duplicate target after symlink resolution",
                .{file.path},
            ) catch return .oom) catch return .oom;
            continue;
        }
        if (target_count > 0 and !std.mem.eql(u8, targets[0].canonical_root, target.canonical_root)) {
            var owned = target;
            owned.deinit(alloc);
            issues.append(alloc, std.fmt.allocPrint(
                alloc,
                "{s}: workspace root changed while resolving",
                .{file.path},
            ) catch return .oom) catch return .oom;
            continue;
        }
        targets[target_count] = target;
        target_count += 1;

        const text = switch (loadTargetText(self, target.canonical_path, target.rel)) {
            .ok => |t| t,
            .failed => |message| {
                defer alloc.free(message);
                issues.append(alloc, issueText(alloc, target.rel, message) catch return .oom) catch return .oom;
                continue;
            },
            .oom => return .oom,
        };
        loaded[loaded_count] = text;
        loaded_count += 1;
    }

    if (issues.items.len > 0 or loaded_count != n or target_count != n) {
        return .{ .failed = formatIssueList(alloc, issues.items) catch return .oom };
    }

    const old_texts = alloc.alloc([]const u8, n) catch return .oom;
    defer alloc.free(old_texts);
    for (loaded, 0..) |*text, i| old_texts[i] = text.text;

    const validation = patch_model.validateSet(alloc, set, old_texts) catch |e| switch (e) {
        error.OutOfMemory => return .oom,
    };
    switch (validation) {
        .rejected => |validation_issues| {
            defer alloc.free(validation_issues);
            var reasons: std.ArrayList([]u8) = .empty;
            defer {
                for (reasons.items) |reason| alloc.free(reason);
                reasons.deinit(alloc);
            }
            for (validation_issues) |issue| {
                const reason = std.fmt.allocPrint(
                    alloc,
                    "{s}: {s}",
                    .{ issue.path, applyErrorShort(issue.err) },
                ) catch return .oom;
                reasons.append(alloc, reason) catch {
                    alloc.free(reason);
                    return .oom;
                };
            }
            return .{ .failed = formatIssueList(alloc, reasons.items) catch return .oom };
        },
        .ok => |new_texts| {
            defer {
                for (new_texts) |text| alloc.free(text);
                alloc.free(new_texts);
            }
            const metas = alloc.alloc(model.PatchFileMeta, n) catch return .oom;
            defer alloc.free(metas);
            for (metas, 0..) |*meta, i| {
                meta.* = .{
                    .path = targets[i].canonical_path,
                    .display_path = targets[i].rel,
                    .old_text = loaded[i].text,
                    .new_text = new_texts[i],
                    .buffer_index = loaded[i].buffer_index,
                    .revision = loaded[i].revision,
                    .patch = &set.files[i],
                };
            }
            const pending = model.createPatchSetPending(alloc, .{
                .thread_index = thread_index,
                .card_index = card_index,
                .root = targets[0].canonical_root,
                .files = metas,
            }) catch |e| switch (e) {
                error.OutOfMemory => return .oom,
            };
            // Patches now belong to the pending review, not to `set`.
            set_owned = false;
            self.agent_edit.pending = pending;
            self.agent_edit.scroll = 0;
            self.agent_edit.active_file = 0;
            self.agent_edit.file_scrolls = @splat(0);
            openReviewSurface(self);
            return stagedResult(self);
        },
    }
}

fn updateCard(self: *App, p: *const model.Pending, status: ws.ToolStatus, text: []const u8) void {
    if (p.thread_index >= self.ai.threads.items.items.len) return;
    const t = &self.ai.threads.items.items[p.thread_index];
    if (p.card_index >= t.messages.items.len) return;
    const msg = &t.messages.items[p.card_index];
    if (msg.role != .tool or msg.tool_name == null) return;
    if (!std.mem.eql(u8, msg.tool_name.?, p.kind.toolName())) return;
    self.ai.threads.setToolDecision(self.alloc, p.thread_index, p.card_index, status, text);
}

fn recordDecision(self: *App, p: *const model.Pending, verdict: agent.Verdict) void {
    if (p.thread_index >= self.ai.tool_states.items.len) return;
    self.ai.tool_states.items[p.thread_index].metrics.recordDecision(self.alloc, p.kind.toolName(), verdict);
}

fn markStale(self: *App, p: *model.Pending, file: ?[]const u8) void {
    p.stale = true;
    if (file) |f| {
        if (p.stale_file) |old| self.alloc.free(old);
        p.stale_file = self.alloc.dupe(u8, f) catch null;
    }
    const label = p.staleLabel();
    if (p.isMulti()) {
        const detail = std.fmt.allocPrint(
            self.alloc,
            "{d} files · -{d} +{d} · {s}: {s}",
            .{ p.files.len, p.removed, p.added, label, file orelse p.files[0].display_path },
        ) catch null;
        if (detail) |t| {
            defer self.alloc.free(t);
            updateCard(self, p, .approval_required, t);
            agentEditMsg(self, t);
        } else agentEditMsg(self, label);
        return;
    }
    const text = std.fmt.allocPrint(
        self.alloc,
        "-{d} +{d} · {s}",
        .{ p.removed, p.added, label },
    ) catch null;
    if (text) |t| {
        defer self.alloc.free(t);
        updateCard(self, p, .approval_required, t);
    }
    agentEditMsg(self, label);
}

fn copyBufferText(self: *App, idx: usize) ?[]u8 {
    if (idx >= self.buffers.items.len) return null;
    const pt = &self.buffers.items[idx].pt;
    if (pt.len() > model.max_stage_bytes) return null;
    const copy = self.alloc.alloc(u8, pt.len()) catch return null;
    if (copy.len > 0) pt.copyRange(0, copy);
    return copy;
}

const FileCurrent = struct { text: []u8, buffer_index: ?usize };

/// Current text for one staged file plus the open buffer (if any). The buffer
/// history revision is checked when the file was staged from a buffer, and a
/// disk-staged target is re-canonicalized under the captured root so a path
/// replaced by an outside symlink is stale.
fn currentFileText(self: *App, p: *const model.Pending, index: usize) ?FileCurrent {
    const file = &p.files[index];
    if (findBufferByPath(self, file.path)) |buf_idx| {
        if (file.revision) |rev| {
            if (self.buffers.items[buf_idx].history.revision != rev) return null;
        }
        const text = copyBufferText(self, buf_idx) orelse return null;
        return .{ .text = text, .buffer_index = buf_idx };
    }
    const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, file.path, self.alloc) catch return null;
    defer self.alloc.free(canonical_now);
    if (!std.mem.eql(u8, canonical_now, file.path) or !tool_exec.isWithin(p.root, canonical_now)) return null;
    const disk = readDiskText(self, file.path) catch return null;
    return .{ .text = disk, .buffer_index = null };
}

fn freeCurrent(self: *App, current: []FileCurrent, initialized: usize) void {
    for (current[0..initialized]) |item| self.alloc.free(item.text);
}

/// Replace one open buffer with a verified full text as one history group.
/// The caller has already committed the same bytes to disk, so the buffer is
/// clean afterwards; non-current buffers stay unsynced until their next
/// `ensureLsp` full-text switch.
fn replaceBufferText(self: *App, idx: usize, text: []const u8) !void {
    if (idx >= self.buffers.items.len) return;
    const buf = &self.buffers.items[idx];
    buf.history.beginGroup();
    try buf.history.record(&buf.pt, 0, buf.pt.len(), text);
    buf.history.endGroup();
    buf.dirty = false;
    buf.folds.clearRetainingCapacity();
    self.clearSpanCache(buf);
    for (self.windows.items) |*window| {
        if (window.buf == idx) {
            window.cursor = @min(window.cursor, buf.pt.len());
            window.view_top = @min(window.view_top, buf.pt.lineCount());
        }
    }
    if (idx == self.current) {
        self.invalidateInlayHints();
        self.syncLspFull();
    }
    self.edit_seq +|= 1;
}

/// Replace a buffer that was opened AFTER the multi-file apply (so it has no
/// apply history group) without inventing a fake history entry. Verified
/// text equality happened before this call; the stale undo/redo stacks are
/// dropped because their offsets describe a different document lineage.
fn replaceBufferTextDirect(self: *App, idx: usize, text: []const u8) !void {
    if (idx >= self.buffers.items.len) return;
    const buf = &self.buffers.items[idx];
    _ = try buf.pt.replace(0, buf.pt.len(), text);
    for (buf.history.undo_stack.items) |*group| group.deinit(self.alloc);
    buf.history.undo_stack.clearRetainingCapacity();
    for (buf.history.redo_stack.items) |*group| group.deinit(self.alloc);
    buf.history.redo_stack.clearRetainingCapacity();
    buf.history.revision +%= 1;
    buf.history.last_record = null;
    afterBufferHistory(self, idx);
}

fn updateBufferAfterDisk(self: *App, current: []const FileCurrent, p: *const model.Pending) bool {
    var ok = true;
    for (current, 0..) |item, i| {
        const idx = item.buffer_index orelse continue;
        replaceBufferText(self, idx, p.files[i].new_text) catch {
            ok = false;
        };
    }
    return ok;
}

const PatchWriteSink = struct {
    app: *App,
    paths: []const []const u8,
    tmp_paths: []const []u8,

    pub fn writeOne(self: *PatchWriteSink, index: usize, text: []const u8) !void {
        const target = self.paths[index];
        var flags: std.Io.Dir.CreateFileOptions = .{ .truncate = true };
        if (std.Io.Dir.cwd().statFile(self.app.io, target, .{ .follow_symlinks = false })) |stat| {
            // Preserve the original mode (executable bit etc.).
            flags.permissions = stat.permissions;
        } else |_| {}
        var file = try std.Io.Dir.cwd().createFile(self.app.io, self.tmp_paths[index], flags);
        defer file.close(self.app.io);
        try file.writeStreamingAll(self.app.io, text);
    }

    pub fn writeTemp(self: *PatchWriteSink, index: usize, text: []const u8) !void {
        return self.writeOne(index, text);
    }

    pub fn renameTemp(self: *PatchWriteSink, index: usize) !void {
        try std.Io.Dir.cwd().rename(self.tmp_paths[index], std.Io.Dir.cwd(), self.paths[index], self.app.io);
    }

    pub fn abortTemp(self: *PatchWriteSink, index: usize) void {
        std.Io.Dir.cwd().deleteFile(self.app.io, self.tmp_paths[index]) catch {};
    }

    pub fn restore(self: *PatchWriteSink, index: usize, old_text: []const u8) !void {
        try self.writeOne(index, old_text);
        try self.renameTemp(index);
    }
};

/// Build the cross-file undo snapshot after a successful multi-file apply.
fn buildUndoSet(
    self: *App,
    p: *const model.Pending,
    current: []const FileCurrent,
) ?model.UndoSet {
    const entries = self.alloc.alloc(model.UndoEntry, p.files.len) catch return null;
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(self.alloc);
        self.alloc.free(entries);
    }
    for (p.files, 0..) |*file, i| {
        var entry = model.UndoEntry{
            .path = &.{},
            .old_text = &.{},
            .new_text = &.{},
            .buffer_index = current[i].buffer_index,
            .open_at_apply = current[i].buffer_index != null,
            .revision = if (current[i].buffer_index) |idx|
                self.buffers.items[idx].history.revision
            else
                null,
        };
        entry.path = self.alloc.dupe(u8, file.path) catch {
            entry.deinit(self.alloc);
            return null;
        };
        entry.old_text = self.alloc.dupe(u8, file.text) catch {
            entry.deinit(self.alloc);
            return null;
        };
        entry.new_text = self.alloc.dupe(u8, file.new_text) catch {
            entry.deinit(self.alloc);
            return null;
        };
        entries[i] = entry;
        initialized += 1;
    }
    return .{
        .files = entries,
        .root = self.alloc.dupe(u8, p.root) catch {
            for (entries[0..initialized]) |*entry| entry.deinit(self.alloc);
            self.alloc.free(entries);
            return null;
        },
        .applied = true,
    };
}

fn commitOutcomeMessage(self: *App, p: *const model.Pending, outcome: model.CommitOutcome) ?[]u8 {
    const failed = &p.files[outcome.failed_index];
    return switch (outcome.status) {
        .committed => std.fmt.allocPrint(self.alloc, "committed", .{}) catch null,
        .write_failed => std.fmt.allocPrint(
            self.alloc,
            "error: write failed for {s}; no files written",
            .{failed.display_path},
        ) catch null,
        .rename_failed => if (outcome.rollback_failed)
            std.fmt.allocPrint(
                self.alloc,
                "error: write failed for {s}; rollback incomplete — some files may be applied",
                .{failed.display_path},
            ) catch null
        else
            std.fmt.allocPrint(
                self.alloc,
                "error: write failed for {s}; rolled back {d} file(s)",
                .{ failed.display_path, outcome.rolled_back },
            ) catch null,
    };
}

/// Multi-file approve: validate every file, then commit the whole set with a
/// two-phase temp+rename transaction. Nothing is written when any file is
/// stale; open buffers are updated (clean, one history group) after the disk
/// transaction succeeds. One explicit cross-file undo snapshot is stored.
fn approveMulti(self: *App, p: *model.Pending) !void {
    const n = p.files.len;
    const current = self.alloc.alloc(FileCurrent, n) catch {
        agentEditMsg(self, "agent patch: out of memory");
        return;
    };
    var current_count: usize = 0;
    defer {
        freeCurrent(self, current, current_count);
        self.alloc.free(current);
    }
    var stale_index: ?usize = null;
    var stale_reason: ?[]const u8 = null;
    for (p.files, 0..) |_, i| {
        const item = currentFileText(self, p, i) orelse {
            stale_index = i;
            stale_reason = p.files[i].display_path;
            break;
        };
        current[current_count] = item;
        current_count += 1;
        if (!p.verifyFile(self.alloc, i, item.text)) {
            stale_index = i;
            stale_reason = p.files[i].display_path;
            break;
        }
    }
    if (stale_index) |_| {
        markStale(self, p, stale_reason);
        return;
    }
    for (p.files) |file| {
        if (!tool_exec.isWithin(p.root, file.path)) {
            markStale(self, p, file.display_path);
            return;
        }
        // Re-resolve immediately before the write: a path or symlink swapped
        // after staging must reject the set instead of redirecting a write.
        const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, file.path, self.alloc) catch {
            markStale(self, p, file.display_path);
            return;
        };
        defer self.alloc.free(canonical_now);
        if (!std.mem.eql(u8, canonical_now, file.path) or !tool_exec.isWithin(p.root, canonical_now)) {
            markStale(self, p, file.display_path);
            return;
        }
    }

    const plan = self.alloc.alloc(model.CommitFile, n) catch {
        agentEditMsg(self, "agent patch: out of memory");
        return;
    };
    defer self.alloc.free(plan);
    const tmp_paths = self.alloc.alloc([]u8, n) catch {
        agentEditMsg(self, "agent patch: out of memory");
        return;
    };
    var tmp_count: usize = 0;
    defer {
        for (tmp_paths[0..tmp_count]) |tmp| {
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            self.alloc.free(tmp);
        }
        self.alloc.free(tmp_paths);
    }
    for (p.files, 0..) |file, i| {
        plan[i] = .{ .path = file.path, .old_text = file.text, .new_text = file.new_text };
        tmp_paths[i] = std.fmt.allocPrint(
            self.alloc,
            "{s}.ozpatch{d}.{d}",
            .{ file.path, std.c.getpid(), i },
        ) catch {
            agentEditMsg(self, "agent patch: out of memory");
            return;
        };
        tmp_count += 1;
    }

    const paths = self.alloc.alloc([]const u8, n) catch {
        agentEditMsg(self, "agent patch: out of memory");
        return;
    };
    defer self.alloc.free(paths);
    for (p.files, 0..) |file, i| paths[i] = file.path;
    var sink = PatchWriteSink{ .app = self, .paths = paths, .tmp_paths = tmp_paths };
    const outcome = model.commitFiles(plan, &sink);
    if (outcome.status != .committed) {
        if (commitOutcomeMessage(self, p, outcome)) |message| {
            defer self.alloc.free(message);
            updateCard(self, p, .err, message);
            agentEditMsg(self, message);
        } else {
            agentEditMsg(self, "error: write failed; no files applied");
        }
        if (outcome.rollback_failed) p.stale = true;
        return;
    }

    const refreshed = updateBufferAfterDisk(self, current, p);
    // If none of the targets was open, open the first result so the user can
    // see what was written. This reads the just-committed disk bytes.
    var any_open = false;
    for (current) |item| {
        if (item.buffer_index != null) {
            any_open = true;
            break;
        }
    }
    if (!any_open) {
        self.openInBuffer(p.files[0].path) catch {};
    }

    const undo = if (refreshed) buildUndoSet(self, p, current) else null;
    if (undo == null) {
        if (!refreshed) {
            agentEditMsg(self, "agent patch applied to disk · some buffers could not refresh; undo unavailable for this set");
        } else {
            agentEditMsg(self, "agent patch: applied, but the cross-file undo snapshot could not be allocated");
        }
        // The files are on disk and buffers are updated; do not claim an undo
        // unit that does not exist.
        const text = std.fmt.allocPrint(
            self.alloc,
            "{d} files · -{d} +{d} · applied to disk (undo unavailable)",
            .{ p.files.len, p.removed, p.added },
        ) catch null;
        if (text) |t| {
            defer self.alloc.free(t);
            updateCard(self, p, .approved, t);
        }
        recordDecision(self, p, .approved);
        clearPending(self);
        return;
    }
    if (self.agent_edit.patch_undo) |*old| old.deinit(self.alloc);
    self.agent_edit.patch_undo = undo;

    const text = std.fmt.allocPrint(
        self.alloc,
        "{d} files · -{d} +{d} · applied to disk · u to undo",
        .{ p.files.len, p.removed, p.added },
    ) catch null;
    if (text) |t| {
        defer self.alloc.free(t);
        updateCard(self, p, .approved, t);
    }
    recordDecision(self, p, .approved);
    self.state.mode = .normal;
    self.visual_anchor = null;
    self.in_insert = false;
    self.focus = .buffer;
    self.ai.focus = .editor;
    self.gitMarksStaleNow();
    self.scheduleGitStatus();
    clearPending(self);
    if (refreshed) {
        agentEditMsgFmt(self, "agent patch approved · {d} files written · u to undo", .{n});
    } else {
        agentEditMsgFmt(self, "agent patch applied to disk · {d} files · some buffers could not refresh; reopen them", .{n});
    }
}

/// Approve: verify staleness, then either apply the historical single-file
/// buffer replacement (one history group, disk untouched until `:w`) or run
/// the multi-file disk transaction.
pub fn agentEditApprove(self: *App) !void {
    if (self.agent_edit.pending == null) return;
    if (!agentEditVisible(self)) {
        agentEditMsg(self, "agent edit: switch to its thread first");
        return;
    }
    const p = &self.agent_edit.pending.?;
    if (p.stale) {
        agentEditMsg(self, p.staleLabel());
        return;
    }
    if (p.isMulti()) {
        try approveMulti(self, p);
        return;
    }

    const file = &p.files[0];
    var buf_idx = findBufferByPath(self, file.path);
    if (buf_idx == null) {
        // The target was not open at stage time. Re-canonicalize it under the
        // captured root (a path replaced by an outside symlink is stale) and
        // re-read it read-only; require the whole snapshot to still match
        // before opening a buffer.
        const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, file.path, self.alloc) catch {
            markStale(self, p, null);
            return;
        };
        defer self.alloc.free(canonical_now);
        if (!std.mem.eql(u8, canonical_now, file.path) or !tool_exec.isWithin(p.root, canonical_now)) {
            markStale(self, p, null);
            return;
        }
        const disk = readDiskText(self, file.path) catch {
            markStale(self, p, null);
            return;
        };
        defer self.alloc.free(disk);
        if (!p.verify(disk)) {
            markStale(self, p, null);
            return;
        }
        self.openInBuffer(file.path) catch {
            markStale(self, p, null);
            return;
        };
        buf_idx = findBufferByPath(self, file.path) orelse {
            markStale(self, p, null);
            return;
        };
    }
    const idx = buf_idx.?;
    // Staged from a buffer: the exact document revision must still match.
    if (file.revision) |rev| {
        if (idx >= self.buffers.items.len or self.buffers.items[idx].history.revision != rev) {
            markStale(self, p, null);
            return;
        }
    }
    // Exact text identity + occurrence count (also covers a buffer that was
    // opened or edited externally after staging from disk).
    const current_text = copyBufferText(self, idx) orelse {
        markStale(self, p, null);
        return;
    };
    defer self.alloc.free(current_text);
    if (!p.verify(current_text)) {
        markStale(self, p, null);
        return;
    }
    // A patch must additionally still produce the exact staged result; this
    // re-runs the retained hunks instead of trusting the snapshot alone.
    if (!p.verifyPatch(self.alloc, current_text)) {
        markStale(self, p, null);
        return;
    }
    if (self.windows.items[self.current_win].buf != idx) self.switchTo(idx);

    self.applyEdit(p.span_start, p.span_end, p.spanReplacement()) catch |e| {
        agentEditMsgFmt(self, "agent edit apply failed: {s}", .{@errorName(e)});
        return;
    };
    self.curCursor().* = @min(p.span_start, self.cur().pt.len());
    self.state.mode = .normal;
    self.visual_anchor = null;
    self.in_insert = false;
    self.focus = .buffer;
    self.ai.focus = .editor;
    // A new single-file apply is now the most recent action; the previous
    // multi-file set is no longer the obvious undo unit.
    if (self.agent_edit.patch_undo) |*old| old.deinit(self.alloc);
    self.agent_edit.patch_undo = null;

    const text = std.fmt.allocPrint(
        self.alloc,
        "-{d} +{d} · applied · u to undo",
        .{ p.removed, p.added },
    ) catch null;
    if (text) |t| {
        defer self.alloc.free(t);
        updateCard(self, p, .approved, t);
    }
    recordDecision(self, p, .approved);
    const approved_toast = switch (p.kind) {
        .edit_file => "agent edit approved · u to undo",
        .apply_patch => "agent patch approved · u to undo",
    };
    clearPending(self);
    agentEditMsg(self, approved_toast);
}

/// Reject: discard the staged diff. The buffer, its history, the files and
/// the dirty flag are all untouched.
pub fn agentEditReject(self: *App) void {
    if (self.agent_edit.pending == null) return;
    if (!agentEditVisible(self)) {
        agentEditMsg(self, "agent edit: switch to its thread first");
        return;
    }
    const p = &self.agent_edit.pending.?;
    const text = if (p.isMulti())
        std.fmt.allocPrint(
            self.alloc,
            "{d} files · -{d} +{d} · discarded",
            .{ p.files.len, p.removed, p.added },
        ) catch null
    else
        std.fmt.allocPrint(
            self.alloc,
            "-{d} +{d} · discarded",
            .{ p.removed, p.added },
        ) catch null;
    if (text) |t| {
        defer self.alloc.free(t);
        updateCard(self, p, .rejected, t);
    }
    recordDecision(self, p, .rejected);
    const rejected_toast = if (p.isMulti())
        "agent patch rejected · no files written"
    else switch (p.kind) {
        .edit_file => "agent edit rejected",
        .apply_patch => "agent patch rejected",
    };
    clearPending(self);
    self.focus = .buffer;
    self.ai.focus = .editor;
    self.state.mode = .normal;
    self.visual_anchor = null;
    agentEditMsg(self, rejected_toast);
}

/// Select the active file in a multi-file review (keyboard j/k and the
/// per-file hint/mouse targets).
pub fn agentEditSelectFile(self: *App, index: usize) void {
    const p = if (self.agent_edit.pending) |*pp| pp else return;
    if (!p.isMulti() or index >= p.files.len) return;
    self.agent_edit.active_file = index;
}

fn afterBufferHistory(self: *App, idx: usize) void {
    if (idx >= self.buffers.items.len) return;
    const buf = &self.buffers.items[idx];
    buf.dirty = false;
    buf.folds.clearRetainingCapacity();
    self.clearSpanCache(buf);
    for (self.windows.items) |*window| {
        if (window.buf == idx) {
            window.cursor = @min(window.cursor, buf.pt.len());
            window.view_top = @min(window.view_top, buf.pt.lineCount());
        }
    }
    if (idx == self.current) {
        self.invalidateInlayHints();
        self.syncLspFull();
    }
    self.edit_seq +|= 1;
}

const PatchHistoryDirection = enum { undo, redo };

/// `u` on any buffer in the last multi-file patch set. Returns true when the
/// key was consumed (including a refused undo, which reports why and changes
/// nothing). False lets the normal per-buffer undo run.
pub fn agentPatchUndo(self: *App) bool {
    return patchHistoryStep(self, .undo);
}

/// Ctrl+r redo for the same cross-file unit.
pub fn agentPatchRedo(self: *App) bool {
    return patchHistoryStep(self, .redo);
}

fn patchHistoryUnavailable(self: *App, path: []const u8, reason: []const u8) bool {
    agentEditMsgFmt(self, "patch undo unavailable · {s}: {s}", .{ path, reason });
    return true;
}

fn patchHistoryStep(self: *App, direction: PatchHistoryDirection) bool {
    const set = if (self.agent_edit.patch_undo) |*undo| undo else return false;
    const cur_path = self.cur().path orelse return false;
    var in_set = false;
    for (set.files) |file| {
        if (std.mem.eql(u8, file.path, cur_path)) {
            in_set = true;
            break;
        }
    }
    // From an unrelated buffer `u` keeps its normal per-buffer meaning.
    if (!in_set) return false;
    // Already in the requested state: leave the key to the normal per-buffer
    // undo/redo so an earlier edit can still be reached.
    if (direction == .undo and !set.applied) return false;
    if (direction == .redo and set.applied) return false;

    const n = set.files.len;
    const texts = self.alloc.alloc([]u8, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    var initialized: usize = 0;
    defer {
        for (texts[0..initialized]) |text| self.alloc.free(text);
        self.alloc.free(texts);
    }
    const buffer_indices = self.alloc.alloc(?usize, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    defer self.alloc.free(buffer_indices);
    const use_history = self.alloc.alloc(bool, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    defer self.alloc.free(use_history);

    for (set.files, 0..) |file, i| {
        if (findBufferByPath(self, file.path)) |idx| {
            if (file.revision) |rev| {
                if (self.buffers.items[idx].history.revision != rev) {
                    return patchHistoryUnavailable(self, file.path, "buffer changed since the apply");
                }
            }
            const hist = &self.buffers.items[idx].history;
            use_history[i] = file.open_at_apply;
            if (use_history[i]) {
                if (direction == .undo and !hist.canUndo()) {
                    return patchHistoryUnavailable(self, file.path, "no undo history");
                }
                if (direction == .redo and !hist.canRedo()) {
                    return patchHistoryUnavailable(self, file.path, "no redo history");
                }
            }
            const current = copyBufferText(self, idx) orelse {
                return patchHistoryUnavailable(self, file.path, "buffer too large");
            };
            texts[i] = current;
            initialized += 1;
            buffer_indices[i] = idx;
            if (!std.mem.eql(u8, current, set.liveText(i))) {
                return patchHistoryUnavailable(self, file.path, "buffer text changed");
            }
        } else {
            use_history[i] = false;
            const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, file.path, self.alloc) catch {
                return patchHistoryUnavailable(self, file.path, "path no longer resolves");
            };
            defer self.alloc.free(canonical_now);
            if (!std.mem.eql(u8, canonical_now, file.path) or
                !tool_exec.isWithin(set.root, canonical_now))
            {
                return patchHistoryUnavailable(self, file.path, "path escapes the workspace");
            }
            const disk = readDiskText(self, file.path) catch {
                return patchHistoryUnavailable(self, file.path, "cannot read the file");
            };
            texts[i] = disk;
            initialized += 1;
            buffer_indices[i] = null;
            if (!std.mem.eql(u8, disk, set.liveText(i))) {
                return patchHistoryUnavailable(self, file.path, "file changed on disk");
            }
        }
    }

    // Re-resolve every path immediately before the undo/redo write, for the
    // same symlink-swap reason as approve.
    for (set.files) |file| {
        const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, file.path, self.alloc) catch {
            return patchHistoryUnavailable(self, file.path, "path no longer resolves");
        };
        defer self.alloc.free(canonical_now);
        if (!std.mem.eql(u8, canonical_now, file.path) or !tool_exec.isWithin(set.root, canonical_now)) {
            return patchHistoryUnavailable(self, file.path, "path escapes the workspace");
        }
    }

    const plan = self.alloc.alloc(model.CommitFile, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    defer self.alloc.free(plan);
    const tmp_paths = self.alloc.alloc([]u8, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    var tmp_count: usize = 0;
    defer {
        for (tmp_paths[0..tmp_count]) |tmp| {
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            self.alloc.free(tmp);
        }
        self.alloc.free(tmp_paths);
    }
    for (set.files, 0..) |file, i| {
        plan[i] = .{
            .path = file.path,
            .old_text = set.liveText(i),
            .new_text = set.targetText(i),
        };
        tmp_paths[i] = std.fmt.allocPrint(
            self.alloc,
            "{s}.ozundo{d}.{d}",
            .{ file.path, std.c.getpid(), i },
        ) catch {
            agentEditMsg(self, "patch undo: out of memory");
            return true;
        };
        tmp_count += 1;
    }
    const paths = self.alloc.alloc([]const u8, n) catch {
        agentEditMsg(self, "patch undo: out of memory");
        return true;
    };
    defer self.alloc.free(paths);
    for (set.files, 0..) |file, i| paths[i] = file.path;
    var sink = PatchWriteSink{ .app = self, .paths = paths, .tmp_paths = tmp_paths };
    const outcome = model.commitFiles(plan, &sink);
    if (outcome.status != .committed) {
        const failed = set.files[outcome.failed_index].path;
        if (outcome.rollback_failed) {
            agentEditMsgFmt(
                self,
                "patch undo failed for {s}; rollback incomplete — some files may be changed",
                .{failed},
            );
        } else {
            agentEditMsgFmt(
                self,
                "patch undo failed for {s}; rolled back {d} file(s), nothing changed",
                .{ failed, outcome.rolled_back },
            );
        }
        return true;
    }

    for (set.files, 0..) |*file, i| {
        if (buffer_indices[i]) |idx| {
            if (use_history[i]) {
                const hist = &self.buffers.items[idx].history;
                switch (direction) {
                    .undo => _ = hist.undo(&self.buffers.items[idx].pt),
                    .redo => _ = hist.redo(&self.buffers.items[idx].pt),
                }
                afterBufferHistory(self, idx);
                file.revision = hist.revision;
            } else {
                replaceBufferTextDirect(self, idx, set.targetText(i)) catch {
                    return patchHistoryUnavailable(self, file.path, "buffer refresh failed");
                };
                file.revision = self.buffers.items[idx].history.revision;
            }
            file.buffer_index = idx;
        } else {
            file.revision = null;
            file.buffer_index = null;
        }
    }
    set.applied = direction == .redo;
    self.gitMarksStaleNow();
    self.scheduleGitStatus();
    if (direction == .undo) {
        agentEditMsgFmt(self, "patch undo: restored {d} file(s)", .{n});
    } else {
        agentEditMsgFmt(self, "patch redo: re-applied {d} file(s)", .{n});
    }
    return true;
}

fn reviewBodyRows(self: *App) u32 {
    const rows = self.vx.window().height;
    if (rows <= app_mod.status_row_count) return 0;
    const m = ws.metrics(rows - app_mod.status_row_count, .changes);
    return m.body_rows -| 4;
}

fn scrollPending(self: *App, delta: i64) void {
    const p = if (self.agent_edit.pending) |*pp| pp else return;
    if (p.isMulti()) {
        scrollActiveReview(self, delta);
        return;
    }
    const vis = reviewBodyRows(self);
    if (vis == 0) return;
    const max_top = p.files[0].diff.len -| vis;
    var top: i64 = @intCast(@min(self.agent_edit.scroll, max_top));
    top += delta;
    if (top < 0) top = 0;
    if (top > max_top) top = @intCast(max_top);
    self.agent_edit.scroll = @intCast(top);
}

/// Mouse wheel over the Changes body: scroll the staged diff through the
/// same clamp the keyboard j/k path uses.
pub fn agentEditScrollBy(self: *App, delta: i64) void {
    scrollPending(self, delta);
}

/// Changes-tab keys while the rail owns the keyboard. Returns true when the
/// key was consumed by the staged review. With no visible pending edit the
/// keys fall through to the normal tab switching (r = Terminal, d = Changes).
pub fn handleAgentEditChangesKey(self: *App, key: vaxis.Key) !bool {
    if (self.ai.tab != .changes or self.ai.focus != .rail) return false;
    if (!agentEditVisible(self)) return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return false;
    if (key.codepoint == vaxis.Key.enter or key.codepoint == 'a') {
        try agentEditApprove(self);
        return true;
    }
    if (key.codepoint == 'r' or key.codepoint == 'd') {
        agentEditReject(self);
        return true;
    }
    if (self.agent_edit.pending.?.isMulti()) {
        // Multi-file review: j/k select the active file, J/K scroll its diff
        // (the wheel scrolls the active diff too). Enter/a and r/d keep their
        // approve/reject meaning so the single-file muscle memory and the
        // drawn buttons stay valid.
        if (key.codepoint == 'j') {
            selectReviewFile(self, 1);
            return true;
        }
        if (key.codepoint == 'k') {
            selectReviewFile(self, -1);
            return true;
        }
        if (key.codepoint == 'J') {
            scrollActiveReview(self, 1);
            return true;
        }
        if (key.codepoint == 'K') {
            scrollActiveReview(self, -1);
            return true;
        }
    }
    if (key.codepoint == 'j') {
        scrollPending(self, 1);
        return true;
    }
    if (key.codepoint == 'k') {
        scrollPending(self, -1);
        return true;
    }
    return false;
}

/// Workbox Changes body for the staged agent edit.
pub fn drawAgentEditChanges(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    x: u32,
    w: u32,
    body_top: u32,
    body_rows: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
) !void {
    if (!agentEditVisible(self)) return;
    const p = &self.agent_edit.pending.?;
    if (p.isMulti()) {
        try drawMultiAgentEdit(self, a, win, x, w, body_top, body_rows, border_style, rail_bg, p);
        return;
    }
    const file = &p.files[0];
    try inline_ui.drawDiffReview(self, a, win, x, w, body_top, body_rows, border_style, rail_bg, .{
        .path = file.display_path,
        .first_line = file.first_line,
        .last_line = file.last_line,
        .removed = p.removed,
        .added = p.added,
        .stale = p.stale,
        .stale_label = p.staleLabel(),
        .partial = p.preview_partial,
        .partial_label = "preview",
        .diff = file.diff,
        .scroll = &self.agent_edit.scroll,
        .approve_action = .agent_approve,
        .reject_action = .agent_reject,
    });
}

fn activeReviewFile(p: *const model.Pending, active: usize) usize {
    return @min(active, p.files.len -| 1);
}

fn selectReviewFile(self: *App, direction: i32) void {
    const p = if (self.agent_edit.pending) |*pp| pp else return;
    if (!p.isMulti()) return;
    const n: i32 = @intCast(p.files.len);
    var next = @as(i32, @intCast(activeReviewFile(p, self.agent_edit.active_file))) + direction;
    if (next < 0) next += n;
    self.agent_edit.active_file = @intCast(@mod(next, n));
}

fn multiVisibleDiffRows(self: *App, p: *const model.Pending) u32 {
    const rows = self.vx.window().height;
    if (rows <= app_mod.status_row_count) return 1;
    const m = ws.metrics(rows - app_mod.status_row_count, .changes);
    if (m.body_rows < 6) return 1;
    const budget = inline_ui.multiFileRowBudget(m.body_rows, p.files.len);
    const overflow = p.files.len > budget;
    const file_rows = (if (overflow) @max(budget -| 1, 1) else budget) + @intFromBool(overflow);
    return m.body_rows -| (1 + file_rows + 2);
}

fn scrollActiveReview(self: *App, delta: i64) void {
    const p = if (self.agent_edit.pending) |*pp| pp else return;
    if (!p.isMulti()) return;
    const idx = activeReviewFile(p, self.agent_edit.active_file);
    const vis = multiVisibleDiffRows(self, p);
    const diff = p.files[idx].diff;
    const max_top = diff.len -| vis;
    var top: i64 = @intCast(@min(self.agent_edit.file_scrolls[idx], max_top));
    top += delta;
    if (top < 0) top = 0;
    if (top > max_top) top = @intCast(max_top);
    self.agent_edit.file_scrolls[idx] = @intCast(top);
}

fn drawMultiAgentEdit(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    x: u32,
    w: u32,
    body_top: u32,
    body_rows: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
    p: *const model.Pending,
) !void {
    var actions: [patch_model.max_files]hints.Action = undefined;
    var paths: [patch_model.max_files][]const u8 = undefined;
    for (p.files, 0..) |file, i| {
        paths[i] = file.display_path;
        actions[i] = .{ .agent_patch_file = i };
    }
    const active = activeReviewFile(p, self.agent_edit.active_file);
    const file = &p.files[active];
    try inline_ui.drawMultiDiffReview(self, a, win, x, w, body_top, body_rows, border_style, rail_bg, .{
        .paths = paths[0..p.files.len],
        .actions = actions[0..p.files.len],
        .active = active,
        .total_removed = p.removed,
        .total_added = p.added,
        .stale = p.stale,
        .stale_label = p.staleLabel(),
        .stale_file = p.stale_file,
        .diff = file.diff,
        .scroll = &self.agent_edit.file_scrolls[active],
        .approve_action = .agent_approve,
        .reject_action = .agent_reject,
    });
}
