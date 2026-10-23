//! AI chat panel: session state, key handling, request lifecycle and
//! rendering (M1).
//!
//! Split from app.zig like the other app/<domain>.zig groups; the App struct
//! owns one `Session` field and routes `<leader>a` / modal keys here.
const std = @import("std");
const vaxis = @import("vaxis");

const buffer = @import("../buffer/root.zig");
const ai = @import("../ai/root.zig");
const autil = @import("util.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const Status = enum { idle, streaming, cancelled, err };

pub const Role = enum { user, assistant };

pub const Message = struct {
    role: Role,
    /// What the transcript shows (the user's typed prompt).
    text: []u8,
    /// What is sent to the provider. User messages carry the editor context;
    /// assistant messages mirror `text`.
    api_text: []u8,
};

/// Session-wide AI state. Deliberately NOT per workspace: closing the panel
/// keeps the conversation, switching workspaces keeps the same thread.
pub const Session = struct {
    active: bool = false,
    config: ?ai.config.Config = null,
    client: ?*ai.client.Client = null,
    messages: std.ArrayList(Message) = .empty,
    input: std.ArrayList(u8) = .empty,
    status: Status = .idle,
    error_text: ?[]u8 = null,
    /// Transcript top row (wrapped rows) for manual scrolling.
    scroll: u32 = 0,
    /// Follow the bottom while streaming; a manual scroll disables it until
    /// the next send.
    auto_scroll: bool = true,
    /// Set on Ctrl+c/Ctrl+n: late worker events must not touch the
    /// conversation.
    cancel_requested: bool = false,
    /// Last rendered transcript geometry (for scroll bounds).
    total_rows: u32 = 0,
    view_rows: u32 = 0,
};

// ---- lifecycle ----

pub fn toggleAiPanel(self: *App) !void {
    if (self.ai.active) {
        self.ai.active = false;
        return;
    }
    self.ai.active = true;
    // A config failure is surfaced in the panel; opening the panel itself
    // must never make the editor unusable.
    if (self.ai.config == null) self.aiLoadConfig() catch {};
    // Opening the panel is a modal transition: nothing else may be pending.
    self.pending_window = false;
    self.pending_replace = null;
    if (self.msg) |m| {
        self.alloc.free(m);
        self.msg = null;
    }
}

pub fn aiLoadConfig(self: *App) !void {
    if (self.ai.config != null) return;
    self.ai.config = ai.config.fromEnv(self.alloc, self.env_map) catch |e| {
        self.aiSetErrorFmt("config: {s}", .{@errorName(e)});
        return e;
    };
}

pub fn aiSetError(self: *App, text: []const u8) void {
    if (self.ai.error_text) |e| self.alloc.free(e);
    self.ai.error_text = self.alloc.dupe(u8, text) catch null;
    self.ai.status = .err;
}

pub fn aiSetErrorFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    if (self.ai.error_text) |e| self.alloc.free(e);
    self.ai.error_text = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    self.ai.status = .err;
}

/// True while a stream worker is alive: the run loop polls (instead of
/// blocking) so deltas are drained and rendered without a keypress.
pub fn aiStreaming(self: *App) bool {
    if (self.ai.client) |c| return c.isRunning() or c.hasEvents();
    return false;
}

pub fn deinitAi(self: *App) void {
    if (self.ai.client) |c| {
        c.requestCancel();
        c.deinit();
        self.alloc.destroy(c);
        self.ai.client = null;
    }
    for (self.ai.messages.items) |m| {
        self.alloc.free(m.text);
        self.alloc.free(m.api_text);
    }
    self.ai.messages.deinit(self.alloc);
    if (self.ai.config) |*cfg| cfg.deinit(self.alloc);
    self.ai.config = null;
    self.ai.input.deinit(self.alloc);
    if (self.ai.error_text) |e| self.alloc.free(e);
    self.ai.error_text = null;
}

