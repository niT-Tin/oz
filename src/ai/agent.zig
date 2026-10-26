//! Agent-loop policy, tool-card formatting and per-thread metrics (M3a).
//!
//! Pure and App-independent: no filesystem, no threads, no UI. `app/ai.zig`
//! owns the actual loop (transport + worker) and calls into this module for
//! the bounded decisions and the textual pieces:
//!
//!   - `Limits` / `planBatch`: at most 4 tool rounds and 8 calls per user
//!     turn. Over-limit calls are reported truthfully and never executed.
//!   - `CardStatus` + `cardStatusText`: the compact card labels (`ok 3ms`,
//!     `approval required`, `approved`/`rejected`, …).
//!   - `summarizeArguments` / `resultExcerpt`: bounded, single-line card
//!     text. Both cap by display-independent byte limits and never split a
//!     UTF-8 sequence; the renderer adds the cell-level clipping.
//!   - `Metrics`: per-tool calls/ok/error/approval/unsupported counts, average
//!     and max latency, a 32-sample ring for the Tools chart, and a
//!     nearest-rank p95 of that recent window. Only real requests are
//!     recorded; running/cancelled cards are not.
//!
//! Nothing here fabricates a baseline: an empty `Metrics` renders as the
//! Tools tab's `no tool calls yet` state, and the chart/p95 samples come from
//! the same real durations as `avg`/`max`. p95 is defined over at most the
//! last `recent_capacity` (32) executed calls per tool, integer nearest-rank
//! (`ceil(0.95*n)-1`, clamped); zero samples mean `null`, never 0ms. The
//! Tools-tab header pools those per-tool recent windows (at most 256 samples)
//! and says so in DESIGN §20.5/§20.11.

const std = @import("std");
const tools = @import("tools.zig");
const terminal_tool = @import("terminal_tool.zig");

/// Hard agent-loop bounds for one user turn. Exposed as `pub const` so tests
/// and the e2e assertions can name the numbers instead of hard-coding them.
pub const max_tool_rounds: u8 = 4;
pub const max_tool_calls_per_turn: u8 = 8;

/// Recent latency window per tool (Tools tab chart / sparkline).
pub const recent_capacity: usize = 32;

/// Maximum tool names tracked separately. The M3 model can only overlap a
/// handful of tools; beyond this, metrics stop opening new buckets rather
/// than allocating without bound.
pub const max_metric_tools: usize = 8;

/// Default display budget for one card's argument summary.
pub const max_args_summary_bytes: usize = 120;
/// Default display budget for one card's result excerpt.
pub const max_excerpt_bytes: usize = 160;

pub const Limits = struct {
    rounds: u8 = max_tool_rounds,
    calls: u8 = max_tool_calls_per_turn,
};

pub const LimitReason = enum { rounds, calls };

/// Outcome of admitting one streamed batch against the loop bounds.
pub const BatchPlan = struct {
    /// Calls that may execute.
    execute: usize,
    /// Calls that must be answered as "not executed" (limit reached).
    skipped: usize,
    /// Why calls were skipped / the batch was refused. `null` with
    /// `skipped == 0` means the whole batch fits.
    reason: ?LimitReason,
};

/// Pure loop-budget decision. `rounds` counts already-started batches,
/// `calls` counts already-admitted calls in this user turn.
pub fn planBatch(rounds: u8, calls: u8, limits: Limits, requested: usize) BatchPlan {
    if (requested == 0) return .{ .execute = 0, .skipped = 0, .reason = null };
    if (rounds >= limits.rounds) {
        return .{ .execute = 0, .skipped = requested, .reason = .rounds };
    }
    if (calls >= limits.calls) {
        return .{ .execute = 0, .skipped = requested, .reason = .calls };
    }
    const remaining: usize = limits.calls - calls;
    const execute = @min(requested, remaining);
    return .{
        .execute = execute,
        .skipped = requested - execute,
        .reason = if (requested > execute) LimitReason.calls else null,
    };
}

/// Owned human-readable transcript note for a stopped loop.
pub fn limitNote(alloc: std.mem.Allocator, reason: LimitReason, limits: Limits) ![]u8 {
    return switch (reason) {
        .rounds => std.fmt.allocPrint(alloc, "tool loop stopped: max rounds ({d}) reached", .{limits.rounds}),
        .calls => std.fmt.allocPrint(alloc, "tool loop stopped: max calls ({d}) reached", .{limits.calls}),
    };
}

/// Card status. `err` is the keyword-safe spelling of the protocol's
/// "error" status; `approval_required` is a staged M3b1 edit awaiting a human
/// decision, while `approved`/`rejected` are that decision. `unsupported`
/// remains a truthful non-execution outcome.
pub const CardStatus = enum {
    running,
    ok,
    err,
    approval_required,
    approved,
    rejected,
    unsupported,
    cancelled,
};

pub fn statusLabel(status: CardStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .ok => "ok",
        .err => "error",
        .approval_required => "approval required",
        .approved => "approved",
        .rejected => "rejected",
        .unsupported => "unsupported",
        .cancelled => "cancelled",
    };
}

/// Total bytes `cardStatusText` can write (longest label + " 4294967295ms").
pub const max_status_text_bytes: usize = 48;

