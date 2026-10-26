//! `terminal` tool staging and explicit approval (M3b3) — App-facing half.
//!
//! Flow (one command at a time, session-wide):
//!
//!   streamed `terminal` call
//!     -> `stageToolCall` validates command/timeout and stages a Pending
//!        (no process; card `approval required`; rail switches to Terminal)
//!     -> human presses/hints/clicks Allow   -> Job.start (`/bin/sh -c`)
//!     -> human presses/hints/clicks Deny    -> card `rejected`, no process
//!     -> Ctrl+c / thread switch while running -> process group killed
//!     -> command finishes -> `drain` fills the card/result and the App
//!        resumes the model follow-up with the real output/exit status.
//!
//! There is no automatic execution path: `stageToolCall` never spawns, and
//! `terminal_job.Job.start` is reachable only from `allow`. The executor in
//! `ai/tool_exec.zig` remains read-only and never sees this tool.
//!
//! Policy decisions (documented in DESIGN §20.12):
//!   - At most one terminal approval/command exists per session (stricter
//!     than per thread). A second terminal call is refused with a real error.
//!   - A pending *approval* is thread-scoped and survives a thread switch
//!     (hidden, no process spawned). It blocks new user turns until resolved.
//!   - A *running* command is killed when its thread is left, and on Ctrl+c;
//!     its result is discarded and the card becomes `cancelled`. This avoids
//!     completed background surprises in a thread the user did not watch.
//!   - File reviews (`agent_edit`) are independent and keep their own slot;
//!     a pending terminal does not clear or cancel a staged diff.
//!   - No sandbox is claimed: the command runs with the user's permissions in
//!     the captured workspace root with a filtered environment and empty stdin.
const std = @import("std");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const ai = @import("../ai/root.zig");
const ws = @import("../ai/workspace.zig");
const agent = @import("../ai/agent.zig");
const terminal_tool = @import("../ai/terminal_tool.zig");
const terminal_job = @import("terminal_job.zig");

pub const StageResult = union(enum) {
    staged: struct {
        timeout_ms: u32,
    },
    /// Another terminal command is already pending or running.
    busy,
    /// Owned error text, already prefixed with "error: ".
    failed: []u8,
    oom,
};

/// What the App loop must do after a human decision.
pub const Decision = union(enum) {
    /// Nothing changed (stale/hidden/no pending).
    none,
    /// Pending cleared and the tool result is final; resume thread `idx`'s
    /// follow-up (unless the thread was cancelled).
    followup: usize,
};

pub const Pending = struct {
    thread_index: usize,
    card_index: usize,
    /// Exact bytes handed to `/bin/sh -c` (never rewritten/quoted).
    command: []u8,
    /// Escaped full command for display (control bytes cannot reach the UI).
    display: []u8,
    timeout_ms: u32,
    /// Captured workspace root (absolute) used as the child's cwd.
    root: []u8,
    generation: u64,

    fn deinit(self: *Pending, alloc: std.mem.Allocator) void {
        alloc.free(self.command);
        alloc.free(self.display);
        alloc.free(self.root);
        self.* = undefined;
    }
};

pub const Session = struct {
    /// Staged approval. Also kept while the command runs so the Terminal tab
    /// can show the exact command; cleared when the result is applied.
    pending: ?Pending = null,
    /// Running/finished-but-not-applied job. Kept independently of `pending`
    /// so a cancelled job is still joined and freed by `drain`.
    job: ?*terminal_job.Job = null,
    job_thread: usize = 0,
    job_generation: u64 = 0,
    /// Terminal-tab scroll (command/output lines).
    scroll: u32 = 0,
    max_scroll: u32 = 0,
};

pub fn deinitAgentTerminal(self: *App) void {
    if (self.agent_terminal.job) |job| {
        job.requestCancel();
        job.deinit();
        self.agent_terminal.job = null;
    }
    if (self.agent_terminal.pending) |*p| p.deinit(self.alloc);
    self.agent_terminal.pending = null;
    self.agent_terminal.scroll = 0;
    self.agent_terminal.max_scroll = 0;
}

