//! OpenAI-compatible tool-call protocol and permission policy (M3 core).
//!
//! Pure protocol only: this module never reads a file, writes a file, runs a
//! command, or touches App/UI state. It defines the wire pieces that M3a's
//! agent loop will wire together:
//!
//!   - `tools` request definitions for read_file, list_directory, grep,
//!     edit_file, apply_patch and terminal, plus a helper that appends
//!     `tools` and `tool_choice:"auto"` to an existing
//!     `openai.buildRequestBody` object;
//!   - an accumulator for streamed `choices[0].delta.tool_calls[]` fragments
//!     (parallel calls, arbitrary argument splits, bounded buffers);
//!   - `role:"tool"` result messages with bounded, JSON-escaped content;
//!   - a deterministic permission policy (allow/confirm/deny) that never
//!     auto-allows writes or terminal access by default.
//!
//! `terminal` is advertised with a strict schema, but this module never runs
//! anything: the App stages it for explicit human approval (M3b3). Its
//! permission is always `confirm` — there is no policy switch that can
//! auto-allow shell execution. Content deltas are not accumulated here; the
//! existing `openai.parseDelta`/client path already owns that stream. The
//! accumulator only records whether text was seen alongside tool calls.
const std = @import("std");
const openai = @import("openai.zig");

/// Maximum number of parallel tool calls addressable by `index`.
pub const max_tool_calls: usize = 32;
/// Default cap for accumulated `function.arguments` JSON.
pub const max_arguments_bytes: usize = 64 * 1024;
/// Default cap for tool-result content (before JSON escaping).
pub const max_result_bytes: usize = 64 * 1024;
/// Maximum accepted tool-call id length.
pub const max_id_bytes: usize = 256;
/// Maximum accepted function-name length.
pub const max_name_bytes: usize = 128;
/// Maximum accepted SSE data payload parsed per `feedChunk` call.
pub const max_chunk_bytes: usize = 512 * 1024;

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub const Kind = enum {
    read_file,
    list_directory,
    grep,
    edit_file,
    apply_patch,
    /// M3b3: one non-interactive shell command. Always staged for explicit
    /// human approval; never auto-allowed.
    terminal,
};

pub const Definition = struct {
    kind: Kind,
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the function parameters. Embedded verbatim in the
    /// request so the model sees exactly what `validate` will expect later.
    parameters_json: []const u8,
};

const read_file_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path, absolute or relative to the workspace root."
    \\    },
    \\    "start_line": {
    \\      "type": "integer",
    \\      "minimum": 1,
    \\      "description": "First line to read, 1-based and inclusive. Omit to start at line 1."
    \\    },
    \\    "end_line": {
    \\      "type": "integer",
    \\      "minimum": 1,
    \\      "description": "Last line to read, 1-based and inclusive. Omit to read to end of file."
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
;

const list_directory_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Directory path, absolute or relative to the workspace root."
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
;

const grep_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Literal substring to search for (case-sensitive; not a regular expression)."
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File or directory to search. Omit to search the workspace root."
    \\    },
    \\    "glob": {
    \\      "type": "string",
    \\      "description": "Optional glob restricting which files are searched, for example \"**/*.zig\"."
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
;

const edit_file_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path, absolute or relative to the workspace root."
    \\    },
    \\    "old_string": {
    \\      "type": "string",
    \\      "minLength": 1,
    \\      "description": "Exact text to replace, including indentation."
    \\    },
    \\    "new_string": {
    \\      "type": "string",
    \\      "description": "Replacement text. An empty string deletes old_string."
    \\    },
    \\    "replace_all": {
    \\      "type": "boolean",
    \\      "description": "Replace every exact occurrence instead of only the first."
    \\    }
    \\  },
    \\  "required": ["path", "old_string", "new_string"]
    \\}
;

const apply_patch_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "patch": {
    \\      "type": "string",
    \\      "minLength": 1,
    \\      "description": "Unified diff text for 1-8 modified files (back-to-back diff --git/---/+++ sections), with optional git-style headers and @@ hunks; paths are relative to the workspace root. Add/delete, binary, rename/copy and mode changes are rejected."
    \\    }
    \\  },
    \\  "required": ["patch"]
    \\}
;

const terminal_parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "minLength": 1,
    \\      "description": "Shell command (executed verbatim by /bin/sh -c in the workspace root)."
    \\    },
    \\    "timeout_ms": {
    \\      "type": "integer",
    \\      "minimum": 100,
    \\      "maximum": 10000,
    \\      "description": "Wall-clock limit in milliseconds; 100-10000. Omit for 5000."
    \\    }
    \\  },
    \\  "required": ["command"],
    \\  "additionalProperties": false
    \\}
;

/// Tools advertised to the model. Order is deterministic; `tools` JSON is
/// built from this array in the same order.
pub const definitions = [_]Definition{
    .{
        .kind = .read_file,
        .name = "read_file",
        .description = "Read a text file, optionally limited to a 1-based inclusive line range.",
        .parameters_json = read_file_parameters,
    },
    .{
        .kind = .list_directory,
        .name = "list_directory",
        .description = "List the immediate entries of a directory.",
        .parameters_json = list_directory_parameters,
    },
    .{
        .kind = .grep,
        .name = "grep",
        .description = "Search file contents with a literal, case-sensitive substring, optionally restricted by path and glob.",
        .parameters_json = grep_parameters,
    },
    .{
        .kind = .edit_file,
        .name = "edit_file",
        .description = "Replace an exact string in a file with new text. Requires user confirmation by default.",
        .parameters_json = edit_file_parameters,
    },
    .{
        .kind = .apply_patch,
        .name = "apply_patch",
        .description = "Apply a unified diff patch to 1-8 modified files. Requires user confirmation by default; multi-file sets are reviewed and written together (all-or-nothing validation).",
        .parameters_json = apply_patch_parameters,
    },
    .{
        .kind = .terminal,
        .name = "terminal",
        .description = "Run ONE shell command with the user's own permissions in the workspace root. Requires explicit user approval before it runs; never executes automatically. Not sandboxed and not network-restricted. Combined output is capped at 64 KiB and runtime at 100-10000 ms (process group killed on timeout).",
        .parameters_json = terminal_parameters,
    },
};

/// Resolve an exact tool name. Unknown names return null.
pub fn definition(name: []const u8) ?Definition {
    for (definitions) |def| {
        if (std.mem.eql(u8, def.name, name)) return def;
    }
    return null;
}

