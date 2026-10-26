//! `terminal` tool protocol/policy (M3b3) — pure, no process execution.
//!
//! The name says what the tool is and is not:
//!
//!   - `terminal` runs ONE non-interactive shell command (`/bin/sh -c`) in
//!     the thread's captured workspace root, with the user's own permissions.
//!     It is **not** the editor terminal (`Alt+r`): no PTY, no keyboard
//!     forwarding, no scrollback, and no shell UI.
//!   - Nothing here spawns anything. This module only validates the requested
//!     command/timeout, bounds and escapes display text, accumulates bounded
//!     output, and formats a truthful tool result. `app/terminal_job.zig`
//!     owns the real POSIX spawn/kill/read loop; `app/agent_terminal.zig`
//!     owns staging and the explicit human approval.
//!
//! ## Security posture (documented, not a sandbox)
//!
//! The command is executed **verbatim** with the user's permissions once a
//! human explicitly allows it. There is no sandbox, no seccomp, no container,
//! no network restriction and no shell-injection mitigation: shell syntax is
//! the point of the tool. The guarantees are bounded, not hermetic:
//!
//!   - no automatic execution — approval is explicit for every command;
//!   - a bounded environment (`env_allowlist`) instead of the full process
//!     environment;
//!   - cwd fixed to the thread's captured workspace root;
//!   - empty stdin, so a command cannot wait for interactive input;
//!   - at most `max_command_bytes` of command text (rejects NUL/empty);
//!   - at most `max_output_bytes` of combined stdout+stderr (excess is read
//!     and discarded so the child never blocks on a full pipe);
//!   - at most `max_timeout_ms` of wall-clock time; the process group is
//!     killed on timeout/cancel.
//!
//! Display text is escaped (`\n`, `\t`, `\\`, `\xNN`) so a command cannot
//! inject terminal escape sequences into oz's own UI. The executed bytes are
//! never rewritten, quoted or truncated.
const std = @import("std");

/// Wire/definition name. Kept here so App code, metrics and tests cannot drift.
pub const tool_name = "terminal";

/// Maximum command text accepted before staging (> 4 KiB is rejected).
pub const max_command_bytes: usize = 4096;
/// Combined stdout+stderr cap. Extra bytes are drained and discarded.
pub const max_output_bytes: usize = 64 * 1024;
/// Bounds of the optional `timeout_ms` argument. Out-of-range is rejected,
/// never silently clamped at the protocol boundary; `clampTimeout` is a
/// defensive inner bound for the spawner.
pub const min_timeout_ms: u32 = 100;
pub const max_timeout_ms: u32 = 10_000;
pub const default_timeout_ms: u32 = 5000;
/// Display budget for the Chat card's argument line. The complete escaped
/// command is always available in the Terminal tab; this is only the compact
/// transcript summary, and past the budget it ends with an explicit
/// `… (+N bytes)` marker instead of an ambiguous cut.
pub const max_card_command_bytes: usize = 200;
/// Executable used for `-c`. Absolute so a PATH change cannot redirect it.
pub const shell_program = "/bin/sh";
/// Environment variables copied into the child. Everything else is dropped.
pub const env_allowlist = [_][]const u8{ "PATH", "HOME", "TERM", "LANG", "LC_ALL", "TMPDIR" };
/// Fallback when the parent environment has no PATH (the shell still needs a
/// deterministic lookup path for external commands).
pub const default_path = "/usr/local/bin:/usr/bin:/bin";

pub const ParseError = error{
    OutOfMemory,
    MalformedArguments,
    ArgumentsNotObject,
    MissingCommand,
    CommandNotString,
    InvalidUtf8,
    CommandEmpty,
    CommandTooLong,
    CommandNul,
    UnknownField,
    TimeoutNotInteger,
    TimeoutOutOfRange,
};

/// Validated `terminal` arguments. `command` is owned and is byte-for-byte
/// what the shell receives.
pub const Args = struct {
    command: []u8,
    timeout_ms: u32,

    pub fn deinit(self: *Args, alloc: std.mem.Allocator) void {
        alloc.free(self.command);
        self.* = undefined;
    }
};

