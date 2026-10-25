//! AI workspace (M2a): pure layout, focus and thread state.
//!
//! Deliberately App-independent: the rail geometry, focus transitions and
//! the multi-thread session model are unit-tested here without constructing
//! an editor. `app/ai.zig` owns the transport (one client per thread) and
//! the rendering; it routes through these types so the policies below have
//! exactly one implementation.
const std = @import("std");

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Wide terminals reserve a docked right rail; medium narrows it; below
/// `mid_cols` the rail becomes an overlay drawer so the editor keeps its
/// full width underneath.
pub const wide_cols: u32 = 110;
pub const mid_cols: u32 = 90;
pub const rail_wide_width: u32 = 38;
pub const rail_mid_width: u32 = 34;
/// The drawer never eats more than `cols - 8`, so at 80 cols the editor
/// still shows 46 usable columns to the left.
pub const drawer_margin: u32 = 8;

pub const RailMode = enum { hidden, docked, drawer };

pub const Layout = struct {
    mode: RailMode = .hidden,
    /// Total reserved rail width in cells (including its left border).
    /// 0 when hidden.
    rail_width: u32 = 0,
    /// Cells the editor/file-tree/splits may use. Equal to the terminal
    /// width in drawer mode (the drawer floats above it).
    editor_width: u32 = 0,
    /// Screen column of the rail's left border (0 when hidden).
    rail_col: u32 = 0,
};

/// Rail width for an OPEN rail at `cols`. Includes the one-cell border.
pub fn railWidth(cols: u32) u32 {
    if (cols >= wide_cols) return rail_wide_width;
    if (cols >= mid_cols) return rail_mid_width;
    const avail = cols -| drawer_margin;
    const width = @min(rail_mid_width, avail);
    return @max(width, 1);
}

/// The single source of truth for the workspace layout. Every renderer and
/// input handler that needs the editor/rail split must use this.
pub fn layout(cols: u32, open: bool) Layout {
    if (!open) return .{ .mode = .hidden, .editor_width = cols };
    const rw = railWidth(cols);
    if (cols >= mid_cols) {
        const editor_width = cols -| rw;
        return .{
            .mode = .docked,
            .rail_width = rw,
            .editor_width = editor_width,
            .rail_col = editor_width,
        };
    }
    return .{
        .mode = .drawer,
        .rail_width = rw,
        .editor_width = cols,
        .rail_col = cols -| rw,
    };
}

/// Section geometry for the rail's interior, in rail-relative rows (row 0
/// is the top of the rail; the status bar is outside the rail). Kept here
/// so the renderer and tests agree on exactly how many thread rows and
/// workbox body rows exist.
pub const Metrics = struct {
    rail_rows: u32 = 0,
    header_row: u32 = 0,
    group_row: u32 = 1,
    thread_top: u32 = 2,
    thread_rows: u32 = 0,
    divider_row: u32 = 0,
    workbox_header_row: u32 = 0,
    tabs_row: u32 = 0,
    body_top: u32 = 0,
    body_rows: u32 = 0,
    prompt_row: ?u32 = null,
};

pub fn metrics(rail_rows: u32, tab: WorkboxTab) Metrics {
    if (rail_rows == 0) return .{};
    if (rail_rows < 8) {
        return .{
            .rail_rows = rail_rows,
            .thread_rows = 1,
            .divider_row = @min(3, rail_rows - 1),
            .workbox_header_row = @min(4, rail_rows - 1),
            .tabs_row = @min(5, rail_rows - 1),
            .body_top = @min(6, rail_rows),
            .body_rows = 0,
        };
    }
    // Two fixed rows (agent header + workspace group), one divider, the
    // workbox header and the tab row. The thread list takes roughly a
    // third of what remains (bounded so the workbox always wins on short
    // terminals).
    var thread_rows = (rail_rows - 6) / 3;
    thread_rows = @min(@max(thread_rows, 3), 8);
    const divider_row = 2 + thread_rows;
    const workbox_header_row = divider_row + 1;
    const tabs_row = workbox_header_row + 1;
    const body_top = tabs_row + 1;
    const prompt_row: ?u32 = if (tab == .chat and rail_rows > body_top + 1) rail_rows - 1 else null;
    const body_bottom = if (prompt_row) |p| p - 1 else rail_rows - 1;
    const body_rows = if (body_bottom >= body_top) body_bottom - body_top + 1 else 0;
    return .{
        .rail_rows = rail_rows,
        .thread_rows = thread_rows,
        .divider_row = divider_row,
        .workbox_header_row = workbox_header_row,
        .tabs_row = tabs_row,
        .body_top = body_top,
        .body_rows = body_rows,
        .prompt_row = prompt_row,
    };
}

// ---------------------------------------------------------------------------
// Focus policy
// ---------------------------------------------------------------------------

pub const Focus = enum { editor, rail, prompt };

pub const WorkboxTab = enum { chat, changes, tools, terminal };

pub const FocusState = struct {
    open: bool,
    focus: Focus,
};

