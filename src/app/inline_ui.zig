//! Inline assistant (M2b2) — App-facing half.
//!
//! Pure request/diff/pending logic lives in `src/app/inline.zig`. This file
//! owns the compact prompt float, the dedicated background client, streaming
//! state, approve/reject and the Workbox Changes rendering.
//!
//! Invariants:
//!   - the inline request never reads or writes a chat `Thread`; it has its
//!     own client and its own request body (system + one user message);
//!   - a generated replacement only becomes a `Pending` and is applied by an
//!     explicit human approve; `Esc`/`Ctrl+c` leaves the buffer untouched;
//!   - approve is refused when the buffer revision/path/range changed since
//!     generation ("stale selection") — the pending diff stays reviewable;
//!   - exactly one pending edit and at most one live inline stream.
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const ai = @import("../ai/root.zig");
const ws = @import("../ai/workspace.zig");
const buffer = @import("../buffer/root.zig");
const autil = @import("util.zig");
const hints = @import("hints.zig");
const inline_model = @import("inline.zig");

pub const Status = enum { idle, prompting, streaming, err };

pub const Session = struct {
    /// True while the compact prompt float owns the keyboard.
    prompt_open: bool = false,
    status: Status = .idle,
    /// Draft instruction (single-line; paste newlines are flattened).
    instruction: std.ArrayList(u8) = .empty,
    /// Set when the prompt opens and consumed by completion/cancel.
    snapshot: ?inline_model.Snapshot = null,
    error_text: ?[]u8 = null,
    /// Replacement bytes accumulated from the stream.
    streamed: std.ArrayList(u8) = .empty,
    /// Completed replacement awaiting review (at most one).
    pending: ?inline_model.Pending = null,
    /// First visible diff line in the Changes body.
    pending_scroll: u32 = 0,
    /// Dedicated transport: never shared with a chat thread.
    client: ?*ai.client.Client = null,
    /// True while the current client belongs to an un-cancelled request;
    /// late events after cancel/completion are dropped.
    request_active: bool = false,
};

fn inlineMsg(self: *App, text: []const u8) void {
    const copy = self.alloc.dupe(u8, text) catch return;
    self.setMsg(copy) catch {
        self.alloc.free(copy);
    };
}

fn clearError(self: *App) void {
    if (self.inline_edit.error_text) |e| {
        self.alloc.free(e);
        self.inline_edit.error_text = null;
    }
}

fn setInlineError(self: *App, text: []const u8) void {
    clearError(self);
    self.inline_edit.error_text = self.alloc.dupe(u8, text) catch null;
    self.inline_edit.status = .err;
    self.inline_edit.request_active = false;
    // Make a retry safe even if the worker has not noticed failure yet:
    // Client.start joins a running-but-cancelled worker before reusing it.
    if (self.inline_edit.client) |c| c.requestCancel();
    self.inline_edit.streamed.clearRetainingCapacity();
}

fn setInlineErrorFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    defer self.alloc.free(text);
    setInlineError(self, text);
}

fn clearSnapshot(self: *App) void {
    if (self.inline_edit.snapshot) |*s| {
        s.deinit(self.alloc);
        self.inline_edit.snapshot = null;
    }
}

pub fn inlinePendingCount(self: *App) u32 {
    return if (self.inline_edit.pending != null) 1 else 0;
}

pub fn inlinePromptOpen(self: *App) bool {
    return self.inline_edit.prompt_open;
}

pub fn inlineStreaming(self: *App) bool {
    if (self.inline_edit.client) |c| return c.isRunning() or c.hasEvents();
    return false;
}

pub fn deinitInline(self: *App) void {
    const s = &self.inline_edit;
    if (s.client) |c| {
        c.requestCancel();
        c.deinit();
        self.alloc.destroy(c);
        s.client = null;
    }
    clearSnapshot(self);
    if (s.pending) |*p| p.deinit(self.alloc);
    s.pending = null;
    s.instruction.deinit(self.alloc);
    s.streamed.deinit(self.alloc);
    clearError(self);
}

fn ensureInlineConfig(self: *App) !*ai.config.Config {
    if (self.ai.config == null) {
        self.ai.config = try ai.config.fromEnv(self.alloc, self.env_map);
    }
    return &self.ai.config.?;
}