/// Parse and validate one `terminal` arguments object. Strict: unknown
/// fields, non-object JSON, missing/empty/NUL/oversized commands, non-integer
/// timeouts and out-of-range timeouts are all typed errors. Nothing is
/// clamped here — the caller must reject before staging.
pub fn parseArgs(alloc: std.mem.Allocator, arguments_json: []const u8) ParseError!Args {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedArguments,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.ArgumentsNotObject;
    const obj = &parsed.value.object;

    // Strict schema: only the two documented fields are accepted. A model
    // that sends `timeout`/`cwd` must get a real error instead of a command
    // silently running with different settings than it asked for.
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "command") and
            !std.mem.eql(u8, entry.key_ptr.*, "timeout_ms"))
        {
            return error.UnknownField;
        }
    }

    const command_value = obj.get("command") orelse return error.MissingCommand;
    if (command_value != .string) return error.CommandNotString;
    const command = command_value.string;
    if (!std.unicode.utf8ValidateSlice(command)) return error.InvalidUtf8;
    if (command.len == 0 or std.mem.trim(u8, command, " \t\r\n").len == 0) {
        return error.CommandEmpty;
    }
    if (command.len > max_command_bytes) return error.CommandTooLong;
    if (std.mem.indexOfScalar(u8, command, 0) != null) return error.CommandNul;

    var timeout_ms: u32 = default_timeout_ms;
    if (obj.get("timeout_ms")) |timeout_value| {
        if (timeout_value != .integer) return error.TimeoutNotInteger;
        const raw = timeout_value.integer;
        if (raw < min_timeout_ms or raw > max_timeout_ms) return error.TimeoutOutOfRange;
        timeout_ms = @intCast(raw);
    }

    return .{
        .command = try alloc.dupe(u8, command),
        .timeout_ms = timeout_ms,
    };
}

/// Defensive inner clamp for the spawner. The protocol path already rejects
/// out-of-range values; this keeps a corrupt/internal caller from spawning
/// with 0 ms or an unbounded deadline.
pub fn clampTimeout(timeout_ms: u32) u32 {
    return @min(@max(timeout_ms, min_timeout_ms), max_timeout_ms);
}

/// Format a timeout for UI text without a non-ASCII glyph.
pub fn timeoutLabel(buf: []u8, timeout_ms: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}ms", .{timeout_ms}) catch "timeout";
}

