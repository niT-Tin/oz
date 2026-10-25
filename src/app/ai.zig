//! AI workspace (M2a): docked Agent Rail + Workbox.
//!
//! State lives at session level (`App.ai`), not per workspace: closing the
//! rail or switching workspaces never drops a thread. The pure layout /
//! focus / thread model is `src/ai/workspace.zig`; this file owns the
//! transport (one client per thread), key routing and rendering.
const std = @import("std");
const vaxis = @import("vaxis");

const buffer = @import("../buffer/root.zig");
const ai = @import("../ai/root.zig");
const autil = @import("util.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const ws = ai.workspace;

pub const Status = ws.Status;
pub const Role = ws.Role;
pub const Message = ws.Message;
pub const AgentThread = ws.Thread;
pub const Focus = ws.Focus;
pub const WorkboxTab = ws.WorkboxTab;

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

fn cancelClient(self: *App, idx: usize) void {
    if (idx < self.ai.clients.items.len) {
        if (self.ai.clients.items[idx]) |c| c.requestCancel();
    }
}

/// Create the first thread lazily (the rail may never be opened).
pub fn ensureAi(self: *App) !void {
    while (self.ai.clients.items.len < self.ai.threads.items.items.len) {
        try self.ai.clients.append(self.alloc, null);
    }
    if (self.ai.threads.items.items.len == 0) {
        try self.ai.clients.append(self.alloc, null);
        const idx = self.ai.threads.create(self.alloc) catch |e| {
            _ = self.ai.clients.pop();
            return e;
        };
        self.ai.threads.active = idx;
        self.ai.thread_cursor = idx;
        self.ai.thread_top = 0;
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
    try self.ai.clients.append(self.alloc, null);
    const idx = self.ai.threads.create(self.alloc) catch |e| {
        _ = self.ai.clients.pop();
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

/// True while ANY thread's worker is alive or has queued events: the run
/// loop polls instead of blocking so deltas (from the active thread or a
/// cancelled thread winding down) are drained without a keypress.
pub fn aiStreaming(self: *App) bool {
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| {
            if (c.isRunning() or c.hasEvents()) return true;
        }
    }
    return false;
}

pub fn deinitAi(self: *App) void {
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| c.requestCancel();
    }
    for (self.ai.clients.items) |maybe| {
        if (maybe) |c| {
            c.deinit();
            self.alloc.destroy(c);
        }
    }
    self.ai.clients.deinit(self.alloc);
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
    if (self.ai.threads.cancel(idx)) cancelClient(self, idx);
}

/// Build the provider request for the active prompt, append the messages,
/// and start that thread's background stream. Errors are surfaced in the
/// thread's workbox.
pub fn aiSend(self: *App) !void {
    if (self.ai.threads.items.items.len == 0) return;
    const idx = self.ai.threads.active;
    const t = &self.ai.threads.items.items[idx];
    if (t.status == .streaming) return;
    const prompt = std.mem.trim(u8, t.input.items, " \t\r\n");
    if (prompt.len == 0) return;
    try aiLoadConfig(self);
    const cfg = &self.ai.config.?;

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

    // Request messages: system is added by openai.buildRequestBody. The
    // new user turn is included here; the assistant placeholder is not.
    var msgs = std.ArrayList(ai.openai.Message).empty;
    defer msgs.deinit(self.alloc);
    for (t.messages.items) |m| {
        if (m.role == .assistant and m.text.len == 0) continue;
        try msgs.append(self.alloc, .{
            .role = if (m.role == .user) "user" else "assistant",
            .content = m.api_text,
        });
    }
    try msgs.append(self.alloc, .{ .role = "user", .content = api_text });
    const body = try ai.openai.buildRequestBody(self.alloc, cfg.model, cfg.system, msgs.items);
    defer self.alloc.free(body);
    const url = try std.fmt.allocPrint(self.alloc, "{s}/chat/completions", .{cfg.base_url});
    defer self.alloc.free(url);

    // Exactly one streaming thread at a time: any other live stream is
    // cancelled before this request starts (switching/new-thread usually
    // already did it; this is the defensive invariant).
    for (self.ai.threads.items.items, 0..) |_, oi| {
        if (oi == idx) continue;
        if (self.ai.threads.cancel(oi)) cancelClient(self, oi);
    }

    self.ai.threads.appendUser(self.alloc, idx, prompt, api_text) catch |e| {
        aiSetThreadError(self, idx, @errorName(e));
        return e;
    };
    self.ai.threads.beginAssistant(self.alloc, idx) catch |e| {
        aiSetThreadError(self, idx, @errorName(e));
        return e;
    };
    while (self.ai.clients.items.len <= idx) {
        self.ai.clients.append(self.alloc, null) catch |e| {
            self.ai.threads.dropEmptyAssistant(self.alloc, idx);
            aiSetThreadError(self, idx, @errorName(e));
            return e;
        };
    }
    const slot = &self.ai.clients.items[idx];
    if (slot.* == null) {
        const c = self.alloc.create(ai.client.Client) catch |e| {
            self.ai.threads.dropEmptyAssistant(self.alloc, idx);
            aiSetThreadError(self, idx, @errorName(e));
            return e;
        };
        c.* = ai.client.Client.init(self.alloc, self.io);
        slot.* = c;
    }
    slot.*.?.start(.{
        .url = url,
        .api_key = cfg.api_key,
        .body = body,
        .mock_dir = cfg.mock_dir,
    }) catch |e| {
        self.ai.threads.dropEmptyAssistant(self.alloc, idx);
        aiSetThreadError(self, idx, "start failed");
        std.log.debug("ai start failed: {s}", .{@errorName(e)});
        return;
    };

    // Only after the worker is running: no failure path can leave a thread
    // stuck at `streaming` with no client to drain.
    self.ai.threads.markStreaming(self.alloc, idx);
    t.input.clearRetainingCapacity();
    t.scroll = 0;
    t.auto_scroll = true;
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
        while (client.pop()) |ev| {
            defer ev.deinit(self.alloc);
            changed = true;
            if (t.cancel_requested) continue;
            switch (ev) {
                .delta => |text| {
                    if (try self.ai.threads.applyDelta(self.alloc, idx, text)) {
                        t.auto_scroll = true;
                    }
                },
                .done => self.ai.threads.finish(idx),
                .err => |text| {
                    self.ai.threads.fail(self.alloc, idx, text);
                },
                .cancelled => {
                    if (t.status == .streaming) {
                        t.status = .cancelled;
                        t.cancel_requested = true;
                    }
                },
            }
        }
        // Safety net: a worker that died without a terminal event must not
        // leave the workbox saying "streaming…" forever.
        if (t.status == .streaming and !client.isRunning() and !client.hasEvents()) {
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
    return @as(?[]const u8, try std.fmt.allocPrint(a, "agent {s} · {s} · {s}", .{ t.title, model, t.statusLabel() }));
}

/// Narrow status-bar variant (drops the "agent " prefix). Used only when the
/// full form would collide with the left status text / git branch.
pub fn aiStatusTextCompact(self: *App, a: std.mem.Allocator) !?[]const u8 {
    if (self.ai.threads.items.items.len == 0) return null;
    const t = self.ai.threads.activeThreadConst();
    const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s} · {s} · {s}", .{ t.title, model, t.statusLabel() }));
}

/// Last-resort status-bar variant that preserves the thread name and status
/// (model omitted) instead of dropping the segment entirely.
pub fn aiStatusTextMini(self: *App, a: std.mem.Allocator) !?[]const u8 {
    if (self.ai.threads.items.items.len == 0) return null;
    const t = self.ai.threads.activeThreadConst();
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s} · {s}", .{ t.title, t.statusLabel() }));
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
    border: vaxis.Style,
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

fn railStatusStyle(st: Styles, status: Status) vaxis.Style {
    return switch (status) {
        .idle => st.dim,
        .streaming => st.accent,
        .cancelled => st.faint,
        .err => st.error_style,
    };
}

fn threadDot(status: Status) []const u8 {
    return switch (status) {
        .idle => "○",
        .streaming => "●",
        .cancelled => "◌",
        .err => "✖",
    };
}

fn threadDotStyle(st: Styles, status: Status) vaxis.Style {
    return switch (status) {
        .idle => st.faint,
        .streaming => st.accent,
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
    const rail_bg = vaxis.Color{ .rgb = t.bg_float };
    const content_w = w -| 3;
    const focused = self.ai.focus != .editor;
    const border_color = if (focused) t.accent else t.fg_faint;
    const border_style = vaxis.Style{ .fg = .{ .rgb = border_color }, .bg = rail_bg };
    const m = ws.metrics(rail_rows, self.ai.tab);

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
        .border = border_style,
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

    // ---- header: ▥ agents  N  [+] ----
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "▥ ", .style = if (focused) st.accent else st.dim });
        try segs.append(a, .{ .text = "agents", .style = if (focused) st.accent else st.bold });
        try segs.append(a, .{ .text = " ", .style = st.base });
        const count = try std.fmt.allocPrint(a, "{d}", .{self.ai.threads.items.items.len});
        try segs.append(a, .{ .text = count, .style = st.dim });
        var used: u32 = 2 + 6 + 1 + @as(u32, @intCast(count.len));
        // right-aligned "+" affordance (n / + also work from the rail).
        if (content_w >= used + 2) {
            try segs.append(a, .{ .text = try spaces(a, content_w - used - 1), .style = .{ .bg = rail_bg } });
            try segs.append(a, .{ .text = "+", .style = st.accent });
            used = content_w;
            if (self.hints.collecting) {
                self.addHintTarget(.{
                    .row = m.header_row,
                    .col = x + 2 + content_w - 1,
                    .width = 1,
                    .height = 1,
                }, .agent_new);
            }
        }
        try drawRailRow(win, a, m.header_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    // ---- workspace group + thread list ----
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        const ws_name = self.curWsName();
        const fit = autil.cellFitPrefix(win, ws_name, content_w);
        try segs.append(a, .{ .text = fit.slice, .style = st.dim });
        var used: u32 = @intCast(fit.cells);
        const label = "workspace";
        const lw = autil.cellWidth(win, label);
        if (content_w >= used + lw + 1) {
            try segs.append(a, .{ .text = try spaces(a, content_w - used - lw), .style = .{ .bg = rail_bg } });
            try segs.append(a, .{ .text = label, .style = st.faint });
            used = content_w;
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
        const dot_style = threadDotStyle(st, thread.status);
        const status_text = thread.statusLabel();
        const status_cells = autil.cellWidth(win, status_text);

        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = threadDot(thread.status), .style = .{ .fg = dot_style.fg, .bg = row_bg } });
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
            try segs.append(a, .{ .text = try spaces(a, content_w -| used -| status_cells), .style = .{ .bg = row_bg } });
            try segs.append(a, .{ .text = status_text, .style = .{ .fg = dot_style.fg, .bg = row_bg } });
            used = content_w;
        }
        if (highlight and selected) cursor_row = y;
        try drawRailRow(win, a, y, x, w, "│", border_style, rail_bg, segs.items, used);
        if (self.hints.collecting) {
            self.addHintTarget(.{
                .row = y,
                .col = x + 2,
                .width = content_w,
                .height = 1,
            }, .{ .agent_thread_select = ti });
        }
    }

    // ---- divider ----
    {
        var rule = std.ArrayList(u8).empty;
        var rc: u32 = 0;
        while (rc < content_w) : (rc += 1) try rule.appendSlice(a, "─");
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = rule.items, .style = st.faint });
        try drawRailRow(win, a, m.divider_row, x, w, "├", border_style, rail_bg, segs.items, content_w);
    }

    // ---- workbox header: thread · status, model right ----
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = active.title, .style = st.bold });
        try segs.append(a, .{ .text = " · ", .style = st.dim });
        try segs.append(a, .{ .text = active.statusLabel(), .style = railStatusStyle(st, active.status) });
        var used: u32 = @intCast(autil.cellWidth(win, active.title) + 3 + autil.cellWidth(win, active.statusLabel()));
        const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
        const mw = autil.cellWidth(win, model);
        if (content_w >= used + mw + 2) {
            const fit = autil.cellFitSuffix(win, model, content_w -| used -| 1);
            if (fit.cells > 0) {
                try segs.append(a, .{ .text = try spaces(a, content_w -| used -| @as(u32, @intCast(fit.cells))), .style = .{ .bg = rail_bg } });
                try segs.append(a, .{ .text = fit.slice, .style = st.faint });
                used += @as(u32, @intCast(fit.cells));
            }
        }
        try drawRailRow(win, a, m.workbox_header_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    // ---- tabs: chat / changes N / tools / terminal ----
    {
        const changes_label = try std.fmt.allocPrint(a, "changes {d}", .{self.inlinePendingCount()});
        const Tabs = [_]struct { tab: WorkboxTab, label: []const u8 }{
            .{ .tab = .chat, .label = "chat" },
            .{ .tab = .changes, .label = changes_label },
            .{ .tab = .tools, .label = "tools" },
            .{ .tab = .terminal, .label = "terminal" },
        };
        var segs = std.ArrayList(vaxis.Segment).empty;
        var used: u32 = 0;
        for (Tabs, 0..) |entry, i| {
            if (i > 0) {
                try segs.append(a, .{ .text = " ", .style = .{ .bg = rail_bg } });
                used += 1;
            }
            const active_tab = self.ai.tab == entry.tab;
            const style: vaxis.Style = if (active_tab)
                .{ .fg = .{ .rgb = t.accent }, .bg = .{ .rgb = t.bg_status }, .bold = true }
            else
                .{ .fg = .{ .rgb = t.fg_dim }, .bg = rail_bg };
            const label_cells: u32 = @intCast(autil.cellWidth(win, entry.label));
            if (self.hints.collecting) {
                self.addHintTarget(.{
                    .row = m.tabs_row,
                    .col = x + 2 + used,
                    .width = label_cells,
                    .height = 1,
                }, .{ .workbox_tab = entry.tab });
            }
            try segs.append(a, .{ .text = entry.label, .style = style });
            used += label_cells;
        }
        try drawRailRow(win, a, m.tabs_row, x, w, "│", border_style, rail_bg, segs.items, used);
    }

    // ---- body ----
    if (m.body_rows > 0) {
        switch (self.ai.tab) {
            .chat => try drawChatBody(self, a, win, st, x, w, border_style, rail_bg, &m, active),
            .changes => {
                if (self.inlinePendingCount() > 0) {
                    try self.drawInlineChanges(a, win, x, w, m.body_top, m.body_rows, border_style, rail_bg);
                } else {
                    try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, "no pending changes", st.dim);
                    if (m.body_rows > 2) {
                        try drawRailTextRow(self, win, a, m.body_top + 2, x, w, border_style, rail_bg, "select lines · <leader>i", st.faint);
                    }
                }
            },
            .tools => {
                try drawRailTextRow(self, win, a, m.body_top, x, w, border_style, rail_bg, "tools arrive in M3", st.dim);
                if (m.body_rows > 2) {
                    try drawRailTextRow(self, win, a, m.body_top + 2, x, w, border_style, rail_bg, "no tool runs recorded", st.faint);
                }
            },
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
        if (self.hints.collecting) {
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
    _ = self;
    const content_w = w -| 3;
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |*r| r.segs.deinit(a);
        rows.deinit(a);
    }
    for (active.messages.items) |msg| {
        try appendMessageRows(a, &rows, st, content_w, msg.role, msg.text);
    }
    if (active.error_text) |err| {
        const prefix = try std.fmt.allocPrint(a, "error: {s}", .{std.mem.trim(u8, err, " \t\r\n")});
        try appendWrappedPlain(a, &rows, content_w, prefix, st.error_style);
    } else if (active.status == .cancelled) {
        try appendWrappedPlain(a, &rows, content_w, "[stream cancelled]", st.faint);
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
}