pub fn pendingVisible(self: *App) bool {
    const p = if (self.agent_terminal.pending) |*pp| pp else return false;
    return p.thread_index == self.ai.threads.active;
}

/// Visible badge count for the Terminal tab (0/1). No fabricated count.
pub fn pendingCount(self: *App) u32 {
    return if (pendingVisible(self)) 1 else 0;
}

pub fn anyPending(self: *App) bool {
    return self.agent_terminal.pending != null;
}

pub fn anyJob(self: *App) bool {
    return self.agent_terminal.job != null;
}

/// Thread-list/workbox status override while a terminal command awaits or
/// runs. Returns null when this thread has no terminal state.
pub fn statusLabelFor(self: *App, idx: usize) ?[]const u8 {
    if (self.agent_terminal.job != null and self.agent_terminal.job_thread == idx) return "terminal…";
    if (self.agent_terminal.pending) |p| {
        if (p.thread_index == idx) return "approval…";
    }
    return null;
}

fn msg(self: *App, text: []const u8) void {
    const copy = self.alloc.dupe(u8, text) catch return;
    self.setMsg(copy) catch self.alloc.free(copy);
}

fn failFmt(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) StageResult {
    const text = std.fmt.allocPrint(alloc, "error: " ++ fmt, args) catch return .oom;
    return .{ .failed = text };
}

fn parseFailure(alloc: std.mem.Allocator, e: terminal_tool.ParseError) StageResult {
    return switch (e) {
        error.OutOfMemory => .oom,
        error.MalformedArguments => failFmt(alloc, "terminal arguments are not valid JSON", .{}),
        error.ArgumentsNotObject => failFmt(alloc, "terminal arguments must be a JSON object", .{}),
        error.MissingCommand => failFmt(alloc, "terminal requires a command", .{}),
        error.CommandNotString => failFmt(alloc, "terminal argument command must be a string", .{}),
        error.InvalidUtf8 => failFmt(alloc, "terminal command must be valid UTF-8", .{}),
        error.CommandEmpty => failFmt(alloc, "terminal command must not be empty", .{}),
        error.CommandTooLong => failFmt(alloc, "terminal command is too long (max {d} bytes)", .{terminal_tool.max_command_bytes}),
        error.CommandNul => failFmt(alloc, "terminal command contains a NUL byte", .{}),
        error.UnknownField => failFmt(alloc, "unsupported terminal argument (expected command, timeout_ms)", .{}),
        error.TimeoutNotInteger => failFmt(alloc, "terminal timeout_ms must be an integer", .{}),
        error.TimeoutOutOfRange => failFmt(alloc, "terminal timeout_ms must be between {d} and {d}", .{ terminal_tool.min_timeout_ms, terminal_tool.max_timeout_ms }),
    };
}

