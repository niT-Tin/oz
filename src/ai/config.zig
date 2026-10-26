//! AI provider configuration from the environment (M1).
//!
//! Read when the panel is opened (so a session can change env between runs,
//! and the status line can show the model). The test seam `OZ_AI_MOCK_DIR` is
//! deliberately undocumented in the README: it exists for deterministic e2e
//! tests only.
const std = @import("std");

pub const default_base_url = "http://127.0.0.1:11434/v1";
pub const default_model = "qwen2.5-coder:7b";
pub const default_system = "You are oz's AI coding assistant inside a terminal editor. Answer concisely and use Markdown.";

pub const Config = struct {
    base_url: []u8,
    model: []u8,
    api_key: ?[]u8 = null,
    system: []u8,
    /// Internal e2e seam: when set, client.zig skips HTTP and replays
    /// `<dir>/stream.sse` (see client.zig).
    mock_dir: ?[]u8 = null,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
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
    const base_raw = nonEmpty(env, "OZ_AI_BASE_URL") orelse default_base_url;
    var base = base_raw;
    while (base.len > 1 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    const model = nonEmpty(env, "OZ_AI_MODEL") orelse default_model;
    const system = nonEmpty(env, "OZ_AI_SYSTEM") orelse default_system;

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
        .base_url = base_copy,
        .model = model_copy,
        .system = system_copy,
        .api_key = api_key,
        .mock_dir = mock_dir,
    };
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
    try std.testing.expect(cfg.mock_dir == null);
}

test "config: env overrides, trailing slash and empty values" {
    const alloc = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    try map.put("OZ_AI_BASE_URL", "https://api.example.test/v1/");
    try map.put("OZ_AI_MODEL", "deepseek-chat");
    try map.put("OZ_AI_API_KEY", "sk-secret");
    try map.put("OZ_AI_SYSTEM", "");
    try map.put("OZ_AI_MOCK_DIR", "/tmp/ai-mock");
    var cfg = try fromEnv(alloc, &map);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("https://api.example.test/v1", cfg.base_url);
    try std.testing.expectEqualStrings("deepseek-chat", cfg.model);
    try std.testing.expectEqualStrings("sk-secret", cfg.api_key.?);
    // empty override falls back to the default system prompt
    try std.testing.expectEqualStrings(default_system, cfg.system);
    try std.testing.expectEqualStrings("/tmp/ai-mock", cfg.mock_dir.?);
}