/// Classify an exact tool name. Unknown names return null (denied by policy).
pub fn classify(name: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) return @field(Kind, field_name);
    }
    return null;
}

pub const JsonError = error{OutOfMemory};

/// Build the OpenAI `tools` array:
/// `[{"type":"function","function":{...}}]`. Caller owns the result.
pub fn buildToolsJson(alloc: std.mem.Allocator) JsonError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    s.beginArray() catch return error.OutOfMemory;
    for (definitions) |def| {
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("type") catch return error.OutOfMemory;
        s.write("function") catch return error.OutOfMemory;
        s.objectField("function") catch return error.OutOfMemory;
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(def.name) catch return error.OutOfMemory;
        s.objectField("description") catch return error.OutOfMemory;
        s.write(def.description) catch return error.OutOfMemory;
        s.objectField("parameters") catch return error.OutOfMemory;
        s.beginWriteRaw() catch return error.OutOfMemory;
        s.writer.writeAll(def.parameters_json) catch return error.OutOfMemory;
        s.endWriteRaw();
        s.endObject() catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Request-body composition
// ---------------------------------------------------------------------------

pub const RequestError = error{ OutOfMemory, NotJsonObject };

/// Append `tools` and `tool_choice:"auto"` to an existing JSON object. This
/// composes with `openai.buildRequestBody` without re-parsing it: the final
/// `}` is replaced with the new fields. Only a top-level object is accepted;
/// the body is otherwise assumed to be valid JSON (it normally comes from
/// `openai.buildRequestBody`). Derived output is owned by the caller.
pub fn appendTools(alloc: std.mem.Allocator, body: []const u8) RequestError![]u8 {
    const open = std.mem.indexOfScalar(u8, body, '{') orelse return error.NotJsonObject;
    if (std.mem.trim(u8, body[0..open], " \t\r\n").len != 0) return error.NotJsonObject;

    var end = body.len;
    while (end > open and isJsonWhitespace(body[end - 1])) end -= 1;
    if (end == 0 or body[end - 1] != '}') return error.NotJsonObject;
    const close = end - 1;

    const needs_comma = std.mem.trim(u8, body[open + 1 .. close], " \t\r\n").len != 0;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, body[0..close]);
    if (needs_comma) try out.append(alloc, ',');
    try out.appendSlice(alloc, "\"tools\":");
    const tools_json = try buildToolsJson(alloc);
    defer alloc.free(tools_json);
    try out.appendSlice(alloc, tools_json);
    try out.appendSlice(alloc, ",\"tool_choice\":\"auto\"}");
    return out.toOwnedSlice(alloc);
}

/// Compose `openai.buildRequestBody` with the tool fields. The returned body
/// is owned by the caller; the base body is freed internally.
pub fn buildRequestBodyWithTools(
    alloc: std.mem.Allocator,
    model: []const u8,
    system: ?[]const u8,
    messages: []const openai.Message,
) RequestError![]u8 {
    const base = try openai.buildRequestBody(alloc, model, system, messages);
    defer alloc.free(base);
    return appendTools(alloc, base);
}

fn isJsonWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---------------------------------------------------------------------------
// Streaming tool-call accumulation
// ---------------------------------------------------------------------------

pub const FinishReason = enum { stop, length, tool_calls, content_filter, function_call, unknown };

pub const ToolCall = struct {
    /// Owned; free with `deinit` (or `freeCalls`).
    id: []u8,
    name: []u8,
    /// Validated JSON serialization of the function arguments.
    arguments_json: []u8,

    pub fn deinit(self: ToolCall, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.arguments_json);
    }
};

/// Free every call's strings plus the call slice itself.
pub fn freeCalls(alloc: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| call.deinit(alloc);
    alloc.free(calls);
}