/// Stage one `terminal` call: validate, capture the workspace root and open
/// the approval surface. No process is created here and the file system is
/// only stat'ed (root check), never written.
pub fn stageToolCall(
    self: *App,
    thread_index: usize,
    card_index: usize,
    call: ai.tools.ToolCall,
) StageResult {
    if (self.agent_terminal.pending != null or self.agent_terminal.job != null) return .busy;

    if (thread_index >= self.ai.tool_states.items.len) {
        return failFmt(self.alloc, "workspace root unavailable", .{});
    }
    const st = &self.ai.tool_states.items[thread_index];
    const root = st.root orelse return failFmt(self.alloc, "workspace root unavailable", .{});

    var args = terminal_tool.parseArgs(self.alloc, call.arguments_json) catch |e| {
        return parseFailure(self.alloc, e);
    };
    // Move the validated command into the pending record: it is exactly the
    // bytes the shell will receive. Capture the timeout before `deinit`
    // invalidates `args`.
    const timeout_ms = args.timeout_ms;
    const command = args.command;
    args.command = &.{};
    args.deinit(self.alloc);

    // The captured root is already absolute; verify it is still a directory
    // so the approval never promises a cwd that cannot be used.
    var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{}) catch {
        self.alloc.free(command);
        return failFmt(self.alloc, "workspace root unavailable", .{});
    };
    dir.close(self.io);

    const display = terminal_tool.escapeCommand(self.alloc, command) catch {
        self.alloc.free(command);
        return .oom;
    };
    const root_copy = self.alloc.dupe(u8, root) catch {
        self.alloc.free(command);
        self.alloc.free(display);
        return .oom;
    };

    self.agent_terminal.pending = .{
        .thread_index = thread_index,
        .card_index = card_index,
        .command = command,
        .display = display,
        .timeout_ms = timeout_ms,
        .root = root_copy,
        .generation = st.generation,
    };
    self.agent_terminal.scroll = 0;
    self.agent_terminal.max_scroll = 0;
    openSurface(self);
    return .{ .staged = .{ .timeout_ms = timeout_ms } };
}

fn openSurface(self: *App) void {
    // Same modal transition as a staged edit, but on the Terminal tab: the
    // review surface is a bounded approval panel, never an interactive shell.
    self.ensureAi() catch {};
    self.ai.rail_open = true;
    self.ai.tab = .terminal;
    self.ai.focus = .rail;
    self.ai.rail_pending_leader = false;
    self.ai.thread_cursor = self.ai.threads.active;
    self.pending_window = false;
    self.pending_replace = null;
}

/// Build the bounded child environment. Only the allowlisted variables are
/// copied; PATH gets a deterministic fallback so `sh` can find commands.
fn buildEnv(self: *App) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(self.alloc);
    errdefer map.deinit();
    for (terminal_tool.env_allowlist) |key| {
        if (self.env_map.get(key)) |value| try map.put(key, value);
    }
    if (map.get("PATH") == null) try map.put("PATH", terminal_tool.default_path);
    return map;
}

fn setCard(
    self: *App,
    thread_index: usize,
    card_index: usize,
    status: ws.ToolStatus,
    text: []const u8,
    api: []const u8,
    duration_ms: u32,
) void {
    self.ai.threads.setToolOutcome(
        self.alloc,
        thread_index,
        card_index,
        status,
        text,
        api,
        duration_ms,
    ) catch {
        if (thread_index < self.ai.threads.items.items.len) {
            const t = &self.ai.threads.items.items[thread_index];
            if (card_index < t.messages.items.len) {
                t.messages.items[card_index].tool_status = .err;
            }
        }
    };
}

fn recordExecution(self: *App, thread_index: usize, status: agent.CardStatus, duration_ms: u32) void {
    if (thread_index >= self.ai.tool_states.items.len) return;
    self.ai.tool_states.items[thread_index].metrics.recordExecution(
        self.alloc,
        terminal_tool.tool_name,
        status,
        duration_ms,
    );
}

fn recordDenied(self: *App, thread_index: usize) void {
    if (thread_index >= self.ai.tool_states.items.len) return;
    self.ai.tool_states.items[thread_index].metrics.recordDecision(
        self.alloc,
        terminal_tool.tool_name,
        .rejected,
    );
}

fn clearPending(self: *App) void {
    if (self.agent_terminal.pending) |*p| p.deinit(self.alloc);
    self.agent_terminal.pending = null;
    self.agent_terminal.scroll = 0;
    self.agent_terminal.max_scroll = 0;
}

