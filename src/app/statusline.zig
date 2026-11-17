//! Pure status-line model/planner.
//!
//! The renderer measures text in terminal cells and hands the planner plain
//! slices; this module owns only arithmetic and priority. It guarantees that
//! segments never overlap, never exceed the requested width, and that the
//! mode badge plus the document position survive at every supported width.
//!
//! Layout contract:
//!   left:  mode badge, dirty, branch, diff/diagnostics, message/recording
//!   right: LSP state, filetype, position, progress, agent reservation
//! The middle is an elastic gap. Items are dropped by importance, never by
//! truncating the tail of one concatenated string.

const std = @import("std");

pub const Role = enum {
    mode_normal,
    mode_insert,
    mode_visual,
    mode_command,
    separator,
    primary,
    secondary,
    muted,
    dirty,
    branch,
    diff_add,
    diff_del,
    diag_error,
    diag_warn,
    diag_info,
    lsp,
    filetype,
    position,
    progress,
    message,
    recording,
    search,
    agent,
};

pub const Item = struct {
    text: []const u8,
    cells: u32,
    role: Role = .secondary,
};

/// All optional fields are already measured; null means "this state has no
/// such information" (e.g. a non-git file has no branch).
pub const Model = struct {
    mode: Item,
    dirty: bool = false,
    branch: ?Item = null,
    diff: ?Item = null,
    diagnostics: ?Item = null,
    message: ?Item = null,
    recording: ?Item = null,
    search: ?Item = null,
    /// Workspace identity (only when the caller has more than one). It is a
    /// different dimension from the buffer list and the focused window.
    workspace: ?Item = null,
    agent: ?Item = null,
    lsp: ?Item = null,
    filetype: ?Item = null,
    position: Item,
    progress: ?Item = null,
    completion_marker: ?Item = null,
};

pub const Placed = struct {
    item: Item,
    x: u32,
    /// Budget actually granted. It can be smaller than item.cells only for
    /// the message slot, where the renderer clips with cellFitPrefix.
    cells: u32,
};

pub const max_segments = 32;

pub const Plan = struct {
    segments: [max_segments]Placed = undefined,
    count: usize = 0,
    mode_x: u32 = 0,
    mode_cells: u32 = 0,
    position_x: u32 = 0,
    position_cells: u32 = 0,
    free_start: u32 = 0,
    free_cells: u32 = 0,

    pub fn slice(self: *const Plan) []const Placed {
        return self.segments[0..self.count];
    }

    pub fn findRole(self: *const Plan, role: Role) ?Placed {
        for (self.slice()) |p| {
            if (p.item.role == role) return p;
        }
        return null;
    }
};

fn add(p: *Plan, it: Item, x: u32, cells: u32) void {
    if (p.count >= max_segments or cells == 0) return;
    p.segments[p.count] = .{ .item = it, .x = x, .cells = cells };
    p.count += 1;
}

fn sep() Item {
    return .{ .text = "  ", .cells = 2, .role = .separator };
}

fn thinSep() Item {
    return .{ .text = " ", .cells = 1, .role = .separator };
}

const Right = struct {
    width: u32 = 0,
    lsp: bool = false,
    filetype: bool = false,
    progress: bool = false,
    marker: bool = false,
    position: bool = true,
};

/// Select right-side metadata for `width`, reserving `agent_cells + 2` when
/// an agent lives at the far right. Selection is by importance: progress and
/// completion marker first, then filetype, then LSP; the position is never
/// dropped while it fits.
fn selectRight(m: Model, width: u32, agent_cells: u32) Right {
    var out = Right{};
    var reserve: u32 = 0;
    if (agent_cells > 0 and width >= agent_cells + 2 + m.position.cells) reserve = agent_cells + 2;
    const avail = width -| reserve;
    out.width = m.position.cells;
    if (m.progress != null and width >= 88 and out.width + 1 + m.progress.?.cells <= avail) {
        out.progress = true;
        out.width += 1 + m.progress.?.cells;
    }
    if (m.completion_marker != null and width >= 70 and out.width + 1 + m.completion_marker.?.cells <= avail) {
        out.marker = true;
        out.width += 1 + m.completion_marker.?.cells;
    }
    if (m.filetype != null and width >= 56 and out.width + 1 + m.filetype.?.cells <= avail) {
        out.filetype = true;
        out.width += 1 + m.filetype.?.cells;
    }
    if (m.lsp != null and width >= 42 and out.width + 1 + m.lsp.?.cells <= avail) {
        out.lsp = true;
        out.width += 1 + m.lsp.?.cells;
    }
    return out;
}

