//! AI workspace (M2a): docked Agent Rail + Workbox.
//!
//! State lives at session level (`App.ai`), not per workspace: closing the
//! rail or switching workspaces never drops a thread. The pure layout /
//! focus / thread model is `src/ai/workspace.zig`; this file owns the
//! transport (one client per thread), key routing and rendering.
const std = @import("std");
const vaxis = @import("vaxis");

const buffer = @import("../buffer/root.zig");
const theme = @import("../theme.zig");
const ai = @import("../ai/root.zig");
const agent = @import("../ai/agent.zig");
const turn = @import("../ai/turn.zig");
const chart = @import("../chart.zig");
const autil = @import("util.zig");
const chrome = @import("chrome.zig");
const animation = @import("animation.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const ws = ai.workspace;
const tool_job = @import("tool_job.zig");
const app_agent_edit = @import("agent_edit_ui.zig");

pub const Status = ws.Status;
pub const Role = ws.Role;
pub const Message = ws.Message;
pub const AgentThread = ws.Thread;
pub const Focus = ws.Focus;
pub const WorkboxTab = ws.WorkboxTab;

/// Per-thread agent-loop/tool state. Parallel to `threads.items` (cards and
/// metrics are per thread: no cross-thread contamination), but kept here so
/// the pure workspace model stays UI/worker independent.
pub const ToolThreadState = struct {
    /// Captured when a user turn starts. Follow-ups keep using the same
    /// workspace root even if the visible workspace switched meanwhile.
    root: ?[]u8 = null,
    /// Tool batches started in this user turn (agent.max_tool_rounds).
    rounds: u8 = 0,
    /// Tool calls admitted for execution this user turn.
    calls: u8 = 0,
    /// A worker batch is in flight (cards show running).
    active: bool = false,
    /// The current stream's terminal event arrived.
    stream_done: bool = false,
    /// Batch finished; a follow-up request is due once the stream settles.
    pending_followup: bool = false,
    /// The pending follow-up is the final no-tools request (loop limit hit).
    final_only: bool = false,
    /// A no-tools final request was already sent: refuse further tool calls.
    final_sent: bool = false,
    /// Bumped whenever work is cancelled; stale job results are discarded.
    generation: u64 = 0,
    /// Message indices of the cards the in-flight job fills, in call order.
    pending_cards: [agent.max_tool_calls_per_turn]usize = @splat(0),
    pending_card_count: usize = 0,
    /// Dim transcript note explaining a stopped loop (owned).
    note: ?[]u8 = null,
    metrics: agent.Metrics = .{},

    fn deinit(self: *ToolThreadState, alloc: std.mem.Allocator) void {
        if (self.root) |r| alloc.free(r);
        if (self.note) |n| alloc.free(n);
        self.metrics.deinit(alloc);
        self.* = undefined;
    }
};

/// Cached Tools-tab chart. Recomputed only when the active thread, the
/// metrics revision or the body dimensions change (agent.ChartKey).
pub const ChartCache = struct {
    key: agent.ChartKey = .{},
    canvas: ?chart.Canvas = null,

    fn clear(self: *ChartCache, alloc: std.mem.Allocator) void {
        if (self.canvas) |*c| c.deinit(alloc);
        self.canvas = null;
        self.key = .{};
    }
};

/// Session-wide AI state. Deliberately NOT per workspace: closing the rail
/// keeps every thread, switching workspaces keeps the same list. Not
/// persisted to disk.
pub const Session = struct {
    config: ?ai.config.Config = null,
    threads: ws.Threads = .{},
    /// One transport client per thread (parallel to `threads.items`); a
    /// thread's own client is what keeps late deltas out of another thread's
    /// transcript. `null` slots are created lazily on the first send.
    clients: std.ArrayList(?*ai.client.Client) = .empty,
    /// Tool loop state + metrics per thread (parallel to `threads.items`).
    tool_states: std.ArrayList(ToolThreadState) = .empty,
    /// At most one background tool batch per thread.
    tool_jobs: std.ArrayList(?*tool_job.Job) = .empty,
    chart_cache: ChartCache = .{},
    rail_open: bool = false,
    focus: Focus = .editor,
    tab: WorkboxTab = .chat,
    /// Thread-list cursor (may differ from `threads.active` until Enter).
    thread_cursor: usize = 0,
    thread_top: usize = 0,
    /// `<leader>` pressed while the thread list owns the keyboard, awaiting
    /// the hint-mode key (`j`). The rail consumes every printable key, so
    /// `<leader>j` must be recognized here rather than in editor.Mode.
    rail_pending_leader: bool = false,
};

/// Keep the per-thread sidecars (client/tool state/job) exactly parallel to
/// the pure thread list. Threads are never deleted in M3a, so appending is
/// enough.
fn syncAiSidecars(self: *App) !void {
    const n = self.ai.threads.items.items.len;
    while (self.ai.clients.items.len < n) try self.ai.clients.append(self.alloc, null);
    while (self.ai.tool_states.items.len < n) try self.ai.tool_states.append(self.alloc, .{});
    while (self.ai.tool_jobs.items.len < n) try self.ai.tool_jobs.append(self.alloc, null);
}

fn toolState(self: *App, idx: usize) ?*ToolThreadState {
    if (idx >= self.ai.tool_states.items.len) return null;
    return &self.ai.tool_states.items[idx];
}

fn setToolNote(self: *App, idx: usize, text: []const u8) void {
    const st = toolState(self, idx) orelse return;
    if (st.note) |old| self.alloc.free(old);
    st.note = self.alloc.dupe(u8, text) catch null;
}

// ---- layout / lifecycle ----

/// Rail geometry for the current terminal width. Renderers must use
/// `editor_width` for every editor/file-tree/split calculation so the rail
/// never draws over editor cells (and drawer mode keeps the editor full
/// width underneath).
pub fn aiLayout(self: *App) ws.Layout {
    return ws.layout(self.vx.window().width, self.ai.rail_open);
}

pub fn aiEditorWidth(self: *App) u32 {
    return aiLayout(self).editor_width;
}

pub fn aiThread(self: *App) *AgentThread {
    return self.ai.threads.activeThread();
}

/// Cancel every piece of work owned by thread `idx`: the transport, the
/// in-flight tool batch (its generation is invalidated so late results can
/// never land) and any running cards. Safe for threads without a client/job.
fn cancelClient(self: *App, idx: usize) void {
    if (idx < self.ai.clients.items.len) {
        if (self.ai.clients.items[idx]) |c| c.requestCancel();
    }
    if (toolState(self, idx)) |st| {
        st.generation +%= 1;
        st.active = false;
        st.pending_followup = false;
        st.final_only = false;
        st.pending_card_count = 0;
    }
    if (idx < self.ai.tool_jobs.items.len) {
        if (self.ai.tool_jobs.items[idx]) |job| job.requestCancel();
    }
    if (idx < self.ai.threads.items.items.len) {
        self.ai.threads.cancelRunningTools(idx);
    }
}

fn resetToolTurn(self: *App, idx: usize) void {
    const st = toolState(self, idx) orelse return;
    st.rounds = 0;
    st.calls = 0;
    st.active = false;
    st.stream_done = false;
    st.pending_followup = false;
    st.final_only = false;
    st.final_sent = false;
    st.pending_card_count = 0;
    if (st.note) |n| {
        self.alloc.free(n);
        st.note = null;
    }
}

/// Create the first thread lazily (the rail may never be opened).
pub fn ensureAi(self: *App) !void {
    try syncAiSidecars(self);
    if (self.ai.threads.items.items.len == 0) {
        try self.ai.clients.append(self.alloc, null);
        errdefer _ = self.ai.clients.pop();
        try self.ai.tool_states.append(self.alloc, .{});
        errdefer _ = self.ai.tool_states.pop();
        try self.ai.tool_jobs.append(self.alloc, null);
        const idx = self.ai.threads.create(self.alloc) catch |e| {
            _ = self.ai.tool_jobs.pop();
            return e;
        };
        self.ai.threads.active = idx;
        self.ai.thread_cursor = idx;
        self.ai.thread_top = 0;
        try syncAiSidecars(self);
    }
    if (self.ai.thread_cursor >= self.ai.threads.items.items.len) {
        self.ai.thread_cursor = self.ai.threads.items.items.len - 1;
    }
}

fn threadVisibleRows(self: *App) u32 {
    const rows = self.vx.window().height -| app_mod.status_row_count;
    return ws.metrics(rows, self.ai.tab).thread_rows;
}

fn ensureThreadVisible(self: *App) void {
    const vis = threadVisibleRows(self);
    if (vis == 0) return;
    const n = self.ai.threads.items.items.len;
    if (n <= vis) {
        self.ai.thread_top = 0;
        return;
    }
    if (self.ai.thread_top + vis > n) self.ai.thread_top = n - vis;
    if (self.ai.thread_cursor < self.ai.thread_top) self.ai.thread_top = self.ai.thread_cursor;
    if (self.ai.thread_cursor >= self.ai.thread_top + vis) {
        self.ai.thread_top = self.ai.thread_cursor - vis + 1;
    }
}

/// `<leader>a`: toggle the rail. Opening focuses the prompt; closing returns
/// focus to the editor. See `ai.workspace.toggleRail` for the policy.
pub fn toggleAiPanel(self: *App) !void {
    self.navigator_peek = false; // never stack the drawer over a nav peek
    const state = ws.toggleRail(self.ai.rail_open, self.ai.focus);
    self.ai.rail_open = state.open;
    self.ai.focus = state.focus;
    if (state.open) {
        try ensureAi(self);
        self.ai.tab = .chat;
        self.ai.thread_cursor = self.ai.threads.active;
        ensureThreadVisible(self);
        // A config failure is surfaced in the workbox; opening the rail must
        // never make the editor unusable.
        aiLoadConfig(self) catch {};
        // Opening is a modal transition: nothing editor-side may be pending.
        self.ai.rail_pending_leader = false;
        self.pending_window = false;
        self.pending_replace = null;
        if (self.msg) |m| {
            self.alloc.free(m);
            self.msg = null;
        }
    }
}

/// `Ctrl+w a`: re-focus the rail from the editor, landing on the thread
/// list. Opens the rail when closed.
pub fn focusAiRail(self: *App) !void {
    try ensureAi(self);
    self.navigator_peek = false;
    self.ai.rail_pending_leader = false;
    const state = ws.focusRail();
    self.ai.rail_open = state.open;
    self.ai.focus = state.focus;
    self.ai.thread_cursor = self.ai.threads.active;
    ensureThreadVisible(self);
    aiLoadConfig(self) catch {};
}

/// Esc / q from the rail or prompt. Wide mode keeps the rail visible and
/// returns keys to the editor; the narrow drawer closes.
fn aiLeaveRail(self: *App) void {
    self.ai.rail_pending_leader = false;
    const narrow = aiLayout(self).mode == .drawer;
    const state = ws.leaveRail(self.ai.rail_open, self.ai.focus, narrow);
    self.ai.rail_open = state.open;
    self.ai.focus = state.focus;
}

/// Append a new thread, cancel the previously active stream (switching
/// policy), and attach to the new thread's prompt.
pub fn aiNewThread(self: *App) !void {
    try ensureAi(self);
    self.navigator_peek = false;
    try self.ai.clients.append(self.alloc, null);
    errdefer _ = self.ai.clients.pop();
    try self.ai.tool_states.append(self.alloc, .{});
    errdefer _ = self.ai.tool_states.pop();
    try self.ai.tool_jobs.append(self.alloc, null);
    const idx = self.ai.threads.create(self.alloc) catch |e| {
        _ = self.ai.tool_jobs.pop();
        return e;
    };
    const res = self.ai.threads.select(idx);
    if (res.cancelled) cancelClient(self, res.prev);
    self.ai.thread_cursor = idx;
    self.ai.tab = .chat;
    self.ai.focus = .prompt;
    ensureThreadVisible(self);
}

fn selectThreadAtCursor(self: *App) void {
    if (self.ai.threads.items.items.len == 0) return;
    self.aiSelectThread(@min(self.ai.thread_cursor, self.ai.threads.items.items.len - 1));
}

/// Attach to thread `idx` exactly like Enter in the thread list. Out-of-range
/// indices are a no-op (hint targets can be stale for one frame).
pub fn aiSelectThread(self: *App, idx: usize) void {
    if (idx >= self.ai.threads.items.items.len) return;
    self.navigator_peek = false;
    const res = self.ai.threads.select(idx);
    if (res.cancelled) cancelClient(self, res.prev);
    self.ai.thread_cursor = idx;
    self.ai.focus = .prompt;
    self.ai.tab = .chat;
    ensureThreadVisible(self);
}

/// Focus the workbox prompt from a hint target: opens the rail if needed
/// (defensive — the prompt target only exists while the rail is drawn),
/// attaches to the active thread and moves keyboard focus to its input row.
pub fn aiFocusPrompt(self: *App) !void {
    try ensureAi(self);
    self.navigator_peek = false;
    self.ai.rail_open = true;
    self.ai.focus = .prompt;
    self.ai.tab = .chat;
    self.ai.thread_cursor = self.ai.threads.active;
    ensureThreadVisible(self);
    aiLoadConfig(self) catch {};
}

/// Switch the Workbox tab (same method the rail's c/d/t/r keys use).
pub fn aiSetWorkboxTab(self: *App, tab: WorkboxTab) void {
    self.ai.tab = tab;
}

/// Hint action: expand/collapse a tool card's result excerpt. Bounds-checked
/// because a hint target may outlive a re-render by one frame.
pub fn aiToggleToolCard(self: *App, msg_index: usize) void {
    if (self.ai.threads.items.items.len == 0) return;
    const t = self.ai.threads.activeThread();
    if (msg_index >= t.messages.items.len) return;
    const msg = &t.messages.items[msg_index];
    if (msg.role != .tool) return;
    msg.tool_expanded = !msg.tool_expanded;
}

fn moveThreadCursor(self: *App, delta: i32) void {
    if (self.ai.threads.items.items.len == 0) return;
    var idx: i32 = @intCast(@min(self.ai.thread_cursor, self.ai.threads.items.items.len - 1));
    idx += delta;
    if (idx < 0) idx = 0;
    const max: i32 = @intCast(self.ai.threads.items.items.len - 1);
    if (idx > max) idx = max;
    self.ai.thread_cursor = @intCast(idx);
    ensureThreadVisible(self);
}

fn setWorkboxTab(self: *App, tab: WorkboxTab) void {
    self.ai.tab = tab;
}

fn cycleWorkboxTab(self: *App, delta: i32) void {
    const n: i32 = @typeInfo(WorkboxTab).@"enum".field_names.len;
    var idx: i32 = @backingInt(self.ai.tab);
    idx = @mod(idx + delta, n);
    self.ai.tab = @fromBackingInt(@intCast(@as(u8, @intCast(idx))));
}

pub fn aiLoadConfig(self: *App) !void {
    if (self.ai.config != null) return;
    self.ai.config = ai.config.fromEnv(self.alloc, self.env_map) catch |e| {
        self.aiSetErrorFmt("config: {s}", .{@errorName(e)});
        return e;
    };
}

pub fn aiSetError(self: *App, text: []const u8) void {
    if (self.ai.threads.items.items.len == 0) return;
    self.ai.threads.fail(self.alloc, self.ai.threads.active, text);
}

pub fn aiSetErrorFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    if (self.ai.threads.items.items.len == 0) return;
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    defer self.alloc.free(text);
    self.ai.threads.fail(self.alloc, self.ai.threads.active, text);
}