/// Serialize an assistant turn's tool calls for the OpenAI wire format:
/// `[{"id":"call_1","type":"function","function":{"name":...,"arguments":"{...}"}}]`.
/// `arguments_json` stays a JSON *string* (the provider's encoding); the
/// caller stores the result on the assistant message so a follow-up request
/// can reference exactly the `tool_call_id`s its results answer.
pub fn buildAssistantToolCallsJson(
    alloc: std.mem.Allocator,
    calls: []const ToolCall,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    s.beginArray() catch return error.OutOfMemory;
    for (calls) |call| {
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("id") catch return error.OutOfMemory;
        s.write(call.id) catch return error.OutOfMemory;
        s.objectField("type") catch return error.OutOfMemory;
        s.write("function") catch return error.OutOfMemory;
        s.objectField("function") catch return error.OutOfMemory;
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(call.name) catch return error.OutOfMemory;
        s.objectField("arguments") catch return error.OutOfMemory;
        s.write(call.arguments_json) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

pub const AccumulateError = error{
    OutOfMemory,
    InvalidJson,
    ChunkTooLarge,
    InvalidToolCalls,
    MissingIndex,
    InvalidIndex,
    IndexOutOfRange,
    InvalidId,
    IdTooLong,
    DuplicateId,
    UnsupportedType,
    InvalidFunction,
    InvalidFunctionName,
    NameTooLong,
    NameConflict,
    InvalidArgumentsFragment,
    ArgumentsTooLong,
};

pub const FinalizeError = error{
    OutOfMemory,
    MissingId,
    MissingName,
    ArgumentsTooLong,
    InvalidArgumentsJson,
    ArgumentsNotObject,
};

const Slot = struct {
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    saw_entry: bool = false,

    fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
        self.arguments.deinit(alloc);
        self.* = .{};
    }
};

/// Incremental accumulator for one streamed assistant turn. Feed each SSE
/// `data:` JSON payload (after `sse.Parser` and without the `[DONE]` marker),
/// then call `finalize` when the stream ends.
pub const Accumulator = struct {
    alloc: std.mem.Allocator,
    slots: [max_tool_calls]?Slot = @splat(null),
    finish_reason: ?FinishReason = null,
    saw_text: bool = false,

    /// Per-instance bounds, so tests (and later callers) can tighten them.
    arguments_limit: usize = max_arguments_bytes,
    id_limit: usize = max_id_bytes,
    name_limit: usize = max_name_bytes,
    chunk_limit: usize = max_chunk_bytes,

    pub fn init(alloc: std.mem.Allocator) Accumulator {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Accumulator) void {
        for (&self.slots) |*slot| {
            if (slot.*) |*s| s.deinit(self.alloc);
            slot.* = null;
        }
        self.slots = @splat(null);
    }

    /// Parse one chunk. Metadata chunks without `choices[0]` are ignored.
    /// Unknown fields are ignored; malformed tool-call fields are typed
    /// errors. An error may leave earlier fragments in place; the caller
    /// should discard the accumulator/turn.
    pub fn feedChunk(self: *Accumulator, json: []const u8) AccumulateError!void {
        if (json.len > self.chunk_limit) return error.ChunkTooLarge;

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const choices = parsed.value.object.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return;

        if (choice.object.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("content")) |content| {
                    if (content == .string and content.string.len > 0) self.saw_text = true;
                }
                if (delta.object.get("tool_calls")) |calls| {
                    if (calls == .array) {
                        for (calls.array.items) |entry| try self.applyEntry(entry);
                    } else if (calls != .null) {
                        return error.InvalidToolCalls;
                    }
                }
            }
        }
        if (choice.object.get("finish_reason")) |finish| {
            if (finish == .string) self.finish_reason = parseFinishReason(finish.string);
        }
    }

    /// Number of index slots that have received at least one entry.
    pub fn callCount(self: *const Accumulator) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.*) |s| {
                if (s.saw_entry) count += 1;
            }
        }
        return count;
    }

    pub fn hasToolCalls(self: *const Accumulator) bool {
        return self.callCount() > 0;
    }

    pub fn finishReason(self: *const Accumulator) ?FinishReason {
        return self.finish_reason;
    }

    /// True when at least one non-empty `delta.content` was seen.
    pub fn sawText(self: *const Accumulator) bool {
        return self.saw_text;
    }

    /// Produce owned calls ordered by `index`. Empty/whitespace arguments are
    /// normalized to `{}`; every other arguments value must be a JSON object.
    /// The accumulator keeps its fragments, so finalize is repeatable but
    /// each call returns fresh owned memory.
    pub fn finalize(self: *Accumulator) FinalizeError![]ToolCall {
        const calls = try self.alloc.alloc(ToolCall, self.callCount());
        var filled: usize = 0;
        errdefer {
            for (calls[0..filled]) |call| call.deinit(self.alloc);
            self.alloc.free(calls);
        }

        for (&self.slots) |*slot| {
            const s = if (slot.*) |*s| s else continue;
            if (!s.saw_entry) continue;

            const id = s.id orelse return error.MissingId;
            if (id.len == 0) return error.MissingId;
            const name = s.name orelse return error.MissingName;
            if (name.len == 0) return error.MissingName;

            const trimmed = std.mem.trim(u8, s.arguments.items, " \t\r\n");
            const arguments_json = if (trimmed.len == 0) "{}" else trimmed;
            if (arguments_json.len > self.arguments_limit) return error.ArgumentsTooLong;
            try validateArgumentsJson(self.alloc, arguments_json);

            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            const owned_name = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(owned_name);
            const owned_arguments = try self.alloc.dupe(u8, arguments_json);
            errdefer self.alloc.free(owned_arguments);

            calls[filled] = .{
                .id = owned_id,
                .name = owned_name,
                .arguments_json = owned_arguments,
            };
            filled += 1;
        }
        return calls;
    }

    fn applyEntry(self: *Accumulator, entry: std.json.Value) AccumulateError!void {
        if (entry != .object) return error.InvalidToolCalls;
        const obj = entry.object;

        const index_value = obj.get("index") orelse return error.MissingIndex;
        if (index_value != .integer or index_value.integer < 0) return error.InvalidIndex;
        if (index_value.integer >= max_tool_calls) return error.IndexOutOfRange;
        const index: usize = @intCast(index_value.integer);

        if (self.slots[index] == null) self.slots[index] = .{};
        const slot = &self.slots[index].?;
        slot.saw_entry = true;

        if (obj.get("id")) |id_value| {
            switch (id_value) {
                .null => {},
                .string => |id| try self.setId(index, slot, id),
                else => return error.InvalidId,
            }
        }

        if (obj.get("type")) |type_value| {
            switch (type_value) {
                .null => {},
                .string => |type_name| {
                    if (!std.mem.eql(u8, type_name, "function")) return error.UnsupportedType;
                },
                else => return error.UnsupportedType,
            }
        }

        if (obj.get("function")) |function_value| {
            switch (function_value) {
                .null => {},
                .object => |function| {
                    if (function.get("name")) |name_value| {
                        switch (name_value) {
                            .null => {},
                            .string => |name| try self.setName(slot, name),
                            else => return error.InvalidFunctionName,
                        }
                    }
                    if (function.get("arguments")) |arguments_value| {
                        switch (arguments_value) {
                            .null => {},
                            .string => |fragment| try self.appendArguments(slot, fragment),
                            else => return error.InvalidArgumentsFragment,
                        }
                    }
                },
                else => return error.InvalidFunction,
            }
        }
    }

    fn setId(self: *Accumulator, index: usize, slot: *Slot, id: []const u8) AccumulateError!void {
        // An empty id fragment is treated as absent; finalize reports it as
        // MissingId if no non-empty id ever arrives.
        if (id.len == 0) return;
        if (id.len > self.id_limit) return error.IdTooLong;
        if (slot.id != null) return error.DuplicateId;

        for (&self.slots, 0..) |*other_slot, other_index| {
            if (other_index == index) continue;
            if (other_slot.*) |other| {
                if (other.id) |existing| {
                    if (std.mem.eql(u8, existing, id)) return error.DuplicateId;
                }
            }
        }
        slot.id = try self.alloc.dupe(u8, id);
    }

    fn setName(self: *Accumulator, slot: *Slot, name: []const u8) AccumulateError!void {
        if (name.len == 0) return;
        if (name.len > self.name_limit) return error.NameTooLong;
        if (slot.name) |existing| {
            // Some gateways repeat the same full name; tolerate that, but a
            // different name for the same index is a protocol error.
            if (std.mem.eql(u8, existing, name)) return;
            return error.NameConflict;
        }
        slot.name = try self.alloc.dupe(u8, name);
    }

    fn appendArguments(self: *Accumulator, slot: *Slot, fragment: []const u8) AccumulateError!void {
        if (fragment.len == 0) return;
        if (fragment.len > self.arguments_limit -| slot.arguments.items.len) {
            return error.ArgumentsTooLong;
        }
        try slot.arguments.appendSlice(self.alloc, fragment);
    }
};

