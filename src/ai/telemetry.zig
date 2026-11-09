const std = @import("std");

pub const Phase = enum {
    idle,
    connecting,
    waiting,
    streaming,
};

pub const Usage = struct {
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
};

pub const Request = struct {
    phase: Phase = .idle,
    started_ms: ?i64 = null,
    finished_ms: ?i64 = null,
    estimated_prompt_tokens: u64 = 0,
    usage: ?Usage = null,

    pub fn begin(self: *Request, now_ms: i64, request_bytes: usize) void {
        self.* = .{
            .phase = .connecting,
            .started_ms = now_ms,
            .estimated_prompt_tokens = estimateTokens(request_bytes),
        };
    }

    pub fn setPhase(self: *Request, phase: Phase) void {
        if (self.started_ms == null or self.finished_ms != null) return;
        self.phase = phase;
    }

    pub fn finish(self: *Request, now_ms: i64) void {
        if (self.started_ms == null or self.finished_ms != null) return;
        self.finished_ms = now_ms;
        self.phase = .idle;
    }

    pub fn elapsedMs(self: *const Request, now_ms: i64) u64 {
        const started = self.started_ms orelse return 0;
        const end = self.finished_ms orelse now_ms;
        return @intCast(@max(end -| started, 0));
    }

    pub fn contextTokens(self: *const Request) u64 {
        if (self.usage) |usage| return usage.total_tokens;
        return self.estimated_prompt_tokens;
    }

    pub fn contextIsExact(self: *const Request) bool {
        return self.usage != null;
    }
};

/// A transport-independent estimate used only until the provider returns real
/// usage. JSON and tool definitions are included because they are sent too.
pub fn estimateTokens(request_bytes: usize) u64 {
    return @intCast((request_bytes + 3) / 4);
}

test "telemetry: request tracks phases, elapsed time and exact usage" {
    var req: Request = .{};
    req.begin(100, 4001);
    try std.testing.expectEqual(Phase.connecting, req.phase);
    try std.testing.expectEqual(@as(u64, 1001), req.contextTokens());
    try std.testing.expect(!req.contextIsExact());

    req.setPhase(.waiting);
    try std.testing.expectEqual(@as(u64, 900), req.elapsedMs(1000));
    req.setPhase(.streaming);
    req.usage = .{ .prompt_tokens = 1000, .completion_tokens = 25, .total_tokens = 1025 };
    try std.testing.expectEqual(@as(u64, 1025), req.contextTokens());
    try std.testing.expect(req.contextIsExact());

    req.finish(2400);
    req.setPhase(.streaming);
    try std.testing.expectEqual(Phase.idle, req.phase);
    try std.testing.expectEqual(@as(u64, 2300), req.elapsedMs(9000));
}