/// `<leader>a`: a true visibility toggle. Opening focuses the prompt;
/// closing returns focus to the editor. While the prompt is focused a
/// printable leader sequence belongs to the prompt, so closing from there
/// takes Esc (back to the editor) followed by `<leader>a`, or Tab (thread
/// rail) followed by `<leader>a`.
pub fn toggleRail(open: bool, focus: Focus) FocusState {
    _ = focus; // policy is visibility-first; the focus after closing is editor
    if (open) return .{ .open = false, .focus = .editor };
    return .{ .open = true, .focus = .prompt };
}

/// `Ctrl+w a`: re-focus the rail from the editor (opening it when closed).
/// Lands on the thread list, not the prompt, so the editor always has one
/// keystroke path back to thread navigation.
pub fn focusRail() FocusState {
    return .{ .open = true, .focus = .rail };
}

/// Esc / q while the rail or prompt has focus. Wide mode keeps the rail
/// visible and hands the keyboard back to the editor; the narrow drawer
/// closes (leaving an open drawer focused on the editor would cover text
/// while the editor consumes keys).
pub fn leaveRail(open: bool, focus: Focus, narrow: bool) FocusState {
    if (!open or focus == .editor) return .{ .open = open, .focus = .editor };
    if (narrow) return .{ .open = false, .focus = .editor };
    return .{ .open = true, .focus = .editor };
}

/// Tab in the prompt: go to the thread list (the prompt itself never
/// receives a tab character; prompts are single-line).
pub fn fromPromptTab() Focus {
    return .rail;
}

/// Enter in the thread list: attach to the selected thread's prompt.
pub fn fromRailEnter() Focus {
    return .prompt;
}

// ---------------------------------------------------------------------------
// Thread model
// ---------------------------------------------------------------------------

pub const Status = enum { idle, streaming, cancelled, err };

pub fn statusLabel(status: Status) []const u8 {
    return switch (status) {
        .idle => "idle",
        .streaming => "streaming…",
        .cancelled => "cancelled",
        .err => "error",
    };
}

pub const Role = enum { user, assistant, tool };

/// Display/execution state of a tool card. Deliberately a plain enum so the
/// pure thread model stays independent from the app's worker/metrics.
pub const ToolStatus = enum {
    none,
    running,
    ok,
    err,
    approval_required,
    /// Human approve/reject outcome of a staged M3b1 edit. These are display
    /// states, not a second tool call.
    approved,
    rejected,
    unsupported,
    cancelled,
};

pub const Message = struct {
    role: Role,
    /// What the transcript shows (the user's typed prompt / assistant text /
    /// a bounded tool-result excerpt).
    text: []u8,
    /// What is sent to the provider. User messages carry the editor
    /// context; assistant messages mirror `text`; tool messages carry the
    /// bounded result content (with an `error: ` prefix when applicable).
    api_text: []u8,
    /// Assistant tool-call turn: serialized OpenAI `tool_calls` array
    /// (owned). Null for a plain assistant message.
    tool_calls_json: ?[]u8 = null,
    /// Tool result: the `tool_call_id` this answers (owned).
    tool_call_id: ?[]u8 = null,
    /// Tool card identity for rendering (owned).
    tool_name: ?[]u8 = null,
    tool_args: ?[]u8 = null,
    tool_status: ToolStatus = .none,
    /// Executed-call duration (0 for non-executed outcomes).
    tool_ms: u32 = 0,
    /// Expanded card view (hint target toggles this).
    tool_expanded: bool = false,

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.api_text);
        if (self.tool_calls_json) |v| alloc.free(v);
        if (self.tool_call_id) |v| alloc.free(v);
        if (self.tool_name) |v| alloc.free(v);
        if (self.tool_args) |v| alloc.free(v);
    }
};

/// One agent thread. Owns its transcript, prompt draft, scroll position and
/// status. The transport client lives beside the session (App side) so this
/// model stays testable without threads-of-execution.
pub const Thread = struct {
    id: u64,
    title: []u8,
    messages: std.ArrayList(Message) = .empty,
    input: std.ArrayList(u8) = .empty,
    status: Status = .idle,
    error_text: ?[]u8 = null,
    /// Transcript top row (wrapped rows) for manual scrolling.
    scroll: u32 = 0,
    /// Follow the bottom while streaming; a manual scroll disables it until
    /// the next send.
    auto_scroll: bool = true,
    /// Last rendered transcript geometry (for scroll bounds).
    total_rows: u32 = 0,
    view_rows: u32 = 0,
    /// Set on cancel / switching away: late worker events must not touch
    /// this thread's conversation.
    cancel_requested: bool = false,

    fn deinit(self: *Thread, alloc: std.mem.Allocator) void {
        for (self.messages.items) |*m| m.deinit(alloc);
        self.messages.deinit(alloc);
        self.input.deinit(alloc);
        if (self.error_text) |e| alloc.free(e);
        alloc.free(self.title);
    }

    pub fn statusLabel(self: *const Thread) []const u8 {
        return switch (self.status) {
            .idle => "idle",
            .streaming => "streaming…",
            .cancelled => "cancelled",
            .err => "error",
        };
    }
};

pub const SelectResult = struct {
    /// Index that was active before the switch.
    prev: usize,
    /// True when the previous thread was streaming and has now been
    /// cancelled. The caller must also signal its transport client.
    cancelled: bool,
};