fn parseFinishReason(raw: []const u8) FinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, raw, "function_call")) return .function_call;
    return .unknown;
}

fn validateArgumentsJson(alloc: std.mem.Allocator, arguments_json: []const u8) FinalizeError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArgumentsJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.ArgumentsNotObject;
}

// ---------------------------------------------------------------------------
// Tool result messages
// ---------------------------------------------------------------------------

pub const ToolResult = struct {
    output: []const u8 = "",
    /// Mark the content with an `error:` prefix. The text is still bounded and
    /// JSON-escaped exactly like a normal result.
    is_error: bool = false,
};

pub const ToolMessageOptions = struct {
    /// Hard cap on result content before JSON escaping; clamped to
    /// `[32, max_result_bytes]`.
    max_content_bytes: usize = max_result_bytes,
};

pub const ToolMessageError = error{ OutOfMemory, InvalidToolCallId };

/// Build `{"role":"tool","tool_call_id":...,"content":...}`. Caller owns the
/// result.
pub fn buildToolResultMessage(
    alloc: std.mem.Allocator,
    tool_call_id: []const u8,
    result: ToolResult,
) ToolMessageError![]u8 {
    return buildToolResultMessageWith(alloc, tool_call_id, result, .{});
}

pub fn buildToolResultMessageWith(
    alloc: std.mem.Allocator,
    tool_call_id: []const u8,
    result: ToolResult,
    options: ToolMessageOptions,
) ToolMessageError![]u8 {
    if (tool_call_id.len == 0 or tool_call_id.len > max_id_bytes) return error.InvalidToolCallId;
    if (!std.unicode.utf8ValidateSlice(tool_call_id)) return error.InvalidToolCallId;

    const content = try buildToolResultContentWith(alloc, result, options);
    defer alloc.free(content);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("role") catch return error.OutOfMemory;
    s.write("tool") catch return error.OutOfMemory;
    s.objectField("tool_call_id") catch return error.OutOfMemory;
    s.write(tool_call_id) catch return error.OutOfMemory;
    s.objectField("content") catch return error.OutOfMemory;
    s.write(content) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Build the bounded, UTF-8-safe `content` string for a `role:"tool"`
/// message. Errors keep an `error: ` prefix; truncation appends the shared
/// marker. Caller owns the result. Exposed so the agent loop can store the
/// exact bytes it will later send, and so display code never re-derives a
/// different truncation.
pub fn buildToolResultContent(
    alloc: std.mem.Allocator,
    result: ToolResult,
    options: ToolMessageOptions,
) error{OutOfMemory}![]u8 {
    return buildToolResultContentWith(alloc, result, options);
}

fn buildToolResultContentWith(
    alloc: std.mem.Allocator,
    result: ToolResult,
    options: ToolMessageOptions,
) error{OutOfMemory}![]u8 {
    const cap = @min(@max(options.max_content_bytes, 32), max_result_bytes);
    const marker = "\n… [truncated]";
    const budget = cap -| marker.len;

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    try content.ensureTotalCapacity(alloc, cap);

    if (result.is_error) {
        const prefix = "error: ";
        _ = try appendBounded(&content, alloc, prefix, budget);
    }
    const truncated = try appendLossyBounded(&content, alloc, result.output, budget);
    if (truncated and content.items.len + marker.len <= cap) {
        try content.appendSlice(alloc, marker);
    }
    return content.toOwnedSlice(alloc);
}

/// Append ASCII-ish prefix text, never exceeding `budget`.
fn appendBounded(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    text: []const u8,
    budget: usize,
) error{OutOfMemory}!bool {
    const room = budget -| out.items.len;
    if (text.len <= room) {
        try out.appendSlice(alloc, text);
        return false;
    }
    try out.appendSlice(alloc, text[0..room]);
    return true;
}

/// Append `input` as valid UTF-8, replacing invalid encoding with U+FFFD and
/// stopping at `budget` bytes. Returns true when some input was not appended.
fn appendLossyBounded(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    input: []const u8,
    budget: usize,
) error{OutOfMemory}!bool {
    const replacement = "\u{FFFD}";
    var i: usize = 0;
    while (i < input.len) {
        if (out.items.len >= budget) return true;
        const first = input[i];
        if (first < 0x80) {
            try out.append(alloc, first);
            i += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
            if (out.items.len + replacement.len > budget) return true;
            try out.appendSlice(alloc, replacement);
            i += 1;
            continue;
        };
        const len: usize = sequence_len;
        if (i + len > input.len or !std.unicode.utf8ValidateSlice(input[i .. i + len])) {
            if (out.items.len + replacement.len > budget) return true;
            try out.appendSlice(alloc, replacement);
            i += 1;
            continue;
        }
        if (out.items.len + len > budget) return true;
        try out.appendSlice(alloc, input[i .. i + len]);
        i += len;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Permission policy
// ---------------------------------------------------------------------------

pub const Permission = enum { allow, confirm, deny };

pub const Policy = struct {
    /// Read-only tools (read_file/list_directory/grep) are auto-allowed.
    allow_reads: bool = true,
    /// Mutating tools (edit_file/apply_patch) still require confirmation.
    allow_writes: bool = false,
};

pub const default_policy: Policy = .{};

/// Conservative, deterministic decision for one tool call. Unknown tool names
/// are denied. `arguments_json` is accepted for a later path/command-rule
/// layer; the current default policy classifies only by exact tool name, so a
/// malformed or hostile argument blob can never upgrade a decision.
pub fn decide(tool_name: []const u8, arguments_json: []const u8) Permission {
    return decideWith(default_policy, tool_name, arguments_json);
}

pub fn decideWith(policy: Policy, tool_name: []const u8, arguments_json: []const u8) Permission {
    _ = arguments_json;
    const kind = classify(tool_name) orelse return .deny;
    return switch (kind) {
        .read_file, .list_directory, .grep => if (policy.allow_reads) .allow else .confirm,
        .edit_file, .apply_patch => if (policy.allow_writes) .allow else .confirm,
        // No policy switch can auto-allow shell execution: terminal is
        // confirm (human allow) or deny (unknown names) only.
        .terminal => .confirm,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestCall = struct {
    index: u32,
    id: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

/// Build a realistic streaming chunk for tests. Field omission matches what
/// OpenAI-compatible servers actually send across fragments.
fn makeChunk(
    alloc: std.mem.Allocator,
    text: ?[]const u8,
    calls: []const TestCall,
    finish: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try s.beginObject();
    try s.objectField("choices");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("delta");
    try s.beginObject();
    if (text) |t| {
        try s.objectField("content");
        try s.write(t);
    }
    if (calls.len > 0) {
        try s.objectField("tool_calls");
        try s.beginArray();
        for (calls) |call| {
            try s.beginObject();
            try s.objectField("index");
            try s.write(call.index);
            if (call.id) |id| {
                try s.objectField("id");
                try s.write(id);
            }
            if (call.type_name) |type_name| {
                try s.objectField("type");
                try s.write(type_name);
            }
            if (call.name != null or call.arguments != null) {
                try s.objectField("function");
                try s.beginObject();
                if (call.name) |name| {
                    try s.objectField("name");
                    try s.write(name);
                }
                if (call.arguments) |arguments| {
                    try s.objectField("arguments");
                    try s.write(arguments);
                }
                try s.endObject();
            }
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
    try s.objectField("finish_reason");
    if (finish) |f| try s.write(f) else try s.write(null);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    return try out.toOwnedSlice();
}

fn feedOne(
    acc: *Accumulator,
    alloc: std.mem.Allocator,
    text: ?[]const u8,
    calls: []const TestCall,
    finish: ?[]const u8,
) !void {
    const chunk = try makeChunk(alloc, text, calls, finish);
    defer alloc.free(chunk);
    try acc.feedChunk(chunk);
}

fn jsonObjectField(value: std.json.Value, field: []const u8) std.json.Value {
    return value.object.get(field).?;
}

test "tools: definitions produce valid OpenAI tools JSON" {
    const alloc = std.testing.allocator;
    const json = try buildToolsJson(alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    const tools = parsed.value.array.items;
    try std.testing.expectEqual(definitions.len, tools.len);

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (tools, 0..) |tool, i| {
        try std.testing.expect(tool == .object);
        try std.testing.expectEqualStrings("function", tool.object.get("type").?.string);

        const function = tool.object.get("function").?;
        try std.testing.expect(function == .object);
        try std.testing.expectEqualStrings(definitions[i].name, function.object.get("name").?.string);
        try std.testing.expect(function.object.get("description").?.string.len > 0);
        try std.testing.expect(seen.get(definitions[i].name) == null);
        try seen.put(definitions[i].name, {});

        const parameters = function.object.get("parameters").?;
        try std.testing.expect(parameters == .object);
        try std.testing.expectEqualStrings("object", parameters.object.get("type").?.string);
        try std.testing.expect(parameters.object.get("properties").? == .object);
        try std.testing.expect(parameters.object.get("required").? == .array);
    }

    // Every embedded schema is independently parseable.
    for (definitions) |def| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, def.parameters_json, .{ .allocate = .alloc_always });
        defer schema.deinit();
        try std.testing.expect(schema.value == .object);
        try std.testing.expectEqualStrings("object", schema.value.object.get("type").?.string);
    }
}

test "tools: lookup, classification and terminal definition" {
    try std.testing.expectEqual(Kind.read_file, definition("read_file").?.kind);
    try std.testing.expectEqual(Kind.apply_patch, definition("apply_patch").?.kind);
    try std.testing.expectEqual(Kind.terminal, definition("terminal").?.kind);
    try std.testing.expect(definition("nope") == null);
    try std.testing.expectEqual(Kind.terminal, classify("terminal").?);
    try std.testing.expectEqual(Kind.grep, classify("grep").?);
    try std.testing.expect(classify("Grep") == null);

    // The terminal schema is strict and bounded; the model gets exactly the
    // command/timeout contract the App validates before staging.
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, definition("terminal").?.parameters_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("object", obj.get("type").?.string);
    try std.testing.expect(obj.get("additionalProperties").?.bool == false);
    const props = obj.get("properties").?.object;
    try std.testing.expect(props.get("command") != null);
    const timeout = props.get("timeout_ms").?.object;
    try std.testing.expectEqualStrings("integer", timeout.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 100), timeout.get("minimum").?.integer);
    try std.testing.expectEqual(@as(i64, 10000), timeout.get("maximum").?.integer);
    try std.testing.expectEqual(@as(usize, 1), obj.get("required").?.array.items.len);
}

test "tools: appendTools composes with openai request bodies" {
    const alloc = std.testing.allocator;
    const messages = [_]openai.Message{.{ .role = "user", .content = "read src/main.zig" }};
    const base = try openai.buildRequestBody(alloc, "qwen2.5-coder:7b", "system", &messages);
    defer alloc.free(base);

    const body = try appendTools(alloc, base);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);
    try std.testing.expectEqualStrings("qwen2.5-coder:7b", root.object.get("model").?.string);
    try std.testing.expect(root.object.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 2), root.object.get("messages").?.array.items.len);
    try std.testing.expectEqual(@as(usize, definitions.len), root.object.get("tools").?.array.items.len);
    try std.testing.expectEqualStrings("auto", root.object.get("tool_choice").?.string);

    const built = try buildRequestBodyWithTools(alloc, "m", null, &messages);
    defer alloc.free(built);
    var parsed_built = try std.json.parseFromSlice(std.json.Value, alloc, built, .{ .allocate = .alloc_always });
    defer parsed_built.deinit();
    try std.testing.expectEqual(@as(usize, definitions.len), parsed_built.value.object.get("tools").?.array.items.len);
}

test "tools: appendTools accepts only a JSON object" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NotJsonObject, appendTools(alloc, ""));
    try std.testing.expectError(error.NotJsonObject, appendTools(alloc, "[]"));
    try std.testing.expectError(error.NotJsonObject, appendTools(alloc, "null"));
    try std.testing.expectError(error.NotJsonObject, appendTools(alloc, "{\"a\":1"));
    try std.testing.expectError(error.NotJsonObject, appendTools(alloc, "x{}"));

    const empty = try appendTools(alloc, "  {}  ");
    defer alloc.free(empty);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, empty, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, definitions.len), parsed.value.object.get("tools").?.array.items.len);
    try std.testing.expectEqualStrings("auto", parsed.value.object.get("tool_choice").?.string);
}