fn currentBufferIndex(self: *App) usize {
    return self.windows.items[self.current_win].buf;
}

/// `<leader>i`: open the compact prompt for the active visual selection.
/// No selection → a clear message and no state change. A pending edit must
/// be resolved first (one-pending policy; never silently replace it).
pub fn startInlineEdit(self: *App) !void {
    if (self.inline_edit.prompt_open) return;
    if (self.inline_edit.pending != null or self.agentEditAnyPending()) {
        inlineMsg(self, "inline edit: reject the pending change first");
        return;
    }
    if (!self.isVisual() or self.visual_anchor == null) {
        inlineMsg(self, "inline edit: select lines first");
        return;
    }
    const anchor = self.visual_anchor.?;
    const cursor = self.curCursor().*;
    const linewise = self.state.mode == .visual_line;
    const range = inline_model.computeRange(&self.cur().pt, linewise, anchor, cursor);
    const text = inline_model.selectionText(self.alloc, &self.cur().pt, range) catch |e| {
        inlineMsg(self, @errorName(e));
        return e;
    };
    defer self.alloc.free(text);
    const snap = inline_model.Snapshot.init(
        self.alloc,
        currentBufferIndex(self),
        self.cur().path,
        range,
        text,
        self.cur().history.revision,
    ) catch |e| {
        inlineMsg(self, @errorName(e));
        return e;
    };
    const s = &self.inline_edit;
    if (s.snapshot) |*old| old.deinit(self.alloc);
    s.snapshot = snap;
    s.prompt_open = true;
    s.status = .prompting;
    s.request_active = false;
    s.pending_scroll = 0;
    s.instruction.clearRetainingCapacity();
    s.streamed.clearRetainingCapacity();
    clearError(self);
    // Prompt shows the model; a config failure is surfaced here but does not
    // touch any chat thread.
    _ = ensureInlineConfig(self) catch |e| setInlineErrorFmt(self, "config: {s}", .{@errorName(e)});
    self.ai.rail_pending_leader = false;
    self.pending_window = false;
    self.pending_replace = null;
}

fn deleteWordBefore(self: *App) void {
    const buf = &self.inline_edit.instruction;
    if (buf.items.len == 0) return;
    var end = buf.items.len;
    while (end > 0 and (buf.items[end - 1] == ' ' or buf.items[end - 1] == '\t')) end -= 1;
    while (end > 0 and buf.items[end - 1] != ' ' and buf.items[end - 1] != '\t') end -= 1;
    buf.shrinkRetainingCapacity(end);
}

/// Prompt key routing. The prompt owns every key while open: editor
/// shortcuts, the leader and vim sequences are unreachable here.
pub fn handleInlineKey(self: *App, key: vaxis.Key) !void {
    const s = &self.inline_edit;
    if (!s.prompt_open) return;
    // Ctrl+c always cancels (including an in-flight generation).
    if (key.mods.ctrl and key.codepoint == 'c') {
        inlineCancel(self);
        return;
    }
    if (key.mods.ctrl and key.codepoint == 'w') {
        deleteWordBefore(self);
        return;
    }
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.codepoint == vaxis.Key.escape) {
        inlineCancel(self);
        return;
    }
    if (key.codepoint == vaxis.Key.enter) {
        try submitInlineEdit(self);
        return;
    }
    if (key.codepoint == vaxis.Key.backspace) {
        if (s.instruction.items.len > 0) {
            const cut = buffer.utf8.prevBoundary(s.instruction.items, s.instruction.items.len);
            s.instruction.shrinkRetainingCapacity(cut);
        }
        return;
    }
    if (key.text) |text| {
        if (text.len > 0) {
            if (s.status == .streaming) return;
            try s.instruction.appendSlice(self.alloc, text);
        }
    }
}

/// Bracketed paste into the prompt: flatten line breaks/tabs so the
/// single-line input stays readable and cannot inject control bytes.
pub fn inlinePaste(self: *App, text: []const u8) !void {
    const s = &self.inline_edit;
    if (!s.prompt_open or s.status == .streaming) return;
    for (text) |c| {
        switch (c) {
            '\n', '\r' => try s.instruction.append(self.alloc, ' '),
            '\t' => try s.instruction.appendSlice(self.alloc, "    "),
            else => {
                if (c < 0x20) continue;
                try s.instruction.append(self.alloc, c);
            },
        }
    }
}