pub const Threads = struct {
    items: std.ArrayList(Thread) = .empty,
    active: usize = 0,
    next_number: u64 = 1,

    pub fn deinit(self: *Threads, alloc: std.mem.Allocator) void {
        for (self.items.items) |*t| t.deinit(alloc);
        self.items.deinit(alloc);
    }

    /// Append a new thread named "thread N". Does not change `active`; the
    /// caller selects it (so switching policy stays in one place). Returns
    /// the new index.
    pub fn create(self: *Threads, alloc: std.mem.Allocator) !usize {
        const title = try std.fmt.allocPrint(alloc, "thread {d}", .{self.next_number});
        errdefer alloc.free(title);
        try self.items.append(alloc, .{ .id = self.next_number, .title = title });
        self.next_number += 1;
        return self.items.items.len - 1;
    }

    /// Switch the active thread. Switching away from a streaming thread
    /// cancels it (status cancelled, transcript frozen). One streaming
    /// thread at a time is therefore enforced by construction.
    pub fn select(self: *Threads, idx: usize) SelectResult {
        std.debug.assert(idx < self.items.items.len);
        const prev = self.active;
        if (prev == idx) return .{ .prev = prev, .cancelled = false };
        var cancelled = false;
        if (prev < self.items.items.len) {
            const old = &self.items.items[prev];
            if (old.status == .streaming) {
                old.cancel_requested = true;
                old.status = .cancelled;
                cancelled = true;
            }
        }
        self.active = idx;
        return .{ .prev = prev, .cancelled = cancelled };
    }

    pub fn activeThread(self: *Threads) *Thread {
        std.debug.assert(self.items.items.len > 0);
        return &self.items.items[self.active];
    }

    pub fn activeThreadConst(self: *const Threads) *const Thread {
        std.debug.assert(self.items.items.len > 0);
        return &self.items.items[self.active];
    }

    pub fn activeStatus(self: *const Threads) Status {
        if (self.items.items.len == 0) return .idle;
        return self.items.items[@min(self.active, self.items.items.len - 1)].status;
    }

    pub fn streamingCount(self: *const Threads) usize {
        var n: usize = 0;
        for (self.items.items) |t| {
            if (t.status == .streaming) n += 1;
        }
        return n;
    }

    pub fn appendMessage(
        self: *Threads,
        alloc: std.mem.Allocator,
        idx: usize,
        role: Role,
        text: []const u8,
        api_text: []const u8,
    ) !void {
        const t = &self.items.items[idx];
        const text_copy = try alloc.dupe(u8, text);
        errdefer alloc.free(text_copy);
        const api_copy = try alloc.dupe(u8, api_text);
        errdefer alloc.free(api_copy);
        try t.messages.append(alloc, .{ .role = role, .text = text_copy, .api_text = api_copy });
    }

    pub fn appendUser(self: *Threads, alloc: std.mem.Allocator, idx: usize, text: []const u8, api_text: []const u8) !void {
        return self.appendMessage(alloc, idx, .user, text, api_text);
    }

    /// Append the empty assistant message that streaming deltas grow.
    pub fn beginAssistant(self: *Threads, alloc: std.mem.Allocator, idx: usize) !void {
        return self.appendMessage(alloc, idx, .assistant, "", "");
    }

    /// Drop a trailing empty assistant placeholder (start failed before any
    /// delta landed) so the transcript doesn't keep a blank bubble forever.
    pub fn dropEmptyAssistant(self: *Threads, alloc: std.mem.Allocator, idx: usize) void {
        const t = &self.items.items[idx];
        if (t.messages.items.len == 0) return;
        const last = &t.messages.items[t.messages.items.len - 1];
        if (last.role != .assistant or last.text.len != 0 or last.tool_calls_json != null) return;
        var msg = t.messages.pop().?;
        msg.deinit(alloc);
    }

    /// Attach a serialized tool-call array to the current assistant turn.
    /// The streamed text (if any) stays in the same message, so a request
    /// can carry OpenAI's `assistant {content, tool_calls}` shape exactly.
    pub fn setAssistantToolCalls(self: *Threads, alloc: std.mem.Allocator, idx: usize, calls_json: []const u8) !void {
        const t = &self.items.items[idx];
        if (t.messages.items.len == 0) {
            try self.appendMessage(alloc, idx, .assistant, "", "");
        }
        const last = &t.messages.items[t.messages.items.len - 1];
        if (last.role != .assistant) {
            try self.appendMessage(alloc, idx, .assistant, "", "");
        }
        const msg = &t.messages.items[t.messages.items.len - 1];
        const copy = try alloc.dupe(u8, calls_json);
        if (msg.tool_calls_json) |old| alloc.free(old);
        msg.tool_calls_json = copy;
    }

    /// Append a running tool card/result message. `content` may be empty for
    /// calls that are about to execute in the worker. Returns the message
    /// index so the worker's result can fill it in place.
    pub fn appendToolMessage(
        self: *Threads,
        alloc: std.mem.Allocator,
        idx: usize,
        call_id: []const u8,
        name: []const u8,
        args: []const u8,
        status: ToolStatus,
        content: []const u8,
    ) !usize {
        const t = &self.items.items[idx];
        const id_copy = try alloc.dupe(u8, call_id);
        errdefer alloc.free(id_copy);
        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);
        const args_copy = try alloc.dupe(u8, args);
        errdefer alloc.free(args_copy);
        const text_copy = try alloc.dupe(u8, content);
        errdefer alloc.free(text_copy);
        const api_copy = try alloc.dupe(u8, content);
        errdefer alloc.free(api_copy);
        try t.messages.append(alloc, .{
            .role = .tool,
            .text = text_copy,
            .api_text = api_copy,
            .tool_call_id = id_copy,
            .tool_name = name_copy,
            .tool_args = args_copy,
            .tool_status = status,
        });
        return t.messages.items.len - 1;
    }

    /// Replace a tool card's display/API content and status in place. The
    /// old buffers are freed exactly once; on OOM the card is left untouched
    /// (the caller reports the failure instead of corrupting the transcript).
    pub fn setToolOutcome(
        self: *Threads,
        alloc: std.mem.Allocator,
        idx: usize,
        msg_index: usize,
        status: ToolStatus,
        text: []const u8,
        api_text: []const u8,
        duration_ms: u32,
    ) !void {
        const t = &self.items.items[idx];
        if (msg_index >= t.messages.items.len) return;
        const msg = &t.messages.items[msg_index];
        if (msg.role != .tool) return;
        const text_copy = try alloc.dupe(u8, text);
        errdefer alloc.free(text_copy);
        const api_copy = try alloc.dupe(u8, api_text);
        errdefer alloc.free(api_copy);
        alloc.free(msg.text);
        alloc.free(msg.api_text);
        msg.text = text_copy;
        msg.api_text = api_copy;
        msg.tool_status = status;
        msg.tool_ms = duration_ms;
    }

    /// Update a staged edit card's status/display text after a human
    /// decision or a stale refusal. `api_text` is deliberately untouched:
    /// the provider already received the staged/not-applied tool result and
    /// rewriting history would misrepresent what was sent.
    pub fn setToolDecision(
        self: *Threads,
        alloc: std.mem.Allocator,
        idx: usize,
        msg_index: usize,
        status: ToolStatus,
        text: []const u8,
    ) void {
        if (idx >= self.items.items.len) return;
        const t = &self.items.items[idx];
        if (msg_index >= t.messages.items.len) return;
        const msg = &t.messages.items[msg_index];
        if (msg.role != .tool) return;
        const text_copy = alloc.dupe(u8, text) catch return;
        alloc.free(msg.text);
        msg.text = text_copy;
        msg.tool_status = status;
    }

    /// Freeze every running tool card as cancelled (Ctrl+c / thread switch).
    /// No result may later overwrite them because the app invalidates the
    /// job generation first.
    pub fn cancelRunningTools(self: *Threads, idx: usize) void {
        if (idx >= self.items.items.len) return;
        for (self.items.items[idx].messages.items) |*m| {
            if (m.role == .tool and m.tool_status == .running) {
                m.tool_status = .cancelled;
                m.tool_ms = 0;
            }
        }
    }

    /// Append a delta to thread `idx`. Returns false when the thread is not
    /// currently streaming or was cancelled — the exact guard that keeps a
    /// late chunk out of a frozen transcript.
    pub fn applyDelta(self: *Threads, alloc: std.mem.Allocator, idx: usize, text: []const u8) !bool {
        if (idx >= self.items.items.len) return false;
        const t = &self.items.items[idx];
        if (t.status != .streaming or t.cancel_requested) return false;
        if (t.messages.items.len == 0) return false;
        const last = &t.messages.items[t.messages.items.len - 1];
        if (last.role != .assistant) return false;
        const merged = try std.mem.concat(alloc, u8, &.{ last.text, text });
        errdefer alloc.free(merged);
        const api_copy = try alloc.dupe(u8, merged);
        alloc.free(last.text);
        alloc.free(last.api_text);
        last.text = merged;
        last.api_text = api_copy;
        return true;
    }

    pub fn markStreaming(self: *Threads, alloc: std.mem.Allocator, idx: usize) void {
        const t = &self.items.items[idx];
        if (t.error_text) |e| {
            alloc.free(e);
            t.error_text = null;
        }
        t.status = .streaming;
        t.cancel_requested = false;
        t.scroll = 0;
        t.auto_scroll = true;
        t.total_rows = 0;
        t.view_rows = 0;
    }

    pub fn finish(self: *Threads, idx: usize) void {
        const t = &self.items.items[idx];
        if (t.status == .streaming) t.status = .idle;
    }

    pub fn fail(self: *Threads, alloc: std.mem.Allocator, idx: usize, text: []const u8) void {
        const t = &self.items.items[idx];
        if (t.error_text) |e| alloc.free(e);
        t.error_text = alloc.dupe(u8, text) catch null;
        t.status = .err;
    }

    /// Ctrl+c / switching away. Returns true when a live stream was marked
    /// cancelled (the caller then asks the transport to stop).
    pub fn cancel(self: *Threads, idx: usize) bool {
        const t = &self.items.items[idx];
        if (t.status != .streaming) return false;
        t.cancel_requested = true;
        t.status = .cancelled;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "workspace layout: 120/110/100/90 dock, 89/80 drawer, hidden" {
    const l120 = layout(120, true);
    try std.testing.expectEqual(RailMode.docked, l120.mode);
    try std.testing.expectEqual(@as(u32, 38), l120.rail_width);
    try std.testing.expectEqual(@as(u32, 82), l120.editor_width);
    try std.testing.expectEqual(@as(u32, 82), l120.rail_col);

    const l110 = layout(110, true);
    try std.testing.expectEqual(RailMode.docked, l110.mode);
    try std.testing.expectEqual(@as(u32, 38), l110.rail_width);
    try std.testing.expectEqual(@as(u32, 72), l110.editor_width);

    const l100 = layout(100, true);
    try std.testing.expectEqual(RailMode.docked, l100.mode);
    try std.testing.expectEqual(@as(u32, 34), l100.rail_width);
    try std.testing.expectEqual(@as(u32, 66), l100.editor_width);

    const l90 = layout(90, true);
    try std.testing.expectEqual(RailMode.docked, l90.mode);
    try std.testing.expectEqual(@as(u32, 34), l90.rail_width);
    try std.testing.expectEqual(@as(u32, 56), l90.editor_width);
    try std.testing.expectEqual(@as(u32, 56), l90.rail_col);

    const l89 = layout(89, true);
    try std.testing.expectEqual(RailMode.drawer, l89.mode);
    try std.testing.expectEqual(@as(u32, 34), l89.rail_width);
    // The editor keeps its full width underneath the overlay.
    try std.testing.expectEqual(@as(u32, 89), l89.editor_width);
    try std.testing.expectEqual(@as(u32, 55), l89.rail_col);

    const l80 = layout(80, true);
    try std.testing.expectEqual(RailMode.drawer, l80.mode);
    try std.testing.expectEqual(@as(u32, 34), l80.rail_width);
    try std.testing.expectEqual(@as(u32, 80), l80.editor_width);
    try std.testing.expectEqual(@as(u32, 46), l80.rail_col);
    // The drawer leaves at least 8 columns of text visible.
    try std.testing.expect(l80.rail_col >= 8);

    const hidden = layout(120, false);
    try std.testing.expectEqual(RailMode.hidden, hidden.mode);
    try std.testing.expectEqual(@as(u32, 0), hidden.rail_width);
    try std.testing.expectEqual(@as(u32, 120), hidden.editor_width);
}

test "workspace layout: rail metrics keep a workbox and chat prompt" {
    const m = metrics(29, .chat);
    try std.testing.expectEqual(@as(u32, 7), m.thread_rows);
    try std.testing.expectEqual(@as(u32, 9), m.divider_row);
    try std.testing.expectEqual(@as(u32, 10), m.workbox_header_row);
    try std.testing.expectEqual(@as(u32, 11), m.tabs_row);
    try std.testing.expectEqual(@as(u32, 28), m.prompt_row.?);
    try std.testing.expect(m.body_rows > 8);

    const m24 = metrics(23, .chat);
    try std.testing.expectEqual(@as(u32, 5), m24.thread_rows);
    try std.testing.expectEqual(@as(u32, 22), m24.prompt_row.?);

    const changes = metrics(23, .changes);
    try std.testing.expect(changes.prompt_row == null);
    try std.testing.expectEqual(@as(u32, 13), changes.body_rows);
}

test "workspace focus: toggle, escape and the two rail re-entry points" {
    // <leader>a opens onto the prompt and closes back to the editor.
    var s = toggleRail(false, .editor);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Focus.prompt, s.focus);
    s = toggleRail(true, .prompt);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(Focus.editor, s.focus);
    s = toggleRail(true, .rail);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(Focus.editor, s.focus);

    // Esc from the prompt keeps a wide rail open but gives the editor keys.
    s = leaveRail(true, .prompt, false);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Focus.editor, s.focus);
    // …while the narrow drawer closes outright.
    s = leaveRail(true, .prompt, true);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(Focus.editor, s.focus);
    // Esc is a no-op for an editor-focused rail.
    s = leaveRail(true, .editor, true);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Focus.editor, s.focus);

    // Ctrl+w a re-enters the rail at the thread list, even when closed.
    s = focusRail();
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Focus.rail, s.focus);
    // Tab from the prompt reaches the thread list; Enter attaches back.
    try std.testing.expectEqual(Focus.rail, fromPromptTab());
    try std.testing.expectEqual(Focus.prompt, fromRailEnter());
}