fn aiSetThreadError(self: *App, idx: usize, text: []const u8) void {
    if (idx < self.ai.threads.items.items.len) {
        self.ai.threads.fail(self.alloc, idx, text);
    }
}

fn aiSetThreadErrorFmt(self: *App, idx: usize, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    defer self.alloc.free(text);
    aiSetThreadError(self, idx, text);
}

/// True while ANY thread's worker is alive or has queued events: the run
/// loop polls instead of blocking so deltas (from the active thread or a
/// cancelled thread winding down) are drained without a keypress.
pub fn aiStreaming(self: *App) bool {
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| {
            if (c.isRunning() or c.hasEvents()) return true;
        }
    }
    // A tool batch keeps the run loop polling (1ms slices) so its completion
    // is consumed without a keypress; `drainToolJobs` then clears the slot.
    for (self.ai.tool_jobs.items) |maybe| {
        if (maybe != null) return true;
    }
    return false;
}

pub fn deinitAi(self: *App) void {
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| c.requestCancel();
    }
    for (self.ai.tool_jobs.items) |maybe| {
        if (maybe) |j| j.requestCancel();
    }
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| {
            c.deinit();
            self.alloc.destroy(c);
        }
    }
    for (self.ai.tool_jobs.items) |maybe| {
        if (maybe) |j| j.deinit();
    }
    // Chart cells reference metric-owned series names only textually;
    // release the canvas first so shutdown order stays obvious.
    self.ai.chart_cache.clear(self.alloc);
    for (self.ai.tool_states.items) |*st| st.deinit(self.alloc);
    self.ai.clients.deinit(self.alloc);
    self.ai.tool_states.deinit(self.alloc);
    self.ai.tool_jobs.deinit(self.alloc);
    self.ai.threads.deinit(self.alloc);
    if (self.ai.config) |*cfg| cfg.deinit(self.alloc);
    self.ai.config = null;
}

// ---- input ----

pub fn handleAiKey(self: *App, key: vaxis.Key) !void {
    switch (self.ai.focus) {
        .editor => {},
        .rail => try handleAiRailKey(self, key),
        .prompt => try handleAiPromptKey(self, key),
    }
}

fn handleAiPromptKey(self: *App, key: vaxis.Key) !void {
    if (self.ai.threads.items.items.len == 0) return;
    const t = self.ai.threads.activeThread();
    switch (ai.panel.classify(key)) {
        .close => aiLeaveRail(self),
        .send => try aiSend(self),
        .cancel => aiCancel(self),
        .new_thread => try aiNewThread(self),
        .focus_rail => {
            self.ai.focus = ws.fromPromptTab();
            self.ai.thread_cursor = self.ai.threads.active;
            ensureThreadVisible(self);
        },
        .scroll_up => aiScroll(self, -1),
        .scroll_down => aiScroll(self, 1),
        .page_up => aiScroll(self, -@as(i64, @intCast(@max(t.view_rows, 1)))),
        .page_down => aiScroll(self, @as(i64, @intCast(@max(t.view_rows, 1)))),
        .backspace => {
            if (t.input.items.len > 0) {
                const cut = buffer.utf8.prevBoundary(t.input.items, t.input.items.len);
                t.input.shrinkRetainingCapacity(cut);
            }
        },
        .text => if (key.text) |text| {
            // key.text is one complete UTF-8 sequence (vaxis reports text
            // per key event); appending it verbatim can never split bytes.
            try t.input.appendSlice(self.alloc, text);
        },
        .ignore => {},
    }
}

fn handleAiRailKey(self: *App, key: vaxis.Key) !void {
    // <leader>j: enter hint mode from the thread list (the rail swallows all
    // printable keys, so this two-key sequence is owned here). Only `j` is
    // meaningful after the leader; other keys cancel the pending sequence,
    // matching editor.Mode's leader behavior.
    if (self.ai.rail_pending_leader) {
        self.ai.rail_pending_leader = false;
        if (key.codepoint == 'j' and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            self.beginHintMode();
        }
        return;
    }
    if (key.codepoint == ' ' and key.mods.eql(.{})) {
        self.ai.rail_pending_leader = true;
        return;
    }
    // Changes tab with a pending inline edit: a/Enter approve, r/d reject,
    // j/k scroll the cached diff. These consume the tab-switch keys only
    // while a review is on screen (documented in README/DESIGN).
    if (try self.handleAgentEditChangesKey(key)) return;
    if (try self.handleInlineChangesKey(key)) return;
    switch (ai.panel.classifyRail(key)) {
        .up => moveThreadCursor(self, -1),
        .down => moveThreadCursor(self, 1),
        .select_thread => selectThreadAtCursor(self),
        .new_thread => try aiNewThread(self),
        .tab_chat => setWorkboxTab(self, .chat),
        .tab_changes => setWorkboxTab(self, .changes),
        .tab_tools => setWorkboxTab(self, .tools),
        .tab_terminal => setWorkboxTab(self, .terminal),
        .tab_next => cycleWorkboxTab(self, 1),
        .tab_prev => cycleWorkboxTab(self, -1),
        .focus_editor => aiLeaveRail(self),
        .cancel => aiCancel(self),
        .ignore => {},
    }
}

/// Paste/OSC-52 text while the rail owns the keyboard. Only the prompt
/// accepts text; the thread list ignores it (no accidental drafts).
pub fn aiPaste(self: *App, text: []const u8) !void {
    if (self.ai.focus != .prompt or self.ai.threads.items.items.len == 0) return;
    try self.ai.threads.activeThread().input.appendSlice(self.alloc, text);
}

/// Mouse wheel over the workbox body: scroll whatever the active tab shows
/// (chat transcript, pending diff) using the SAME clamped scroll state the
/// keyboard j/k path uses. Tabs without scroll state are a no-op.
pub fn aiScrollWheel(self: *App, delta: i64) void {
    if (self.ai.threads.items.items.len == 0) return;
    switch (self.ai.tab) {
        .chat => aiScroll(self, delta),
        .changes => {
            if (self.agentEditVisible()) {
                self.agentEditScrollBy(delta);
            } else if (self.inline_edit.pending != null) {
                self.inlineScrollBy(delta);
            }
        },
        else => {},
    }
}

/// Public wrapper for the thread-list selection move (wheel over the rail's
/// thread list). Same clamp as j/k.
pub fn aiMoveThreadCursor(self: *App, delta: i32) void {
    moveThreadCursor(self, delta);
}

pub fn aiScroll(self: *App, delta: i64) void {
    if (self.ai.threads.items.items.len == 0) return;
    const t = self.ai.threads.activeThread();
    t.auto_scroll = false;
    const max_top = t.total_rows -| t.view_rows;
    var top: i64 = @intCast(@min(t.scroll, max_top));
    top += delta;
    if (top < 0) top = 0;
    if (top > max_top) top = max_top;
    t.scroll = @intCast(top);
}

pub fn aiCancel(self: *App) void {
    if (self.ai.threads.items.items.len == 0) return;
    const idx = self.ai.threads.active;
    const streaming = self.ai.threads.cancel(idx);
    // Ctrl+c also stops a tool loop whose stream already finished but whose
    // worker/follow-up is still live. `cancelClient` freezes running cards
    // and invalidates the job generation.
    const tool_live = if (toolState(self, idx)) |st| st.active or st.pending_followup else false;
    if (streaming or tool_live) cancelClient(self, idx);
}

/// Build the provider request for the active prompt, append the messages,
/// and start that thread's background stream. Errors are surfaced in the
/// thread's workbox.
const RequestPlan = struct {
    body: []u8,
    url: []u8,

    fn deinit(self: *RequestPlan, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.url);
    }
};

/// Serialize the thread's transcript (+ optional new user turn) into an
/// OpenAI-compatible request. `include_tools` adds the M3 tool definitions
/// and `tool_choice:"auto"`; the final no-tools follow-up omits both.
fn buildThreadBody(
    self: *App,
    idx: usize,
    include_tools: bool,
    extra_user: ?[]const u8,
) !RequestPlan {
    const cfg = &(self.ai.config orelse return error.ConfigUnavailable);
    const t = &self.ai.threads.items.items[idx];
    const req_msgs = try turn.buildMessages(self.alloc, t.messages.items, extra_user);
    defer self.alloc.free(req_msgs);

    const base = try ai.openai.buildRequestBody(self.alloc, cfg.model, cfg.system, req_msgs);
    defer self.alloc.free(base);
    const body = if (include_tools)
        try ai.tools.appendTools(self.alloc, base)
    else
        try self.alloc.dupe(u8, base);
    errdefer self.alloc.free(body);
    const url = try std.fmt.allocPrint(self.alloc, "{s}/chat/completions", .{cfg.base_url});
    return .{ .body = body, .url = url };
}

fn ensureThreadClient(self: *App, idx: usize) !*ai.client.Client {
    try syncAiSidecars(self);
    if (idx >= self.ai.clients.items.len) return error.IndexOutOfRange;
    const slot = &self.ai.clients.items[idx];
    if (slot.* == null) {
        const c = try self.alloc.create(ai.client.Client);
        c.* = ai.client.Client.init(self.alloc, self.io);
        slot.* = c;
    }
    return slot.*.?;
}

/// Start one stream for `idx`. The caller has already appended any user /
/// assistant messages; this only cancels other live work, starts the
/// worker, and flips the thread to streaming.
fn startThreadRequest(self: *App, idx: usize, plan: *RequestPlan) !void {
    const cfg = &(self.ai.config orelse return error.ConfigUnavailable);
    // Exactly one live stream/agent loop at a time (defensive invariant).
    for (self.ai.threads.items.items, 0..) |_, oi| {
        if (oi == idx) continue;
        const streaming = self.ai.threads.cancel(oi);
        const tool_live = if (toolState(self, oi)) |st| st.active or st.pending_followup else false;
        if (streaming or tool_live) cancelClient(self, oi);
    }
    const client = try ensureThreadClient(self, idx);
    client.start(.{
        .url = plan.url,
        .api_key = cfg.api_key,
        .body = plan.body,
        .mock_dir = cfg.mock_dir,
    }) catch |e| {
        std.log.debug("ai start failed: {s}", .{@errorName(e)});
        return error.StartFailed;
    };
    self.ai.threads.markStreaming(self.alloc, idx);
    if (toolState(self, idx)) |st| {
        st.stream_done = false;
        st.active = false;
    }
}