// ---- input ----

pub fn handleAiKey(self: *App, key: vaxis.Key) !void {
    switch (ai.panel.classify(key)) {
        .close => self.ai.active = false,
        .send => try self.aiSend(),
        .cancel => self.aiCancel(),
        .clear => self.aiClear(),
        .scroll_up => self.aiScroll(-1),
        .scroll_down => self.aiScroll(1),
        .page_up => self.aiScroll(-@as(i64, @intCast(@max(self.ai.view_rows, 1)))),
        .page_down => self.aiScroll(@as(i64, @intCast(@max(self.ai.view_rows, 1)))),
        .backspace => {
            if (self.ai.input.items.len > 0) {
                const cut = buffer.utf8.prevBoundary(self.ai.input.items, self.ai.input.items.len);
                self.ai.input.shrinkRetainingCapacity(cut);
            }
        },
        .text => if (key.text) |text| {
            // key.text is one complete UTF-8 sequence (vaxis reports text
            // per key event); appending it verbatim can never split bytes.
            try self.ai.input.appendSlice(self.alloc, text);
        },
        .ignore => {},
    }
}

pub fn aiScroll(self: *App, delta: i64) void {
    self.ai.auto_scroll = false;
    const max_top = self.ai.total_rows -| self.ai.view_rows;
    var top: i64 = @intCast(@min(self.ai.scroll, max_top));
    top += delta;
    if (top < 0) top = 0;
    if (top > max_top) top = max_top;
    self.ai.scroll = @intCast(top);
}

pub fn aiCancel(self: *App) void {
    if (self.ai.status != .streaming) return;
    self.ai.cancel_requested = true;
    if (self.ai.client) |c| c.requestCancel();
    self.ai.status = .cancelled;
}

pub fn aiClear(self: *App) void {
    if (self.ai.status == .streaming) {
        self.ai.cancel_requested = true;
        if (self.ai.client) |c| c.requestCancel();
    }
    for (self.ai.messages.items) |m| {
        self.alloc.free(m.text);
        self.alloc.free(m.api_text);
    }
    self.ai.messages.clearRetainingCapacity();
    self.ai.input.clearRetainingCapacity();
    if (self.ai.error_text) |e| self.alloc.free(e);
    self.ai.error_text = null;
    self.ai.status = .idle;
    self.ai.scroll = 0;
    self.ai.auto_scroll = true;
    self.ai.total_rows = 0;
}