test "tools: accumulates one call across fragments" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .type_name = "function", .name = "read_file", .arguments = "{\"path\":" }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = "\"src/main.zig\"" }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = ",\"start_line\":1}" }}, "tool_calls");

    try std.testing.expect(acc.hasToolCalls());
    try std.testing.expectEqual(@as(usize, 1), acc.callCount());
    try std.testing.expectEqual(FinishReason.tool_calls, acc.finishReason().?);

    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_0", calls[0].id);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\",\"start_line\":1}", calls[0].arguments_json);
}

test "tools: parallel calls accumulate by index and finalize in order" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    const args0 = "{\"path\":\"a.zig\"}";
    const args1 = "{\"path\":\"b\"}";

    try feedOne(&acc, alloc, "I will inspect both.", &.{.{ .index = 0, .id = "call_0", .type_name = "function", .name = "read_file", .arguments = args0[0..5] }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 1, .id = "call_1", .type_name = "function", .name = "list_directory", .arguments = args1[0..5] }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = args0[5..] }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 1, .arguments = args1[5..] }}, "tool_calls");

    try std.testing.expect(acc.sawText());
    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("call_0", calls[0].id);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings(args0, calls[0].arguments_json);
    try std.testing.expectEqualStrings("call_1", calls[1].id);
    try std.testing.expectEqualStrings("list_directory", calls[1].name);
    try std.testing.expectEqualStrings(args1, calls[1].arguments_json);
}