/// Issue the automatic follow-up request after a tool batch (or the final
/// no-tools request once a loop limit was hit). A new assistant bubble is
/// created for the streamed answer; on any failure it is removed and the
/// thread reports the error instead of hanging.
fn issueFollowup(self: *App, idx: usize, include_tools: bool) !void {
    if (idx >= self.ai.threads.items.items.len) return;
    try self.ai.threads.beginAssistant(self.alloc, idx);
    var plan = buildThreadBody(self, idx, include_tools, null) catch |e| {
        self.ai.threads.dropEmptyAssistant(self.alloc, idx);
        aiSetThreadError(self, idx, @errorName(e));
        return e;
    };
    defer plan.deinit(self.alloc);
    startThreadRequest(self, idx, &plan) catch |e| {
        self.ai.threads.dropEmptyAssistant(self.alloc, idx);
        aiSetThreadError(self, idx, "start failed");
        return e;
    };
    if (toolState(self, idx)) |st| {
        st.pending_followup = false;
        if (!include_tools) st.final_sent = true;
    }
}

/// Called when a batch has finished AND its stream's terminal event has
/// been consumed. Starts the next request (tools enabled) or, once the
/// round/call budget is spent or the model already got its final no-tools
/// turn, settles the thread at idle. Returns true when it acted.
fn maybeFollowup(self: *App, idx: usize) !bool {
    const t = &self.ai.threads.items.items[idx];
    const st = toolState(self, idx) orelse return false;
    if (t.cancel_requested or t.status != .streaming) return false;
    if (!st.stream_done or !st.pending_followup or st.active) return false;

    if (st.final_sent) {
        st.pending_followup = false;
        self.ai.threads.finish(idx);
        return true;
    }
    const include_tools = !st.final_only;
    try issueFollowup(self, idx, include_tools);
    return true;
}

fn stopToolLoop(self: *App, idx: usize, reason: agent.LimitReason) void {
    const st = toolState(self, idx) orelse return;
    const note = agent.limitNote(self.alloc, reason, .{}) catch return;
    defer self.alloc.free(note);
    setToolNote(self, idx, note);
    st.final_only = true;
}

pub fn aiSend(self: *App) !void {
    if (self.ai.threads.items.items.len == 0) return;
    const idx = self.ai.threads.active;
    const t = &self.ai.threads.items.items[idx];
    if (t.status == .streaming) return;
    const prompt = std.mem.trim(u8, t.input.items, " \t\r\n");
    if (prompt.len == 0) return;
    try aiLoadConfig(self);
    if (self.ai.config == null) {
        aiSetThreadError(self, idx, "config unavailable");
        return;
    }
    try syncAiSidecars(self);

    if (t.error_text) |e| {
        self.alloc.free(e);
        t.error_text = null;
    }

    // Editor context: file path + selection or a cursor window (bounded).
    const text = try self.curText();
    defer self.alloc.free(text);
    var selection: ?ai.context.Selection = null;
    if (self.isVisual()) {
        if (self.visual_anchor) |anchor| {
            const pt = &self.cur().pt;
            const cursor = self.curCursor().*;
            var start = @min(anchor, cursor);
            var end = @max(anchor, cursor);
            if (self.state.mode == .visual_line) {
                const first = pt.lineOf(start);
                const last = pt.lineOf(end);
                start = pt.lineStart(first);
                end = pt.lineStart(last) + pt.lineLen(last);
                if (end < pt.len()) end += 1;
            } else {
                end = @min(end + self.charLenAt(pt, end), pt.len());
            }
            selection = .{ .start = start, .end = end };
        }
    }
    const context = try ai.context.build(self.alloc, .{
        .path = self.cur().path,
        .text = text,
        .cursor = self.curCursor().*,
        .selection = selection,
    }, .{});
    defer self.alloc.free(context);

    const prompt_copy = try self.alloc.dupe(u8, prompt);
    defer self.alloc.free(prompt_copy);
    const api_text = try std.fmt.allocPrint(self.alloc, "{s}\nUser request:\n{s}", .{ context, prompt });
    defer self.alloc.free(api_text);

    var plan = try buildThreadBody(self, idx, true, api_text);
    defer plan.deinit(self.alloc);

    // The tool root is captured once per user turn: follow-up rounds keep
    // reading the same workspace even if the visible workspace changes.
    const st = toolState(self, idx) orelse return error.ToolStateUnavailable;
    if (st.root) |old| self.alloc.free(old);
    st.root = self.currentRootDir() catch null;
    resetToolTurn(self, idx);

    self.ai.threads.appendUser(self.alloc, idx, prompt, api_text) catch |e| {
        aiSetThreadError(self, idx, @errorName(e));
        return e;
    };
    self.ai.threads.beginAssistant(self.alloc, idx) catch |e| {
        aiSetThreadError(self, idx, @errorName(e));
        return e;
    };
    startThreadRequest(self, idx, &plan) catch |e| {
        self.ai.threads.dropEmptyAssistant(self.alloc, idx);
        aiSetThreadError(self, idx, "start failed");
        return e;
    };

    t.input.clearRetainingCapacity();
    t.scroll = 0;
    t.auto_scroll = true;
}

fn displayToolStatus(status: agent.CardStatus) ws.ToolStatus {
    return switch (status) {
        .running => .running,
        .ok => .ok,
        .err => .err,
        .approval_required => .approval_required,
        .approved => .approved,
        .rejected => .rejected,
        .unsupported => .unsupported,
        .cancelled => .cancelled,
    };
}

fn mapOutcomeStatus(status: ai.tool_exec.Status) agent.CardStatus {
    return switch (status) {
        .ok => .ok,
        .err => .err,
        .approval_required => .approval_required,
        .unsupported => .unsupported,
    };
}

/// Handle one streamed assistant turn's tool calls: attach the OpenAI
/// tool-call turn to the transcript, create compact cards, execute only the
/// admitted read-only prefix on a worker, and leave the rest truthfully
/// unexecuted. `edit_file` and `apply_patch` are intercepted and staged for
/// human review; they are never sent to the executor, so no write can happen
/// here. Ownership of `calls` is consumed in every branch.
fn aiHandleToolCalls(self: *App, idx: usize, calls: []ai.tools.ToolCall) void {
    const t = &self.ai.threads.items.items[idx];
    const st = toolState(self, idx);
    if (st == null or t.cancel_requested or t.status != .streaming) {
        ai.tools.freeCalls(self.alloc, calls);
        return;
    }

    const calls_json = ai.tools.buildAssistantToolCallsJson(self.alloc, calls) catch {
        ai.tools.freeCalls(self.alloc, calls);
        aiSetThreadErrorFmt(self, idx, "tool call protocol: out of memory", .{});
        return;
    };
    defer self.alloc.free(calls_json);
    self.ai.threads.setAssistantToolCalls(self.alloc, idx, calls_json) catch {
        ai.tools.freeCalls(self.alloc, calls);
        aiSetThreadErrorFmt(self, idx, "tool call protocol: out of memory", .{});
        return;
    };

    // After the final no-tools request the model must not be able to start
    // another execution round; answer truthfully and stop.
    if (st.?.final_sent) {
        for (calls) |call| {
            const args = agent.summarizeArguments(self.alloc, call.name, call.arguments_json) catch null;
            defer if (args) |a| self.alloc.free(a);
            _ = self.ai.threads.appendToolMessage(
                self.alloc,
                idx,
                call.id,
                call.name,
                args orelse "{}",
                .unsupported,
                "error: tool calls are disabled after the final round",
            ) catch {};
            st.?.metrics.record(self.alloc, call.name, .unsupported, 0);
        }
        ai.tools.freeCalls(self.alloc, calls);
        st.?.pending_followup = false;
        setToolNote(self, idx, "tool loop stopped: model called tools after the final round");
        return;
    }

    const plan = agent.planBatch(st.?.rounds, st.?.calls, .{}, calls.len);
    // Read-only calls are admitted to the background worker; write tools are
    // handled locally. `worker_calls` owns only the read-only subset and is
    // transferred to `tool_job.Job.start` (which frees it on failure).
    var worker_calls: []ai.tools.ToolCall = &.{};
    if (plan.execute > 0) {
        worker_calls = self.alloc.alloc(ai.tools.ToolCall, plan.execute) catch {
            ai.tools.freeCalls(self.alloc, calls);
            aiSetThreadErrorFmt(self, idx, "tool call protocol: out of memory", .{});
            return;
        };
    }
    var worker_count: usize = 0;
    var freed: [ai.tools.max_tool_calls]bool = @splat(false);
    st.?.pending_card_count = 0;

    const limit_text: ?[]u8 = if (plan.reason) |reason| (switch (reason) {
        .rounds => std.fmt.allocPrint(self.alloc, "error: tool round limit ({d}) reached; not executed", .{agent.max_tool_rounds}),
        .calls => std.fmt.allocPrint(self.alloc, "error: tool call limit ({d}) reached; not executed", .{agent.max_tool_calls_per_turn}),
    } catch null) else null;
    defer if (limit_text) |text| self.alloc.free(text);

    for (calls, 0..) |call, i| {
        const args = agent.summarizeArguments(self.alloc, call.name, call.arguments_json) catch null;
        defer if (args) |a| self.alloc.free(a);
        const args_text = args orelse "{}";
        if (i >= plan.execute) {
            _ = self.ai.threads.appendToolMessage(
                self.alloc,
                idx,
                call.id,
                call.name,
                args_text,
                .unsupported,
                limit_text orelse "error: not executed",
            ) catch {};
            st.?.metrics.record(self.alloc, call.name, .unsupported, 0);
            continue;
        }

        const msg_index = self.ai.threads.appendToolMessage(
            self.alloc,
            idx,
            call.id,
            call.name,
            args_text,
            .running,
            "",
        ) catch {
            // Undo ownership: free every call not yet moved/freed, plus the
            // read-only calls already copied into `worker_calls`.
            for (worker_calls[0..worker_count]) |wc| wc.deinit(self.alloc);
            if (worker_calls.len > 0) self.alloc.free(worker_calls);
            for (calls, 0..) |c, j| {
                if (!freed[j]) c.deinit(self.alloc);
            }
            self.alloc.free(calls);
            aiSetThreadErrorFmt(self, idx, "tool call protocol: out of memory", .{});
            return;
        };

        // Unknown names share the local unsupported path (the card/result
        // still name the real requested tool).
        const kind = ai.tools.classify(call.name) orelse .terminal;
        switch (kind) {
            .read_file, .list_directory, .grep => {
                worker_calls[worker_count] = call;
                worker_count += 1;
                freed[i] = true;
                if (st.?.pending_card_count < agent.max_tool_calls_per_turn) {
                    st.?.pending_cards[st.?.pending_card_count] = msg_index;
                    st.?.pending_card_count += 1;
                }
            },
            .edit_file, .apply_patch => {
                // M3b: stage a reviewable diff instead of executing. The
                // executor/worker never sees this call, and the staged patch
                // is applied to the in-memory buffer only after an explicit
                // human approve.
                const result = switch (kind) {
                    .edit_file => app_agent_edit.stageToolCall(self, idx, msg_index, call),
                    .apply_patch => app_agent_edit.stagePatchToolCall(self, idx, msg_index, call),
                    else => unreachable,
                };
                switch (result) {
                    .staged => |staged| {
                        const text = std.fmt.allocPrint(
                            self.alloc,
                            "-{d} +{d} · staged · review in Changes",
                            .{ staged.removed, staged.added },
                        ) catch null;
                        defer if (text) |x| self.alloc.free(x);
                        const api_text = std.fmt.allocPrint(
                            self.alloc,
                            "approval required: {s} staged for review; not applied",
                            .{call.name},
                        ) catch null;
                        defer if (api_text) |x| self.alloc.free(x);
                        self.ai.threads.setToolOutcome(
                            self.alloc,
                            idx,
                            msg_index,
                            .approval_required,
                            text orelse "staged · review in Changes",
                            api_text orelse "approval required: staged for review; not applied",
                            0,
                        ) catch {
                            t.messages.items[msg_index].tool_status = .err;
                        };
                        st.?.metrics.record(self.alloc, call.name, .approval_required, 0);
                    },
                    .busy => {
                        setLocalToolCard(
                            self,
                            idx,
                            msg_index,
                            .err,
                            "error: resolve the pending edit first; not executed",
                            "error: resolve the pending edit first; not executed",
                        );
                        st.?.metrics.record(self.alloc, call.name, .err, 0);
                    },
                    .failed => |message| {
                        defer self.alloc.free(message);
                        setLocalToolCard(self, idx, msg_index, .err, message, message);
                        st.?.metrics.record(self.alloc, call.name, .err, 0);
                    },
                    .oom => {
                        setLocalToolCard(
                            self,
                            idx,
                            msg_index,
                            .err,
                            "error: out of memory",
                            "error: out of memory",
                        );
                        st.?.metrics.record(self.alloc, call.name, .err, 0);
                    },
                }
                call.deinit(self.alloc);
                freed[i] = true;
            },
            .terminal => {
                // No execution and no fake approval: terminal is not
                // implemented (there is no sandbox in this slice). The
                // card/result say exactly that.
                const text_owned = tryUnsupportedToolText(self.alloc, call.name);
                defer if (text_owned) |x| self.alloc.free(x);
                const text = text_owned orelse "not executed";
                setLocalToolCard(self, idx, msg_index, .unsupported, text, text);
                st.?.metrics.record(self.alloc, call.name, .unsupported, 0);
                call.deinit(self.alloc);
                freed[i] = true;
            },
        }
    }
    // Skipped (over-budget) calls are answered truthfully above; their call
    // structs were not consumed by a card.
    for (calls[plan.execute..]) |call| call.deinit(self.alloc);
    self.alloc.free(calls);

    st.?.rounds +|= 1;
    st.?.calls +|= @intCast(plan.execute);
    if (plan.reason) |reason| stopToolLoop(self, idx, reason);
    if (st.?.calls >= agent.max_tool_calls_per_turn) stopToolLoop(self, idx, .calls);
    if (st.?.rounds >= agent.max_tool_rounds) stopToolLoop(self, idx, .rounds);

    if (worker_count == 0) {
        if (worker_calls.len > 0) self.alloc.free(worker_calls);
        st.?.active = false;
        st.?.pending_followup = true;
        return;
    }
    std.debug.assert(worker_count == st.?.pending_card_count);

    const root = st.?.root orelse {
        for (worker_calls[0..worker_count]) |call| call.deinit(self.alloc);
        self.alloc.free(worker_calls);
        for (st.?.pending_cards[0..st.?.pending_card_count]) |msg_index| {
            const name = if (msg_index < t.messages.items.len) (t.messages.items[msg_index].tool_name orelse "?") else "?";
            self.ai.threads.setToolOutcome(
                self.alloc,
                idx,
                msg_index,
                .err,
                "error: workspace root unavailable",
                "error: workspace root unavailable",
                0,
            ) catch {};
            st.?.metrics.record(self.alloc, name, .err, 0);
        }
        st.?.pending_card_count = 0;
        st.?.pending_followup = true;
        st.?.final_only = true;
        setToolNote(self, idx, "tool loop stopped: workspace root unavailable");
        return;
    };
    const job = tool_job.Job.start(self.alloc, self.io, root, worker_calls, st.?.generation, toolTestDelayMs(self)) catch {
        // Job.start freed `worker_calls` on failure.
        for (st.?.pending_cards[0..st.?.pending_card_count]) |msg_index| {
            const name = if (msg_index < t.messages.items.len) (t.messages.items[msg_index].tool_name orelse "?") else "?";
            self.ai.threads.setToolOutcome(
                self.alloc,
                idx,
                msg_index,
                .err,
                "error: tool execution failed to start",
                "error: tool execution failed to start",
                0,
            ) catch {};
            st.?.metrics.record(self.alloc, name, .err, 0);
        }
        st.?.pending_card_count = 0;
        st.?.pending_followup = true;
        st.?.final_only = true;
        setToolNote(self, idx, "tool loop stopped: worker failed to start");
        return;
    };
    if (idx >= self.ai.tool_jobs.items.len) {
        job.requestCancel();
        // syncAiSidecars keeps this in range; if it ever isn't, surface the
        // failure instead of leaking a running job.
        var j = job;
        j.deinit();
        st.?.pending_followup = true;
        st.?.final_only = true;
        return;
    }
    self.ai.tool_jobs.items[idx] = job;
    st.?.active = true;
}