/// Build the provider request for the current prompt, append the messages,
/// and start the background stream. Errors are surfaced in the panel.
pub fn aiSend(self: *App) !void {
    if (self.ai.status == .streaming) return;
    const prompt = std.mem.trim(u8, self.ai.input.items, " \t\r\n");
    if (prompt.len == 0) return;
    try self.aiLoadConfig();
    const cfg = &self.ai.config.?;

    if (self.ai.error_text) |e| {
        self.alloc.free(e);
        self.ai.error_text = null;
    }
    self.ai.status = .idle;
    self.ai.cancel_requested = false;

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
    const api_text = try std.fmt.allocPrint(self.alloc, "{s}\nUser request:\n{s}", .{ context, prompt });
    const empty_text = try self.alloc.dupe(u8, "");
    const empty_api = try self.alloc.dupe(u8, "");
    // Ownership moves into `messages`; on append failure everything is
    // freed exactly once (no errdefer can fire after the move).
    self.ai.messages.append(self.alloc, .{
        .role = .user,
        .text = prompt_copy,
        .api_text = api_text,
    }) catch |e| {
        self.alloc.free(prompt_copy);
        self.alloc.free(api_text);
        self.alloc.free(empty_text);
        self.alloc.free(empty_api);
        return e;
    };
    // Placeholder that streaming deltas append to. It is not sent while
    // empty (the request builder below skips empty assistant messages).
    self.ai.messages.append(self.alloc, .{
        .role = .assistant,
        .text = empty_text,
        .api_text = empty_api,
    }) catch |e| {
        const popped = self.ai.messages.pop().?;
        self.alloc.free(popped.text);
        self.alloc.free(popped.api_text);
        self.alloc.free(empty_text);
        self.alloc.free(empty_api);
        return e;
    };

    // Request messages: system is added by openai.buildRequestBody.
    var msgs = std.ArrayList(ai.openai.Message).empty;
    defer msgs.deinit(self.alloc);
    for (self.ai.messages.items) |m| {
        if (m.role == .assistant and m.text.len == 0) continue;
        try msgs.append(self.alloc, .{
            .role = if (m.role == .user) "user" else "assistant",
            .content = m.api_text,
        });
    }
    const body = try ai.openai.buildRequestBody(self.alloc, cfg.model, cfg.system, msgs.items);
    defer self.alloc.free(body);
    const url = try std.fmt.allocPrint(self.alloc, "{s}/chat/completions", .{cfg.base_url});
    defer self.alloc.free(url);

    if (self.ai.client == null) {
        const c = try self.alloc.create(ai.client.Client);
        c.* = ai.client.Client.init(self.alloc, self.io);
        self.ai.client = c;
    }
    self.ai.client.?.start(.{
        .url = url,
        .api_key = cfg.api_key,
        .body = body,
        .mock_dir = cfg.mock_dir,
    }) catch |e| {
        self.aiSetErrorFmt("start: {s}", .{@errorName(e)});
        return;
    };

    self.ai.input.clearRetainingCapacity();
    self.ai.scroll = 0;
    self.ai.auto_scroll = true;
    self.ai.status = .streaming;
}

/// Drain worker events into the conversation. Returns true when anything
/// changed (the run loop then repaints immediately).
pub fn drainAi(self: *App) !bool {
    const client = self.ai.client orelse return false;
    var changed = false;
    while (client.pop()) |ev| {
        defer ev.deinit(self.alloc);
        changed = true;
        if (self.ai.cancel_requested) {
            // Cancelled (status already shown) or cleared (status idle):
            // drop queued content without touching the transcript.
            continue;
        }
        switch (ev) {
            .delta => |text| {
                if (self.ai.status != .streaming) continue;
                if (self.ai.messages.items.len == 0) continue;
                const last = &self.ai.messages.items[self.ai.messages.items.len - 1];
                if (last.role != .assistant) continue;
                const old_text = last.text;
                last.text = try std.mem.concat(self.alloc, u8, &.{ old_text, text });
                self.alloc.free(old_text);
                const old_api = last.api_text;
                last.api_text = try self.alloc.dupe(u8, last.text);
                self.alloc.free(old_api);
            },
            .done => {
                self.ai.status = .idle;
            },
            .err => |text| {
                self.aiSetError(text);
            },
            .cancelled => {
                self.ai.status = .cancelled;
            },
        }
    }
    // Safety net: a worker that died without a terminal event must not
    // leave the panel saying "streaming…" forever.
    if (self.ai.status == .streaming and !client.isRunning() and !client.hasEvents()) {
        self.aiSetError("stream ended unexpectedly");
        changed = true;
    }
    return changed;
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
                // this row has content, otherwise emit it (panel too narrow).
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

fn spaces(alloc: std.mem.Allocator, n: u32) ![]const u8 {
    const buf = try alloc.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Copy `text` with terminal control bytes replaced so a pasted newline/tab
/// can never escape the panel's row. Tabs become four spaces (the editor's
/// tab_width) so code blocks stay aligned.
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
    // Heading: 1-6 '#' + space. The markers are concealed.
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
                    // Unclosed marker: render the rest as inline code.
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
    self: *App,
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    st: Styles,
    inner_w: u32,
    role: Role,
    text: []const u8,
) !void {
    _ = self;
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
            // Indent code by two cells inside the message column.
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
        // Every logical line was a concealed fence; still emit the label.
        try wrap.flush();
    }

    // One blank spacer row between messages.
    try rows.append(a, .{});
}