test "threads: create names sequentially, select switches active" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);

    const a = try ts.create(alloc);
    const b = try ts.create(alloc);
    const c = try ts.create(alloc);
    try std.testing.expectEqual(@as(usize, 0), a);
    try std.testing.expectEqual(@as(usize, 1), b);
    try std.testing.expectEqual(@as(usize, 2), c);
    try std.testing.expectEqualStrings("thread 1", ts.items.items[a].title);
    try std.testing.expectEqualStrings("thread 2", ts.items.items[b].title);
    try std.testing.expectEqualStrings("thread 3", ts.items.items[c].title);
    try std.testing.expectEqual(@as(u64, 1), ts.items.items[a].id);
    try std.testing.expectEqual(@as(u64, 3), ts.items.items[c].id);

    try std.testing.expectEqual(@as(usize, 0), ts.active);
    const r = ts.select(c);
    try std.testing.expectEqual(@as(usize, 0), r.prev);
    try std.testing.expect(!r.cancelled);
    try std.testing.expectEqual(@as(usize, 2), ts.active);
    try std.testing.expectEqual(Status.idle, ts.activeStatus());
}

test "threads: transcripts are isolated and active status follows the active thread" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);
    const a = try ts.create(alloc);
    const b = try ts.create(alloc);

    try ts.appendUser(alloc, a, "alpha prompt", "ctx alpha");
    try ts.beginAssistant(alloc, a);
    ts.items.items[a].status = .streaming;
    try std.testing.expect(try ts.applyDelta(alloc, a, "alpha reply"));
    ts.finish(a);
    try std.testing.expectEqualStrings("alpha reply", ts.items.items[a].messages.items[1].text);

    try ts.appendUser(alloc, b, "beta prompt", "ctx beta");
    try ts.beginAssistant(alloc, b);
    ts.items.items[b].status = .streaming;
    try std.testing.expect(try ts.applyDelta(alloc, b, "beta reply"));
    ts.finish(b);

    // A's transcript never contains B's text and vice versa.
    try std.testing.expectEqual(@as(usize, 2), ts.items.items[a].messages.items.len);
    try std.testing.expectEqual(@as(usize, 2), ts.items.items[b].messages.items.len);
    try std.testing.expectEqualStrings("alpha prompt", ts.items.items[a].messages.items[0].text);
    try std.testing.expectEqualStrings("ctx alpha", ts.items.items[a].messages.items[0].api_text);
    try std.testing.expectEqualStrings("beta prompt", ts.items.items[b].messages.items[0].text);
    try std.testing.expectEqualStrings("ctx beta", ts.items.items[b].messages.items[0].api_text);
    try std.testing.expectEqualStrings("beta reply", ts.items.items[b].messages.items[1].text);

    // The session-level status is derived from the ACTIVE thread only.
    ts.active = a;
    try std.testing.expectEqual(Status.idle, ts.activeStatus());
    ts.items.items[b].status = .err;
    try std.testing.expectEqual(Status.idle, ts.activeStatus());
    ts.active = b;
    try std.testing.expectEqual(Status.err, ts.activeStatus());
}