/// Internal e2e seam: a hold before the read-only tool worker executes, so
/// the running card/spinner is observable across frames. Unset in every
/// normal run; capped so a stray value cannot hang the worker.
fn toolTestDelayMs(self: *App) u32 {
    const raw = self.env_map.get("OZ_AI_TOOL_DELAY_MS") orelse return 0;
    const ms = std.fmt.parseInt(u32, raw, 10) catch return 0;
    return @min(ms, 5000);
}

/// Card/result for a non-executed local tool. `text` is display-only; `api`
/// is the bounded tool result the provider sees.
fn setLocalToolCard(
    self: *App,
    idx: usize,
    msg_index: usize,
    status: ws.ToolStatus,
    text: []const u8,
    api: []const u8,
) void {
    self.ai.threads.setToolOutcome(self.alloc, idx, msg_index, status, text, api, 0) catch {
        if (idx < self.ai.threads.items.items.len and
            msg_index < self.ai.threads.items.items[idx].messages.items.len)
        {
            self.ai.threads.items.items[idx].messages.items[msg_index].tool_status = .err;
        }
    };
}

/// Owned, truthful text for terminal/unknown tools.
fn tryUnsupportedToolText(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (std.mem.eql(u8, name, "terminal")) {
        return alloc.dupe(u8, "not executed — terminal execution is not available") catch null;
    }
    return std.fmt.allocPrint(alloc, "not executed — unsupported tool: {s}", .{name}) catch null;
}

/// Consume finished tool workers. Results apply only to the exact thread and
/// loop generation that spawned them; anything else (cancel, thread switch,
/// a stopped loop) is freed without touching a transcript.
pub fn drainToolJobs(self: *App) !bool {
    var changed = false;
    for (self.ai.tool_jobs.items, 0..) |*slot, idx| {
        const job = slot.* orelse continue;
        if (!job.isDone()) continue;
        changed = true;
        const results = job.takeResults();
        const t = &self.ai.threads.items.items[idx];
        const st = toolState(self, idx);
        const matches = st != null and st.?.active and
            job.generation == st.?.generation and
            st.?.pending_card_count == results.len and
            !t.cancel_requested and t.status == .streaming;

        if (matches) {
            const s = st.?;
            for (results, 0..) |*result, i| {
                const msg_index = s.pending_cards[i];
                if (msg_index >= t.messages.items.len) continue;
                const msg = &t.messages.items[msg_index];
                if (msg.role != .tool) continue;
                const name = msg.tool_name orelse "?";
                const excerpt = agent.resultExcerpt(self.alloc, result.content, agent.max_excerpt_bytes) catch null;
                defer if (excerpt) |e| self.alloc.free(e);
                const api = ai.tools.buildToolResultContent(
                    self.alloc,
                    .{ .output = result.content },
                    .{},
                ) catch null;
                defer if (api) |a| self.alloc.free(a);
                self.ai.threads.setToolOutcome(
                    self.alloc,
                    idx,
                    msg_index,
                    displayToolStatus(result.status),
                    excerpt orelse "",
                    api orelse result.content,
                    result.duration_ms,
                ) catch {
                    // Keep the card truthful even if the copy failed: mark it
                    // errored without allocating.
                    t.messages.items[msg_index].tool_status = .err;
                };
                s.metrics.record(self.alloc, name, result.status, result.duration_ms);
            }
            s.active = false;
            s.pending_card_count = 0;
            s.pending_followup = true;
        } else if (st) |s| {
            s.active = false;
            s.pending_card_count = 0;
        }
        for (results) |*result| result.deinit(self.alloc);
        self.alloc.free(results);
        job.deinit();
        slot.* = null;

        if (matches) {
            _ = try maybeFollowup(self, idx);
        }
    }
    return changed;
}

/// Drain every thread's worker events. Returns true when anything changed
/// (the run loop then repaints immediately). A cancelled thread's late
/// events are freed and dropped — they can never mutate a frozen (or any
/// other) transcript.
pub fn drainAi(self: *App) !bool {
    var changed = false;
    for (self.ai.clients.items, 0..) |maybe, idx| {
        const client = maybe orelse continue;
        if (idx >= self.ai.threads.items.items.len) continue;
        const t = &self.ai.threads.items.items[idx];
        var saw_terminal = false;
        while (client.pop()) |ev| {
            changed = true;
            switch (ev) {
                .delta => |text| {
                    defer self.alloc.free(text);
                    if (t.cancel_requested) continue;
                    if (try self.ai.threads.applyDelta(self.alloc, idx, text)) {
                        t.auto_scroll = true;
                    }
                },
                .done => saw_terminal = true,
                .err => |text| {
                    defer self.alloc.free(text);
                    saw_terminal = true;
                    if (t.cancel_requested) continue;
                    // A stream failure also ends any in-flight tool work; no
                    // stale result may resurrect the turn.
                    cancelClient(self, idx);
                    self.ai.threads.fail(self.alloc, idx, text);
                },
                .cancelled => {
                    saw_terminal = true;
                    if (t.status == .streaming) {
                        t.status = .cancelled;
                        t.cancel_requested = true;
                    }
                },
                .tool_calls => |calls| {
                    if (t.cancel_requested) {
                        ai.tools.freeCalls(self.alloc, calls);
                        continue;
                    }
                    aiHandleToolCalls(self, idx, calls);
                },
            }
        }

        if (saw_terminal) {
            // The worker pushes its terminal event last; join so a follow-up
            // can reuse the client immediately (no Busy race).
            client.joinAfterTerminal();
            const st = toolState(self, idx);
            if (st) |s| s.stream_done = true;
            if (!t.cancel_requested and t.status == .streaming) {
                if (st) |s| {
                    if (s.active) {
                        // Wait for the worker; drainToolJobs will follow up.
                    } else if (s.pending_followup) {
                        _ = maybeFollowup(self, idx) catch |e| {
                            aiSetThreadErrorFmt(self, idx, "follow-up failed: {s}", .{@errorName(e)});
                        };
                    } else {
                        self.ai.threads.finish(idx);
                    }
                } else {
                    self.ai.threads.finish(idx);
                }
            }
        }
        // Safety net: a worker that died without a terminal event must not
        // leave the workbox saying "streaming…" forever — unless a tool
        // batch is still legitimately running and will follow up.
        const st = toolState(self, idx);
        const waiting_tools = if (st) |s| s.active or s.pending_followup else false;
        if (t.status == .streaming and !waiting_tools and !client.isRunning() and !client.hasEvents()) {
            self.ai.threads.fail(self.alloc, idx, "stream ended unexpectedly");
            changed = true;
        }
    }
    return changed;
}

/// Right-aligned status-bar segment: active thread / model / status. null
/// until the session has at least one thread (the rail may never be opened).
pub fn aiStatusText(self: *App, a: std.mem.Allocator) !?[]const u8 {
    if (self.ai.threads.items.items.len == 0) return null;
    const t = self.ai.threads.activeThreadConst();
    const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
    return @as(?[]const u8, try std.fmt.allocPrint(a, "agent {s} · {s} · {s}", .{ t.title, model, aiStatusLabelFor(self, self.ai.threads.active) }));
}

/// Narrow status-bar variant (drops the "agent " prefix). Used only when the
/// full form would collide with the left status text / git branch.
pub fn aiStatusTextCompact(self: *App, a: std.mem.Allocator) !?[]const u8 {
    if (self.ai.threads.items.items.len == 0) return null;
    const t = self.ai.threads.activeThreadConst();
    const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s} · {s} · {s}", .{ t.title, model, aiStatusLabelFor(self, self.ai.threads.active) }));
}

/// Last-resort status-bar variant that preserves the thread name and status
/// (model omitted) instead of dropping the segment entirely.
pub fn aiStatusTextMini(self: *App, a: std.mem.Allocator) !?[]const u8 {
    if (self.ai.threads.items.items.len == 0) return null;
    const t = self.ai.threads.activeThreadConst();
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s} · {s}", .{ t.title, aiStatusLabelFor(self, self.ai.threads.active) }));
}

// ---- rendering ----

const Row = struct {
    segs: std.ArrayList(vaxis.Segment) = .empty,
    cells: u32 = 0,
};

const Styles = struct {
    base: vaxis.Style,
    dim: vaxis.Style,
    faint: vaxis.Style,
    accent: vaxis.Style,
    code: vaxis.Style,
    bold: vaxis.Style,
    italic: vaxis.Style,
    label_user: vaxis.Style,
    label_ai: vaxis.Style,
    error_style: vaxis.Style,
    warn: vaxis.Style,
    border: vaxis.Style,
    /// Raw palette endpoints for streaming/running pulses. Kept beside the
    /// prebuilt styles so animated elements share the theme mapping (no
    /// second color table that can drift).
    pulse_a: theme.Rgb,
    pulse_b: theme.Rgb,
};