/// Card right-hand status text. Executed calls append their real duration;
/// non-executed outcomes never pretend to have one.
pub fn cardStatusText(buf: []u8, status: CardStatus, duration_ms: u32) []const u8 {
    return switch (status) {
        .ok => std.fmt.bufPrint(buf, "ok {d}ms", .{duration_ms}) catch "ok",
        .err => std.fmt.bufPrint(buf, "error {d}ms", .{duration_ms}) catch "error",
        .approval_required, .approved, .rejected, .unsupported, .running, .cancelled => statusLabel(status),
    };
}

/// Strip control bytes and collapse runs of whitespace so a card summary is
/// one safe terminal line. Returns the number of bytes written.
fn sanitizeInto(out: []u8, input: []const u8) usize {
    var n: usize = 0;
    var last_space = false;
    var i: usize = 0;
    while (i < input.len and n < out.len) {
        const b = input[i];
        if (b == '\n' or b == '\r' or b == '\t' or b < 0x20 or b == 0x7f) {
            if (!last_space and n < out.len) {
                out[n] = ' ';
                n += 1;
                last_space = true;
            }
            i += 1;
            continue;
        }
        out[n] = b;
        n += 1;
        last_space = b == ' ';
        i += 1;
    }
    return n;
}

/// Cut `text[0..len]` back to a UTF-8 boundary (never return half a glyph).
fn utf8Cut(text: []const u8, len: usize) usize {
    if (len >= text.len) return text.len;
    var cut = len;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

fn appendEllipsis(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, "…");
}

fn appendFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    try out.appendSlice(alloc, text);
}

