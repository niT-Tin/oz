//! AI provider configuration from the environment (M1).
//!
//! Read when the panel is opened (so a session can change env between runs,
//! and the status line can show the model). The test seam `OZ_AI_MOCK_DIR` is
//! deliberately undocumented in the README: it exists for deterministic e2e
//! tests only.
const std = @import("std");
const acp = @import("acp.zig");
const agent = @import("agent.zig");

pub const default_base_url = "http://127.0.0.1:11434/v1";
pub const default_model = "qwen2.5-coder:7b";
pub const default_system = "You are oz's AI coding assistant inside a terminal editor. Answer concisely and use Markdown.";

pub const Config = struct {
    acp_command: ?[]u8 = null,
    acp_cwd: ?[]u8 = null,
    base_url: []u8,
    model: []u8,
    api_key: ?[]u8 = null,
    system: []u8,
    /// Optional provider context-window size, used only for the UI percentage.
    /// Token counts themselves come from usage and never depend on this value.
    context_tokens: ?u32 = null,
    tool_limits: agent.Limits = .{},
    /// Internal e2e seam: when set, client.zig skips HTTP and replays
    /// `<dir>/stream.sse` (see client.zig).
    mock_dir: ?[]u8 = null,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.acp_command) |v| alloc.free(v);
        if (self.acp_cwd) |v| alloc.free(v);
        alloc.free(self.base_url);
        alloc.free(self.model);
        alloc.free(self.system);
        if (self.api_key) |k| alloc.free(k);
        if (self.mock_dir) |m| alloc.free(m);
        self.* = undefined;
    }
};

/// Parse configuration from any map-like object with `get(key) ?[]const u8`
/// (`std.process.Environ.Map`, `std.StringHashMap([]const u8)`, …).
pub fn fromEnv(alloc: std.mem.Allocator, env: anytype) !Config {
    const command_raw = nonEmpty(env, "OZ_ACP_COMMAND") orelse if (nonEmpty(env, "OZ_ACP_AGENT")) |name| try acp.preset(name) else null;
    if (command_raw) |v| try acp.validateCommand(alloc, v);
    const command = if (command_raw) |v| try alloc.dupe(u8, v) else null;
    errdefer if (command) |v| alloc.free(v);
    const cwd = if (nonEmpty(env, "OZ_ACP_CWD")) |v| try alloc.dupe(u8, v) else null;
    errdefer if (cwd) |v| alloc.free(v);
    const base_raw = nonEmpty(env, "OZ_AI_BASE_URL") orelse default_base_url;
    var base = base_raw;
    while (base.len > 1 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    const model = if (command != null) nonEmpty(env, "OZ_ACP_AGENT") orelse "ACP" else nonEmpty(env, "OZ_AI_MODEL") orelse default_model;
    const system = nonEmpty(env, "OZ_AI_SYSTEM") orelse default_system;
    const context_tokens = try parseContextTokens(env);
    const tool_limits = agent.Limits{
        .rounds = try parseLimit(env, "OZ_AI_MAX_TOOL_ROUNDS", agent.max_tool_rounds, agent.hard_max_tool_rounds),
        .calls = try parseLimit(env, "OZ_AI_MAX_TOOL_CALLS", agent.max_tool_calls_per_turn, agent.hard_max_tool_calls),
    };

    const base_copy = try alloc.dupe(u8, base);
    errdefer alloc.free(base_copy);
    const model_copy = try alloc.dupe(u8, model);
    errdefer alloc.free(model_copy);
    const system_copy = try alloc.dupe(u8, system);
    errdefer alloc.free(system_copy);
    const api_key: ?[]u8 = if (nonEmpty(env, "OZ_AI_API_KEY")) |k| try alloc.dupe(u8, k) else null;
    errdefer if (api_key) |k| alloc.free(k);
    const mock_dir: ?[]u8 = if (nonEmpty(env, "OZ_AI_MOCK_DIR")) |m| try alloc.dupe(u8, m) else null;
    errdefer if (mock_dir) |m| alloc.free(m);

    return .{
        .acp_command = command,
        .acp_cwd = cwd,
        .base_url = base_copy,
        .model = model_copy,
        .system = system_copy,
        .context_tokens = context_tokens,
        .tool_limits = tool_limits,
        .api_key = api_key,
        .mock_dir = mock_dir,
    };
}

fn parseContextTokens(env: anytype) !?u32 {
    const raw = nonEmpty(env, "OZ_AI_CONTEXT_TOKENS") orelse return null;
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidContextTokens;
    if (value == 0) return error.InvalidContextTokens;
    return value;
}

fn parseLimit(env: anytype, key: []const u8, default: u16, maximum: u16) !u16 {
    const raw = nonEmpty(env, key) orelse return default;
    const value = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidToolLimit;
    if (value == 0 or value > maximum) return error.InvalidToolLimit;
    return value;
}

fn nonEmpty(env: anytype, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    if (v.len == 0) return null;
    return v;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "config: defaults" {
    const alloc = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    var cfg = try fromEnv(alloc, &map);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings(default_base_url, cfg.base_url);
    try std.testing.expectEqualStrings(default_model, cfg.model);
    try std.testing.expectEqualStrings(default_system, cfg.system);
    try std.testing.expect(cfg.api_key == null);
    try std.testing.expect(cfg.context_tokens == null);
    try std.testing.expect(cfg.mock_dir == null);
    try std.testing.expectEqual(@as(u16, 32), cfg.tool_limits.rounds);
    try std.testing.expectEqual(@as(u16, 128), cfg.tool_limits.calls);
}

test "config: tool budgets are configurable and strictly bounded" {
    const alloc = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    try map.put("OZ_AI_MAX_TOOL_ROUNDS", "64");
    try map.put("OZ_AI_MAX_TOOL_CALLS", "512");
    var cfg = try fromEnv(alloc, &map);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 64), cfg.tool_limits.rounds);
    try std.testing.expectEqual(@as(u16, 512), cfg.tool_limits.calls);
    for ([_][]const u8{ "0", "-1", "257", "65536", "abc" }) |bad| {
        try map.put("OZ_AI_MAX_TOOL_ROUNDS", bad);
        try std.testing.expectError(error.InvalidToolLimit, fromEnv(alloc, &map));
    }
    try map.put("OZ_AI_MAX_TOOL_ROUNDS", "256");
    try map.put("OZ_AI_MAX_TOOL_CALLS", "1025");
    try std.testing.expectError(error.InvalidToolLimit, fromEnv(alloc, &map));
}