/// Wraps styled segments into fixed-width rows, repeating a continuation
/// prefix on every wrapped row (so transcript labels stay aligned).
const Assembler = struct {
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    inner_w: u32,
    first_prefix: []const vaxis.Segment,
    first_cells: u32,
    cont_prefix: []const vaxis.Segment,
    cont_cells: u32,
    cur: Row = .{},
    started: bool = false,

    fn beginFirst(self: *Assembler) !void {
        self.cur = .{};
        for (self.first_prefix) |s| {
            try self.cur.segs.append(self.a, s);
        }
        self.cur.cells = self.first_cells;
        self.started = true;
    }

    fn beginCont(self: *Assembler) !void {
        self.cur = .{};
        for (self.cont_prefix) |s| {
            try self.cur.segs.append(self.a, s);
        }
        self.cur.cells = self.cont_cells;
        self.started = true;
    }

    fn flush(self: *Assembler) !void {
        try self.rows.append(self.a, self.cur);
        self.cur = .{};
        self.started = false;
    }

    fn addStyleSeg(self: *Assembler, text: []const u8, style: vaxis.Style) !void {
        var rest = text;
        while (rest.len > 0) {
            if (!self.started) try self.beginCont();
            const avail = self.inner_w -| self.cur.cells;
            if (avail == 0) {
                try self.flush();
                continue;
            }
            var take = buffer.utf8.truncateWidth(rest, avail);
            if (take.len == 0) {
                // A wide glyph did not fit in the leftover cells: wrap when
                // this row has content, otherwise emit it (rail too narrow).
                if (self.cur.cells > self.cont_cells) {
                    try self.flush();
                    continue;
                }
                const d = buffer.utf8.decodeAt(rest, 0);
                const n = if (d.len == 0) @min(rest.len, 1) else @min(@as(usize, d.len), rest.len);
                take = rest[0..n];
            }
            if (take.len == 0) break;
            try self.cur.segs.append(self.a, .{ .text = take, .style = style });
            self.cur.cells += buffer.utf8.displayWidth(take);
            rest = rest[take.len..];
            if (rest.len > 0) try self.flush();
        }
    }

    fn newline(self: *Assembler) !void {
        if (!self.started) try self.beginCont();
        try self.flush();
    }
};

fn spaces(alloc: std.mem.Allocator, n: usize) ![]const u8 {
    const buf = try alloc.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Copy `text` with terminal control bytes replaced so a pasted newline/tab
/// can never escape a row. Tabs become four spaces (the editor's tab_width)
/// so code blocks stay aligned.
fn displaySafe(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '\t' => try out.appendSlice(alloc, "    "),
            '\n', '\r' => try out.append(alloc, ' '),
            else => {
                if (c < 0x20) {
                    try out.append(alloc, ' ');
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Parse minimal Markdown into styled segments: headings, **bold**,
/// *italic*, `inline code`; markers are concealed. Fenced code is handled by
/// the caller (fence lines are skipped, body lines use the code style).
fn parseInline(
    a: std.mem.Allocator,
    st: Styles,
    line: []const u8,
    out: *std.ArrayList(vaxis.Segment),
) !void {
    if (line.len >= 2 and line[0] == '#') {
        var h: usize = 0;
        while (h < line.len and h < 6 and line[h] == '#') h += 1;
        if (h < line.len and line[h] == ' ') {
            const title = line[h + 1 ..];
            if (title.len > 0) try out.append(a, .{ .text = title, .style = st.accent });
            return;
        }
    }

    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < line.len) {
        var marker: u8 = 0;
        var mlen: usize = 1;
        if (line[i] == '`') {
            marker = 1;
        } else if (line[i] == '*') {
            if (i + 1 < line.len and line[i + 1] == '*') {
                marker = 2;
                mlen = 2;
            } else {
                marker = 3;
            }
        }
        if (marker == 0) {
            i += 1;
            continue;
        }
        if (i > plain_start) try out.append(a, .{ .text = line[plain_start..i], .style = st.base });
        const body_start = i + mlen;
        var body_end = line.len;
        var after = line.len;
        switch (marker) {
            1 => {
                if (std.mem.indexOfScalar(u8, line[body_start..], '`')) |ci| {
                    body_end = body_start + ci;
                    after = body_end + 1;
                } else {
                    body_end = line.len;
                    after = line.len;
                }
            },
            2 => {
                if (std.mem.indexOf(u8, line[body_start..], "**")) |ci| {
                    body_end = body_start + ci;
                    after = body_end + 2;
                } else {
                    body_end = line.len;
                    after = body_end;
                }
            },
            3 => {
                if (std.mem.indexOfScalar(u8, line[body_start..], '*')) |ci| {
                    body_end = body_start + ci;
                    after = body_end + 1;
                } else {
                    body_end = line.len;
                    after = body_end;
                }
            },
            else => {},
        }
        if (body_end > body_start) {
            const style = switch (marker) {
                1 => st.code,
                2 => st.bold,
                3 => st.italic,
                else => st.base,
            };
            try out.append(a, .{ .text = line[body_start..body_end], .style = style });
        }
        if (after <= i) after = i + 1; // never stall on a stray marker
        i = after;
        plain_start = after;
    }
    if (plain_start < line.len) try out.append(a, .{ .text = line[plain_start..], .style = st.base });
}

fn appendMessageRows(
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    st: Styles,
    inner_w: u32,
    role: Role,
    text: []const u8,
) !void {
    const label: []const u8 = if (role == .user) " you› " else " ai› ";
    const label_style = if (role == .user) st.label_user else st.label_ai;
    const label_width: u32 = buffer.utf8.displayWidth(label);

    const first_prefix = try a.alloc(vaxis.Segment, 1);
    first_prefix[0] = .{ .text = label, .style = label_style };
    const cont = try spaces(a, label_width);
    const cont_prefix = try a.alloc(vaxis.Segment, 1);
    cont_prefix[0] = .{ .text = cont, .style = .{ .bg = st.base.bg } };

    var wrap = Assembler{
        .a = a,
        .rows = rows,
        .inner_w = inner_w,
        .first_prefix = first_prefix,
        .first_cells = label_width,
        .cont_prefix = cont_prefix,
        .cont_cells = label_width,
    };
    try wrap.beginFirst();

    var in_fence = false;
    var any_line = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        any_line = true;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue; // conceal the fence markers
        }
        const safe_line = try displaySafe(a, line);
        if (in_fence) {
            try wrap.addStyleSeg("  ", st.base);
            try wrap.addStyleSeg(safe_line, st.code);
            try wrap.newline();
        } else {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try parseInline(a, st, safe_line, &segs);
            for (segs.items) |seg| try wrap.addStyleSeg(seg.text, seg.style);
            try wrap.newline();
        }
    }
    if (!any_line) {
        try wrap.newline();
    } else if (wrap.started) {
        try wrap.flush();
    }
    try rows.append(a, .{});
}

/// Append one already-clipped card row: segments are cut at `inner_w` cell
/// boundaries so a long tool name/path can never spill into the rail border.
fn appendCardRow(
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    inner_w: u32,
    segs: []const vaxis.Segment,
) !void {
    var row = Row{};
    var remaining = inner_w;
    for (segs) |seg| {
        if (remaining == 0) break;
        const fit = buffer.utf8.truncateWidth(seg.text, remaining);
        if (fit.len == 0) continue;
        const cells = buffer.utf8.displayWidth(fit);
        try row.segs.append(a, .{ .text = fit, .style = seg.style });
        row.cells += cells;
        remaining -|= cells;
    }
    try rows.append(a, row);
}

fn cardStatusStyle(st: Styles, status: ws.ToolStatus) vaxis.Style {
    return switch (status) {
        .running => st.accent,
        .ok => st.code,
        .err => st.error_style,
        .approval_required => st.warn,
        .approved => st.code,
        .rejected => st.error_style,
        .unsupported => st.dim,
        .cancelled => st.faint,
        .none => st.dim,
    };
}

fn cardIcon(status: ws.ToolStatus) []const u8 {
    return switch (status) {
        .running => "~",
        .ok => "+",
        .err => "x",
        .approval_required => "!",
        .approved => "+",
        .rejected => "x",
        .unsupported => "-",
        .cancelled => "x",
        .none => ".",
    };
}

/// Compact 2–4 row tool card in the chat transcript:
///
///   ✓ read_file                     ok 3ms
///     src/main.zig:1-20
///     ↳ const answer = 42;
///
/// Running/error/approval/unsupported states are distinct (icon + label +
/// color); a blocked tool never shows a fabricated result. Expanded cards
/// (hint target) add up to 8 result lines. `msg.text` is already a bounded
/// excerpt; `msg.api_text` is the full bounded result used when expanded.
fn appendToolCardRows(
    self: *App,
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    st: Styles,
    inner_w: u32,
    msg: *const Message,
) !void {
    const status = msg.tool_status;
    const name = msg.tool_name orelse "tool";
    const args = msg.tool_args orelse "";
    const now_ms = self.frame_now_ms;
    var status_style = cardStatusStyle(st, status);
    const icon = if (status == .running) animation.spinnerGlyph(now_ms) else cardIcon(status);
    if (status == .running) {
        // Demo `running-pulse`: the icon and status word breathe between the
        // two accent slots. The glyph itself cycles | / - \ every 120ms.
        status_style.fg = .{ .rgb = animation.pulseColor(st.pulse_a, st.pulse_b, now_ms, animation.stream_pulse_ms) };
        status_style.bold = true;
    }

    var status_buf: [agent.max_status_text_bytes]u8 = undefined;
    const status_text = agent.cardStatusText(&status_buf, switch (status) {
        .running => .running,
        .ok => .ok,
        .err => .err,
        .approval_required => .approval_required,
        .approved => .approved,
        .rejected => .rejected,
        .unsupported => .unsupported,
        .cancelled => .cancelled,
        .none => .running,
    }, msg.tool_ms);
    const status_owned = try a.dupe(u8, status_text);

    const icon_text = try std.fmt.allocPrint(a, "{s} ", .{icon});
    const icon_cells: u32 = @intCast(buffer.utf8.displayWidth(icon_text));
    const status_cells: u32 = @intCast(buffer.utf8.displayWidth(status_owned));
    const name_cells: u32 = @intCast(buffer.utf8.displayWidth(name));

    var header: std.ArrayList(vaxis.Segment) = .empty;
    if (inner_w <= icon_cells + 1) {
        try header.append(a, .{ .text = try a.dupe(u8, buffer.utf8.truncateWidth(status_owned, inner_w)), .style = status_style });
    } else {
        const room_for_name_and_status = inner_w - icon_cells;
        if (name_cells + 1 + status_cells <= room_for_name_and_status) {
            try header.append(a, .{ .text = icon_text, .style = status_style });
            try header.append(a, .{ .text = name, .style = st.bold });
            const pad = room_for_name_and_status - name_cells - status_cells;
            if (pad > 0) try header.append(a, .{ .text = try spaces(a, pad), .style = .{ .bg = st.base.bg } });
            try header.append(a, .{ .text = status_owned, .style = status_style });
        } else {
            const name_room = room_for_name_and_status -| (status_cells + 1);
            if (name_room > 0) {
                try header.append(a, .{ .text = icon_text, .style = status_style });
                try header.append(a, .{ .text = buffer.utf8.truncateWidth(name, name_room), .style = st.bold });
                const pad = room_for_name_and_status - @as(u32, @intCast(buffer.utf8.displayWidth(buffer.utf8.truncateWidth(name, name_room)))) - status_cells;
                if (pad > 0) try header.append(a, .{ .text = try spaces(a, pad), .style = .{ .bg = st.base.bg } });
                try header.append(a, .{ .text = status_owned, .style = status_style });
            } else {
                try header.append(a, .{ .text = buffer.utf8.truncateWidth(status_owned, inner_w), .style = status_style });
            }
        }
    }
    try appendCardRow(a, rows, inner_w, header.items);

    if (args.len > 0) {
        const args_safe = try displaySafe(a, args);
        const line = try std.fmt.allocPrint(a, "  {s}", .{args_safe});
        try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.dim }});
    }

    switch (status) {
        .approval_required => {
            if (msg.text.len > 0) {
                const safe = try displaySafe(a, msg.text);
                const line = try std.fmt.allocPrint(a, "  {s}", .{safe});
                try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.warn }});
            } else {
                try appendCardRow(a, rows, inner_w, &.{.{ .text = "  staged — review in Changes", .style = st.warn }});
            }
        },
        .approved => {
            if (msg.text.len > 0) {
                const safe = try displaySafe(a, msg.text);
                const line = try std.fmt.allocPrint(a, "  {s}", .{safe});
                try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.code }});
            }
        },
        .rejected => {
            if (msg.text.len > 0) {
                const safe = try displaySafe(a, msg.text);
                const line = try std.fmt.allocPrint(a, "  {s}", .{safe});
                try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.error_style }});
            }
        },
        .unsupported => {
            if (msg.text.len > 0) {
                const safe = try displaySafe(a, msg.text);
                const line = try std.fmt.allocPrint(a, "  {s}", .{safe});
                try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.faint }});
            } else {
                try appendCardRow(a, rows, inner_w, &.{.{ .text = "  not executed", .style = st.faint }});
            }
        },
        .cancelled => {
            try appendCardRow(a, rows, inner_w, &.{.{ .text = "  stopped (no result applied)", .style = st.faint }});
        },
        .running => {
            try appendCardRow(a, rows, inner_w, &.{.{ .text = "  ⋯ working", .style = st.faint }});
        },
        .ok, .err, .none => {
            if (msg.text.len > 0) {
                const safe = try displaySafe(a, msg.text);
                const line = try std.fmt.allocPrint(a, "  ↳ {s}", .{safe});
                try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = if (status == .err) st.error_style else st.code }});
            }
        },
    }

    if (msg.tool_expanded) {
        var line_buf: [16][]const u8 = undefined;
        const view = agent.bodyLines(msg.api_text, &line_buf, 8);
        var i: usize = 0;
        while (i < view.count) : (i += 1) {
            const safe = try displaySafe(a, line_buf[i]);
            const line = try std.fmt.allocPrint(a, "  │ {s}", .{safe});
            try appendCardRow(a, rows, inner_w, &.{.{ .text = line, .style = st.faint }});
        }
        if (view.more) {
            try appendCardRow(a, rows, inner_w, &.{.{ .text = "  …", .style = st.faint }});
        }
    }

    // One blank row separates adjacent cards without wasting a full row on
    // a single-tool transcript.
    try rows.append(a, .{});
}