/// Compact one-line argument summary for a tool card:
///
///   read_file      -> "src/main.zig:10-20" / "src/main.zig"
///   list_directory -> "src"
///   grep           -> "\"needle\" in src · *.zig"
///   edit_file      -> "src/main.zig (replace)"
///   apply_patch    -> "patch: 12 lines"
///   terminal       -> escaped command (bounded, explicit marker) + timeout
///   unknown        -> bounded, sanitized raw JSON
///
/// The full `arguments_json` is never shown verbatim (it can be 64 KiB).
pub fn summarizeArguments(
    alloc: std.mem.Allocator,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch {
        return boundedSanitized(alloc, arguments_json, max_args_summary_bytes);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return boundedSanitized(alloc, arguments_json, max_args_summary_bytes);

    const obj = &parsed.value.object;

    // terminal has its own bounded display helper; handle it before the
    // generic summary buffer is allocated (no empty-list deinit/errdefer).
    if (std.mem.eql(u8, name, "terminal")) {
        if (obj.get("command")) |command_value| {
            if (command_value == .string) {
                var timeout_ms: u32 = terminal_tool.default_timeout_ms;
                if (obj.get("timeout_ms")) |t| {
                    if (t == .integer and t.integer > 0 and t.integer <= std.math.maxInt(u32)) {
                        timeout_ms = @intCast(t.integer);
                    }
                }
                return terminal_tool.commandForCard(alloc, command_value.string, timeout_ms);
            }
        }
        return boundedSanitized(alloc, arguments_json, max_args_summary_bytes);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, max_args_summary_bytes + 3);

    const path_value = if (obj.get("path")) |p| p else null;
    const path = if (path_value) |p| (if (p == .string and p.string.len > 0) p.string else null) else null;

    if (std.mem.eql(u8, name, "read_file")) {
        if (path) |p| try appendBoundedText(&out, alloc, p, max_args_summary_bytes);
        if (obj.get("start_line")) |s| {
            if (s == .integer and s.integer > 0) {
                const start: u64 = @intCast(s.integer);
                if (obj.get("end_line")) |e| {
                    if (e == .integer and e.integer > 0) {
                        try appendFmt(&out, alloc, ":{d}-{d}", .{ start, @as(u64, @intCast(e.integer)) });
                    } else {
                        try appendFmt(&out, alloc, ":{d}", .{start});
                    }
                } else {
                    try appendFmt(&out, alloc, ":{d}", .{start});
                }
            }
        }
        if (out.items.len == 0) try appendBoundedText(&out, alloc, arguments_json, max_args_summary_bytes);
        return out.toOwnedSlice(alloc);
    }
    if (std.mem.eql(u8, name, "list_directory")) {
        try appendBoundedText(&out, alloc, path orelse ".", max_args_summary_bytes);
        return out.toOwnedSlice(alloc);
    }
    if (std.mem.eql(u8, name, "grep")) {
        try out.append(alloc, '"');
        if (obj.get("pattern")) |p| {
            if (p == .string) try appendBoundedText(&out, alloc, p.string, max_args_summary_bytes -| 2);
        }
        try out.append(alloc, '"');
        if (path) |p| {
            try out.appendSlice(alloc, " in ");
            try appendBoundedText(&out, alloc, p, max_args_summary_bytes -| out.items.len);
        }
        if (obj.get("glob")) |g| {
            if (g == .string and g.string.len > 0) {
                try out.appendSlice(alloc, " · ");
                try appendBoundedText(&out, alloc, g.string, max_args_summary_bytes -| out.items.len);
            }
        }
        return out.toOwnedSlice(alloc);
    }
    if (std.mem.eql(u8, name, "edit_file")) {
        try appendBoundedText(&out, alloc, path orelse "?", max_args_summary_bytes -| 10);
        try out.appendSlice(alloc, " (replace)");
        return out.toOwnedSlice(alloc);
    }
    if (std.mem.eql(u8, name, "apply_patch")) {
        var lines: usize = 0;
        if (obj.get("patch")) |p| {
            if (p == .string and p.string.len > 0) {
                const trailing = p.string[p.string.len - 1] == '\n';
                lines = std.mem.count(u8, p.string, "\n") + 1 - @intFromBool(trailing);
            }
        }
        try appendFmt(&out, alloc, "patch: {d} lines", .{lines});
        return out.toOwnedSlice(alloc);
    }
    // Unknown tool: a bounded raw summary is still truthful (the card says
    // unsupported; this only identifies what was requested).
    return boundedSanitized(alloc, arguments_json, max_args_summary_bytes);
}

fn appendBoundedText(out: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8, limit: usize) !void {
    const room = limit -| out.items.len;
    if (room == 0) return;
    const cut = utf8Cut(text, room);
    try out.appendSlice(alloc, text[0..cut]);
    if (cut < text.len) try appendEllipsis(out, alloc);
}

fn boundedSanitized(alloc: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var scratch: [1024]u8 = undefined;
    const n = sanitizeInto(&scratch, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const cut = utf8Cut(scratch[0..n], @min(limit, n));
    try out.appendSlice(alloc, scratch[0..cut]);
    if (cut < n) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

/// One-line display excerpt of a tool result. Executor outputs are
/// `<header>\n---\n<body>`; the header is skipped when present. Errors keep
/// their `error:` prefix (never hidden), and the result is valid UTF-8 with
/// control bytes replaced.
pub fn resultExcerpt(alloc: std.mem.Allocator, content: []const u8, max_bytes: usize) ![]u8 {
    var body = content;
    if (std.mem.indexOf(u8, body, "\n---\n")) |at| body = body[at + 5 ..];
    // First non-empty line.
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var scratch: [1024]u8 = undefined;
        const n = sanitizeInto(&scratch, line);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        const limit = @min(max_bytes, 1024);
        const cut = utf8Cut(scratch[0..n], limit);
        try out.appendSlice(alloc, scratch[0..cut]);
        if (cut < n) try out.appendSlice(alloc, "…");
        return out.toOwnedSlice(alloc);
    }
    return alloc.dupe(u8, "");
}

/// Split a tool result into display lines, skipping the `<header>\n---\n`
/// prologue. Used by the expanded card view: the caller supplies the output
/// slice (stack storage is fine) and the returned slices point into
/// `content`; no allocation happens here.
pub fn bodyLines(content: []const u8, out: [][]const u8, max_lines: usize) struct { count: usize, more: bool } {
    var body = content;
    if (std.mem.indexOf(u8, body, "\n---\n")) |at| body = body[at + 5 ..];
    const limit = @min(@min(max_lines, out.len), 64);
    var n: usize = 0;
    var more = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (n >= limit) {
            more = true;
            break;
        }
        out[n] = line;
        n += 1;
    }
    return .{ .count = n, .more = more };
}

/// Nearest-rank p95 over `samples`, sorted in place. The 0-based index is
/// `ceil(0.95*n)-1`, clamped to the array (so n=1 returns its only sample and
/// n=2 returns the larger). Integer and allocation-free; empty -> null.
fn nearestRankP95(samples: []u32) ?u32 {
    if (samples.len == 0) return null;
    std.sort.insertion(u32, samples, {}, std.sort.asc(u32));
    const rank = (95 * samples.len + 99) / 100; // ceil(95*n/100)
    const idx = @min(rank - 1, samples.len - 1);
    return samples[idx];
}

/// Per-tool counters and recent latency ring. Names are owned copies so the
/// chart/metrics survive the request buffers they came from.
pub const Stats = struct {
    name: []u8 = &.{},
    calls: u32 = 0,
    ok: u32 = 0,
    errors: u32 = 0,
    approval_required: u32 = 0,
    /// Human decisions on staged edits (approved is also counted in `ok`,
    /// rejected here; neither increments `calls` nor the latency domain).
    denied: u32 = 0,
    unsupported: u32 = 0,
    /// Executed calls only (ok/error): average/max latency domain.
    duration_count: u32 = 0,
    total_ms: u64 = 0,
    max_ms: u32 = 0,
    recent: [recent_capacity]u32 = @splat(0),
    recent_len: u8 = 0,
    recent_next: u8 = 0,

    pub fn deinit(self: *Stats, alloc: std.mem.Allocator) void {
        if (self.name.len > 0) alloc.free(self.name);
        self.* = undefined;
    }

    /// Integer mean over every executed call (not just the recent window).
    pub fn averageMs(self: *const Stats) ?u32 {
        if (self.duration_count == 0) return null;
        return @intCast((self.total_ms + self.duration_count / 2) / self.duration_count);
    }

    /// Copy the recent samples (oldest first) into `out`. Returns the count.
    pub fn recentInto(self: *const Stats, out: []u32) usize {
        const n = self.recent_len;
        if (n == 0 or out.len == 0) return 0;
        const count = @min(@as(usize, n), out.len);
        const skip = @as(usize, n) - count;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx = (self.recent_next + recent_capacity - n + skip + i) % recent_capacity;
            out[i] = self.recent[idx];
        }
        return count;
    }

    /// Nearest-rank p95 of this tool's recent executed-call window: at most
    /// the last `recent_capacity` (32) real durations, integer
    /// `ceil(0.95*n)-1` (clamped), null with no samples. Sorts a fixed
    /// stack copy, so this read never allocates and the ring/revision/counters
    /// are untouched. This is not an all-time percentile: older calls outside
    /// the ring do not participate.
    pub fn p95RecentMs(self: *const Stats) ?u32 {
        var sorted: [recent_capacity]u32 = undefined;
        const n = self.recentInto(&sorted);
        return nearestRankP95(sorted[0..n]);
    }
};