/// Escape a command for display. Control bytes (including ESC and newlines),
/// DEL and invalid UTF-8 bytes become visible escapes; backslash is escaped
/// too so the displayed text is unambiguous. The executed command is NOT
/// modified. Caller owns the result.
pub fn escapeCommand(alloc: std.mem.Allocator, command: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, command.len + command.len / 8 + 8);

    var i: usize = 0;
    while (i < command.len) {
        const b = command[i];
        if (b == '\\') {
            try out.appendSlice(alloc, "\\\\");
            i += 1;
        } else if (b == '\n') {
            try out.appendSlice(alloc, "\\n");
            i += 1;
        } else if (b == '\r') {
            try out.appendSlice(alloc, "\\r");
            i += 1;
        } else if (b == '\t') {
            try out.appendSlice(alloc, "\\t");
            i += 1;
        } else if (b >= 0x20 and b <= 0x7e) {
            try out.append(alloc, b);
            i += 1;
        } else if (b < 0x20 or b == 0x7f) {
            try appendHexEscape(&out, alloc, b);
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                try appendHexEscape(&out, alloc, b);
                i += 1;
                continue;
            };
            if (i + len <= command.len and std.unicode.utf8ValidateSlice(command[i .. i + len])) {
                try out.appendSlice(alloc, command[i .. i + len]);
                i += len;
            } else {
                try appendHexEscape(&out, alloc, b);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

fn appendHexEscape(out: *std.ArrayList(u8), alloc: std.mem.Allocator, b: u8) !void {
    const hex = "0123456789abcdef";
    try out.appendSlice(alloc, "\\x");
    try out.append(alloc, hex[b >> 4]);
    try out.append(alloc, hex[b & 0x0f]);
}

/// Compact Chat-card summary: escaped command, bounded with an explicit
/// `… (+N bytes)` marker, plus a non-default timeout. Caller owns the result.
pub fn commandForCard(
    alloc: std.mem.Allocator,
    command: []const u8,
    timeout_ms: u32,
) error{OutOfMemory}![]u8 {
    const escaped = try escapeCommand(alloc, command);
    defer alloc.free(escaped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, @min(escaped.len, max_card_command_bytes) + 48);

    if (escaped.len <= max_card_command_bytes) {
        try out.appendSlice(alloc, escaped);
    } else {
        var cut = max_card_command_bytes -| 1;
        while (cut > 0 and (escaped[cut] & 0xC0) == 0x80) cut -= 1;
        try out.appendSlice(alloc, escaped[0..cut]);
        var num: [32]u8 = undefined;
        const tail = std.fmt.bufPrint(&num, "… (+{d} bytes)", .{escaped.len - cut}) catch "…";
        try out.appendSlice(alloc, tail);
    }
    if (timeout_ms != default_timeout_ms) {
        var num: [32]u8 = undefined;
        const tail = std.fmt.bufPrint(&num, " · timeout {d}ms", .{timeout_ms}) catch "";
        try out.appendSlice(alloc, tail);
    }
    return out.toOwnedSlice(alloc);
}

/// Combined-output accumulator. Bytes beyond `max_output_bytes` are counted
/// (not stored) so the caller can keep draining the pipe without unbounded
/// memory and report a truthful truncation marker.
pub const OutputBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Total bytes observed (stored + dropped).
    total: usize = 0,
    /// Bytes observed after the cap was reached.
    dropped: usize = 0,

    pub fn deinit(self: *OutputBuffer, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
        self.* = .{};
    }

    pub fn append(self: *OutputBuffer, alloc: std.mem.Allocator, chunk: []const u8) error{OutOfMemory}!void {
        if (chunk.len == 0) return;
        self.total +|= chunk.len;
        const room = max_output_bytes -| self.bytes.items.len;
        const take = @min(room, chunk.len);
        if (take > 0) try self.bytes.appendSlice(alloc, chunk[0..take]);
        self.dropped +|= chunk.len - take;
    }

    pub fn truncated(self: *const OutputBuffer) bool {
        return self.dropped > 0;
    }
};

/// Truthful metadata for one finished terminal command. `output` is the
/// bounded combined stream from `OutputBuffer`.
pub const ResultMeta = struct {
    /// Shell exit code when the process exited normally.
    exit_code: ?u8 = null,
    /// Signal number when the process was terminated by a signal.
    signal: ?u32 = null,
    /// The tool's own deadline fired and the process group was killed.
    timed_out: bool = false,
    /// Reading the child's stdout/stderr failed; the output is partial and the
    /// result must not be reported as success.
    read_error: bool = false,
    duration_ms: u32 = 0,
    dropped_bytes: usize = 0,
};

pub fn isError(meta: ResultMeta) bool {
    if (meta.timed_out) return true;
    if (meta.read_error) return true;
    if (meta.signal != null) return true;
    if (meta.exit_code) |code| return code != 0;
    return true; // no exit/signal information is never success
}

/// Build the bounded `role:"tool"` content sent back to the model. The
/// App also passes this through `tools.buildToolResultContent`, which keeps
/// the protocol's hard 64 KiB cap and UTF-8 safety. Header lines end at
/// `---`; `agent.resultExcerpt`/`bodyLines` skip them as usual.
pub fn buildResultContent(
    alloc: std.mem.Allocator,
    meta: ResultMeta,
    output: []const u8,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, if (isError(meta)) "error: " else "exit: ");

    if (!isError(meta)) {
        // Success reads as `exit: 0`; error responses name the failure.
        if (meta.exit_code) |code| {
            const text = try std.fmt.allocPrint(alloc, "{d}", .{code});
            defer alloc.free(text);
            try out.appendSlice(alloc, text);
        } else {
            try out.appendSlice(alloc, "0");
        }
    } else if (meta.timed_out) {
        const text = try std.fmt.allocPrint(alloc, "timeout; process group killed", .{});
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    } else if (meta.read_error) {
        try out.appendSlice(alloc, "output read failed; result incomplete");
    } else if (meta.signal) |sig| {
        const text = try std.fmt.allocPrint(alloc, "terminated by signal {d}", .{sig});
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    } else if (meta.exit_code) |code| {
        const text = try std.fmt.allocPrint(alloc, "exit code {d}", .{code});
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    } else {
        try out.appendSlice(alloc, "unknown termination");
    }

    var num: [64]u8 = undefined;
    const duration = std.fmt.bufPrint(&num, "\nduration: {d}ms\n", .{meta.duration_ms}) catch "\nduration: ?\n";
    try out.appendSlice(alloc, duration);
    if (meta.dropped_bytes > 0) {
        var num2: [64]u8 = undefined;
        const dropped = std.fmt.bufPrint(&num2, "output_truncated: {d} bytes dropped\n", .{meta.dropped_bytes}) catch "output_truncated\n";
        try out.appendSlice(alloc, dropped);
    }
    try out.appendSlice(alloc, "---\n");
    if (output.len == 0) {
        try out.appendSlice(alloc, "(no output)");
    } else {
        try out.appendSlice(alloc, output);
        if (meta.dropped_bytes > 0) {
            var num3: [80]u8 = undefined;
            const marker = std.fmt.bufPrint(&num3, "\n… [output truncated: {d} bytes dropped]", .{meta.dropped_bytes}) catch "\n… [output truncated]";
            try out.appendSlice(alloc, marker);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "terminal_tool: strict argument validation" {
    const alloc = std.testing.allocator;

    var ok = try parseArgs(alloc, "{\"command\":\"printf hi\"}");
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("printf hi", ok.command);
    try std.testing.expectEqual(default_timeout_ms, ok.timeout_ms);

    var timed = try parseArgs(alloc, "{\"command\":\"echo hi\",\"timeout_ms\":250}");
    defer timed.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 250), timed.timeout_ms);

    // Accepted bounds.
    var lo = try parseArgs(alloc, "{\"command\":\"true\",\"timeout_ms\":100}");
    defer lo.deinit(alloc);
    try std.testing.expectEqual(min_timeout_ms, lo.timeout_ms);
    var hi = try parseArgs(alloc, "{\"command\":\"true\",\"timeout_ms\":10000}");
    defer hi.deinit(alloc);
    try std.testing.expectEqual(max_timeout_ms, hi.timeout_ms);

    const cases = [_]struct { json: []const u8, want: ParseError }{
        .{ .json = "", .want = error.MalformedArguments },
        .{ .json = "not json", .want = error.MalformedArguments },
        .{ .json = "[]", .want = error.ArgumentsNotObject },
        .{ .json = "{}", .want = error.MissingCommand },
        .{ .json = "{\"command\":1}", .want = error.CommandNotString },
        .{ .json = "{\"command\":\"\"}", .want = error.CommandEmpty },
        .{ .json = "{\"command\":\"   \\n\"}", .want = error.CommandEmpty },
        .{ .json = "{\"command\":\"ok\",\"timeout\":100}", .want = error.UnknownField },
        .{ .json = "{\"command\":\"ok\",\"cwd\":\"/\"}", .want = error.UnknownField },
        .{ .json = "{\"command\":\"ok\",\"timeout_ms\":1.5}", .want = error.TimeoutNotInteger },
        .{ .json = "{\"command\":\"ok\",\"timeout_ms\":\"100\"}", .want = error.TimeoutNotInteger },
        .{ .json = "{\"command\":\"ok\",\"timeout_ms\":99}", .want = error.TimeoutOutOfRange },
        .{ .json = "{\"command\":\"ok\",\"timeout_ms\":10001}", .want = error.TimeoutOutOfRange },
        .{ .json = "{\"command\":\"ok\",\"timeout_ms\":-1}", .want = error.TimeoutOutOfRange },
    };
    for (cases) |case| {
        const result = parseArgs(alloc, case.json);
        if (result) |args_value| {
            var args = args_value;
            args.deinit(alloc);
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(case.want, err);
        }
    }

    // NUL is rejected before staging; a NUL cannot be realized as a C string
    // for the shell and must never be silently stripped.
    var nul_buf: [32]u8 = undefined;
    const nul_json = try std.fmt.bufPrint(&nul_buf, "{{\"command\":\"echo\\u0000hi\"}}", .{});
    try std.testing.expectError(error.CommandNul, parseArgs(alloc, nul_json));

    // Command > 4 KiB is rejected, not truncated.
    var big: [max_command_bytes + 1]u8 = @splat('x');
    var big_json: std.ArrayList(u8) = .empty;
    defer big_json.deinit(alloc);
    try big_json.appendSlice(alloc, "{\"command\":\"");
    try big_json.appendSlice(alloc, &big);
    try big_json.appendSlice(alloc, "\"}");
    try std.testing.expectError(error.CommandTooLong, parseArgs(alloc, big_json.items));
}

test "terminal_tool: timeout clamp is defensive only" {
    try std.testing.expectEqual(min_timeout_ms, clampTimeout(0));
    try std.testing.expectEqual(min_timeout_ms, clampTimeout(1));
    try std.testing.expectEqual(default_timeout_ms, clampTimeout(default_timeout_ms));
    try std.testing.expectEqual(max_timeout_ms, clampTimeout(max_timeout_ms + 1));
    try std.testing.expectEqual(max_timeout_ms, clampTimeout(std.math.maxInt(u32)));

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("5000ms", timeoutLabel(&buf, 5000));
}

test "terminal_tool: display escaping is unambiguous and bounded" {
    const alloc = std.testing.allocator;

    const escaped = try escapeCommand(alloc, "echo 'a b' && printf '\\n'\n\t\x1b[31m");
    defer alloc.free(escaped);
    try std.testing.expectEqualStrings("echo 'a b' && printf '\\\\n'\\n\\t\\x1b[31m", escaped);
    try std.testing.expect(std.mem.indexOfScalar(u8, escaped, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, escaped, 0x1b) == null);

    const card = try commandForCard(alloc, "printf hi", default_timeout_ms);
    defer alloc.free(card);
    try std.testing.expectEqualStrings("printf hi", card);

    const timed = try commandForCard(alloc, "sleep 1", 250);
    defer alloc.free(timed);
    try std.testing.expectEqualStrings("sleep 1 · timeout 250ms", timed);

    // A long command is bounded with an explicit marker; the prefix is
    // still a prefix of the escaped command (never a mid-glyph cut).
    var long: [600]u8 = undefined;
    @memset(&long, 'q');
    const bounded = try commandForCard(alloc, &long, default_timeout_ms);
    defer alloc.free(bounded);
    try std.testing.expect(bounded.len <= max_card_command_bytes + 32);
    try std.testing.expect(std.mem.startsWith(u8, bounded, "qqqq"));
    try std.testing.expect(std.mem.indexOf(u8, bounded, "… (+") != null);
    try std.testing.expect(std.mem.endsWith(u8, bounded, " bytes)"));

    // Invalid UTF-8 never reaches the UI raw.
    const raw = [_]u8{ 'a', 0xff, 'b' };
    const safe = try escapeCommand(alloc, &raw);
    defer alloc.free(safe);
    try std.testing.expectEqualStrings("a\\xffb", safe);
}

test "terminal_tool: output accumulator caps and counts dropped bytes" {
    const alloc = std.testing.allocator;
    var out: OutputBuffer = .{};
    defer out.deinit(alloc);

    try out.append(alloc, "hello ");
    try out.append(alloc, "world");
    try std.testing.expectEqualStrings("hello world", out.bytes.items);
    try std.testing.expectEqual(@as(usize, 11), out.total);
    try std.testing.expect(!out.truncated());

    // Fill past the cap; the extra is counted, not stored.
    const chunk = try alloc.alloc(u8, max_output_bytes);
    defer alloc.free(chunk);
    @memset(chunk, 'x');
    try out.append(alloc, chunk);
    try out.append(alloc, "TAIL");
    try std.testing.expectEqual(max_output_bytes, out.bytes.items.len);
    // 11 stored + 65536 offered: 65525 of the big chunk fit, 11 overflow,
    // then the 4-byte tail is dropped as well.
    try std.testing.expectEqual(@as(usize, 15), out.dropped);
    try std.testing.expectEqual(max_output_bytes + 11 + 4, out.total);
    try std.testing.expect(out.truncated());
}

test "terminal_tool: result content is truthful and bounded" {
    const alloc = std.testing.allocator;

    const ok = try buildResultContent(alloc, .{ .exit_code = 0, .duration_ms = 7 }, "hello\n");
    defer alloc.free(ok);
    try std.testing.expect(std.mem.startsWith(u8, ok, "exit: 0\n"));
    try std.testing.expect(std.mem.indexOf(u8, ok, "duration: 7ms\n---\nhello\n") != null);
    try std.testing.expect(!isError(.{ .exit_code = 0 }));

    const fail = try buildResultContent(alloc, .{ .exit_code = 3, .duration_ms = 9 }, "boom\n");
    defer alloc.free(fail);
    try std.testing.expect(std.mem.startsWith(u8, fail, "error: exit code 3\n"));
    try std.testing.expect(isError(.{ .exit_code = 3 }));

    const timeout = try buildResultContent(alloc, .{ .timed_out = true, .exit_code = null, .duration_ms = 200 }, "");
    defer alloc.free(timeout);
    try std.testing.expect(std.mem.indexOf(u8, timeout, "error: timeout; process group killed") != null);
    try std.testing.expect(std.mem.endsWith(u8, timeout, "---\n(no output)"));
    try std.testing.expect(isError(.{ .timed_out = true }));

    const signal = try buildResultContent(alloc, .{ .signal = 9, .duration_ms = 1 }, "partial");
    defer alloc.free(signal);
    try std.testing.expect(std.mem.indexOf(u8, signal, "terminated by signal 9") != null);

    const truncated = try buildResultContent(alloc, .{
        .exit_code = 0,
        .duration_ms = 2,
        .dropped_bytes = 123,
    }, "kept");
    defer alloc.free(truncated);
    try std.testing.expect(std.mem.indexOf(u8, truncated, "output_truncated: 123 bytes dropped") != null);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "… [output truncated: 123 bytes dropped]"));

    // No metadata is never success.
    try std.testing.expect(isError(.{}));
}