fn appendWrappedPlain(
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    inner_w: u32,
    text: []const u8,
    style: vaxis.Style,
) !void {
    var wrap = Assembler{
        .a = a,
        .rows = rows,
        .inner_w = inner_w,
        .first_prefix = &[_]vaxis.Segment{},
        .first_cells = 0,
        .cont_prefix = &[_]vaxis.Segment{},
        .cont_cells = 0,
    };
    try wrap.beginFirst();
    var any = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        any = true;
        const safe = try displaySafe(a, line);
        try wrap.addStyleSeg(safe, style);
        try wrap.newline();
    }
    if (!any) try wrap.newline();
}

fn railStatusStyle(st: Styles, status: Status, now_ms: i64) vaxis.Style {
    return switch (status) {
        .idle => st.dim,
        .streaming => .{
            .fg = .{ .rgb = animation.pulseColor(st.pulse_a, st.pulse_b, now_ms, animation.stream_pulse_ms) },
            .bg = st.base.bg,
            .bold = true,
        },
        .cancelled => st.faint,
        .err => st.error_style,
    };
}

/// Status label with the M3a tool state layered on: an in-flight batch (or a
/// batch waiting for its follow-up) reads `tools…`, never `idle`. Once the
/// results land and the follow-up streams, the normal label returns.
fn aiStatusLabelFor(self: *App, idx: usize) []const u8 {
    if (idx < self.ai.threads.items.items.len) {
        if (toolState(self, idx)) |st| {
            if (st.active or st.pending_followup) return "tools…";
        }
        return self.ai.threads.items.items[idx].statusLabel();
    }
    return "idle";
}

fn threadDot(status: Status) []const u8 {
    return switch (status) {
        .idle => "o",
        .streaming => "*",
        .cancelled => "x",
        .err => "!",
    };
}

fn threadDotStyle(st: Styles, status: Status, now_ms: i64) vaxis.Style {
    return switch (status) {
        .idle => st.faint,
        .streaming => .{
            .fg = .{ .rgb = animation.pulseColor(st.pulse_a, st.pulse_b, now_ms, animation.stream_pulse_ms) },
            .bg = st.base.bg,
            .bold = true,
        },
        .cancelled => st.dim,
        .err => st.error_style,
    };
}

/// Draw one rail row: left border, one cell of padding, `content` (which
/// must fit `content_w`), padding to the right edge, then the last cell of
/// breathing room. Every row therefore writes exactly `w` cells.
fn drawRailRow(
    win: vaxis.Window,
    a: std.mem.Allocator,
    y: u32,
    x: u32,
    w: u32,
    border: []const u8,
    border_style: vaxis.Style,
    bg: vaxis.Color,
    content: []const vaxis.Segment,
    used_cells: u32,
) !void {
    const content_w = w -| 3;
    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.append(a, .{ .text = border, .style = border_style });
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    for (content) |seg| try segs.append(a, seg);
    const pad = content_w -| used_cells;
    if (pad > 0) try segs.append(a, .{ .text = try spaces(a, pad), .style = .{ .bg = bg } });
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    _ = win.print(segs.items, .{ .row_offset = @intCast(y), .col_offset = @intCast(x), .wrap = .none });
}

fn drawRailTextRow(
    self: *App,
    win: vaxis.Window,
    a: std.mem.Allocator,
    y: u32,
    x: u32,
    w: u32,
    border_style: vaxis.Style,
    bg: vaxis.Color,
    text: []const u8,
    style: vaxis.Style,
) !void {
    _ = self;
    const content_w = w -| 3;
    const fit = autil.cellFitPrefix(win, text, content_w);
    var segs = std.ArrayList(vaxis.Segment).empty;
    if (fit.cells > 0) try segs.append(a, .{ .text = fit.slice, .style = style });
    try drawRailRow(win, a, y, x, w, "│", border_style, bg, segs.items, @intCast(fit.cells));
}