pub const Metrics = struct {
    items: [max_metric_tools]?Stats = @splat(null),
    occupied: u8 = 0,
    /// Changes whenever counters/samples change. The Tools chart cache keys
    /// on this instead of re-rendering every frame.
    revision: u64 = 0,

    pub fn deinit(self: *Metrics, alloc: std.mem.Allocator) void {
        for (&self.items) |*slot| {
            if (slot.*) |*s| s.deinit(alloc);
            slot.* = null;
        }
        self.occupied = 0;
        self.revision = 0;
    }

    pub fn count(self: *const Metrics) usize {
        return self.occupied;
    }

    pub fn at(self: *Metrics, index: usize) ?*Stats {
        if (index >= max_metric_tools) return null;
        if (self.items[index]) |*s| return s;
        return null;
    }

    pub fn atConst(self: *const Metrics, index: usize) ?*const Stats {
        if (index >= max_metric_tools) return null;
        if (self.items[index]) |*s| return s;
        return null;
    }

    pub fn get(self: *Metrics, name: []const u8) ?*Stats {
        for (&self.items) |*slot| {
            if (slot.*) |*s| {
                if (std.mem.eql(u8, s.name, name)) return s;
            }
        }
        return null;
    }

    /// Get the bucket for `name`, creating it (bounded by `max_metric_tools`).
    /// Returns null once the bucket table is full (call counters are then not
    /// recorded rather than allocating without bound).
    fn ensureStats(self: *Metrics, alloc: std.mem.Allocator, name: []const u8) ?*Stats {
        if (self.get(name)) |stats| return stats;
        if (self.occupied >= max_metric_tools) return null;
        const owned = alloc.dupe(u8, name) catch return null;
        var idx: usize = 0;
        while (idx < max_metric_tools and self.items[idx] != null) : (idx += 1) {}
        if (idx >= max_metric_tools) {
            alloc.free(owned);
            return null;
        }
        self.items[idx] = .{ .name = owned };
        self.occupied += 1;
        return &self.items[idx].?;
    }

    /// Record one real tool result. `running`/`cancelled` are display states,
    /// not calls, and are ignored. Executed calls (ok/error) feed the latency
    /// ring; approval_required/unsupported only increment their counters.
    pub fn record(
        self: *Metrics,
        alloc: std.mem.Allocator,
        name: []const u8,
        status: CardStatus,
        duration_ms: u32,
    ) void {
        if (status == .running or status == .cancelled) return;
        const s = self.ensureStats(alloc, name) orelse return;
        s.calls += 1;
        switch (status) {
            .ok => {
                s.ok += 1;
                self.addDuration(s, duration_ms);
            },
            .err => {
                s.errors += 1;
                self.addDuration(s, duration_ms);
            },
            .approval_required => s.approval_required += 1,
            .approved, .rejected => unreachable, // use recordDecision
            .unsupported => s.unsupported += 1,
            .running, .cancelled => unreachable,
        }
        self.revision +%= 1;
    }

    /// The human decision on a staged edit. Deliberately separate from
    /// `record`: approving/rejecting is not a second tool call and has no
    /// latency sample. Approved outcomes count as `ok` (the call ultimately
    /// succeeded); rejection is a distinct `denied` count.
    pub fn recordDecision(
        self: *Metrics,
        alloc: std.mem.Allocator,
        name: []const u8,
        verdict: Verdict,
    ) void {
        const s = self.ensureStats(alloc, name) orelse return;
        switch (verdict) {
            .approved => s.ok += 1,
            .rejected => s.denied += 1,
        }
        self.revision +%= 1;
    }

    /// Record the real execution outcome of a call whose `calls` counter was
    /// already recorded when it was admitted (M3b3 terminal: the command is
    /// staged as `approval_required` first, then allowed and executed). This
    /// adds ok/error counters and a real latency sample without counting the
    /// call twice. Non-executed outcomes are ignored.
    pub fn recordExecution(
        self: *Metrics,
        alloc: std.mem.Allocator,
        name: []const u8,
        status: CardStatus,
        duration_ms: u32,
    ) void {
        if (status != .ok and status != .err) return;
        const s = self.ensureStats(alloc, name) orelse return;
        switch (status) {
            .ok => s.ok += 1,
            .err => s.errors += 1,
            else => unreachable,
        }
        self.addDuration(s, duration_ms);
        self.revision +%= 1;
    }

    fn addDuration(self: *Metrics, s: *Stats, duration_ms: u32) void {
        _ = self;
        s.duration_count += 1;
        s.total_ms += duration_ms;
        s.max_ms = @max(s.max_ms, duration_ms);
        s.recent[s.recent_next] = duration_ms;
        s.recent_next = @intCast((@as(usize, s.recent_next) + 1) % recent_capacity);
        if (s.recent_len < recent_capacity) s.recent_len += 1;
    }

    pub fn totalCalls(self: *const Metrics) u32 {
        var n: u32 = 0;
        for (&self.items) |*slot| {
            if (slot.*) |*s| n += s.calls;
        }
        return n;
    }

    pub fn totalDurations(self: *const Metrics) u32 {
        var n: u32 = 0;
        for (&self.items) |*slot| {
            if (slot.*) |*s| n += s.duration_count;
        }
        return n;
    }

    /// Aggregate mean across every executed call (all tools).
    pub fn averageMs(self: *const Metrics) ?u32 {
        var total: u64 = 0;
        var durations: u32 = 0;
        for (&self.items) |*slot| {
            if (slot.*) |*s| {
                total += s.total_ms;
                durations += s.duration_count;
            }
        }
        if (durations == 0) return null;
        return @intCast((total + durations / 2) / durations);
    }

    /// Nearest-rank p95 over the pooled per-tool recent windows (at most
    /// `recent_capacity` samples from each tracked tool, ≤256 total). The
    /// Tools-tab header uses this; per-tool cards use `Stats.p95RecentMs`.
    /// Allocation-free stack collection; empty -> null and revision untouched.
    pub fn p95RecentMs(self: *const Metrics) ?u32 {
        var samples: [max_metric_tools * recent_capacity]u32 = undefined;
        var n: usize = 0;
        for (&self.items) |*slot| {
            if (slot.*) |*s| n += s.recentInto(samples[n..]);
        }
        return nearestRankP95(samples[0..n]);
    }
};