/// Plan one status row in `width` cells. `mode` is expected padded to a
/// stable width by the caller (so NORMAL → INSERT does not shift position).
pub fn plan(m: Model, width: u32) Plan {
    var out = Plan{};
    if (width == 0) return out;

    const agent_cells: u32 = if (m.agent) |a| a.cells else 0;
    var right = selectRight(m, width, agent_cells);
    var agent_gap: u32 = if (agent_cells > 0 and width >= right.width + agent_cells + 2) 2 else 0;
    var right_start: u32 = width -| (right.width + agent_cells + agent_gap);
    if (right_start + right.width > width) right_start = 0;

    // ---- left side: mode is always first and never moves ----
    const mode_cells = @min(m.mode.cells, width);
    add(&out, m.mode, 0, mode_cells);
    out.mode_x = 0;
    out.mode_cells = mode_cells;
    var x: u32 = mode_cells;

    const left_order = [_]enum { recording, dirty, search, workspace, branch, diff, diagnostics }{
        .recording, .dirty, .search, .workspace, .branch, .diff, .diagnostics,
    };
    for (left_order) |kind| {
        const item_opt: ?Item = switch (kind) {
            .recording => m.recording,
            .search => m.search,
            .dirty => if (m.dirty) Item{ .text = "●", .cells = 1, .role = .dirty } else null,
            .workspace => if (width >= 56) m.workspace else null,
            .branch => if (width >= 60) m.branch else null,
            .diff => if (width >= 72) m.diff else null,
            .diagnostics => if (width >= 48) m.diagnostics else null,
        };
        const it = item_opt orelse continue;
        if (x + sep().cells + it.cells > right_start) continue;
        add(&out, sep(), x, sep().cells);
        x += sep().cells;
        add(&out, it, x, it.cells);
        x += it.cells;
    }

    // Temporary messages outrank optional service metadata: if the elastic
    // middle is too small, drop LSP/filetype/progress (never the position or
    // the Agent reservation) and let the message use that width. Permission,
    // recording and Agent state remain visible.
    if (m.message) |msg| {
        if (x + sep().cells + msg.cells > right_start) {
            right.lsp = false;
            right.filetype = false;
            right.progress = false;
            right.marker = false;
            right.width = m.position.cells;
            agent_gap = if (agent_cells > 0 and width >= right.width + agent_cells + 2) 2 else 0;
            right_start = width -| (right.width + agent_cells + agent_gap);
        }
        if (x + sep().cells + 6 <= right_start) {
            const avail = right_start - x - sep().cells;
            add(&out, sep(), x, sep().cells);
            x += sep().cells;
            add(&out, msg, x, @min(msg.cells, avail));
            x += @min(msg.cells, avail);
        }
    }
    out.free_start = x;
    out.free_cells = right_start -| x;

    // ---- right group, left to right ----
    var rx = right_start;
    if (right.lsp) {
        add(&out, m.lsp.?, rx, m.lsp.?.cells);
        rx += m.lsp.?.cells;
        add(&out, thinSep(), rx, 1);
        rx += 1;
    }
    if (right.marker) {
        add(&out, m.completion_marker.?, rx, m.completion_marker.?.cells);
        rx += m.completion_marker.?.cells;
        add(&out, thinSep(), rx, 1);
        rx += 1;
    }
    if (right.filetype) {
        add(&out, m.filetype.?, rx, m.filetype.?.cells);
        rx += m.filetype.?.cells;
        add(&out, thinSep(), rx, 1);
        rx += 1;
    }
    add(&out, m.position, rx, m.position.cells);
    out.position_x = rx;
    out.position_cells = m.position.cells;
    rx += m.position.cells;
    if (right.progress) {
        add(&out, thinSep(), rx, 1);
        rx += 1;
        add(&out, m.progress.?, rx, m.progress.?.cells);
        rx += m.progress.?.cells;
    }

    if (m.agent) |agent| {
        if (rx <= width and width -| agent.cells >= rx) {
            add(&out, agent, width - agent.cells, agent.cells);
        }
    }

    std.mem.sort(Placed, out.segments[0..out.count], {}, struct {
        fn lt(_: void, a: Placed, b: Placed) bool {
            return a.x < b.x;
        }
    }.lt);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn item(text: []const u8, cells: u32, role: Role) Item {
    return .{ .text = text, .cells = cells, .role = role };
}

fn baseModel() Model {
    return .{
        .mode = item(" NORMAL ", 8, .mode_normal),
        .position = item("6:1", 3, .position),
    };
}

test "statusline: widths never overlap or overflow and keep mode/position" {
    const t = std.testing;
    const widths = [_]u32{ 40, 60, 80, 100, 120, 160, 200 };
    var m = baseModel();
    m.dirty = true;
    m.branch = item("⎇ feature/very-long-branch-name-that-keeps-going", 48, .branch);
    m.diff = item("+12 ~3", 6, .diff_add);
    m.diagnostics = item("E1 W2", 5, .diag_error);
    m.message = item("saved src/main.zig", 37, .message);
    m.lsp = item("[zls]", 5, .lsp);
    m.filetype = item("zig", 3, .filetype);
    m.progress = item("Top/72", 6, .progress);
    m.recording = item("REC @a", 6, .recording);
    m.agent = item("agent · streaming", 16, .agent);
    for (widths) |w| {
        const p = plan(m, w);
        try t.expect(p.count > 0);
        var last_end: u32 = 0;
        var first = true;
        var pos_seen = false;
        for (p.slice()) |seg| {
            try t.expect(seg.x + seg.cells <= w);
            if (!first) try t.expect(seg.x >= last_end);
            first = false;
            last_end = seg.x + seg.cells;
            if (seg.item.role == .position) pos_seen = true;
        }
        try t.expect(pos_seen);
        try t.expect(p.findRole(.mode_normal) != null);
        try t.expectEqual(@as(u32, 0), p.mode_x);
    }
}

test "statusline: mode badge width is stable and does not move the position" {
    const t = std.testing;
    var normal = baseModel();
    normal.position = item("6:1", 3, .position);
    var insert = baseModel();
    insert.mode = item(" INSERT ", 8, .mode_insert);
    const a = plan(normal, 100);
    const b = plan(insert, 100);
    try t.expectEqual(a.position_x, b.position_x);
    try t.expectEqual(a.mode_cells, b.mode_cells);
}

test "statusline: optional metadata drops before mode and position on narrow rows" {
    const t = std.testing;
    var m = baseModel();
    m.branch = item("⎇ main", 6, .branch);
    m.lsp = item("[zls]", 5, .lsp);
    m.filetype = item("zig", 3, .filetype);
    m.progress = item("42%", 3, .progress);
    const narrow = plan(m, 40);
    try t.expect(narrow.findRole(.mode_normal) != null);
    try t.expect(narrow.findRole(.position) != null);
    try t.expect(narrow.findRole(.lsp) == null);
    try t.expect(narrow.findRole(.progress) == null);
    const wide = plan(m, 160);
    try t.expect(wide.findRole(.lsp) != null);
    try t.expect(wide.findRole(.filetype) != null);
    try t.expect(wide.findRole(.progress) != null);
}

test "statusline: message is clipped before the right group and never overlaps it" {
    const t = std.testing;
    var m = baseModel();
    m.message = item("a very long message that must not push the position", 52, .message);
    m.lsp = item("[zls]", 5, .lsp);
    m.filetype = item("zig", 3, .filetype);
    const p = plan(m, 60);
    const msg = p.findRole(.message).?;
    try t.expect(msg.cells < 52);
    try t.expect(msg.x + msg.cells <= p.position_x);
    try t.expect(p.position_x + p.position_cells <= 60);
}

test "statusline: agent reservation is right-aligned and leaves the position readable" {
    const t = std.testing;
    var m = baseModel();
    m.agent = item("agent busy", 10, .agent);
    m.lsp = item("[zls]", 5, .lsp);
    m.filetype = item("zig", 3, .filetype);
    const p = plan(m, 80);
    const agent = p.findRole(.agent).?;
    try t.expectEqual(@as(u32, 70), agent.x);
    try t.expect(agent.x >= p.position_x + p.position_cells);
}

test "statusline: workspace identity is placed before message and branch" {
    const t = std.testing;
    var m = baseModel();
    m.workspace = item("[main]", 6, .secondary);
    m.branch = item("⎇ main", 6, .branch);
    m.message = item("LSP txt: NoLspServer", 20, .message);
    const p = plan(m, 80);
    const ws = p.findRole(.secondary) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("[main]", ws.item.text);
    try t.expect(ws.x > p.mode_cells);
    const msg = p.findRole(.message) orelse return error.TestUnexpectedResult;
    try t.expect(msg.x > ws.x + ws.cells);
}

test "statusline: search count survives optional metadata and stays within narrow rows" {
    var m = baseModel();
    m.search = item("[12/1234]", 9, .search);
    m.branch = item("a-very-long-branch-name", 23, .branch);
    m.workspace = item("[large-workspace]", 17, .secondary);
    m.diagnostics = item("E99 W99", 7, .diag_error);
    m.message = item("an intentionally long error message while searching", 51, .message);
    for ([_]u32{ 40, 60, 80, 120 }) |width| {
        const p = plan(m, width);
        const count = p.findRole(.search) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("[12/1234]", count.item.text);
        try std.testing.expect(count.x + count.cells <= width);
        for (p.slice(), 0..) |seg, i| {
            try std.testing.expect(seg.x + seg.cells <= width);
            for (p.slice()[i + 1 ..]) |other| {
                try std.testing.expect(seg.x + seg.cells <= other.x or other.x + other.cells <= seg.x);
            }
        }
    }
}