/// Draw the docked rail / drawer. Called after the editor panes (and the
/// terminal) so the rail covers exactly its reserved cells; overlays that
/// open afterwards (pickers, hovers) render above it.
pub fn drawAiRail(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    const lay = aiLayout(self);
    if (lay.mode == .hidden) return;
    const cols: u32 = win.width;
    const rows: u32 = win.height;
    if (rows <= app_mod.status_row_count) return;
    const rail_rows = rows - app_mod.status_row_count;
    const x = lay.rail_col;
    const w = lay.rail_width;
    if (w < 12 or rail_rows < 8 or x + w > cols) return;

    const t = self.theme;
    // One blank column between editor content and the rail's left border.
    // Docked mode already excludes it from the editor layout; drawer mode
    // floats over the full-width editor, so paint the gutter over its last
    // cell here (after every editor/terminal/overlay draw, before the rail).
    if (lay.rail_gutter > 0 and lay.rail_col >= lay.rail_gutter) {
        const gutter_col = lay.rail_col - lay.rail_gutter;
        var gutter_row: u32 = 0;
        while (gutter_row < rail_rows) : (gutter_row += 1) {
            win.writeCell(@intCast(gutter_col), @intCast(gutter_row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = .{ .rgb = t.bg } },
            });
        }
    }
    const rail_bg = vaxis.Color{ .rgb = t.bg_float };
    const content_w = w -| 3;
    const focused = self.ai.focus != .editor;
    // The left rule is the rail's hard boundary: the theme's active window
    // separator while the rail owns the keyboard, `win_sep` otherwise. Both
    // slots are palette-derived; the focused border is distinctly colored
    // in every theme.
    const border_style = chrome.panelBorderStyle(t, focused, rail_bg);
    const m = ws.metrics(rail_rows, self.ai.tab);
    // Mouse-only wheel regions: the thread list and the workbox body scroll
    // the state the keyboard j/k (and aiScroll) already owns. Tabs/prompt
    // rows keep their click targets; the wheel never steals terminal input.
    self.addMouseScrollTarget(m.thread_top, x, w, m.thread_rows, .ai_threads);
    if (m.body_rows > 0) self.addMouseScrollTarget(m.body_top, x, w, m.body_rows, .ai_workbox);

    // Solid bg first: every rail cell (including the border/padding) is
    // bg_float, so cell-exactness tests can sample anywhere inside it.
    const panel = win.child(.{
        .x_off = @intCast(x),
        .y_off = 0,
        .width = @intCast(w),
        .height = @intCast(rail_rows),
    });
    panel.fill(.{ .style = .{ .bg = rail_bg } });

    const st = Styles{
        .base = .{ .fg = .{ .rgb = t.fg }, .bg = rail_bg },
        .dim = .{ .fg = .{ .rgb = t.fg_dim }, .bg = rail_bg },
        .faint = .{ .fg = .{ .rgb = t.fg_faint }, .bg = rail_bg },
        .accent = .{ .fg = .{ .rgb = t.accent }, .bg = rail_bg, .bold = true },
        .code = .{ .fg = .{ .rgb = t.string }, .bg = rail_bg },
        .bold = .{ .fg = .{ .rgb = t.fg }, .bg = rail_bg, .bold = true },
        .italic = .{ .fg = .{ .rgb = t.fg_dim }, .bg = rail_bg, .italic = true },
        .label_user = .{ .fg = .{ .rgb = t.accent }, .bg = rail_bg, .bold = true },
        .label_ai = .{ .fg = .{ .rgb = t.keyword }, .bg = rail_bg, .bold = true },
        .error_style = .{ .fg = .{ .rgb = t.diag_error }, .bg = rail_bg },
        .warn = .{ .fg = .{ .rgb = t.diag_warn }, .bg = rail_bg },
        .border = border_style,
        .pulse_a = t.accent,
        .pulse_b = t.accent_alt,
    };

    if (self.ai.threads.items.items.len == 0) {
        // Defensive: the rail is only open after ensureAi, but never crash
        // on an empty model.
        var only = std.ArrayList(vaxis.Segment).empty;
        try only.append(a, .{ .text = "no threads", .style = st.dim });
        try drawRailRow(win, a, 0, x, w, "│", border_style, rail_bg, only.items, 10);
        return;
    }
    const active = self.ai.threads.activeThread();
    const active_idx = self.ai.threads.active;

    // ---- header band: AGENTS  N  [+] ----
    {
        // A full-width header band separates the rail from the editor even
        // when the rail does not own the keyboard; the count is a separate
        // token so `AGENTS 1` is readable (and no decorative glyph is
        // required).
        const header_bg = vaxis.Color{ .rgb = t.bg_status };
        const header_border_style = chrome.panelBorderStyle(t, focused, header_bg);
        const header_label_style = vaxis.Style{
            .fg = .{ .rgb = if (focused) t.accent else t.fg },
            .bg = header_bg,
            .bold = true,
        };
        const header_dim_style = vaxis.Style{ .fg = .{ .rgb = t.fg_dim }, .bg = header_bg };
        const header_base_style = vaxis.Style{ .fg = .{ .rgb = t.fg }, .bg = header_bg };
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "AGENTS", .style = header_label_style });
        try segs.append(a, .{ .text = "  ", .style = header_base_style });
        // vaxis cells reference this slice until vx.render(), after
        // drawAiRail has returned — the frame arena owns it like every
        // other label on the rail.
        const count = try std.fmt.allocPrint(a, "{d}", .{self.ai.threads.items.items.len});
        try segs.append(a, .{ .text = count, .style = header_dim_style });
        var used: u32 = 6 + 2 + @as(u32, @intCast(count.len));
        // right-aligned "+" affordance (n / + also work from the rail).
        if (content_w >= used + 2) {
            try segs.append(a, .{ .text = try spaces(a, content_w - used - 1), .style = .{ .bg = header_bg } });
            try segs.append(a, .{ .text = "+", .style = .{ .fg = .{ .rgb = t.accent }, .bg = header_bg, .bold = true } });
            used = content_w;
            if (self.mouseTargetsCollecting()) {
                self.addHintTarget(.{
                    .row = m.header_row,
                    .col = x + 2 + content_w - 1,
                    .width = 1,
                    .height = 1,
                }, .agent_new);
            }
        }
        try drawRailRow(win, a, m.header_row, x, w, "│", header_border_style, header_bg, segs.items, used);
    }

    // ---- workspace group ----
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        const ws_name = self.curWsName();
        const suffix = " / workspace";
        const suffix_w: u32 = @intCast(autil.cellWidth(win, suffix));
        const ws_fit = autil.cellFitPrefix(win, ws_name, content_w -| suffix_w);
        try segs.append(a, .{ .text = ws_fit.slice, .style = st.dim });
        var used: u32 = @intCast(ws_fit.cells);
        if (content_w >= used + suffix_w) {
            try segs.append(a, .{ .text = suffix, .style = st.faint });
            used += suffix_w;
        }
        try drawRailRow(win, a, m.group_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    if (self.ai.thread_cursor >= self.ai.threads.items.items.len) {
        self.ai.thread_cursor = self.ai.threads.items.items.len - 1;
    }
    if (self.ai.threads.items.items.len <= m.thread_rows) {
        self.ai.thread_top = 0;
    } else {
        const n = self.ai.threads.items.items.len;
        if (self.ai.thread_top + m.thread_rows > n) self.ai.thread_top = n - m.thread_rows;
        if (self.ai.thread_cursor < self.ai.thread_top) self.ai.thread_top = self.ai.thread_cursor;
        if (self.ai.thread_cursor >= self.ai.thread_top + m.thread_rows) {
            self.ai.thread_top = self.ai.thread_cursor - m.thread_rows + 1;
        }
    }

    var cursor_row: ?u32 = null;
    var vis: u32 = 0;
    while (vis < m.thread_rows) : (vis += 1) {
        const ti = self.ai.thread_top + vis;
        const y = m.thread_top + vis;
        if (ti >= self.ai.threads.items.items.len) {
            try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, &.{}, 0);
            continue;
        }
        const thread = &self.ai.threads.items.items[ti];
        const selected = ti == self.ai.thread_cursor;
        const attached = ti == active_idx;
        const highlight = (self.ai.focus == .rail and selected) or (self.ai.focus == .prompt and attached);
        const row_bg: vaxis.Color = if (highlight) .{ .rgb = t.bg_sel } else rail_bg;
        const title_style: vaxis.Style = .{
            .fg = .{ .rgb = if (attached) t.fg else t.fg_dim },
            .bg = row_bg,
            .bold = attached,
        };
        const dot_style = threadDotStyle(st, thread.status, self.frame_now_ms);
        const status_text = aiStatusLabelFor(self, ti);
        const status_cells = autil.cellWidth(win, status_text);
        // Active thread: `>` + bold in monochrome. Other rows keep an ASCII
        // status marker so no nerd-font/geometric glyph is required.
        const marker: []const u8 = if (attached) ">" else threadDot(thread.status);
        const marker_style: vaxis.Style = if (attached)
            chrome.activeThreadMarkerStyle(t, row_bg)
        else
            .{ .fg = dot_style.fg, .bg = row_bg };

        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = marker, .style = marker_style });
        try segs.append(a, .{ .text = " ", .style = .{ .bg = row_bg } });
        var used: u32 = 2;
        // Keep the status word when there is room; otherwise let the title
        // use the full row (narrow rails never overflow).
        const show_status = content_w >= used + status_cells + 5;
        const title_cap: usize = @intCast(content_w -| used -| (if (show_status) status_cells + 1 else 0));
        const title_fit = autil.cellFitPrefix(win, thread.title, title_cap);
        try segs.append(a, .{ .text = title_fit.slice, .style = title_style });
        used += @intCast(title_fit.cells);
        if (show_status) {
            try segs.append(a, .{ .text = try spaces(a, content_w -| used -| status_cells), .style = .{
                .fg = .{ .rgb = t.fg_faint },
                .bg = row_bg,
            } });
            try segs.append(a, .{ .text = status_text, .style = .{ .fg = dot_style.fg, .bg = row_bg } });
            used = content_w;
        }
        if (highlight and selected) cursor_row = y;
        try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, segs.items, used);
        if (self.mouseTargetsCollecting()) {
            self.addHintTarget(.{
                .row = y,
                .col = x + 2,
                .width = content_w,
                .height = 1,
            }, .{ .agent_thread_select = ti });
        }
    }

    // ---- divider: thread list | workbox ----
    {
        var rule = std.ArrayList(u8).empty;
        var rc: u32 = 0;
        while (rc < content_w) : (rc += 1) try rule.appendSlice(a, "─");
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = rule.items, .style = chrome.separatorStyle(t, .major, rail_bg) });
        try drawRailRow(win, a, m.divider_row, x, w, "├", border_style, rail_bg, segs.items, content_w);
    }

    // ---- workbox header: thread · status, model right ----
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = active.title, .style = st.bold });
        try segs.append(a, .{ .text = " · ", .style = st.dim });
        const active_status_label = aiStatusLabelFor(self, active_idx);
        try segs.append(a, .{ .text = active_status_label, .style = railStatusStyle(st, active.status, self.frame_now_ms) });
        var used: u32 = @intCast(autil.cellWidth(win, active.title) + 3 + autil.cellWidth(win, active_status_label));
        const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
        const mw = autil.cellWidth(win, model);
        if (content_w >= used + mw + 2) {
            const fit = autil.cellFitSuffix(win, model, content_w -| used -| 1);
            if (fit.cells > 0) {
                try segs.append(a, .{ .text = try spaces(a, content_w -| used -| @as(u32, @intCast(fit.cells))), .style = .{
                    .fg = .{ .rgb = t.fg_faint },
                    .bg = rail_bg,
                } });
                try segs.append(a, .{ .text = fit.slice, .style = st.faint });
                used += @as(u32, @intCast(fit.cells));
            }
        }
        try drawRailRow(win, a, m.workbox_header_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    // ---- tabs: >chat │ changes N │ tools │ terminal ----
    // Observe the real pending count once per frame. A change starts a
    // short, explicitly-deadlined flash on the Changes label; the run loop
    // polls only while `reviewFlashActive` is true, so an idle rail burns
    // no CPU after the deadline.
    const pending_now = self.reviewPendingCount();
    if (!self.review_flash_seen) {
        self.review_flash_seen = true;
        self.review_flash_count = pending_now;
    } else if (pending_now != self.review_flash_count) {
        self.review_flash_count = pending_now;
        self.review_flash_start_ms = self.frame_now_ms;
    }
    const badge_flashing = animation.flashActive(
        self.review_flash_start_ms,
        self.frame_now_ms,
        animation.badge_flash_ms,
    );

    // The active tab carries a `>` marker on the soft selection background,
    // `fg` bold text and an accent_alt underline; the shared chrome helper
    // keeps it identical to the navigator and buffer tabs. `│`
    // separators keep the four targets from reading as one label; the
    // compact labels leave room for the badge at 34-cell rail widths.
    {
        const changes_label = try std.fmt.allocPrint(a, "changes {d}", .{self.reviewPendingCount()});
        const Tabs = [_]struct { tab: WorkboxTab, label: []const u8 }{
            .{ .tab = .chat, .label = "chat" },
            .{ .tab = .changes, .label = changes_label },
            .{ .tab = .tools, .label = "tools" },
            .{ .tab = .terminal, .label = "terminal" },
        };
        var segs = std.ArrayList(vaxis.Segment).empty;
        var used: u32 = 0;
        // 38-cell rail (content 35): spend the extra cells on separator
        // breathing room. The first rule keeps its space on the right so the
        // active `>` marker + all four labels still fit 35 cells; 34-cell
        // rails (100 dock / 80 drawer) keep the compact 30-cell row.
        const spaced = content_w >= 35;
        for (Tabs, 0..) |entry, i| {
            const active_tab = self.ai.tab == entry.tab;
            const label_cells: u32 = @intCast(autil.cellWidth(win, entry.label));
            const marker_cells: u32 = if (active_tab) 1 else 0;
            const sep_cells: u32 = if (i == 0) 0 else if (spaced) (if (i == 1) 2 else 3) else 1;
            // Extremely narrow rails omit trailing tabs instead of running
            // past the border; all tabs fit at the supported 34/38 widths.
            if (used + sep_cells + marker_cells + label_cells > content_w) break;
            if (i > 0) {
                const sep_text = if (spaced) (if (i == 1) "│ " else " │ ") else "│";
                try segs.append(a, .{ .text = sep_text, .style = chrome.separatorStyle(t, .minor, rail_bg) });
                used += sep_cells;
            }
            var style: vaxis.Style = if (active_tab)
                chrome.activeTabStyle(t)
            else
                chrome.inactiveTabStyle(t, rail_bg);
            if (entry.tab == .changes and badge_flashing) {
                style.fg = .{ .rgb = animation.pulseColor(t.accent, t.accent_alt, self.frame_now_ms, 300) };
                style.bold = true;
            }
            const target_col = x + 2 + used;
            if (active_tab) {
                // The marker shares the tab's soft selection + accent
                // underline, so marker + label read as one selected tab.
                try segs.append(a, .{ .text = ">", .style = chrome.activeTabMarkerStyle(t) });
                used += 1;
            }
            if (self.mouseTargetsCollecting()) {
                // The active tab's `>` marker belongs to the same target as
                // its label (the label overlay covers the marker).
                self.addHintTarget(.{
                    .row = m.tabs_row,
                    .col = target_col,
                    .width = label_cells + marker_cells,
                    .height = 1,
                }, .{ .workbox_tab = entry.tab });
            }
            try segs.append(a, .{ .text = entry.label, .style = style });
            used += label_cells;
        }
        try drawRailRow(win, a, m.tabs_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    // ---- rule: tab strip | body ----
    {
        var rule = std.ArrayList(u8).empty;
        var rc: u32 = 0;
        while (rc < content_w) : (rc += 1) try rule.appendSlice(a, "─");
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = rule.items, .style = chrome.separatorStyle(t, .major, rail_bg) });
        try drawRailRow(win, a, m.tabs_sep_row, x, w, "├", border_style, rail_bg, segs.items, content_w);
    }

    // ---- body ----
    if (m.body_rows > 0) {
        switch (self.ai.tab) {
            .chat => try drawChatBody(self, a, win, st, x, w, border_style, rail_bg, &m, active),
            .changes => {
                if (self.agentEditVisible()) {
                    try self.drawAgentEditChanges(a, win, x, w, m.body_top, m.body_rows, border_style, rail_bg);
                } else if (self.inlinePendingCount() > 0) {
                    try self.drawInlineChanges(a, win, x, w, m.body_top, m.body_rows, border_style, rail_bg);
                } else {
                    try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, "no pending changes", st.dim);
                    if (m.body_rows > 2) {
                        try drawRailTextRow(self, win, a, m.body_top + 2, x, w, border_style, rail_bg, "select lines · <leader>i", st.faint);
                    }
                    // Keep the empty review body a closed panel: every row
                    // between/after the two text rows still draws the rail
                    // border (the scenario matrix samples the bottom-left
                    // cell whenever Changes is the active tab).
                    var fill_y = m.body_top + 1;
                    while (fill_y < m.body_top + m.body_rows) : (fill_y += 1) {
                        if (fill_y == m.body_top + 2) continue;
                        try drawRailTextRow(self, win, a, fill_y, x, w, border_style, rail_bg, "", st.faint);
                    }
                }
            },
            .tools => try drawToolsTab(self, a, win, st, x, w, border_style, rail_bg, &m),
            .terminal => {
                try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, "agent terminal arrives in M3", st.dim);
                if (m.body_rows > 2) {
                    try drawRailTextRow(self, win, a, m.body_top + 2, x, w, border_style, rail_bg, "editor terminal: Alt+r", st.faint);
                }
            },
        }
    }

    // ---- prompt (chat only) ----
    if (m.prompt_row) |prompt_row| {
        const t2 = active;
        const prefix = "❯ ";
        const prefix_cells: u32 = 2;
        const cap: usize = content_w -| prefix_cells;
        const safe_input = try displaySafe(a, t2.input.items);
        const fit = autil.cellFitSuffix(win, safe_input, cap);
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = prefix, .style = st.accent });
        if (fit.cells > 0) try segs.append(a, .{ .text = fit.slice, .style = st.base });
        const used: u32 = prefix_cells + @as(u32, @intCast(fit.cells));
        try drawRailRow(win, a, prompt_row, x, w, "│", border_style, rail_bg, segs.items, used);
        if (self.mouseTargetsCollecting()) {
            self.addHintTarget(.{
                .row = prompt_row,
                .col = x + 2,
                .width = content_w,
                .height = 1,
            }, .agent_prompt_focus);
        }
        if (self.ai.focus == .prompt) {
            const cursor_col = x + 2 + prefix_cells + @as(u32, @intCast(fit.cells));
            self.vx.screen.cursor = .{
                .row = @intCast(prompt_row),
                .col = @intCast(@min(cursor_col, x + w - 2)),
            };
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .beam;
        }
    }

    if (self.ai.focus == .rail) {
        if (cursor_row) |row| {
            self.vx.screen.cursor = .{ .row = @intCast(row), .col = @intCast(x + 2) };
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .block;
        }
    }
}