/// Human decision on a staged edit (see `Metrics.recordDecision`).
pub const Verdict = enum { approved, rejected };

/// Cache identity for the Tools chart. Rendering is only redone when the
/// active thread, metrics revision, or body dimensions change.
pub const ChartKey = struct {
    thread: usize = std.math.maxInt(usize),
    revision: u64 = std.math.maxInt(u64),
    width: u16 = 0,
    height: u16 = 0,

    pub fn validFor(self: ChartKey, thread: usize, revision: u64, width: u16, height: u16) bool {
        return self.thread == thread and self.revision == revision and
            self.width == width and self.height == height;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "agent: batch plan enforces rounds then calls" {
    const limits = Limits{};
    const p1 = planBatch(0, 0, limits, 2);
    try std.testing.expectEqual(@as(usize, 2), p1.execute);
    try std.testing.expectEqual(@as(usize, 0), p1.skipped);
    try std.testing.expect(p1.reason == null);

    // 7 calls already admitted: only one more fits in the 8-call budget.
    const p2 = planBatch(1, 7, limits, 3);
    try std.testing.expectEqual(@as(usize, 1), p2.execute);
    try std.testing.expectEqual(@as(usize, 2), p2.skipped);
    try std.testing.expectEqual(LimitReason.calls, p2.reason.?);

    // Budget exhausted: nothing executes, every call is skipped truthfully.
    const p3 = planBatch(2, 8, limits, 4);
    try std.testing.expectEqual(@as(usize, 0), p3.execute);
    try std.testing.expectEqual(@as(usize, 4), p3.skipped);
    try std.testing.expectEqual(LimitReason.calls, p3.reason.?);

    // Round cap wins once 4 batches have started.
    const p4 = planBatch(4, 2, limits, 1);
    try std.testing.expectEqual(@as(usize, 0), p4.execute);
    try std.testing.expectEqual(LimitReason.rounds, p4.reason.?);

    const empty = planBatch(0, 0, limits, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.execute);
    try std.testing.expect(empty.reason == null);
}

test "agent: limit note names the bound and stays owned" {
    const alloc = std.testing.allocator;
    const r = try limitNote(alloc, .rounds, .{});
    defer alloc.free(r);
    try std.testing.expectEqualStrings("tool loop stopped: max rounds (4) reached", r);
    const c = try limitNote(alloc, .calls, .{});
    defer alloc.free(c);
    try std.testing.expectEqualStrings("tool loop stopped: max calls (8) reached", c);
}

test "agent: card status text is truthful about execution" {
    var buf: [max_status_text_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("ok 3ms", cardStatusText(&buf, .ok, 3));
    try std.testing.expectEqualStrings("error 0ms", cardStatusText(&buf, .err, 0));
    try std.testing.expectEqualStrings("running", cardStatusText(&buf, .running, 0));
    try std.testing.expectEqualStrings("approval required", cardStatusText(&buf, .approval_required, 0));
    try std.testing.expectEqualStrings("approved", cardStatusText(&buf, .approved, 0));
    try std.testing.expectEqualStrings("rejected", cardStatusText(&buf, .rejected, 0));
    try std.testing.expectEqualStrings("unsupported", cardStatusText(&buf, .unsupported, 0));
    try std.testing.expectEqualStrings("cancelled", cardStatusText(&buf, .cancelled, 0));
}

test "agent: argument summaries are bounded and tool-specific" {
    const alloc = std.testing.allocator;
    const rf = try summarizeArguments(alloc, "read_file", "{\"path\":\"src/main.zig\",\"start_line\":10,\"end_line\":20}");
    defer alloc.free(rf);
    try std.testing.expectEqualStrings("src/main.zig:10-20", rf);

    const g = try summarizeArguments(alloc, "grep", "{\"pattern\":\"needle\",\"path\":\"src\",\"glob\":\"**/*.zig\"}");
    defer alloc.free(g);
    try std.testing.expectEqualStrings("\"needle\" in src · **/*.zig", g);

    const ed = try summarizeArguments(alloc, "edit_file", "{\"path\":\"a.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}");
    defer alloc.free(ed);
    try std.testing.expectEqualStrings("a.txt (replace)", ed);

    const ap = try summarizeArguments(alloc, "apply_patch", "{\"patch\":\"--- a\\n+++ b\\n@@\\n-x\\n+y\\n\"}");
    defer alloc.free(ap);
    try std.testing.expectEqualStrings("patch: 5 lines", ap);

    // Malformed / unknown arguments fall back to sanitized text, never a
    // panic and never unbounded output.
    var big: [4096]u8 = undefined;
    @memset(&big, 'a');
    const fallback = try summarizeArguments(alloc, "mystery", big[0..4096]);
    defer alloc.free(fallback);
    try std.testing.expect(fallback.len <= max_args_summary_bytes + 3);
    try std.testing.expect(std.mem.endsWith(u8, fallback, "…"));

    const ctl = try summarizeArguments(alloc, "nope", "{\"path\":\"a\\u0001b\"}not json");
    defer alloc.free(ctl);
    try std.testing.expect(std.mem.indexOfScalar(u8, ctl, 1) == null);

    // terminal: the card gets the escaped command (control bytes cannot leak
    // into the UI) plus a non-default timeout; over-long commands are bounded
    // with an explicit marker.
    const term = try summarizeArguments(alloc, "terminal", "{\"command\":\"echo\\nhi\",\"timeout_ms\":250}");
    defer alloc.free(term);
    try std.testing.expectEqualStrings("echo\\nhi · timeout 250ms", term);

    var long_cmd: [600]u8 = @splat('z');
    var long_json: std.ArrayList(u8) = .empty;
    defer long_json.deinit(alloc);
    try long_json.appendSlice(alloc, "{\"command\":\"");
    try long_json.appendSlice(alloc, &long_cmd);
    try long_json.appendSlice(alloc, "\"}");
    const term_long = try summarizeArguments(alloc, "terminal", long_json.items);
    defer alloc.free(term_long);
    try std.testing.expect(term_long.len <= terminal_tool.max_card_command_bytes + 32);
    try std.testing.expect(std.mem.indexOf(u8, term_long, "… (+") != null);
}

test "agent: result excerpt skips headers, keeps errors, truncates UTF-8" {
    const alloc = std.testing.allocator;
    const read = "path: src/main.zig\nlines: 1-2\n---\nconst answer = 42;\nsecond line\n";
    const ex = try resultExcerpt(alloc, read, max_excerpt_bytes);
    defer alloc.free(ex);
    try std.testing.expectEqualStrings("const answer = 42;", ex);

    const err_text = "error: not found: missing.zig";
    const ex_err = try resultExcerpt(alloc, err_text, max_excerpt_bytes);
    defer alloc.free(ex_err);
    try std.testing.expectEqualStrings("error: not found: missing.zig", ex_err);

    const empty = try resultExcerpt(alloc, "", max_excerpt_bytes);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);

    // 40 × "界" = 120 bytes; a 10-byte cap must cut on a boundary.
    const cjk = "界界界界界界界界界界界界界界界界界界界界";
    const cut = try resultExcerpt(alloc, cjk, 10);
    defer alloc.free(cut);
    try std.testing.expect(cut.len <= 13);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut[0 .. cut.len - 3])); // before "…"
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));

    // The bodyLines view never exposes the prologue.
    var line_buf: [8][]const u8 = undefined;
    const view = bodyLines(read, &line_buf, 4);
    try std.testing.expectEqual(@as(usize, 3), view.count);
    try std.testing.expectEqualStrings("const answer = 42;", line_buf[0]);
    try std.testing.expect(!view.more);
}