/// Build and start the dedicated inline stream. Errors stay in the prompt;
/// no buffer or chat state is touched.
pub fn submitInlineEdit(self: *App) !void {
    const s = &self.inline_edit;
    if (!s.prompt_open or s.status == .streaming) return;
    const instruction = std.mem.trim(u8, s.instruction.items, " \t\r\n");
    if (instruction.len == 0) {
        setInlineError(self, "write an instruction first");
        return;
    }
    const snap = if (s.snapshot) |*sp| sp else {
        setInlineError(self, "selection lost");
        return;
    };
    const cfg = ensureInlineConfig(self) catch |e| {
        setInlineErrorFmt(self, "config: {s}", .{@errorName(e)});
        return;
    };
    const body = inline_model.buildRequestBody(
        self.alloc,
        cfg.model,
        snap.path,
        snap.range,
        instruction,
        snap.text,
    ) catch |e| {
        setInlineErrorFmt(self, "request: {s}", .{@errorName(e)});
        return;
    };
    defer self.alloc.free(body);
    const url = std.fmt.allocPrint(self.alloc, "{s}/chat/completions", .{cfg.base_url}) catch |e| {
        setInlineErrorFmt(self, "request: {s}", .{@errorName(e)});
        return;
    };
    defer self.alloc.free(url);

    if (s.client == null) {
        const c = self.alloc.create(ai.client.Client) catch |e| {
            setInlineErrorFmt(self, "client: {s}", .{@errorName(e)});
            return;
        };
        c.* = ai.client.Client.init(self.alloc, self.io);
        s.client = c;
    }
    s.client.?.start(.{
        .url = url,
        .api_key = cfg.api_key,
        .body = body,
        .mock_dir = cfg.mock_dir,
    }) catch |e| {
        setInlineErrorFmt(self, "start failed: {s}", .{@errorName(e)});
        return;
    };
    clearError(self);
    s.streamed.clearRetainingCapacity();
    s.status = .streaming;
    s.request_active = true;
}

/// Esc / Ctrl+c: cancel the worker (if any), close the prompt, keep the
/// visual selection and leave the buffer byte-identical.
pub fn inlineCancel(self: *App) void {
    const s = &self.inline_edit;
    const was_streaming = s.status == .streaming;
    if (s.client) |c| {
        if (s.request_active) c.requestCancel();
    }
    s.request_active = false;
    s.prompt_open = false;
    s.status = .idle;
    s.streamed.clearRetainingCapacity();
    s.instruction.clearRetainingCapacity();
    clearError(self);
    clearSnapshot(self);
    inlineMsg(self, if (was_streaming) "inline edit cancelled" else "inline edit cancelled");
}

fn completeInline(self: *App) !void {
    const s = &self.inline_edit;
    if (!s.request_active) return;
    if (s.snapshot == null) {
        inlineCancel(self);
        return;
    }
    const replacement = inline_model.stripFences(self.alloc, s.streamed.items) catch |e| {
        setInlineErrorFmt(self, "replacement: {s}", .{@errorName(e)});
        return;
    };
    defer self.alloc.free(replacement);
    if (s.pending != null) {
        setInlineError(self, "reject the pending change first");
        return;
    }
    const pending = inline_model.Pending.init(self.alloc, &s.snapshot.?, replacement) catch |e| {
        setInlineErrorFmt(self, "pending: {s}", .{@errorName(e)});
        return;
    };
    s.pending = pending;
    s.pending_scroll = 0;
    s.request_active = false;
    s.status = .idle;
    s.prompt_open = false;
    s.streamed.clearRetainingCapacity();
    s.instruction.clearRetainingCapacity();
    clearError(self);
    clearSnapshot(self);
    self.exitVisual();
    self.state.mode = .normal;
    self.in_insert = false;
    self.focus = .buffer;
    // Show the review surface: open the rail if needed, Changes tab, badge 1.
    self.ensureAi() catch {};
    self.ai.rail_open = true;
    self.ai.tab = .changes;
    self.ai.focus = .rail;
    self.ai.rail_pending_leader = false;
    self.ai.thread_cursor = self.ai.threads.active;
    inlineMsg(self, "inline edit ready · a approve · r reject");
}