pub fn drawAiPanel(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    const height: u32 = win.height;
    const width: u32 = win.width;
    // Border + status + at least one transcript row + prompt + border.
    if (height < 5 or width < 10) return;
    var box_h: u32 = @min(28, height -| 4);
    if (box_h < 5) box_h = @min(height, 5);
    var box_w: u32 = @min(96, width -| 4);
    if (box_w < 20) box_w = @min(width, 20);
    const start_row: u32 = (height -| box_h) / 2;
    const start_col: u32 = (width -| box_w) / 2;
    const inner_w: u32 = box_w - 2;
    const transcript_h: u32 = box_h - 4;
    const t = self.theme;

    const panel_bg = vaxis.Color{ .rgb = t.bg_float };
    const base = vaxis.Style{ .fg = .{ .rgb = t.fg }, .bg = panel_bg };
    const st = Styles{
        .base = base,
        .dim = .{ .fg = .{ .rgb = t.fg_dim }, .bg = panel_bg },
        .faint = .{ .fg = .{ .rgb = t.fg_faint }, .bg = panel_bg },
        .accent = .{ .fg = .{ .rgb = t.accent }, .bg = panel_bg, .bold = true },
        .code = .{ .fg = .{ .rgb = t.string }, .bg = panel_bg },
        .bold = .{ .fg = .{ .rgb = t.fg }, .bg = panel_bg, .bold = true },
        .italic = .{ .fg = .{ .rgb = t.fg_dim }, .bg = panel_bg, .italic = true },
        .label_user = .{ .fg = .{ .rgb = t.accent }, .bg = panel_bg, .bold = true },
        .label_ai = .{ .fg = .{ .rgb = t.keyword }, .bg = panel_bg, .bold = true },
        .error_style = .{ .fg = .{ .rgb = t.diag_error }, .bg = panel_bg },
        .border = .{ .fg = .{ .rgb = t.fg_faint }, .bg = panel_bg },
    };

    // Solid panel background first: every cell of the box is bg_float.
    const panel = win.child(.{
        .x_off = @intCast(start_col),
        .y_off = @intCast(start_row),
        .width = @intCast(box_w),
        .height = @intCast(box_h),
    });
    panel.fill(.{ .style = .{ .bg = panel_bg } });

    // ---- transcript rows (wrapped Markdown) ----
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |*r| r.segs.deinit(a);
        rows.deinit(a);
    }
    for (self.ai.messages.items) |m| {
        try appendMessageRows(self, a, &rows, st, inner_w, m.role, m.text);
    }
    const total: u32 = @intCast(rows.items.len);
    self.ai.total_rows = total;
    self.ai.view_rows = transcript_h;
    const max_top = total -| transcript_h;
    if (self.ai.auto_scroll) {
        self.ai.scroll = max_top;
    } else if (self.ai.scroll > max_top) {
        self.ai.scroll = max_top;
    }
    const top = self.ai.scroll;

    // ---- borders, status, prompt ----
    const border_style = st.border;
    const border = "│";
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "╭", .style = border_style });
        try segs.append(a, .{ .text = " AI ", .style = st.accent });
        var cx: u32 = 5;
        while (cx < box_w - 1) : (cx += 1) {
            try segs.append(a, .{ .text = "─", .style = border_style });
        }
        try segs.append(a, .{ .text = "╮", .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
    }
    {
        const model: []const u8 = if (self.ai.config) |cfg| cfg.model else ai.config.default_model;
        const status_text = try std.fmt.allocPrint(a, " {s}  {s}", .{ model, try aiStatusLine(self, a) });
        const status_style: vaxis.Style = switch (self.ai.status) {
            .idle => st.dim,
            .streaming => st.accent,
            .cancelled => st.faint,
            .err => st.error_style,
        };
        const fit = autil.cellFitPrefix(win, status_text, inner_w);
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = border, .style = border_style });
        try segs.append(a, .{ .text = fit.slice, .style = status_style });
        const pad = try spaces(a, inner_w -| @as(u32, @intCast(fit.cells)));
        try segs.append(a, .{ .text = pad, .style = .{ .bg = panel_bg } });
        try segs.append(a, .{ .text = border, .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1), .col_offset = @intCast(start_col), .wrap = .none });
    }

    // transcript rows
    var k: u32 = 0;
    while (k < transcript_h) : (k += 1) {
        const ri = top + k;
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = border, .style = border_style });
        var cells: u32 = 0;
        if (ri < rows.items.len) {
            const row = rows.items[ri];
            for (row.segs.items) |seg| try segs.append(a, seg);
            cells = row.cells;
        }
        if (cells < inner_w) {
            const pad = try spaces(a, inner_w - cells);
            try segs.append(a, .{ .text = pad, .style = .{ .bg = panel_bg } });
        }
        try segs.append(a, .{ .text = border, .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 2 + k), .col_offset = @intCast(start_col), .wrap = .none });
    }

    // prompt row
    const prompt_row = start_row + box_h - 2;
    var prompt_cells: u32 = 0;
    {
        // " " + "❯ " measured in terminal cells (a wide glyph in some
        // terminals would otherwise shift the cursor and right padding).
        const prefix_cells: u32 = 1 + @as(u32, @intCast(autil.cellWidth(win, "❯ ")));
        const cap: usize = inner_w -| prefix_cells;
        const safe_input = try displaySafe(a, self.ai.input.items);
        const fit = autil.cellFitSuffix(win, safe_input, cap);
        prompt_cells = @intCast(fit.cells);
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = border, .style = border_style });
        try segs.append(a, .{ .text = " ", .style = .{ .bg = panel_bg } });
        try segs.append(a, .{ .text = "❯ ", .style = st.accent });
        try segs.append(a, .{ .text = fit.slice, .style = base });
        const pad = try spaces(a, inner_w -| prefix_cells -| @as(u32, @intCast(fit.cells)));
        try segs.append(a, .{ .text = pad, .style = .{ .bg = panel_bg } });
        try segs.append(a, .{ .text = border, .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(prompt_row), .col_offset = @intCast(start_col), .wrap = .none });
    }
    // bottom border
    {
        var segs = std.ArrayList(vaxis.Segment).empty;
        try segs.append(a, .{ .text = "╰", .style = border_style });
        var cx: u32 = 0;
        while (cx < box_w - 2) : (cx += 1) {
            try segs.append(a, .{ .text = "─", .style = border_style });
        }
        try segs.append(a, .{ .text = "╯", .style = border_style });
        _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + box_h - 1), .col_offset = @intCast(start_col), .wrap = .none });
    }

    // Cursor at the end of the prompt (inside the right border).
    const prompt_col = start_col + 1 + 1 + @as(u32, @intCast(autil.cellWidth(win, "❯ "))) + prompt_cells;
    self.vx.screen.cursor = .{
        .row = @intCast(prompt_row),
        .col = @intCast(@min(prompt_col, start_col + box_w - 2)),
    };
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_shape = .beam;
}

fn aiStatusLine(self: *App, a: std.mem.Allocator) ![]const u8 {
    return switch (self.ai.status) {
        .idle => "idle",
        .streaming => "streaming…",
        .cancelled => "cancelled",
        .err => blk: {
            const err = self.ai.error_text orelse "error";
            var clean = try a.alloc(u8, err.len);
            for (err, 0..) |c, i| clean[i] = if (c == '\n' or c == '\r') ' ' else c;
            break :blk try std.fmt.allocPrint(a, "error: {s}", .{clean});
        },
    };
}