test "agent: metrics aggregate average, max and a chronological ring" {
    const alloc = std.testing.allocator;
    var m: Metrics = .{};
    defer m.deinit(alloc);

    m.record(alloc, "read_file", .ok, 10);
    m.record(alloc, "read_file", .ok, 20);
    m.record(alloc, "read_file", .err, 30);
    m.record(alloc, "grep", .ok, 5);
    m.record(alloc, "read_file", .approval_required, 0);
    m.record(alloc, "read_file", .running, 0);
    m.record(alloc, "read_file", .cancelled, 0);

    const rf = m.get("read_file").?;
    try std.testing.expectEqual(@as(u32, 4), rf.calls); // 3 results + 1 approval
    try std.testing.expectEqual(@as(u32, 2), rf.ok);
    try std.testing.expectEqual(@as(u32, 1), rf.errors);
    try std.testing.expectEqual(@as(u32, 1), rf.approval_required);
    try std.testing.expectEqual(@as(u32, 0), rf.unsupported);
    try std.testing.expectEqual(@as(u32, 3), rf.duration_count);
    try std.testing.expectEqual(@as(?u32, 20), rf.averageMs()); // (10+20+30)/3
    try std.testing.expectEqual(@as(u32, 30), rf.max_ms);
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expectEqual(@as(u32, 5), m.totalCalls());
    try std.testing.expectEqual(@as(?u32, 16), m.averageMs()); // (60+5)/4 rounded

    var samples: [recent_capacity]u32 = undefined;
    const n = rf.recentInto(&samples);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, samples[0..n]);

    // Ring wraps after 32 samples and still reports oldest → newest.
    var i: u32 = 0;
    while (i < 40) : (i += 1) m.record(alloc, "list_directory", .ok, i);
    const ld = m.get("list_directory").?;
    const got = ld.recentInto(&samples);
    try std.testing.expectEqual(recent_capacity, got);
    try std.testing.expectEqual(@as(u32, 8), samples[0]);
    try std.testing.expectEqual(@as(u32, 39), samples[got - 1]);
    try std.testing.expectEqual(@as(u32, 40), ld.calls);

    // A metrics revision changes on every recorded call, so the chart cache
    // can key on it.
    const before = m.revision;
    m.record(alloc, "read_file", .ok, 1);
    try std.testing.expect(m.revision != before);

    // Empty metrics are a real empty state, not fabricated data.
    var empty: Metrics = .{};
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    try std.testing.expectEqual(@as(u32, 0), empty.totalCalls());
    try std.testing.expect(empty.averageMs() == null);
}