/// Drain the dedicated inline client. Returns true when anything changed.
pub fn drainInline(self: *App) !bool {
    const s = &self.inline_edit;
    const c = s.client orelse return false;
    var changed = false;
    while (c.pop()) |ev| {
        defer ev.deinit(self.alloc);
        changed = true;
        if (!s.request_active) continue; // late events after cancel/complete
        switch (ev) {
            .delta => |text| {
                if (s.status != .streaming) continue;
                if (s.streamed.items.len + text.len > inline_model.max_replacement_bytes) {
                    if (s.client) |cl| cl.requestCancel();
                    setInlineError(self, "replacement too large");
                    continue;
                }
                try s.streamed.appendSlice(self.alloc, text);
            },
            .done => try completeInline(self),
            .err => |text| setInlineError(self, text),
            .cancelled => {
                if (s.request_active) setInlineError(self, "stream cancelled");
            },
            // The inline request never advertises tools; a tool-call event
            // is a protocol surprise. `defer ev.deinit` already freed it.
            .tool_calls => {},
        }
    }
    if (s.request_active and s.status == .streaming and !c.isRunning() and !c.hasEvents()) {
        setInlineError(self, "stream ended unexpectedly");
        changed = true;
    }
    return changed;
}

fn clearPending(self: *App) void {
    if (self.inline_edit.pending) |*p| p.deinit(self.alloc);
    self.inline_edit.pending = null;
    self.inline_edit.pending_scroll = 0;
}

fn findPendingBuffer(self: *App, p: *const inline_model.Pending) ?usize {
    if (p.path) |want| {
        for (self.buffers.items, 0..) |buf, i| {
            if (buf.path) |got| {
                if (std.mem.eql(u8, got, want)) return i;
            }
        }
        return null;
    }
    // Unnamed scratch buffer: only the original index is meaningful.
    if (p.buffer_index < self.buffers.items.len) return p.buffer_index;
    return null;
}

fn pendingSnapshotsEqual(self: *App, p: *const inline_model.Pending, buf: *const App.Buffer) bool {
    const len = p.end - p.start;
    if (p.original.len != len or p.end > buf.pt.len()) return false;
    if (len == 0) return true;
    const actual = self.alloc.alloc(u8, len) catch return false;
    defer self.alloc.free(actual);
    buf.pt.copyRange(p.start, actual);
    return std.mem.eql(u8, actual, p.original);
}

/// Apply the pending replacement as ONE undo group, after staleness checks.
pub fn inlineApprove(self: *App) !void {
    const s = &self.inline_edit;
    const p = if (s.pending) |*pp| pp else return;
    if (p.end < p.start) {
        p.stale = true;
        inlineMsg(self, "stale selection");
        return;
    }
    const idx = findPendingBuffer(self, p) orelse {
        p.stale = true;
        inlineMsg(self, "stale selection");
        return;
    };
    const buf_idx = idx;
    const stale = p.isStale(self.buffers.items[buf_idx].history.revision) or
        !pendingSnapshotsEqual(self, p, &self.buffers.items[buf_idx]);
    if (stale) {
        p.stale = true;
        inlineMsg(self, "stale selection");
        return;
    }
    // Review while another buffer was focused: switch to the pending buffer
    // so the edit and the post-approve cursor land where the diff says.
    if (self.windows.items[self.current_win].buf != buf_idx) {
        self.switchTo(buf_idx);
    }
    const start = p.start;
    const end = p.end;
    const replacement = p.replacement;
    self.applyEdit(start, end, replacement) catch |e| {
        inlineMsg(self, @errorName(e));
        return;
    };
    self.curCursor().* = @min(start, self.cur().pt.len());
    self.state.mode = .normal;
    self.visual_anchor = null;
    self.in_insert = false;
    self.focus = .buffer;
    clearPending(self);
    self.ai.focus = .editor;
    inlineMsg(self, "inline edit applied · u to undo");
}