/// Explicit Allow: spawn the approved command in a background job. Every
/// failure path produces a real error card and resumes the loop so the model
/// can recover; nothing is faked as success.
pub fn allow(self: *App) Decision {
    const p = if (self.agent_terminal.pending) |*pp| pp else return .none;
    if (!pendingVisible(self)) {
        msg(self, "terminal: switch to its thread first");
        return .none;
    }
    if (self.agent_terminal.job != null) return .none;
    const thread_index = p.thread_index;
    const card_index = p.card_index;
    const generation = p.generation;
    if (thread_index >= self.ai.threads.items.items.len) return .none;
    const t = &self.ai.threads.items.items[thread_index];
    if (t.cancel_requested or t.status == .err) {
        // The turn was cancelled/failed; never start a process from a stale
        // approval surface.
        setCard(self, thread_index, card_index, .cancelled, "cancelled · not executed", "cancelled: not executed", 0);
        clearPending(self);
        return .none;
    }

    if (!terminal_job.supported) {
        const text = "error: terminal execution is not supported on this platform";
        setCard(self, thread_index, card_index, .err, text, text, 0);
        recordExecution(self, thread_index, .err, 0);
        clearPending(self);
        return .{ .followup = thread_index };
    }

    const command = self.alloc.dupe(u8, p.command) catch return failAllowOom(self, thread_index, card_index);
    defer self.alloc.free(command);
    const root = self.alloc.dupe(u8, p.root) catch return failAllowOom(self, thread_index, card_index);
    defer self.alloc.free(root);
    const timeout_ms = p.timeout_ms;

    const env = buildEnv(self) catch return failAllowOom(self, thread_index, card_index);
    // `Job.start` takes ownership of `env` on every path (deinits it on
    // failure), so no local errdefer is needed/appropriate.
    const job = terminal_job.Job.start(self.alloc, self.io, root, command, timeout_ms, env) catch |e| {
        const text = std.fmt.allocPrint(
            self.alloc,
            "error: terminal execution failed to start: {s}",
            .{@errorName(e)},
        ) catch null;
        defer if (text) |x| self.alloc.free(x);
        const shown = text orelse "error: terminal execution failed to start";
        setCard(self, thread_index, card_index, .err, shown, shown, 0);
        recordExecution(self, thread_index, .err, 0);
        clearPending(self);
        return .{ .followup = thread_index };
    };

    self.agent_terminal.job = job;
    self.agent_terminal.job_thread = thread_index;
    self.agent_terminal.job_generation = generation;

    // Keep it visible as `running`; the real exit code/duration/output
    // replace this in `drain`.
    setCard(self, thread_index, card_index, .running, "running…", "terminal command running", 0);
    return .none;
}

fn failAllowOom(self: *App, thread_index: usize, card_index: usize) Decision {
    const text = "error: out of memory";
    setCard(self, thread_index, card_index, .err, text, text, 0);
    recordExecution(self, thread_index, .err, 0);
    clearPending(self);
    return .{ .followup = thread_index };
}

/// Explicit Deny: no process is spawned. The model receives a truthful
/// denied/not-executed tool result once the loop resumes.
pub fn deny(self: *App) Decision {
    const p = if (self.agent_terminal.pending) |*pp| pp else return .none;
    if (!pendingVisible(self)) {
        msg(self, "terminal: switch to its thread first");
        return .none;
    }
    if (self.agent_terminal.job != null) return .none; // already running
    const thread_index = p.thread_index;
    const card_index = p.card_index;
    setCard(
        self,
        thread_index,
        card_index,
        .rejected,
        "denied · not executed",
        "denied: user rejected the command; not executed",
        0,
    );
    recordDenied(self, thread_index);
    clearPending(self);
    msg(self, "terminal command denied");
    return .{ .followup = thread_index };
}

