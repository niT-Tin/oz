//! Thread-transcript → OpenAI request-message assembly (M3a).
//!
//! Pure and testable: this is the single mapping used for both a fresh user
//! turn and an automatic tool follow-up. Keeping it in one function is what
//! guarantees the follow-up request contains exactly the assistant
//! tool-call turn and its `role:"tool"` results the model asked for (and no
//! other thread's messages).
//!
//! Order is the transcript's order. Empty assistant placeholders (the
//! in-flight bubble) are omitted, exactly like M1; an assistant turn with
//! `tool_calls_json` is kept even when its text is empty, because OpenAI
//! requires the calls to precede their tool results.

const std = @import("std");
const openai = @import("openai.zig");
const ws = @import("workspace.zig");

pub const AssemblyError = error{ OutOfMemory, MissingToolCallId };

/// Build borrowed request messages for thread `messages`. `extra_user` (when
/// supplied) is appended as one additional user turn; slices stay owned by
/// the caller and must outlive `buildRequestBody`.
pub fn buildMessages(
    alloc: std.mem.Allocator,
    messages: []const ws.Message,
    extra_user: ?[]const u8,
) AssemblyError![]openai.Message {
    var out: std.ArrayList(openai.Message) = .empty;
    errdefer out.deinit(alloc);

    for (messages) |m| {
        switch (m.role) {
            .user => try out.append(alloc, .{ .role = "user", .content = m.api_text }),
            .assistant => {
                if (m.tool_calls_json) |calls| {
                    try out.append(alloc, .{
                        .role = "assistant",
                        .content = m.api_text,
                        .tool_calls_json = calls,
                    });
                } else if (m.text.len > 0) {
                    try out.append(alloc, .{ .role = "assistant", .content = m.api_text });
                }
            },
            .tool => {
                const id = m.tool_call_id orelse return error.MissingToolCallId;
                try out.append(alloc, .{
                    .role = "tool",
                    .content = m.api_text,
                    .tool_call_id = id,
                });
            },
        }
    }
    if (extra_user) |text| {
        try out.append(alloc, .{ .role = "user", .content = text });
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn initMessages(alloc: std.mem.Allocator) ![]ws.Message {
    var list: std.ArrayList(ws.Message) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(alloc);
        list.deinit(alloc);
    }
    try list.append(alloc, .{ .role = .user, .text = try alloc.dupe(u8, "hi"), .api_text = try alloc.dupe(u8, "ctx + hi") });
    try list.append(alloc, .{ .role = .assistant, .text = try alloc.dupe(u8, "looking"), .api_text = try alloc.dupe(u8, "looking") });
    try list.append(alloc, .{
        .role = .assistant,
        .text = try alloc.dupe(u8, ""),
        .api_text = try alloc.dupe(u8, ""),
        .tool_calls_json = try alloc.dupe(u8, "[{\"id\":\"call_1\"}]"),
    });
    try list.append(alloc, .{
        .role = .tool,
        .text = try alloc.dupe(u8, "const x = 1;"),
        .api_text = try alloc.dupe(u8, "error: nope"),
        .tool_call_id = try alloc.dupe(u8, "call_1"),
        .tool_name = try alloc.dupe(u8, "read_file"),
    });
    return list.toOwnedSlice(alloc);
}

test "turn: assembly preserves order and OpenAI tool shape" {
    const alloc = std.testing.allocator;
    const messages = try initMessages(alloc);
    defer {
        for (messages) |*m| m.deinit(alloc);
        alloc.free(messages);
    }

    const req = try buildMessages(alloc, messages, "new prompt");
    defer alloc.free(req);
    try std.testing.expectEqual(@as(usize, 5), req.len);
    try std.testing.expectEqualStrings("user", req[0].role);
    try std.testing.expectEqualStrings("ctx + hi", req[0].content);
    try std.testing.expectEqualStrings("assistant", req[1].role);
    // Empty assistant placeholder with calls is kept and keeps its calls.
    try std.testing.expectEqualStrings("assistant", req[2].role);
    try std.testing.expectEqual(@as(usize, 0), req[2].content.len);
    try std.testing.expectEqualStrings("[{\"id\":\"call_1\"}]", req[2].tool_calls_json.?);
    try std.testing.expectEqualStrings("tool", req[3].role);
    try std.testing.expectEqualStrings("call_1", req[3].tool_call_id.?);
    try std.testing.expectEqualStrings("error: nope", req[3].content);
    try std.testing.expectEqualStrings("user", req[4].role);
    try std.testing.expectEqualStrings("new prompt", req[4].content);

    const body = try openai.buildRequestBody(alloc, "m", "sys", req);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"error: nope\"") != null);
}

test "turn: empty assistant placeholders are skipped, tool ids required" {
    const alloc = std.testing.allocator;
    var msgs: std.ArrayList(ws.Message) = .empty;
    defer {
        for (msgs.items) |*m| m.deinit(alloc);
        msgs.deinit(alloc);
    }
    try msgs.append(alloc, .{ .role = .assistant, .text = try alloc.dupe(u8, ""), .api_text = try alloc.dupe(u8, "") });
    const req = try buildMessages(alloc, msgs.items, null);
    defer alloc.free(req);
    try std.testing.expectEqual(@as(usize, 0), req.len);

    try msgs.append(alloc, .{
        .role = .tool,
        .text = try alloc.dupe(u8, "x"),
        .api_text = try alloc.dupe(u8, "x"),
    });
    try std.testing.expectError(error.MissingToolCallId, buildMessages(alloc, msgs.items, null));
}