test "tools: arguments split at every byte boundary" {
    const alloc = std.testing.allocator;
    const args = "{\"path\":\"src/main.zig\",\"start_line\":1,\"end_line\":5}";
    var split: usize = 0;
    while (split <= args.len) : (split += 1) {
        var acc = Accumulator.init(alloc);
        defer acc.deinit();

        try feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .type_name = "function", .name = "read_file", .arguments = args[0..split] }}, null);
        try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = args[split..] }}, "tool_calls");

        const calls = try acc.finalize();
        defer freeCalls(alloc, calls);
        try std.testing.expectEqual(@as(usize, 1), calls.len);
        try std.testing.expectEqualStrings("read_file", calls[0].name);
        try std.testing.expectEqualStrings(args, calls[0].arguments_json);
    }
}

test "tools: arguments split inside JSON escape sequences" {
    const alloc = std.testing.allocator;
    const args = "{\"path\":\"a.zig\",\"old_string\":\"x\",\"new_string\":\"line\\n\\\"quoted\\\" \\\\ end\"}";
    var split: usize = 0;
    while (split <= args.len) : (split += 1) {
        var acc = Accumulator.init(alloc);
        defer acc.deinit();

        try feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .type_name = "function", .name = "edit_file", .arguments = args[0..split] }}, null);
        try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = args[split..] }}, "tool_calls");

        const calls = try acc.finalize();
        defer freeCalls(alloc, calls);
        try std.testing.expectEqual(@as(usize, 1), calls.len);
        try std.testing.expectEqualStrings(args, calls[0].arguments_json);
        // The parsed argument text preserves the intended escape sequences.
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, calls[0].arguments_json, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("line\n\"quoted\" \\ end", parsed.value.object.get("new_string").?.string);
    }
}

test "tools: multiple calls in one chunk, including out-of-order entries" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    try feedOne(&acc, alloc, null, &.{
        .{ .index = 1, .id = "call_1", .type_name = "function", .name = "grep", .arguments = "{\"pattern\":\"TODO\"}" },
        .{ .index = 0, .id = "call_0", .type_name = "function", .name = "read_file", .arguments = "{\"path\":\"a\"}" },
    }, "tool_calls");

    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings("grep", calls[1].name);
}

test "tools: optional index gaps, repeated name and empty arguments" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    try feedOne(&acc, alloc, null, &.{.{ .index = 2, .id = "call_2", .type_name = "function", .name = "read_file" }}, null);
    try feedOne(&acc, alloc, null, &.{.{ .index = 2, .name = "read_file" }}, "tool_calls");

    try std.testing.expectEqual(@as(usize, 1), acc.callCount());
    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_2", calls[0].id);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings("{}", calls[0].arguments_json);
}

test "tools: normal text-only stream finalizes to no calls" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();
    try feedOne(&acc, alloc, "hello", &.{}, null);
    try feedOne(&acc, alloc, null, &.{}, "stop");
    try std.testing.expect(acc.sawText());
    try std.testing.expect(!acc.hasToolCalls());
    try std.testing.expectEqual(FinishReason.stop, acc.finishReason().?);
    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "tools: unknown finish reasons are tolerated" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();
    try feedOne(&acc, alloc, null, &.{}, "something_new");
    try std.testing.expectEqual(FinishReason.unknown, acc.finishReason().?);
    // Wrongly typed finish_reason is ignored rather than aborting the stream.
    try acc.feedChunk("{\"choices\":[{\"delta\":{},\"finish_reason\":7}]}");
    try std.testing.expectEqual(FinishReason.unknown, acc.finishReason().?);
}

test "tools: missing id or name is a finalize error" {
    const alloc = std.testing.allocator;

    var no_id = Accumulator.init(alloc);
    defer no_id.deinit();
    try feedOne(&no_id, alloc, null, &.{.{ .index = 0, .name = "read_file", .arguments = "{}" }}, "tool_calls");
    try std.testing.expectError(error.MissingId, no_id.finalize());

    var empty_id = Accumulator.init(alloc);
    defer empty_id.deinit();
    try feedOne(&empty_id, alloc, null, &.{.{ .index = 0, .id = "", .name = "read_file", .arguments = "{}" }}, "tool_calls");
    try std.testing.expectError(error.MissingId, empty_id.finalize());

    var no_name = Accumulator.init(alloc);
    defer no_name.deinit();
    try feedOne(&no_name, alloc, null, &.{.{ .index = 0, .id = "call_0", .arguments = "{}" }}, "tool_calls");
    try std.testing.expectError(error.MissingName, no_name.finalize());
}