/// Ctrl+c while a terminal approval/command is pending in `thread_index`.
/// Kills a running command (real process-group kill) and freezes the card as
/// cancelled; no follow-up is sent because the turn itself is cancelled.
pub fn cancelForThread(self: *App, thread_index: usize) bool {
    const p = if (self.agent_terminal.pending) |*pp| pp else return false;
    if (p.thread_index != thread_index) return false;
    const card_index = p.card_index;
    if (self.agent_terminal.job) |job| {
        job.requestCancel();
        setCard(self, thread_index, card_index, .cancelled, "cancelled · command stopped", "cancelled: not executed", 0);
    } else {
        setCard(self, thread_index, card_index, .cancelled, "cancelled · not executed", "cancelled: not executed", 0);
    }
    if (thread_index < self.ai.tool_states.items.len) {
        self.ai.tool_states.items[thread_index].pending_followup = false;
    }
    if (thread_index < self.ai.threads.items.items.len) {
        const t = &self.ai.threads.items.items[thread_index];
        t.cancel_requested = true;
        t.status = .cancelled;
    }
    clearPending(self);
    return true;
}

/// Leaving a thread: a running command is killed (and its result discarded);
/// a not-yet-approved command is preserved hidden for that thread.
pub fn leaveThread(self: *App, prev_index: usize) void {
    const p = if (self.agent_terminal.pending) |*pp| pp else return;
    if (p.thread_index != prev_index) return;
    if (self.agent_terminal.job == null) return; // pending approval survives
    self.agent_terminal.job.?.requestCancel();
    setCard(self, prev_index, p.card_index, .cancelled, "cancelled · command stopped", "cancelled: not executed", 0);
    if (prev_index < self.ai.tool_states.items.len) {
        self.ai.tool_states.items[prev_index].pending_followup = false;
    }
    clearPending(self);
}

pub fn scrollBy(self: *App, delta: i64) void {
    const max = self.agent_terminal.max_scroll;
    var top: i64 = @intCast(@min(self.agent_terminal.scroll, max));
    top += delta;
    if (top < 0) top = 0;
    if (top > max) top = @intCast(max);
    self.agent_terminal.scroll = @intCast(top);
}

pub fn setMaxScroll(self: *App, max: u32) void {
    self.agent_terminal.max_scroll = max;
    if (self.agent_terminal.scroll > max) self.agent_terminal.scroll = max;
}

/// Whether an awaiting/running terminal command in `idx` must pause that
/// thread's automatic model follow-up until a human decides.
pub fn blocksFollowup(self: *App, idx: usize) bool {
    if (self.agent_terminal.pending) |p| {
        if (p.thread_index == idx) return true;
    }
    if (self.agent_terminal.job != null and self.agent_terminal.job_thread == idx) return true;
    return false;
}

pub const DrainResult = struct {
    /// A job was consumed (even a cancelled/discarded one).
    changed: bool = false,
    /// The current thread's result is final; the App may resume its loop.
    resume_thread: ?usize = null,
};