/// Discard the pending edit without touching the buffer or its history.
pub fn inlineReject(self: *App) void {
    if (self.inline_edit.pending == null) return;
    clearPending(self);
    self.focus = .buffer;
    self.ai.focus = .editor;
    self.state.mode = .normal;
    self.visual_anchor = null;
    inlineMsg(self, "inline edit rejected");
}

fn diffViewRows(self: *App) u32 {
    const rows = self.vx.window().height;
    if (rows <= app_mod.status_row_count) return 0;
    const m = ws.metrics(rows - app_mod.status_row_count, .changes);
    return m.body_rows -| 4;
}

fn scrollPending(self: *App, delta: i64) void {
    const p = if (self.inline_edit.pending) |*pp| pp else return;
    const vis = diffViewRows(self);
    if (vis == 0) return;
    const max_top = p.diff.len -| vis;
    var top: i64 = @intCast(@min(self.inline_edit.pending_scroll, max_top));
    top += delta;
    if (top < 0) top = 0;
    if (top > max_top) top = @intCast(max_top);
    self.inline_edit.pending_scroll = @intCast(top);
}

/// Changes-tab keys while the rail owns the keyboard. Returns true when the
/// key was consumed by the pending review.
pub fn handleInlineChangesKey(self: *App, key: vaxis.Key) !bool {
    const s = &self.inline_edit;
    if (s.pending == null or self.ai.tab != .changes or self.ai.focus != .rail) return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return false;
    if (key.codepoint == vaxis.Key.enter or key.codepoint == 'a') {
        try inlineApprove(self);
        return true;
    }
    if (key.codepoint == 'r' or key.codepoint == 'd') {
        inlineReject(self);
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

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn drawRow(
    win: vaxis.Window,
    a: std.mem.Allocator,
    y: u32,
    x: u32,
    w: u32,
    border: []const u8,
    border_style: vaxis.Style,
    bg: vaxis.Color,
    content: []const vaxis.Segment,
    used: u32,
) !void {
    const content_w = w -| 3;
    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.append(a, .{ .text = border, .style = border_style });
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    for (content) |seg| try segs.append(a, seg);
    const pad = content_w -| used;
    if (pad > 0) {
        const spaces = try a.alloc(u8, pad);
        @memset(spaces, ' ');
        try segs.append(a, .{ .text = spaces, .style = .{ .bg = bg } });
    }
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    _ = win.print(segs.items, .{ .row_offset = @intCast(y), .col_offset = @intCast(x), .wrap = .none });
}

fn drawTextRow(
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
    const segs = [_]vaxis.Segment{.{ .text = fit.slice, .style = style }};
    try drawRow(win, a, y, x, w, "│", border_style, bg, &segs, @intCast(fit.cells));
}

fn drawFloatRow(
    win: vaxis.Window,
    a: std.mem.Allocator,
    y: u32,
    x: u32,
    w: u32,
    bg: vaxis.Color,
    border_style: vaxis.Style,
    content: []const vaxis.Segment,
    used: u32,
) !void {
    const inner = w -| 4;
    var segs = std.ArrayList(vaxis.Segment).empty;
    try segs.append(a, .{ .text = "│", .style = border_style });
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    for (content) |seg| try segs.append(a, seg);
    const pad = inner -| used;
    if (pad > 0) {
        const spaces = try a.alloc(u8, pad);
        @memset(spaces, ' ');
        try segs.append(a, .{ .text = spaces, .style = .{ .bg = bg } });
    }
    try segs.append(a, .{ .text = " ", .style = .{ .bg = bg } });
    try segs.append(a, .{ .text = "│", .style = border_style });
    _ = win.print(segs.items, .{ .row_offset = @intCast(y), .col_offset = @intCast(x), .wrap = .none });
}

/// Compact centered prompt float, height 6:
///   ╭─ inline edit ─────╮
///   │ model: …   ready │
///   │ ❯ instruction    │
///   │ Enter … Esc …    │
///   │ lines A-B · N B  │
///   ╰──────────────────╯
pub fn drawInlinePrompt(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    const s = &self.inline_edit;
    if (!s.prompt_open) return;
    const rows: u32 = win.height;
    const cols: u32 = win.width;
    if (rows < 8 or cols < 24) return;
    const width = @min(@as(u32, 64), cols -| 4);
    if (width < 24) return;
    const height: u32 = 6;
    const x = (cols - width) / 2;
    var y = (rows - height) / 2;
    if (y + height > rows - 1) y = (rows - 1) -| height;

    const t = self.theme;
    const bg = vaxis.Color{ .rgb = t.bg_float };
    const border_style: vaxis.Style = .{ .fg = .{ .rgb = t.accent }, .bg = bg };
    const dim: vaxis.Style = .{ .fg = .{ .rgb = t.fg_dim }, .bg = bg };
    const faint: vaxis.Style = .{ .fg = .{ .rgb = t.fg_faint }, .bg = bg };
    const base: vaxis.Style = .{ .fg = .{ .rgb = t.fg }, .bg = bg };
    const err_style: vaxis.Style = .{ .fg = .{ .rgb = t.diag_error }, .bg = bg, .bold = true };
    const accent: vaxis.Style = .{ .fg = .{ .rgb = t.accent }, .bg = bg, .bold = true };

    const panel = win.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(height),
    });
    panel.fill(.{ .style = .{ .bg = bg } });

    // top border + title
    {
        const title = "inline edit";
        const fixed: u32 = @intCast(title.len + 5);
        const dashes = width -| fixed;
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "╭─ ", .style = border_style });
        try segs.append(a, .{ .text = title, .style = accent });
        try segs.append(a, .{ .text = " ", .style = border_style });
        if (dashes > 0) try segs.append(a, .{ .text = try dashRun(a, dashes), .style = border_style });
        try segs.append(a, .{ .text = "╮", .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(y), .col_offset = @intCast(x), .wrap = .none });
    }

    // model + status
    {
        const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
        const status_text: []const u8 = switch (s.status) {
            .idle, .prompting => "ready",
            .streaming => "streaming…",
            .err => "error",
        };
        const status_style: vaxis.Style = switch (s.status) {
            .streaming => accent,
            .err => err_style,
            else => dim,
        };
        const inner = width -| 4;
        const status_cells: u32 = @intCast(autil.cellWidth(win, status_text));
        const left_cap: usize = @intCast(inner -| status_cells -| 1);
        const left = try std.fmt.allocPrint(a, "model: {s}", .{model});
        const fit = autil.cellFitPrefix(win, left, left_cap);
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = fit.slice, .style = dim });
        var used: u32 = @intCast(fit.cells);
        if (inner >= used + status_cells) {
            const pad = inner - used - status_cells;
            if (pad > 0) {
                const sp = try a.alloc(u8, pad);
                @memset(sp, ' ');
                try segs.append(a, .{ .text = sp, .style = .{ .bg = bg } });
            }
            try segs.append(a, .{ .text = status_text, .style = status_style });
            used = inner;
        }
        try drawFloatRow(win, a, y + 1, x, width, bg, border_style, segs.items, used);
    }

    // input row
    {
        const inner = width -| 4;
        const prefix = "❯ ";
        const cap: usize = @intCast(inner -| 2);
        const safe = try displaySafePrompt(a, s.instruction.items);
        const fit = autil.cellFitSuffix(win, safe, cap);
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = prefix, .style = accent });
        if (fit.cells > 0) try segs.append(a, .{ .text = fit.slice, .style = base });
        const used: u32 = 2 + @as(u32, @intCast(fit.cells));
        try drawFloatRow(win, a, y + 2, x, width, bg, border_style, segs.items, used);
        const cursor_col = x + 2 + 2 + @as(u32, @intCast(fit.cells));
        self.vx.screen.cursor = .{
            .row = @intCast(y + 2),
            .col = @intCast(@min(cursor_col, x + width - 2)),
        };
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = .beam;
    }

    // help / error (arena-owned: vaxis cells reference these slices until
    // vx.render(), so stack buffers would be dangling text)
    {
        const msg: []const u8 = if (s.error_text) |e|
            try std.fmt.allocPrint(a, "error: {s}", .{std.mem.trim(u8, e, " \t\r\n")})
        else if (s.status == .streaming)
            "Esc cancel · streaming replacement…"
        else
            "Enter generate · Esc cancel";
        const style: vaxis.Style = if (s.error_text != null) err_style else faint;
        const fit = autil.cellFitPrefix(win, msg, width -| 4);
        try drawFloatRow(win, a, y + 3, x, width, bg, border_style, &[_]vaxis.Segment{.{ .text = fit.slice, .style = style }}, @intCast(fit.cells));
    }

    // selection info
    {
        const snap = if (s.snapshot) |*sp| sp else null;
        const info: []const u8 = if (snap) |sp| blk: {
            const ll = inline_model.lineLabel(sp.range);
            break :blk try std.fmt.allocPrint(a, "lines {d}-{d} · {d} bytes · {s}", .{
                ll.first,
                ll.last,
                sp.text.len,
                if (sp.path) |p| std.fs.path.basename(p) else "[No Name]",
            });
        } else "no selection";
        const fit = autil.cellFitPrefix(win, info, width -| 4);
        try drawFloatRow(win, a, y + 4, x, width, bg, border_style, &[_]vaxis.Segment{.{ .text = fit.slice, .style = faint }}, @intCast(fit.cells));
    }

    // bottom border
    {
        const dashes = width -| 2;
        const segs = [_]vaxis.Segment{
            .{ .text = "╰", .style = border_style },
            .{ .text = try dashRun(a, dashes), .style = border_style },
            .{ .text = "╯", .style = border_style },
        };
        _ = win.print(&segs, .{ .row_offset = @intCast(y + height - 1), .col_offset = @intCast(x), .wrap = .none });
    }
}