test "threads: switching away cancels streaming and freezes the transcript" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);
    const a = try ts.create(alloc);
    const b = try ts.create(alloc);

    try ts.appendUser(alloc, a, "keep streaming", "ctx");
    try ts.beginAssistant(alloc, a);
    ts.markStreaming(alloc, a);
    try std.testing.expect(try ts.applyDelta(alloc, a, "AAA"));
    try std.testing.expectEqual(Status.streaming, ts.activeStatus());

    // Switch to B: A is cancelled and marked so late events are dropped.
    const r = ts.select(b);
    try std.testing.expect(r.cancelled);
    try std.testing.expectEqual(@as(usize, 1), ts.active);
    try std.testing.expectEqual(Status.cancelled, ts.items.items[a].status);
    try std.testing.expect(ts.items.items[a].cancel_requested);
    try std.testing.expectEqual(Status.idle, ts.activeStatus());
    try std.testing.expectEqual(@as(usize, 0), ts.streamingCount());

    // A late delta must not land anywhere — not in A, not in B.
    try std.testing.expect(!try ts.applyDelta(alloc, a, "LATE"));
    try std.testing.expectEqualStrings("AAA", ts.items.items[a].messages.items[1].text);
    try std.testing.expect(!try ts.applyDelta(alloc, b, "LATE"));
    try std.testing.expectEqual(@as(usize, 0), ts.items.items[b].messages.items.len);

    // B streams its own reply; A's frozen transcript stays untouched.
    try ts.appendUser(alloc, b, "b prompt", "ctx b");
    try ts.beginAssistant(alloc, b);
    ts.markStreaming(alloc, b);
    try std.testing.expect(try ts.applyDelta(alloc, b, "BBB"));
    try std.testing.expectEqualStrings("BBB", ts.items.items[b].messages.items[1].text);
    try std.testing.expectEqualStrings("AAA", ts.items.items[a].messages.items[1].text);

    // Switching back shows A's frozen transcript with cancelled status.
    const back = ts.select(a);
    try std.testing.expect(back.cancelled); // B was streaming, so this cancels B
    try std.testing.expectEqual(Status.cancelled, ts.items.items[b].status);
    try std.testing.expectEqual(Status.cancelled, ts.activeStatus());
    try std.testing.expectEqualStrings("AAA", ts.items.items[a].messages.items[1].text);
    try std.testing.expectEqual(@as(usize, 2), ts.items.items[a].messages.items.len);
}