test "agent: p95 recent window is nearest-rank over real samples" {
    // Direct ring fill keeps the fixture independent from wall-clock timing.
    var s: Stats = .{};
    const fill = struct {
        fn f(st: *Stats, values: []const u32) void {
            for (values) |v| {
                st.recent[st.recent_next] = v;
                st.recent_next = @intCast((@as(usize, st.recent_next) + 1) % recent_capacity);
                if (st.recent_len < recent_capacity) st.recent_len += 1;
            }
        }
    }.f;

    try std.testing.expect(s.p95RecentMs() == null); // empty -> null, not 0

    fill(&s, &.{7});
    try std.testing.expectEqual(@as(?u32, 7), s.p95RecentMs()); // n=1: only sample

    s = .{};
    fill(&s, &.{ 10, 20 });
    try std.testing.expectEqual(@as(?u32, 20), s.p95RecentMs()); // n=2: nearest rank

    s = .{};
    fill(&s, &.{ 30, 10, 20 });
    try std.testing.expectEqual(@as(?u32, 30), s.p95RecentMs()); // unsorted

    // n=20 / n=21 pin the ceil(0.95*n) boundary: 19th vs 20th smallest.
    s = .{};
    var values_20: [20]u32 = undefined;
    for (&values_20, 0..) |*v, i| v.* = @intCast((i + 1) * 2); // 2, 4, …, 40
    fill(&s, &values_20);
    try std.testing.expectEqual(@as(?u32, 38), s.p95RecentMs()); // index 18

    s = .{};
    var values_21: [21]u32 = undefined;
    for (&values_21, 0..) |*v, i| v.* = @intCast(i + 1); // 1..21
    fill(&s, &values_21);
    try std.testing.expectEqual(@as(?u32, 20), s.p95RecentMs()); // index 19

    // 32 samples: ceil(30.4)=31 -> index 30 (the second-highest sample).
    s = .{};
    var values_32: [32]u32 = undefined;
    for (&values_32, 0..) |*v, i| v.* = @intCast(i + 1);
    fill(&s, &values_32);
    try std.testing.expectEqual(@as(?u32, 31), s.p95RecentMs());

    // Duplicates: 20 samples, only 18 of them are 5ms; the 19th smallest
    // (nearest-rank index 18) is already a 100ms outlier.
    s = .{};
    var dup: [20]u32 = @splat(5);
    dup[7] = 100;
    dup[19] = 100;
    fill(&s, &dup);
    try std.testing.expectEqual(@as(?u32, 100), s.p95RecentMs());

    // Duplicates below the rank stay below p95: one 100ms outlier in 20
    // samples is index 19 only, so the 19th smallest is still 5ms.
    s = .{};
    var one_outlier: [20]u32 = @splat(5);
    one_outlier[3] = 100;
    fill(&s, &one_outlier);
    try std.testing.expectEqual(@as(?u32, 5), s.p95RecentMs());

    // All equal is a real p95, not a sentinel.
    s = .{};
    var equal: [recent_capacity]u32 = @splat(42);
    fill(&s, &equal);
    try std.testing.expectEqual(@as(?u32, 42), s.p95RecentMs());
}

test "agent: p95 uses the wrapped recent ring and never mutates metrics" {
    const alloc = std.testing.allocator;
    var m: Metrics = .{};
    defer m.deinit(alloc);

    try std.testing.expect(m.p95RecentMs() == null);
    try std.testing.expectEqual(@as(u64, 0), m.revision);

    // Allocation-free by construction: neither read accepts an allocator
    // (they only sort a fixed stack copy; no heap path exists).
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(@TypeOf(Stats.p95RecentMs)).@"fn".param_types.len);
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(@TypeOf(Metrics.p95RecentMs)).@"fn".param_types.len);

    // 40 calls wrap the 32-slot ring; only samples 8..39 are still recent.
    var i: u32 = 0;
    while (i < 40) : (i += 1) m.record(alloc, "read_file", .ok, i);
    const rf = m.get("read_file").?;
    try std.testing.expectEqual(@as(usize, recent_capacity), @as(usize, rf.recent_len));
    try std.testing.expectEqual(@as(?u32, 38), rf.p95RecentMs()); // idx 30 of 8..39
    try std.testing.expectEqual(@as(?u32, 38), m.p95RecentMs()); // only tool

    // Reading p95 is pure: the revision, counters and ring bytes are untouched
    // (the implementation sorts a fixed stack copy and never allocates).
    var before: [recent_capacity]u32 = undefined;
    const before_n = rf.recentInto(&before);
    const revision = m.revision;
    const calls = rf.calls;
    const total = rf.total_ms;
    _ = rf.p95RecentMs();
    _ = m.p95RecentMs();
    try std.testing.expectEqual(revision, m.revision);
    try std.testing.expectEqual(calls, rf.calls);
    try std.testing.expectEqual(total, rf.total_ms);
    var after: [recent_capacity]u32 = undefined;
    const after_n = rf.recentInto(&after);
    try std.testing.expectEqual(before_n, after_n);
    try std.testing.expectEqualSlices(u32, before[0..before_n], after[0..after_n]);
    // Ring order is preserved (not reordered in place by the p95 read).
    try std.testing.expectEqual(@as(u32, 8), before[0]);
    try std.testing.expectEqual(@as(u32, 39), before[before_n - 1]);

    // A header p95 pools the per-tool recent windows (still nearest-rank,
    // still real samples): read_file contributes 8..39, grep adds 10 and 20.
    // The 33rd of 34 sorted samples is 38ms.
    m.record(alloc, "grep", .ok, 10);
    m.record(alloc, "grep", .ok, 20);
    try std.testing.expectEqual(@as(?u32, 38), m.p95RecentMs());

    // A new real call still bumps revision; p95 reads never did.
    const bumped = m.revision;
    m.record(alloc, "grep", .ok, 1);
    try std.testing.expect(m.revision != bumped);
}