fn packThemeRgb(rgb: [3]u8) u32 {
    return (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | rgb[2];
}

fn chartColor(theme_color: [3]u8) u32 {
    return packThemeRgb(theme_color);
}

/// Deterministic per-tool chart colors (the theme's syntax palette).
fn toolSeriesColor(self: *App, index: usize) u32 {
    const t = self.theme;
    const palette = [_][3]u8{
        t.accent, t.string, t.keyword,  t.function,
        t.number, t.type,   t.operator, t.boolean,
    };
    return chartColor(palette[index % palette.len]);
}

/// Return the cached chart canvas, re-rendering only when the active thread,
/// metrics revision or body dimensions changed. Series names stay owned by
/// the metrics; samples are copied into frame scratch before `chart.render`
/// (which copies what it needs into cells).
fn toolChartCanvas(
    self: *App,
    a: std.mem.Allocator,
    active_idx: usize,
    content_w: u32,
    height: u32,
) ?*const chart.Canvas {
    const state = toolState(self, active_idx) orelse return null;
    const metrics = &state.metrics;
    if (metrics.count() == 0) return null;
    const width: u16 = @intCast(@min(content_w, @as(u32, chart.max_width)));
    const h: u16 = @intCast(@min(height, @as(u32, chart.max_height)));
    if (width == 0 or h == 0) return null;

    const cache = &self.ai.chart_cache;
    if (cache.canvas != null and cache.key.validFor(active_idx, metrics.revision, width, h)) {
        return &cache.canvas.?;
    }
    cache.clear(self.alloc);

    var series_list: std.ArrayList(chart.Series) = .empty;
    defer series_list.deinit(a);
    var samples: std.ArrayList(u32) = .empty;
    defer samples.deinit(a);
    // Preallocate the whole sample pool: `series_list` stores slices into
    // `samples`, so a later growth reallocation would invalidate earlier
    // series before `chart.render` reads them.
    samples.ensureTotalCapacity(a, metrics.count() * agent.recent_capacity) catch return null;
    var i: usize = 0;
    while (i < metrics.count()) : (i += 1) {
        const stats = metrics.atConst(i) orelse continue;
        if (stats.recent_len == 0) continue;
        if (series_list.items.len >= chart.max_series) break;
        var scratch: [agent.recent_capacity]u32 = undefined;
        const n = stats.recentInto(&scratch);
        const start = samples.items.len;
        samples.appendSlice(a, scratch[0..n]) catch return null;
        series_list.append(a, .{
            .name = stats.name,
            .color = toolSeriesColor(self, series_list.items.len),
            .samples = samples.items[start..],
        }) catch return null;
    }
    if (series_list.items.len == 0) return null;

    const canvas = chart.render(self.alloc, series_list.items, .{
        .width = width,
        .height = h,
        .max_points = agent.recent_capacity,
        .show_legend = true,
        .show_axis = h >= 3,
    }) catch return null;
    cache.canvas = canvas;
    cache.key = .{ .thread = active_idx, .revision = metrics.revision, .width = width, .height = h };
    return &cache.canvas.?;
}

fn drawChartCanvas(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    x: u32,
    w: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
    y: u32,
    canvas: *const chart.Canvas,
) !void {
    var row: u32 = 0;
    while (row < canvas.height) : (row += 1) {
        var segs = std.ArrayList(vaxis.Segment).empty;
        defer segs.deinit(a);
        for (canvas.row(row)) |cell| {
            if (cell.width == 0) continue;
            const fg: vaxis.Color = if (cell.fg) |packed_fg| .{ .rgb = .{
                @intCast((packed_fg >> 16) & 0xff),
                @intCast((packed_fg >> 8) & 0xff),
                @intCast(packed_fg & 0xff),
            } } else .{ .rgb = self.theme.fg_dim };
            try segs.append(a, .{ .text = cell.text, .style = .{ .fg = fg, .bg = rail_bg } });
        }
        try drawRailRow(win, a, y + row, x, w, "│", border_style, rail_bg, segs.items, canvas.width);
    }
}

fn drawToolsTab(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    st: Styles,
    x: u32,
    w: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
    m: *const ws.Metrics,
) !void {
    const active_idx = self.ai.threads.active;
    const state = toolState(self, active_idx);
    const metrics: ?*agent.Metrics = if (state) |s| &s.metrics else null;
    const n = if (metrics) |mm| mm.count() else 0;
    if (n == 0) {
        try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, "no tool calls yet", st.dim);
        if (m.body_rows > 2) {
            try drawRailTextRow(self, win, a, m.body_top + 2, x, w, border_style, rail_bg, "read-only tools: read_file · list_directory · grep", st.faint);
        }
        return;
    }
    const mm = metrics.?;
    const calls = mm.totalCalls();
    const avg = mm.averageMs();
    const p95 = mm.p95RecentMs();
    const content_w = w -| 3;
    const width_cells: usize = content_w;

    // Summary candidates are tried widest first; the compact fallback keeps
    // `p95` visible on the 34/38-cell rail and the 80-column drawer, and the
    // last candidate is still clipped by drawRailTextRow (never overflows).
    // Strings come from the frame allocator: vaxis retains grapheme slices
    // until the frame flush, so stack buffers would be reused too early.
    const summary: []const u8 = if (avg) |value| blk: {
        if (p95) |p| {
            const full = try std.fmt.allocPrint(a, "tools · {d} calls · avg {d}ms · p95 {d}ms", .{ calls, value, p });
            if (autil.cellWidth(win, full) <= width_cells) break :blk full;
            const mid = try std.fmt.allocPrint(a, "{d} calls · avg {d}ms · p95 {d}ms", .{ calls, value, p });
            if (autil.cellWidth(win, mid) <= width_cells) break :blk mid;
            const compact = try std.fmt.allocPrint(a, "avg {d}ms · p95 {d}ms", .{ value, p });
            if (autil.cellWidth(win, compact) <= width_cells) break :blk compact;
            break :blk try std.fmt.allocPrint(a, "p95 {d}ms", .{p});
        }
        const full = try std.fmt.allocPrint(a, "tools · {d} calls · avg {d}ms", .{ calls, value });
        if (autil.cellWidth(win, full) <= width_cells) break :blk full;
        break :blk try std.fmt.allocPrint(a, "avg {d}ms", .{value});
    } else try std.fmt.allocPrint(a, "tools · {d} calls · no durations", .{calls});
    if (m.body_rows > 0) {
        try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, summary, st.bold);
    }

    const remaining = m.body_rows -| 1;
    const max_cards = @max(@as(u32, 1), (remaining -| 2) / 3);
    const visible: u32 = @min(@as(u32, @intCast(n)), max_cards);
    const more = n - visible;
    // Reserve one line for `+N more tools` when some cards do not fit, so
    // the overflow marker is never silently painted over by the chart.
    var chart_h: u32 = @min(@as(u32, 8), remaining -| (visible * 3) -| @intFromBool(more > 0));
    if (chart_h == 1) chart_h = 0;

    var y = m.body_top + 1;
    const body_end = m.body_top + m.body_rows;
    var i: u32 = 0;
    while (i < visible and y + 3 <= body_end) : (i += 1) {
        const stats = mm.atConst(i) orelse break;
        // row 1: name + call count (right-aligned count). Clip the name to
        // the rail width before handing it to vaxis: unknown tool names can
        // be long and must never spill past the border.
        const head = buffer.utf8.truncateWidth(stats.name, content_w);
        var head_segs = std.ArrayList(vaxis.Segment).empty;
        defer head_segs.deinit(a);
        try head_segs.append(a, .{ .text = head, .style = st.bold });
        const count_text = try std.fmt.allocPrint(a, "calls {d}", .{stats.calls});
        const head_cells: u32 = @intCast(autil.cellWidth(win, head));
        const count_cells: u32 = @intCast(autil.cellWidth(win, count_text));
        if (head_cells +| count_cells < content_w) {
            try head_segs.append(a, .{ .text = try spaces(a, content_w - head_cells - count_cells), .style = .{ .bg = rail_bg } });
            try head_segs.append(a, .{ .text = count_text, .style = st.dim });
        }
        try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, head_segs.items, @min(content_w, head_cells +| count_cells));
        y += 1;

        var counts = try std.fmt.allocPrint(a, "ok {d} · err {d}", .{ stats.ok, stats.errors });
        if (stats.approval_required > 0) {
            counts = try std.fmt.allocPrint(a, "{s} · appr {d}", .{ counts, stats.approval_required });
        }
        if (stats.denied > 0) {
            counts = try std.fmt.allocPrint(a, "{s} · denied {d}", .{ counts, stats.denied });
        }
        if (stats.unsupported > 0) {
            counts = try std.fmt.allocPrint(a, "{s} · unsup {d}", .{ counts, stats.unsupported });
        }
        try drawRailTextRow(self, win, a, y, x, w, border_style, rail_bg, counts, st.dim);
        y += 1;

        // p95 is the tool's own recent window (≤32 real samples); avg/max
        // stay all-time. Drop max first, then avg, rather than overflow.
        const latency: []const u8 = if (stats.averageMs()) |avg_ms| blk: {
            if (stats.p95RecentMs()) |p| {
                const full = try std.fmt.allocPrint(a, "avg {d}ms · p95 {d}ms · max {d}ms", .{ avg_ms, p, stats.max_ms });
                if (autil.cellWidth(win, full) <= width_cells) break :blk full;
                const compact = try std.fmt.allocPrint(a, "avg {d}ms · p95 {d}ms", .{ avg_ms, p });
                if (autil.cellWidth(win, compact) <= width_cells) break :blk compact;
                break :blk try std.fmt.allocPrint(a, "p95 {d}ms", .{p});
            }
            const plain = try std.fmt.allocPrint(a, "avg {d}ms · max {d}ms", .{ avg_ms, stats.max_ms });
            if (autil.cellWidth(win, plain) <= width_cells) break :blk plain;
            break :blk try std.fmt.allocPrint(a, "avg {d}ms", .{avg_ms});
        } else "no latency samples";
        try drawRailTextRow(self, win, a, y, x, w, border_style, rail_bg, latency, st.dim);
        y += 1;
    }

    if (more > 0 and y < body_end) {
        const text = try std.fmt.allocPrint(a, "+{d} more tools", .{more});
        try drawRailTextRow(self, win, a, y, x, w, border_style, rail_bg, text, st.faint);
    }

    if (chart_h >= 2 and body_end >= chart_h + 1) {
        const chart_y = body_end - chart_h;
        if (chart_y > m.body_top) {
            if (toolChartCanvas(self, a, active_idx, w -| 3, chart_h)) |canvas| {
                try drawChartCanvas(self, a, win, x, w, border_style, rail_bg, chart_y, canvas);
            } else if (chart_y < body_end) {
                try drawRailTextRow(self, win, a, chart_y, x, w, border_style, rail_bg, "no latency samples yet", st.faint);
            }
        }
    }
}

fn drawChatBody(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    st: Styles,
    x: u32,
    w: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
    m: *const ws.Metrics,
    active: *AgentThread,
) !void {
    const content_w = w -| 3;
    const CardRow = struct { msg: usize, row: u32 };
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |*r| r.segs.deinit(a);
        rows.deinit(a);
    }
    var card_rows: std.ArrayList(CardRow) = .empty;
    defer card_rows.deinit(self.alloc);

    for (active.messages.items, 0..) |msg, mi| {
        if (msg.role == .tool) {
            const at: u32 = @intCast(rows.items.len);
            try appendToolCardRows(self, a, &rows, st, content_w, &msg);
            try card_rows.append(self.alloc, .{ .msg = mi, .row = at });
        } else {
            // A tool-call assistant turn with no text is represented by its
            // cards; an empty in-flight bubble renders nothing (M1 behavior).
            if (msg.role == .assistant and msg.tool_calls_json != null and msg.text.len == 0) continue;
            try appendMessageRows(a, &rows, st, content_w, msg.role, msg.text);
        }
    }
    if (active.error_text) |err| {
        const prefix = try std.fmt.allocPrint(a, "error: {s}", .{std.mem.trim(u8, err, " \t\r\n")});
        try appendWrappedPlain(a, &rows, content_w, prefix, st.error_style);
    } else if (active.status == .cancelled) {
        try appendWrappedPlain(a, &rows, content_w, "[stream cancelled]", st.faint);
    }
    if (toolState(self, self.ai.threads.active)) |tool_state| {
        if (tool_state.note) |note| {
            try appendWrappedPlain(a, &rows, content_w, note, st.faint);
        }
    }
    if (active.messages.items.len == 0 and active.error_text == null and active.status != .cancelled) {
        try appendWrappedPlain(a, &rows, content_w, "no messages yet", st.dim);
        try appendWrappedPlain(a, &rows, content_w, "ask about this file", st.faint);
    }

    const total: u32 = @intCast(rows.items.len);
    active.total_rows = total;
    active.view_rows = m.body_rows;
    const max_top = total -| m.body_rows;
    if (active.auto_scroll) {
        active.scroll = max_top;
    } else if (active.scroll > max_top) {
        active.scroll = max_top;
    }
    const top = active.scroll;

    var k: u32 = 0;
    while (k < m.body_rows) : (k += 1) {
        const ri = top + k;
        const y = m.body_top + k;
        if (ri >= rows.items.len) {
            try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, &.{}, 0);
            continue;
        }
        const row = rows.items[ri];
        try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, row.segs.items, row.cells);
    }

    // Tool cards are interactive through the existing hint API: activating
    // the label toggles the result excerpt open/closed (a real action; no
    // invented controls). Only visible card rows are targets.
    if (self.mouseTargetsCollecting()) {
        for (card_rows.items) |card| {
            if (card.row < top) continue;
            const rel = card.row - top;
            if (rel >= m.body_rows) continue;
            self.addHintTarget(.{
                .row = m.body_top + rel,
                .col = x + 2,
                .width = content_w,
                .height = 1,
            }, .{ .tool_card_toggle = card.msg });
        }
    }
}