test "threads: cancel only affects a live stream and late done leaves status alone" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);
    _ = try ts.create(alloc);
    try ts.appendUser(alloc, 0, "p", "c");
    try ts.beginAssistant(alloc, 0);
    ts.markStreaming(alloc, 0);
    try std.testing.expect(ts.cancel(0));
    try std.testing.expectEqual(Status.cancelled, ts.activeStatus());
    try std.testing.expect(!ts.cancel(0));
    // done arriving after a cancel must not resurrect the thread
    ts.finish(0);
    try std.testing.expectEqual(Status.cancelled, ts.activeStatus());
}

// ---------------------------------------------------------------------------
// Property-style invariants (M2.5)
//
// These are deterministic sweeps, not randomized: the layout model is pure
// and the state space is tiny, so checking every width/height in the useful
// range gives complete coverage with a fast, reproducible test.
// ---------------------------------------------------------------------------

test "property: layout partitions the width for every 40..200 columns" {
    var cols: u32 = 40;
    while (cols <= 200) : (cols += 1) {
        const open = layout(cols, true);
        const closed = layout(cols, false);
        try std.testing.expectEqual(RailMode.hidden, closed.mode);
        try std.testing.expectEqual(cols, closed.editor_width);
        try std.testing.expectEqual(@as(u32, 0), closed.rail_width);
        try std.testing.expectEqual(@as(u32, 0), closed.rail_col);

        try std.testing.expect(open.rail_width > 0);
        try std.testing.expect(open.rail_width <= cols);
        try std.testing.expectEqual(cols, open.rail_col + open.rail_width);
        switch (open.mode) {
            .hidden => return error.TestUnexpectedResult,
            .docked => {
                try std.testing.expect(cols >= 90);
                try std.testing.expectEqual(cols, open.editor_width + open.rail_width);
                try std.testing.expectEqual(open.editor_width, open.rail_col);
                try std.testing.expect(open.editor_width > 0);
                const expected: u32 = if (cols >= 110) 38 else 34;
                try std.testing.expectEqual(expected, open.rail_width);
            },
            .drawer => {
                try std.testing.expect(cols < 90);
                try std.testing.expectEqual(cols, open.editor_width);
                try std.testing.expect(open.rail_col >= 8);
                try std.testing.expectEqual(@min(@as(u32, 34), cols - 8), open.rail_width);
            },
        }

        // Breakpoint monotonicity: the reserved rail width never shrinks as
        // the terminal gets wider.
        if (cols < 200) {
            try std.testing.expect(railWidth(cols) <= railWidth(cols + 1));
        }
    }
}