test "agent: approval decisions do not count as a second call" {
    const alloc = std.testing.allocator;
    var m: Metrics = .{};
    defer m.deinit(alloc);

    // One edit_file call was staged: one call, one approval_required, no
    // latency sample yet.
    m.record(alloc, "edit_file", .approval_required, 0);
    const staged = m.get("edit_file").?;
    try std.testing.expectEqual(@as(u32, 1), staged.calls);
    try std.testing.expectEqual(@as(u32, 1), staged.approval_required);
    try std.testing.expectEqual(@as(u32, 0), staged.ok);
    try std.testing.expectEqual(@as(u32, 0), staged.denied);

    // Approve: the same call becomes ok; it is not counted again.
    const before = m.revision;
    m.recordDecision(alloc, "edit_file", .approved);
    try std.testing.expectEqual(@as(u32, 1), staged.calls);
    try std.testing.expectEqual(@as(u32, 1), staged.ok);
    try std.testing.expectEqual(@as(u32, 0), staged.denied);
    try std.testing.expectEqual(@as(u32, 0), staged.duration_count);
    try std.testing.expect(m.revision != before);

    // Reject on another staged call: denied, still calls == 1.
    m.recordDecision(alloc, "edit_file", .rejected);
    try std.testing.expectEqual(@as(u32, 1), staged.calls);
    try std.testing.expectEqual(@as(u32, 1), staged.denied);
    try std.testing.expectEqual(@as(u32, 1), staged.ok);
    try std.testing.expectEqual(@as(u32, 0), staged.duration_count);
}

test "agent: staged terminal execution records one call and real duration" {
    const alloc = std.testing.allocator;
    var m: Metrics = .{};
    defer m.deinit(alloc);

    // Staged for approval: one call, one approval_required, no latency yet.
    m.record(alloc, "terminal", .approval_required, 0);
    const term = m.get("terminal").?;
    try std.testing.expectEqual(@as(u32, 1), term.calls);
    try std.testing.expectEqual(@as(u32, 1), term.approval_required);
    try std.testing.expectEqual(@as(u32, 0), term.ok);
    try std.testing.expectEqual(@as(u32, 0), term.duration_count);

    // Allowed and executed: the same call gains a real sample, no second
    // call count.
    const before = m.revision;
    m.recordExecution(alloc, "terminal", .ok, 12);
    try std.testing.expectEqual(@as(u32, 1), term.calls);
    try std.testing.expectEqual(@as(u32, 1), term.ok);
    try std.testing.expectEqual(@as(u32, 1), term.duration_count);
    try std.testing.expectEqual(@as(?u32, 12), term.averageMs());
    try std.testing.expectEqual(@as(?u32, 12), term.p95RecentMs());
    try std.testing.expect(m.revision != before);

    // A second execution outcome (would be another call staged first) adds
    // ok/error + sample only; running/cancelled/approval markers are ignored.
    m.recordExecution(alloc, "terminal", .err, 4);
    m.recordExecution(alloc, "terminal", .running, 99);
    m.recordExecution(alloc, "terminal", .cancelled, 99);
    m.recordExecution(alloc, "terminal", .approval_required, 99);
    try std.testing.expectEqual(@as(u32, 1), term.calls);
    try std.testing.expectEqual(@as(u32, 1), term.ok);
    try std.testing.expectEqual(@as(u32, 1), term.errors);
    try std.testing.expectEqual(@as(u32, 2), term.duration_count);
    try std.testing.expectEqual(@as(?u32, 8), term.averageMs());
}

test "agent: chart cache key invalidates on thread/revision/size" {
    var key = ChartKey{ .thread = 0, .revision = 8, .width = 35, .height = 8 };
    try std.testing.expect(key.validFor(0, 8, 35, 8));
    try std.testing.expect(!key.validFor(1, 8, 35, 8));
    try std.testing.expect(!key.validFor(0, 9, 35, 8));
    try std.testing.expect(!key.validFor(0, 8, 31, 8));
    try std.testing.expect(!key.validFor(0, 8, 35, 6));
    key = .{};
    try std.testing.expect(!key.validFor(0, 0, 1, 1));
}