fn dashRun(alloc: std.mem.Allocator, cells: u32) ![]const u8 {
    if (cells == 0) return "";
    const out = try alloc.alloc(u8, cells * 3);
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        out[i * 3] = 0xE2;
        out[i * 3 + 1] = 0x94;
        out[i * 3 + 2] = 0x80;
    }
    return out;
}

fn displaySafePrompt(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '\t' => try out.appendSlice(alloc, "    "),
            '\n', '\r' => try out.append(alloc, ' '),
            else => {
                if (c < 0x20) try out.append(alloc, ' ') else try out.append(alloc, c);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Generic staged-diff review body shared by the inline assistant and the
/// M3b1 agent edit. Fixed rows: header, stats, approve/reject buttons, blank,
/// then the cached diff lines. Rendering only touches visible rows; the diff
/// itself is never rebuilt per frame.
pub const ReviewView = struct {
    path: []const u8,
    first_line: u32,
    last_line: u32,
    removed: u32,
    added: u32,
    stale: bool = false,
    stale_label: []const u8 = "stale selection",
    /// True when the diff is a bounded preview rather than the whole edit.
    partial: bool = false,
    partial_label: []const u8 = "preview",
    diff: []const inline_model.DiffLine,
    scroll: *u32,
    approve_action: hints.Action,
    reject_action: hints.Action,
};

pub fn drawDiffReview(
    self: *App,
    a: std.mem.Allocator,
    win: vaxis.Window,
    x: u32,
    w: u32,
    body_top: u32,
    body_rows: u32,
    border_style: vaxis.Style,
    rail_bg: vaxis.Color,
    view: ReviewView,
) !void {
    if (body_rows == 0) return;
    const t = self.theme;
    const dim: vaxis.Style = .{ .fg = .{ .rgb = t.fg_dim }, .bg = rail_bg };
    const base: vaxis.Style = .{ .fg = .{ .rgb = t.fg }, .bg = rail_bg };
    const err_style: vaxis.Style = .{ .fg = .{ .rgb = t.diag_error }, .bg = rail_bg, .bold = true };
    const add_style: vaxis.Style = .{ .fg = .{ .rgb = t.string }, .bg = rail_bg };
    const accent: vaxis.Style = .{ .fg = .{ .rgb = t.accent }, .bg = rail_bg, .bold = true };
    const bottom = body_top + body_rows;
    var row = body_top;

    // header: path · lines A-B
    {
        const text = try std.fmt.allocPrint(a, "{s} · lines {d}-{d}", .{ view.path, view.first_line, view.last_line });
        try drawTextRow(self, win, a, row, x, w, border_style, rail_bg, text, base);
        row += 1;
    }
    if (row >= bottom) return;
    // stats + stale/partial markers
    {
        var text = try std.fmt.allocPrint(a, "-{d} +{d}", .{ view.removed, view.added });
        if (view.partial) text = try std.fmt.allocPrint(a, "{s}  {s}", .{ text, view.partial_label });
        if (view.stale) text = try std.fmt.allocPrint(a, "{s}  {s}", .{ text, view.stale_label });
        try drawTextRow(self, win, a, row, x, w, border_style, rail_bg, text, if (view.stale) err_style else dim);
        row += 1;
    }
    if (row >= bottom) return;
    // buttons (hint targets: Approve / Reject)
    {
        const content_w = w -| 3;
        const full = "[a] approve  [r] reject";
        if (content_w >= autil.cellWidth(win, full)) {
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{ .text = "[a] approve", .style = accent });
            try segs.append(a, .{ .text = "  ", .style = .{ .bg = rail_bg } });
            try segs.append(a, .{ .text = "[r] reject", .style = err_style });
            const used: u32 = @intCast(autil.cellWidth(win, full));
            try drawRow(win, a, row, x, w, "│", border_style, rail_bg, segs.items, used);
            if (self.hints.collecting) {
                self.addHintTarget(.{ .row = row, .col = x + 2, .width = 3, .height = 1 }, view.approve_action);
                self.addHintTarget(.{
                    .row = row,
                    .col = x + 2 + @as(u32, @intCast("[a] approve  ".len)),
                    .width = 3,
                    .height = 1,
                }, view.reject_action);
            }
        } else {
            try drawTextRow(self, win, a, row, x, w, border_style, rail_bg, "[a] approve  [r] reject", accent);
        }
        row += 1;
    }
    if (row >= bottom) return;
    // breathing row
    try drawRow(win, a, row, x, w, "│", border_style, rail_bg, &.{}, 0);
    row += 1;
    const diff_rows = bottom -| row;
    if (diff_rows == 0) return;
    const max_top = view.diff.len -| diff_rows;
    if (view.scroll.* > max_top) view.scroll.* = @intCast(max_top);
    const top = view.scroll.*;
    var k: u32 = 0;
    while (k < diff_rows) : (k += 1) {
        const idx = top + k;
        if (idx >= view.diff.len) break;
        const d = view.diff[idx];
        const prefix: []const u8 = switch (d.kind) {
            .context => "  ",
            .removed => "- ",
            .added => "+ ",
        };
        const style: vaxis.Style = switch (d.kind) {
            .context => base,
            .removed => err_style,
            .added => add_style,
        };
        // Cached diff text + a two-cell prefix drawn as segments: no
        // per-frame diff string construction/allocation.
        const content_w = w -| 3;
        const fit = autil.cellFitPrefix(win, d.text, content_w -| 2);
        const segs = [_]vaxis.Segment{
            .{ .text = prefix, .style = style },
            .{ .text = fit.slice, .style = style },
        };
        const used: u32 = 2 + @as(u32, @intCast(fit.cells));
        try drawRow(win, a, row + k, x, w, "│", border_style, rail_bg, &segs, used);
    }
    // Fill every remaining body row with the rail border: the Changes body
    // must stay a closed panel even when the diff is shorter than the body
    // (scenario/golden checks sample the bottom-left cell).
    var y = row + @min(@as(u32, @intCast(view.diff.len -| top)), diff_rows);
    while (y < bottom) : (y += 1) {
        try drawRow(win, a, y, x, w, "│", border_style, rail_bg, &.{}, 0);
    }
}

/// Workbox Changes body for the pending inline edit.
pub fn drawInlineChanges(
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
    const p = if (self.inline_edit.pending) |*pp| pp else return;
    try drawDiffReview(self, a, win, x, w, body_top, body_rows, border_style, rail_bg, .{
        .path = p.path orelse "[No Name]",
        .first_line = p.first_line,
        .last_line = p.last_line,
        .removed = p.removed,
        .added = p.added,
        .stale = p.stale,
        .stale_label = "stale selection",
        .diff = p.diff,
        .scroll = &self.inline_edit.pending_scroll,
        .approve_action = .inline_approve,
        .reject_action = .inline_reject,
    });
}