test "property: rail breakpoints are exactly 90 and 110" {
    try std.testing.expectEqual(RailMode.drawer, layout(89, true).mode);
    try std.testing.expectEqual(@as(u32, 34), layout(89, true).rail_width);
    try std.testing.expectEqual(RailMode.docked, layout(90, true).mode);
    try std.testing.expectEqual(@as(u32, 34), layout(90, true).rail_width);
    try std.testing.expectEqual(RailMode.docked, layout(109, true).mode);
    try std.testing.expectEqual(@as(u32, 34), layout(109, true).rail_width);
    try std.testing.expectEqual(RailMode.docked, layout(110, true).mode);
    try std.testing.expectEqual(@as(u32, 38), layout(110, true).rail_width);
}

test "property: rail metrics stay inside the rail for 0..200 rows" {
    const tabs = [_]WorkboxTab{ .chat, .changes, .tools, .terminal };
    var rows: u32 = 0;
    while (rows <= 200) : (rows += 1) {
        for (tabs) |tab| {
            const m = metrics(rows, tab);
            try std.testing.expectEqual(rows, m.rail_rows);
            if (rows == 0) {
                try std.testing.expectEqual(@as(u32, 0), m.thread_rows);
                try std.testing.expectEqual(@as(u32, 0), m.body_rows);
                try std.testing.expect(m.prompt_row == null);
                continue;
            }
            if (rows < 8) {
                // Defensive metrics for terminals too short to render the
                // rail; the renderer refuses to draw below 8 rows, but the
                // model must still be arithmetic-safe.
                try std.testing.expect(m.divider_row < rows);
                try std.testing.expect(m.workbox_header_row < rows);
                try std.testing.expect(m.tabs_row < rows);
                try std.testing.expect(m.body_top <= rows);
                try std.testing.expectEqual(@as(u32, 0), m.body_rows);
                try std.testing.expect(m.prompt_row == null);
                continue;
            }
            try std.testing.expect(m.thread_rows >= 3 and m.thread_rows <= 8);
            try std.testing.expectEqual(@as(u32, 2), m.thread_top);
            try std.testing.expectEqual(m.thread_top + m.thread_rows, m.divider_row);
            try std.testing.expectEqual(m.divider_row + 1, m.workbox_header_row);
            try std.testing.expectEqual(m.workbox_header_row + 1, m.tabs_row);
            try std.testing.expectEqual(m.tabs_row + 1, m.body_top);
            try std.testing.expect(m.body_top <= m.rail_rows);
            try std.testing.expect(m.body_top + m.body_rows <= m.rail_rows);
            if (m.prompt_row) |p| {
                try std.testing.expect(p < m.rail_rows);
                try std.testing.expect(p >= m.body_top);
                try std.testing.expectEqual(m.rail_rows - 1, p);
                try std.testing.expect(tab == .chat);
            }
        }
    }
}

