//! OpenAI-compatible chat-completions wire format (M1 AI chat).
//!
//! Request: POST {base_url}/chat/completions with `stream: true`.
//! Response: Server-Sent Events whose `data:` payloads are JSON chunks with
//! `choices[0].delta.content` and (on the final chunk) `finish_reason`.
//! Errors: a non-2xx response usually carries `{"error":{"message":...}}`.
const std = @import("std");

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const RequestError = error{OutOfMemory};

/// Build the JSON request body. `system` is prepended as a system message
/// when non-null. Output is owned by the caller.
pub fn buildRequestBody(
    alloc: std.mem.Allocator,
    model: []const u8,
    system: ?[]const u8,
    messages: []const Message,
) RequestError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    s.beginObject() catch return error.OutOfMemory;
    s.objectField("model") catch return error.OutOfMemory;
    s.write(model) catch return error.OutOfMemory;
    s.objectField("stream") catch return error.OutOfMemory;
    s.write(true) catch return error.OutOfMemory;
    s.objectField("messages") catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
    if (system) |sys| {
        try writeMessage(&s, "system", sys);
    }
    for (messages) |m| try writeMessage(&s, m.role, m.content);
    s.endArray() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;

    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeMessage(s: *std.json.Stringify, role: []const u8, content: []const u8) RequestError!void {
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("role") catch return error.OutOfMemory;
    s.write(role) catch return error.OutOfMemory;
    s.objectField("content") catch return error.OutOfMemory;
    s.write(content) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
}

/// One streamed chunk's useful fields. Both strings are owned (null when the
/// field is absent or null).
pub const Delta = struct {
    content: ?[]u8 = null,
    finish_reason: ?[]u8 = null,

    pub fn deinit(self: *Delta, alloc: std.mem.Allocator) void {
        if (self.content) |c| alloc.free(c);
        if (self.finish_reason) |f| alloc.free(f);
        self.* = .{};
    }
};

pub const DeltaError = error{ OutOfMemory, InvalidJson };

/// Parse one `data:` JSON chunk. A syntactically valid chunk without
/// `choices[0]` returns an empty Delta (some gateways send metadata chunks).
/// Malformed JSON is an explicit error; the client ignores such events.
pub fn parseDelta(alloc: std.mem.Allocator, json: []const u8) DeltaError!Delta {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    var d: Delta = .{};
    errdefer d.deinit(alloc);
    if (parsed.value != .object) return d;

    const choices = parsed.value.object.get("choices") orelse return d;
    if (choices != .array or choices.array.items.len == 0) return d;
    const choice = choices.array.items[0];
    if (choice != .object) return d;

    if (choice.object.get("delta")) |delta| {
        if (delta == .object) {
            if (delta.object.get("content")) |content| {
                if (content == .string) {
                    if (content.string.len > 0) {
                        d.content = try alloc.dupe(u8, content.string);
                    }
                }
            }
        }
    }
    if (choice.object.get("finish_reason")) |finish| {
        if (finish == .string) {
            d.finish_reason = try alloc.dupe(u8, finish.string);
        }
    }
    return d;
}

/// Extract a human-readable message from a non-2xx response body
/// (`{"error":{"message":...}}` or a bare `{"message":...}`). Returns null
/// when the body is not a JSON error object. Caller owns the result.
pub fn parseErrorBody(alloc: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    if (root.get("error")) |err| {
        if (err == .object) {
            if (err.object.get("message")) |m| {
                if (m == .string) return try alloc.dupe(u8, std.mem.trim(u8, m.string, " \t\r\n"));
            }
        }
    }
    if (root.get("message")) |m| {
        if (m == .string) return try alloc.dupe(u8, std.mem.trim(u8, m.string, " \t\r\n"));
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "openai: request body has model, stream and messages" {
    const alloc = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "user", .content = "hi \"there\"" }};
    const body = try buildRequestBody(alloc, "qwen2.5-coder:7b", "system prompt", &msgs);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"qwen2.5-coder:7b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi \\\"there\\\"\"") != null);
    // no system prompt when null
    const body2 = try buildRequestBody(alloc, "m", null, &msgs);
    defer alloc.free(body2);
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"system\"") == null);
}

test "openai: delta content and finish_reason" {
    const alloc = std.testing.allocator;
    var d = try parseDelta(
        alloc,
        "{\"choices\":[{\"delta\":{\"content\":\"Hel\"},\"finish_reason\":null}]}",
    );
    defer d.deinit(alloc);
    try std.testing.expectEqualStrings("Hel", d.content.?);
    try std.testing.expect(d.finish_reason == null);

    var f = try parseDelta(
        alloc,
        "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
    );
    defer f.deinit(alloc);
    try std.testing.expect(f.content == null);
    try std.testing.expectEqualStrings("stop", f.finish_reason.?);
}

test "openai: delta with missing fields is empty, malformed is an error" {
    const alloc = std.testing.allocator;
    var a = try parseDelta(alloc, "{}");
    defer a.deinit(alloc);
    try std.testing.expect(a.content == null);
    var b = try parseDelta(alloc, "{\"choices\":[]}");
    defer b.deinit(alloc);
    try std.testing.expect(b.content == null);
    var c = try parseDelta(alloc, "{\"choices\":[{\"delta\":{\"content\":null}}]}");
    defer c.deinit(alloc);
    try std.testing.expect(c.content == null);
    try std.testing.expectError(error.InvalidJson, parseDelta(alloc, "{not json"));
    try std.testing.expectError(error.InvalidJson, parseDelta(alloc, ""));
}

test "openai: error body message extraction" {
    const alloc = std.testing.allocator;
    const m = (try parseErrorBody(alloc, "{\"error\":{\"message\":\"bad api key\"}}")).?;
    defer alloc.free(m);
    try std.testing.expectEqualStrings("bad api key", m);
    const m2 = (try parseErrorBody(alloc, "{\"message\":\"rate limited\"}")).?;
    defer alloc.free(m2);
    try std.testing.expectEqualStrings("rate limited", m2);
    try std.testing.expect((try parseErrorBody(alloc, "plain text")) == null);
    try std.testing.expect((try parseErrorBody(alloc, "{\"ok\":true}")) == null);
}