test "config: env overrides, trailing slash and empty values" {
    const alloc = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    try map.put("OZ_AI_BASE_URL", "https://api.example.test/v1/");
    try map.put("OZ_AI_MODEL", "deepseek-chat");
    try map.put("OZ_AI_API_KEY", "sk-secret");
    try map.put("OZ_AI_SYSTEM", "");
    try map.put("OZ_AI_CONTEXT_TOKENS", "128000");
    try map.put("OZ_AI_MOCK_DIR", "/tmp/ai-mock");
    var cfg = try fromEnv(alloc, &map);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("https://api.example.test/v1", cfg.base_url);
    try std.testing.expectEqualStrings("deepseek-chat", cfg.model);
    try std.testing.expectEqualStrings("sk-secret", cfg.api_key.?);
    // empty override falls back to the default system prompt
    try std.testing.expectEqualStrings(default_system, cfg.system);
    try std.testing.expectEqual(@as(?u32, 128000), cfg.context_tokens);
    try std.testing.expectEqualStrings("/tmp/ai-mock", cfg.mock_dir.?);
}

test "config: invalid context window is a visible configuration error" {
    const alloc = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    try map.put("OZ_AI_CONTEXT_TOKENS", "0");
    try std.testing.expectError(error.InvalidContextTokens, fromEnv(alloc, &map));
}

test "config: ACP presets, argv override and cwd" {
    const a = std.testing.allocator;
    var env = std.StringHashMap([]const u8).init(a);
    defer env.deinit();
    for ([_][]const u8{ "kimi", "codex", "deepseek" }) |name| {
        try env.put("OZ_ACP_AGENT", name);
        var cfg = try fromEnv(a, env);
        defer cfg.deinit(a);
        try std.testing.expectEqualStrings(try acp.preset(name), cfg.acp_command.?);
        try std.testing.expectEqualStrings(name, cfg.model);
    }
    try env.put("OZ_ACP_COMMAND", "[\"my agent\",\"--stdio\"]");
    try env.put("OZ_ACP_CWD", "/tmp/dsh source");
    var cfg = try fromEnv(a, env);
    defer cfg.deinit(a);
    try std.testing.expectEqualStrings("[\"my agent\",\"--stdio\"]", cfg.acp_command.?);
    try std.testing.expectEqualStrings("/tmp/dsh source", cfg.acp_cwd.?);
    try env.put("OZ_ACP_COMMAND", "[]");
    try std.testing.expectError(error.InvalidAcpCommand, fromEnv(a, env));
}