test "property: extreme dimensions never panic or overflow" {
    const widths = [_]u32{ 0, 1, 7, 8, 9, 39, 40, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
    const heights = [_]u32{ 0, 1, 2, 3, 7, 8, 9, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
    const tabs = [_]WorkboxTab{ .chat, .changes, .tools, .terminal };
    for (widths) |cols| {
        const open = layout(cols, true);
        if (cols >= 12) {
            try std.testing.expectEqual(cols, open.rail_col + open.rail_width);
        } else {
            // Below the drawer's 8-column margin the model still yields a
            // non-empty rail; the renderer refuses to draw it at all, so the
            // only contract here is "no panic and a usable width".
            try std.testing.expect(open.rail_width >= 1);
        }
        try std.testing.expect(open.rail_width <= cols or cols < 12);
        const hidden = layout(cols, false);
        try std.testing.expectEqual(cols, hidden.editor_width);
        try std.testing.expectEqual(@as(u32, 0), hidden.rail_width);
    }
    for (heights) |rows| {
        for (tabs) |tab| {
            const m = metrics(rows, tab);
            try std.testing.expectEqual(rows, m.rail_rows);
            if (rows >= 8) {
                try std.testing.expect(m.body_top + m.body_rows <= rows);
                if (m.prompt_row) |p| try std.testing.expect(p < rows);
            }
        }
    }
}

fn validFocusState(open: bool, focus: Focus) bool {
    // A closed rail always owns no focus; an open rail may be navigated
    // from the editor (non-modal dock) or own a rail/prompt focus.
    if (!open) return focus == .editor;
    return switch (focus) {
        .editor, .rail, .prompt => true,
    };
}

test "property: focus transitions never produce an invalid state" {
    for ([_]bool{ false, true }) |open| {
        for ([_]Focus{ .editor, .rail, .prompt }) |focus| {
            for ([_]bool{ false, true }) |narrow| {
                const toggled = toggleRail(open, focus);
                try std.testing.expect(validFocusState(toggled.open, toggled.focus));
                try std.testing.expectEqual(!open, toggled.open);
                try std.testing.expectEqual(if (open) Focus.editor else Focus.prompt, toggled.focus);

                const left = leaveRail(open, focus, narrow);
                try std.testing.expect(validFocusState(left.open, left.focus));
                try std.testing.expectEqual(Focus.editor, left.focus);
                if (!open or focus == .editor) {
                    try std.testing.expectEqual(open, left.open);
                } else if (narrow) {
                    try std.testing.expect(!left.open);
                } else {
                    try std.testing.expect(left.open);
                }

                const focused = focusRail();
                try std.testing.expect(validFocusState(focused.open, focused.focus));
                try std.testing.expect(focused.open);
                try std.testing.expectEqual(Focus.rail, focused.focus);
            }
        }
    }
    // Prompt -> thread list -> prompt round trip.
    try std.testing.expectEqual(Focus.rail, fromPromptTab());
    try std.testing.expectEqual(Focus.prompt, fromRailEnter());
}

test "threads: tool messages preserve order, ids and owned content" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);
    const a = try ts.create(alloc);
    try ts.appendUser(alloc, a, "read a file", "ctx");
    try ts.beginAssistant(alloc, a);
    ts.items.items[a].status = .streaming;
    try std.testing.expect(try ts.applyDelta(alloc, a, "let me look"));
    try ts.setAssistantToolCalls(alloc, a, "[{\"id\":\"call_1\"}]");
    const card = try ts.appendToolMessage(alloc, a, "call_1", "read_file", "a.zig", .running, "");
    try ts.setToolOutcome(alloc, a, card, .ok, "const x = 1;", "path: a.zig\n---\nconst x = 1;", 7);

    const msgs = ts.items.items[a].messages.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqualStrings("let me look", msgs[1].text);
    try std.testing.expectEqualStrings("[{\"id\":\"call_1\"}]", msgs[1].tool_calls_json.?);
    try std.testing.expectEqual(Role.tool, msgs[2].role);
    try std.testing.expectEqualStrings("call_1", msgs[2].tool_call_id.?);
    try std.testing.expectEqualStrings("read_file", msgs[2].tool_name.?);
    try std.testing.expectEqualStrings("a.zig", msgs[2].tool_args.?);
    try std.testing.expectEqual(ToolStatus.ok, msgs[2].tool_status);
    try std.testing.expectEqual(@as(u32, 7), msgs[2].tool_ms);
    try std.testing.expectEqualStrings("const x = 1;", msgs[2].text);
    try std.testing.expectEqualStrings("path: a.zig\n---\nconst x = 1;", msgs[2].api_text);
    try std.testing.expect(!msgs[2].tool_expanded);

    // Failed updates do not corrupt the card.
    ts.items.items[a].messages.items[2].tool_expanded = true;
    ts.cancelRunningTools(a);
    try std.testing.expectEqual(ToolStatus.ok, ts.items.items[a].messages.items[2].tool_status);

    // A placeholder-only assistant with calls is never dropped as "empty".
    ts.dropEmptyAssistant(alloc, a);
    try std.testing.expectEqual(@as(usize, 3), ts.items.items[a].messages.items.len);
}

test "threads: cancelling tool cards is display-only and idempotent" {
    const alloc = std.testing.allocator;
    var ts: Threads = .{};
    defer ts.deinit(alloc);
    _ = try ts.create(alloc);
    try ts.appendUser(alloc, 0, "go", "go");
    _ = try ts.appendToolMessage(alloc, 0, "c1", "grep", "x", .running, "");
    _ = try ts.appendToolMessage(alloc, 0, "c2", "grep", "y", .ok, "found");
    ts.cancelRunningTools(0);
    ts.cancelRunningTools(0);
    try std.testing.expectEqual(ToolStatus.cancelled, ts.items.items[0].messages.items[1].tool_status);
    try std.testing.expectEqual(ToolStatus.ok, ts.items.items[0].messages.items[2].tool_status);
}
