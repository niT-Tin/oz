//! Staged agent edits (M3b1) — App-facing half.
//!
//! Pure argument/occurrence/preview/pending logic lives in
//! `src/app/agent_edit.zig`. This file owns:
//!   - workspace confinement + read-only target loading at stage time;
//!   - the one-pending interaction with the inline assistant;
//!   - approve (open buffer if needed, stale checks, ONE undo group) and
//!     reject (no buffer/history change);
//!   - the Changes review rendering (through the shared diff renderer) and
//!     the `agent_approve` / `agent_reject` hint actions;
//!   - thread-scoped visibility: a pending edit is only reviewable/applicable
//!     from the thread that staged it.
//!
//! No tool execution happens here: the executor is never asked to write.
//! Approve edits the in-memory buffer only; `:w` remains the user's separate
//! action.
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

pub const Session = struct {
    /// At most one staged agent edit (session-wide). Thread-scoped by
    /// `Pending.thread_index`; switching threads hides it but never frees it.
    pending: ?model.Pending = null,
    /// First visible diff line in the Changes body.
    scroll: u32 = 0,
};

pub const StageResult = union(enum) {
    staged: struct {
        removed: u32,
        added: u32,
        path: []const u8,
    },
    /// Another review (agent or inline) is already pending/prompting.
    busy,
    /// Owned error text, already prefixed with "error: ".
    failed: []u8,
    oom,
};

pub fn deinitAgentEdit(self: *App) void {
    clearPending(self);
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
    openReviewSurface(self);

    const staged = &self.agent_edit.pending.?;
    return .{ .staged = .{
        .removed = staged.removed,
        .added = staged.added,
        .path = staged.display_path,
    } };
}

/// Stage one `apply_patch` call as a whole-file replacement review. Parsing,
/// path confinement, target loading and hunk application are all read-only;
/// the caller formats the card from the returned stats. The buffer, its
/// history, the dirty flag and the file are untouched until a human approve.
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

    var patch = patch_model.parse(self.alloc, args.patch) catch |e| {
        return patchParseFailure(self.alloc, e);
    };

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

    const new_text = patch_model.apply(self.alloc, &patch, loaded.text) catch |e| {
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
        .patch = &patch,
    }) catch |e| {
        patch.deinit(self.alloc);
        return switch (e) {
            error.OutOfMemory => .oom,
        };
    };

    self.agent_edit.pending = pending;
    self.agent_edit.scroll = 0;
    openReviewSurface(self);

    const staged = &self.agent_edit.pending.?;
    return .{ .staged = .{
        .removed = staged.removed,
        .added = staged.added,
        .path = staged.display_path,
    } };
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

fn markStale(self: *App, p: *model.Pending) void {
    p.stale = true;
    const label = p.staleLabel();
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

/// Approve: verify staleness, open/activate the target buffer, then apply the
/// whole staged replacement as ONE undo group. Never writes to disk.
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

    var buf_idx = findBufferByPath(self, p.path);
    if (buf_idx == null) {
        // The target was not open at stage time. Re-canonicalize it under the
        // captured root (a path replaced by an outside symlink is stale) and
        // re-read it read-only; require the whole snapshot to still match
        // before opening a buffer.
        const canonical_now = std.Io.Dir.cwd().realPathFileAlloc(self.io, p.path, self.alloc) catch {
            markStale(self, p);
            return;
        };
        defer self.alloc.free(canonical_now);
        if (!std.mem.eql(u8, canonical_now, p.path) or !tool_exec.isWithin(p.root, canonical_now)) {
            markStale(self, p);
            return;
        }
        const disk = readDiskText(self, p.path) catch {
            markStale(self, p);
            return;
        };
        defer self.alloc.free(disk);
        if (!p.verify(disk)) {
            markStale(self, p);
            return;
        }
        self.openInBuffer(p.path) catch {
            markStale(self, p);
            return;
        };
        buf_idx = findBufferByPath(self, p.path) orelse {
            markStale(self, p);
            return;
        };
    }
    const idx = buf_idx.?;
    // Staged from a buffer: the exact document revision must still match.
    if (p.revision) |rev| {
        if (idx >= self.buffers.items.len or self.buffers.items[idx].history.revision != rev) {
            markStale(self, p);
            return;
        }
    }
    // Exact text identity + occurrence count (also covers a buffer that was
    // opened or edited externally after staging from disk).
    if (!bufferTextEquals(self, idx, p.text)) {
        markStale(self, p);
        return;
    }
    // A patch must additionally still produce the exact staged result; this
    // re-runs the retained hunks instead of trusting the snapshot alone.
    if (!p.verifyPatch(self.alloc, p.text)) {
        markStale(self, p);
        return;
    }
    if (self.windows.items[self.current_win].buf != idx) self.switchTo(idx);

    const start = p.span_start;
    self.applyEdit(p.span_start, p.span_end, p.span_replacement) catch |e| {
        agentEditMsgFmt(self, "agent edit apply failed: {s}", .{@errorName(e)});
        return;
    };
    self.curCursor().* = @min(start, self.cur().pt.len());
    self.state.mode = .normal;
    self.visual_anchor = null;
    self.in_insert = false;
    self.focus = .buffer;
    self.ai.focus = .editor;

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

/// Reject: discard the staged diff. The buffer, its history, the file and the
/// dirty flag are all untouched.
pub fn agentEditReject(self: *App) void {
    if (self.agent_edit.pending == null) return;
    if (!agentEditVisible(self)) {
        agentEditMsg(self, "agent edit: switch to its thread first");
        return;
    }
    const p = &self.agent_edit.pending.?;
    const text = std.fmt.allocPrint(
        self.alloc,
        "-{d} +{d} · discarded",
        .{ p.removed, p.added },
    ) catch null;
    if (text) |t| {
        defer self.alloc.free(t);
        updateCard(self, p, .rejected, t);
    }
    recordDecision(self, p, .rejected);
    const rejected_toast = switch (p.kind) {
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

fn reviewBodyRows(self: *App) u32 {
    const rows = self.vx.window().height;
    if (rows <= app_mod.status_row_count) return 0;
    const m = ws.metrics(rows - app_mod.status_row_count, .changes);
    return m.body_rows -| 4;
}

fn scrollPending(self: *App, delta: i64) void {
    const p = if (self.agent_edit.pending) |*pp| pp else return;
    const vis = reviewBodyRows(self);
    if (vis == 0) return;
    const max_top = p.diff.len -| vis;
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
    try inline_ui.drawDiffReview(self, a, win, x, w, body_top, body_rows, border_style, rail_bg, .{
        .path = p.display_path,
        .first_line = p.first_line,
        .last_line = p.last_line,
        .removed = p.removed,
        .added = p.added,
        .stale = p.stale,
        .stale_label = p.staleLabel(),
        .partial = p.preview_partial,
        .partial_label = "preview",
        .diff = p.diff,
        .scroll = &self.agent_edit.scroll,
        .approve_action = .agent_approve,
        .reject_action = .agent_reject,
    });
}