/// Consume a finished job. Applies the real result only when the pending
/// approval and loop generation still match; otherwise the result is freed
/// without touching any transcript.
pub fn drain(self: *App) DrainResult {
    const job = self.agent_terminal.job orelse return .{};
    if (!job.isDone()) return .{};
    const job_thread = self.agent_terminal.job_thread;
    const job_generation = self.agent_terminal.job_generation;

    var result = job.takeResult();
    job.deinit();
    self.agent_terminal.job = null;
    defer result.deinit(self.alloc);

    const p = if (self.agent_terminal.pending) |*pp| pp else {
        // Cancelled/left thread: result already discarded by policy.
        return .{ .changed = true };
    };
    if (p.thread_index != job_thread or job_generation != p.generation) {
        // The approval was superseded (e.g. cancelClient bumped generation).
        // Do not apply a stale result; freeze the card truthfully.
        setCard(self, p.thread_index, p.card_index, .cancelled, "cancelled · result discarded", "cancelled: result discarded", 0);
        clearPending(self);
        return .{ .changed = true };
    }
    if (job_thread >= self.ai.threads.items.items.len or job_thread >= self.ai.tool_states.items.len) {
        clearPending(self);
        return .{ .changed = true };
    }
    const t = &self.ai.threads.items.items[job_thread];
    if (t.cancel_requested) {
        clearPending(self);
        return .{ .changed = true };
    }

    const thread_index = p.thread_index;
    const card_index = p.card_index;

    if (result.status == .cancelled) {
        setCard(self, thread_index, card_index, .cancelled, "cancelled · command stopped", "cancelled: not executed", 0);
        clearPending(self);
        return .{ .changed = true };
    }

    // Build the exact bounded tool result the provider will see (header +
    // output + truncation marker), then reuse the protocol's 64 KiB/UTF-8
    // bound. The card text is a separate, shorter excerpt.
    const content = terminal_tool.buildResultContent(self.alloc, result.meta, result.output) catch {
        clearPending(self);
        return .{ .changed = true };
    };
    defer self.alloc.free(content);
    const api = ai.tools.buildToolResultContent(self.alloc, .{ .output = content }, .{}) catch {
        clearPending(self);
        return .{ .changed = true };
    };
    defer self.alloc.free(api);

    const excerpt = agent.resultExcerpt(self.alloc, content, agent.max_excerpt_bytes) catch null;
    defer if (excerpt) |e| self.alloc.free(e);

    const card_text = formatCardText(self.alloc, result.meta, excerpt orelse "") catch null;
    defer if (card_text) |x| self.alloc.free(x);

    const ok = result.status == .ok;
    setCard(
        self,
        thread_index,
        card_index,
        if (ok) .ok else .err,
        card_text orelse (if (ok) "exit 0" else "error"),
        api,
        result.meta.duration_ms,
    );
    recordExecution(self, thread_index, if (ok) .ok else .err, result.meta.duration_ms);
    clearPending(self);
    return .{ .changed = true, .resume_thread = thread_index };
}

/// Bounded one-line card text: exit status/timeout + first output line.
fn formatCardText(
    alloc: std.mem.Allocator,
    meta: terminal_tool.ResultMeta,
    excerpt: []const u8,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var num: [48]u8 = undefined;
    if (meta.timed_out) {
        const head = std.fmt.bufPrint(&num, "timeout · killed after {d}ms", .{meta.duration_ms}) catch "timeout · killed";
        try out.appendSlice(alloc, head);
    } else if (meta.read_error) {
        try out.appendSlice(alloc, "output read failed");
    } else if (meta.signal) |sig| {
        const head = std.fmt.bufPrint(&num, "signal {d}", .{sig}) catch "signal";
        try out.appendSlice(alloc, head);
    } else if (meta.exit_code) |code| {
        const head = std.fmt.bufPrint(&num, "exit {d}", .{code}) catch "exit";
        try out.appendSlice(alloc, head);
    } else {
        try out.appendSlice(alloc, "unknown termination");
    }
    // Truncation comes before the excerpt so a narrow card/rail cannot clip
    // the only truthful truncation marker.
    if (meta.dropped_bytes > 0) {
        try out.appendSlice(alloc, " · output truncated");
    }
    if (excerpt.len > 0) {
        try out.appendSlice(alloc, " · ");
        try out.appendSlice(alloc, excerpt);
    } else if (meta.exit_code == 0 and !meta.timed_out and meta.signal == null) {
        try out.appendSlice(alloc, " · no output");
    }
    return out.toOwnedSlice(alloc);
}

/// Most recent terminal tool card in `thread_index` (for the Terminal tab's
/// result view). The message owns its strings; callers must not retain it
/// across transcript mutations.
pub fn lastCard(self: *App, thread_index: usize) ?*const ws.Message {
    if (thread_index >= self.ai.threads.items.items.len) return null;
    const messages = self.ai.threads.items.items[thread_index].messages.items;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const m = &messages[i];
        if (m.role != .tool) continue;
        const name = m.tool_name orelse continue;
        if (std.mem.eql(u8, name, terminal_tool.tool_name)) return m;
    }
    return null;
}

/// The visible pending approval, if any (Terminal tab rendering).
pub fn visiblePending(self: *App) ?*const Pending {
    if (!pendingVisible(self)) return null;
    return &self.agent_terminal.pending.?;
}