test "tools: duplicate ids are rejected" {
    const alloc = std.testing.allocator;

    var same_slot = Accumulator.init(alloc);
    defer same_slot.deinit();
    try feedOne(&same_slot, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file" }}, null);
    try std.testing.expectError(error.DuplicateId, feedOne(&same_slot, alloc, null, &.{.{ .index = 0, .id = "call_0" }}, null));

    var other_slot = Accumulator.init(alloc);
    defer other_slot.deinit();
    try feedOne(&other_slot, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file" }}, null);
    try std.testing.expectError(error.DuplicateId, feedOne(&other_slot, alloc, null, &.{.{ .index = 1, .id = "call_0", .name = "grep" }}, null));
}

test "tools: conflicting names are rejected, identical repeats accepted" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file" }}, null);
    try std.testing.expectError(error.NameConflict, feedOne(&acc, alloc, null, &.{.{ .index = 0, .name = "grep" }}, null));
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .name = "read_file", .arguments = "{}" }}, "tool_calls");
}

test "tools: malformed call fields are typed errors" {
    const alloc = std.testing.allocator;

    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    try std.testing.expectError(error.InvalidJson, acc.feedChunk("{not json"));
    try std.testing.expectError(error.MissingIndex, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"x\"}]}}]}"));
    try std.testing.expectError(error.InvalidIndex, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-1}]}}]}"));
    try std.testing.expectError(error.IndexOutOfRange, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":32}]}}]}"));
    try std.testing.expectError(error.UnsupportedType, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"custom\"}]}}]}"));
    try std.testing.expectError(error.UnsupportedType, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":7}]}}]}"));
    try std.testing.expectError(error.InvalidId, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":7}]}}]}"));
    try std.testing.expectError(error.InvalidFunction, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":\"x\"}]}}]}"));
    try std.testing.expectError(error.InvalidFunctionName, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":7}}]}}]}"));
    try std.testing.expectError(error.InvalidArgumentsFragment, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":7}}]}}]}"));
    try std.testing.expectError(error.InvalidToolCalls, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":{}}}]}"));
    try std.testing.expectError(error.InvalidToolCalls, acc.feedChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[7]}}]}"));
}

test "tools: unknown fields are ignored at every level" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();
    try acc.feedChunk(
        "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{" ++
            "\"index\":0,\"logprobs\":null,\"delta\":{\"content\":\"thinking\",\"extra\":{\"a\":1}," ++
            "\"tool_calls\":[{\"index\":0,\"id\":\"call_0\",\"type\":\"function\",\"extra\":true," ++
            "\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\",\"extra\":[1,2]}}]}," ++
            "\"finish_reason\":\"tool_calls\"}]}",
    );
    const calls = try acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", calls[0].arguments_json);
}

test "tools: invalid finalized arguments are typed errors" {
    const alloc = std.testing.allocator;

    var broken = Accumulator.init(alloc);
    defer broken.deinit();
    try feedOne(&broken, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file", .arguments = "{" }}, "tool_calls");
    try std.testing.expectError(error.InvalidArgumentsJson, broken.finalize());

    var array = Accumulator.init(alloc);
    defer array.deinit();
    try feedOne(&array, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file", .arguments = "[]" }}, "tool_calls");
    try std.testing.expectError(error.ArgumentsNotObject, array.finalize());

    var empty = Accumulator.init(alloc);
    defer empty.deinit();
    try feedOne(&empty, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file", .arguments = "  " }}, "tool_calls");
    const calls = try empty.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqualStrings("{}", calls[0].arguments_json);
}

test "tools: accumulation and chunk limits are enforced" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();

    acc.chunk_limit = 16;
    try std.testing.expectError(error.ChunkTooLarge, acc.feedChunk("xxxxxxxxxxxxxxxxx"));
    acc.chunk_limit = max_chunk_bytes;

    acc.arguments_limit = 8;
    try std.testing.expectError(error.ArgumentsTooLong, feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file", .arguments = "123456789" }}, null));
    // The failed fragment is not appended; the next fragment starts at 0.
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = "12345678" }}, null);
    try std.testing.expectError(error.ArgumentsTooLong, feedOne(&acc, alloc, null, &.{.{ .index = 0, .arguments = "x" }}, null));
}

test "tools: id and name length limits are enforced" {
    const alloc = std.testing.allocator;

    var id_acc = Accumulator.init(alloc);
    defer id_acc.deinit();
    id_acc.id_limit = 4;
    try std.testing.expectError(error.IdTooLong, feedOne(&id_acc, alloc, null, &.{.{ .index = 0, .id = "12345", .name = "read_file" }}, null));
    try feedOne(&id_acc, alloc, null, &.{.{ .index = 0, .id = "call", .name = "read_file", .arguments = "{}" }}, "tool_calls");
    const calls = try id_acc.finalize();
    defer freeCalls(alloc, calls);
    try std.testing.expectEqualStrings("call", calls[0].id);

    var name_acc = Accumulator.init(alloc);
    defer name_acc.deinit();
    name_acc.name_limit = 4;
    try std.testing.expectError(error.NameTooLong, feedOne(&name_acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file" }}, null));
    try feedOne(&name_acc, alloc, null, &.{.{ .index = 0, .name = "grep" }}, "tool_calls");
    const named = try name_acc.finalize();
    defer freeCalls(alloc, named);
    try std.testing.expectEqualStrings("grep", named[0].name);
}

test "tools: finalize is repeatable and owns fresh memory" {
    const alloc = std.testing.allocator;
    var acc = Accumulator.init(alloc);
    defer acc.deinit();
    try feedOne(&acc, alloc, null, &.{.{ .index = 0, .id = "call_0", .name = "read_file", .arguments = "{\"path\":\"a\"}" }}, "tool_calls");

    const first = try acc.finalize();
    defer freeCalls(alloc, first);
    const second = try acc.finalize();
    defer freeCalls(alloc, second);

    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings(first[0].arguments_json, second[0].arguments_json);
    try std.testing.expect(first[0].id.ptr != second[0].id.ptr);
}

test "tools: result message is a JSON tool message with escaped content" {
    const alloc = std.testing.allocator;
    const output = "line 1\nquote \" backslash \\ tab \t 中文";
    const message = try buildToolResultMessage(alloc, "call_abc", .{ .output = output });
    defer alloc.free(message);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, message, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expect(root == .object);
    try std.testing.expectEqualStrings("tool", jsonObjectField(root, "role").string);
    try std.testing.expectEqualStrings("call_abc", jsonObjectField(root, "tool_call_id").string);
    try std.testing.expect(jsonObjectField(root, "content") == .string);
    try std.testing.expectEqualStrings(output, jsonObjectField(root, "content").string);

    // The raw bytes must not contain an unescaped quote/newline from content.
    try std.testing.expect(std.mem.indexOf(u8, message, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "\\n") != null);
}

test "tools: result content is bounded, UTF-8 safe and error-prefixed" {
    const alloc = std.testing.allocator;

    const big: [500]u8 = @splat('a');
    const truncated = try buildToolResultMessageWith(alloc, "call_0", .{ .output = &big }, .{ .max_content_bytes = 40 });
    defer alloc.free(truncated);
    var parsed_truncated = try std.json.parseFromSlice(std.json.Value, alloc, truncated, .{ .allocate = .alloc_always });
    defer parsed_truncated.deinit();
    const truncated_content = jsonObjectField(parsed_truncated.value, "content").string;
    try std.testing.expect(truncated_content.len <= 40);
    try std.testing.expect(std.mem.endsWith(u8, truncated_content, "[truncated]"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated_content));

    const invalid_utf8 = [_]u8{ 'o', 'k', 0xff, '!', 0xc3 };
    const lossy = try buildToolResultMessage(alloc, "call_1", .{ .output = &invalid_utf8 });
    defer alloc.free(lossy);
    var parsed_lossy = try std.json.parseFromSlice(std.json.Value, alloc, lossy, .{ .allocate = .alloc_always });
    defer parsed_lossy.deinit();
    const lossy_content = jsonObjectField(parsed_lossy.value, "content").string;
    try std.testing.expect(std.unicode.utf8ValidateSlice(lossy_content));
    try std.testing.expect(std.mem.indexOf(u8, lossy_content, "\u{FFFD}") != null);

    const failure = try buildToolResultMessage(alloc, "call_2", .{ .output = "permission denied", .is_error = true });
    defer alloc.free(failure);
    var parsed_failure = try std.json.parseFromSlice(std.json.Value, alloc, failure, .{ .allocate = .alloc_always });
    defer parsed_failure.deinit();
    try std.testing.expectEqualStrings("error: permission denied", jsonObjectField(parsed_failure.value, "content").string);
}

test "tools: result message validates the call id and clamps the cap" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidToolCallId, buildToolResultMessage(alloc, "", .{}));
    const long_id: [max_id_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidToolCallId, buildToolResultMessage(alloc, &long_id, .{}));
    const bad_id = [_]u8{0xff};
    try std.testing.expectError(error.InvalidToolCallId, buildToolResultMessage(alloc, &bad_id, .{}));

    const huge: [max_result_bytes + 1024]u8 = @splat('z');
    const message = try buildToolResultMessageWith(alloc, "call_0", .{ .output = &huge }, .{ .max_content_bytes = max_result_bytes * 4 });
    defer alloc.free(message);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, message, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const content = jsonObjectField(parsed.value, "content").string;
    try std.testing.expect(content.len <= max_result_bytes);
}

test "tools: default permission policy is conservative" {
    try std.testing.expectEqual(Permission.allow, decide("read_file", "{\"path\":\"a\"}"));
    try std.testing.expectEqual(Permission.allow, decide("list_directory", "{}"));
    try std.testing.expectEqual(Permission.allow, decide("grep", "{\"pattern\":\"x\"}"));

    try std.testing.expectEqual(Permission.confirm, decide("edit_file", "{}"));
    try std.testing.expectEqual(Permission.confirm, decide("apply_patch", "{}"));
    // Terminal is advertised but can only ever be confirmed (human allow) or
    // denied (unknown). There is no auto-allow.
    try std.testing.expectEqual(Permission.confirm, decide("terminal", "{\"command\":\"echo hi\"}"));

    try std.testing.expectEqual(Permission.deny, decide("shell", "{}"));
    try std.testing.expectEqual(Permission.deny, decide("Read_File", "{}"));
    try std.testing.expectEqual(Permission.deny, decide("", "{}"));
}

test "tools: policy overrides are explicit and unknown tools stay denied" {
    try std.testing.expectEqual(Permission.allow, decideWith(.{ .allow_writes = true }, "edit_file", "{}"));
    try std.testing.expectEqual(Permission.allow, decideWith(.{ .allow_writes = true }, "apply_patch", "{}"));
    // Enabling writes does not implicitly enable terminal.
    try std.testing.expectEqual(Permission.confirm, decideWith(.{ .allow_writes = true }, "terminal", "{}"));
    try std.testing.expectEqual(Permission.confirm, decideWith(.{ .allow_reads = false }, "grep", "{}"));

    const permissive: Policy = .{ .allow_reads = true, .allow_writes = true };
    try std.testing.expectEqual(Permission.confirm, decideWith(permissive, "terminal", "{}"));
    try std.testing.expectEqual(Permission.deny, decideWith(permissive, "rm_rf", "{}"));
}

test "tools: assistant tool-call turn serializes id/name/arguments" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("read_file"), .arguments_json = @constCast("{\"path\":\"a.zig\"}") },
        .{ .id = @constCast("call_2"), .name = @constCast("grep"), .arguments_json = @constCast("{\"pattern\":\"x\\\"y\"}") },
    };
    const json = try buildAssistantToolCallsJson(alloc, &calls);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("call_1", arr[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("function", arr[0].object.get("type").?.string);
    const f0 = arr[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read_file", f0.get("name").?.string);
    // Arguments stay a JSON string, not an inline object.
    try std.testing.expect(f0.get("arguments").? == .string);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", f0.get("arguments").?.string);
    const f1 = arr[1].object.get("function").?.object;
    try std.testing.expectEqualStrings("{\"pattern\":\"x\\\"y\"}", f1.get("arguments").?.string);

    const empty = try buildAssistantToolCallsJson(alloc, &.{});
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("[]", empty);
}

test "tools: bounded tool content is shared by message and loop" {
    const alloc = std.testing.allocator;
    const huge: [max_result_bytes + 64]u8 = @splat('q');
    const content = try buildToolResultContent(alloc, .{ .output = &huge }, .{});
    defer alloc.free(content);
    try std.testing.expect(content.len <= max_result_bytes);
    try std.testing.expect(std.mem.endsWith(u8, content, "\n… [truncated]"));

    const err_content = try buildToolResultContent(alloc, .{ .output = "nope", .is_error = true }, .{});
    defer alloc.free(err_content);
    try std.testing.expectEqualStrings("error: nope", err_content);

    // The message builder wraps exactly those bytes.
    const msg = try buildToolResultMessage(alloc, "call_9", .{ .output = "nope", .is_error = true });
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"content\":\"error: nope\"") != null);
}
