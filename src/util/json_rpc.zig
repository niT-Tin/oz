//! JSON-RPC 2.0 framing + message construction for LSP (DESIGN.md §9.1).
//! Content-Length header framing over stdio, JSON via std.json.
//! Pure logic (no process/network here).
//!
//! Framing follows the LSP spec: a header block of `Name: value` lines
//! terminated by a blank line (`\r\n\r\n`), of which only `Content-Length`
//! matters, followed by exactly `Content-Length` bytes of JSON body.
//! Messages are built/parsed with `std.json` (Zig 0.16 API: `Scanner`,
//! `Value`, `Stringify`).
const std = @import("std");

/// Read one Content-Length framed message from `reader`.
///
/// `reader` is `anytype` and must expose the `std.Io.Reader` interface
/// methods used here (`takeDelimiter`, `readAlloc`); a `std.Io.Reader` from
/// `std.Io.Reader.fixed` or `std.Io.File` works. Pass a pointer (`&reader`)
/// so the stream position advances across successive calls.
///
/// Returns null on clean EOF at a message boundary. Returns an error on
/// malformed headers, a missing/invalid Content-Length, or EOF in the middle
/// of a header or body.
///
/// `content` is allocated with `allocator` and owned by the caller.
pub fn readFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
) !?[]u8 {
    var content_length: ?usize = null;
    var saw_header = false;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.InvalidHeader, // header line longer than the reader buffer
            else => |e| return e,
        };
        if (line) |raw| {
            var l = raw;
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
            if (l.len == 0) {
                // Blank line: end of the header section, or (when no header
                // has been seen yet) inter-frame padding which we skip.
                if (saw_header) {
                    const n = content_length orelse return error.MissingContentLength;
                    const body = try reader.readAlloc(allocator, n);
                    return body;
                }
                continue;
            }
            saw_header = true;
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse
                return error.InvalidHeader;
            const name = std.mem.trim(u8, l[0..colon], " \t");
            const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (content_length != null) return error.InvalidHeader; // duplicate Content-Length
                content_length = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidContentLength;
            }
            // Any other headers (e.g. Content-Type) are ignored.
        } else {
            // Clean EOF at a message boundary.
            if (saw_header) return error.UnexpectedEof;
            return null;
        }
    }
}

/// Write `Content-Length: N\r\n\r\n` followed by `content` to `writer`.
///
/// `writer` is `anytype` and must expose the `std.Io.Writer` interface
/// methods used here (`print`, `writeAll`); a `std.Io.Writer` from
/// `std.Io.Writer.Allocating` or `std.Io.File` works. Does not flush.
pub fn writeFrame(writer: anytype, content: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{content.len});
    try writer.writeAll(content);
}

/// Parse a JSON-RPC 2.0 message. `id`/`method` are null for
/// notifications/responses respectively; `result`/`error` for responses.
///
/// Ownership: `parseMessage` copies every string into `allocator`-owned
/// memory (`method`, `err.message`, and the heap parts of the `params` /
/// `result` `std.json.Value` trees), so `content` does not need to outlive
/// the Message. Free everything with `deinit` (which is only valid for
/// Messages produced by `parseMessage`).
///
/// Detail change vs. the original contract note ("`content` must stay alive
/// as long as the Message's slices are used"): we copy instead of borrowing,
/// so callers cannot dangle after the de-framed buffer is freed, at the cost
/// of one allocation per string; `deinit` releases them all.
pub const Message = struct {
    id: ?u64,
    method: ?[]const u8,
    params: ?std.json.Value,
    result: ?std.json.Value,
    err: ?struct { code: i64, message: []const u8 },

    /// Release all allocations owned by this Message (created by
    /// `parseMessage`). Safe to call on a Message that is still all-null.
    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.method) |m| allocator.free(m);
        if (self.err) |e| allocator.free(e.message);
        if (self.params) |*v| freeValue(allocator, v);
        if (self.result) |*v| freeValue(allocator, v);
        self.* = undefined;
    }
};

/// Recursively free a `std.json.Value` tree whose strings/keys were allocated
/// by `std.json.Value.jsonParse` with `.alloc_always` (as done in
/// `parseMessage`, with `parse_numbers = false` so numbers stay reachable as
/// `.number_string`): every string/key/number is an individual allocation,
/// arrays and object maps own their backing storage.
pub fn freeValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| freeValue(allocator, item);
            arr.deinit();
        },
        .object => |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr);
            }
            map.deinit(allocator);
        },
        else => {},
    }
}

/// Parse `content` (already de-framed) into a Message.
/// See `Message` for ownership (call `deinit` to free).
///
/// Recognizes request / notification / response / error shapes by extracting
/// `id` (JSON numbers only; a string or non-`u64` id is treated as absent →
/// null), `method`, `params`, `result` and `error{code,message}`. Missing
/// fields are null. The `jsonrpc` field is optional; when present it must be
/// the string `"2.0"`. Unknown fields are skipped, duplicate known fields are
/// an error, and the top level must be a JSON object. (Trailing content after
/// the object is not inspected.) Numbers inside `params`/`result` Values are
/// kept as `.number_string` (see `takeValue`).
pub fn parseMessage(allocator: std.mem.Allocator, content: []const u8) !Message {
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();

    var msg: Message = .{
        .id = null,
        .method = null,
        .params = null,
        .result = null,
        .err = null,
    };
    errdefer msg.deinit(allocator);

    // Top level must be a JSON object.
    const top = try scanner.nextAllocMax(allocator, .alloc_always, content.len);
    switch (top) {
        .object_begin => {},
        else => {
            freeTokenPayload(allocator, top);
            return error.InvalidMessage;
        },
    }

    while (true) {
        const key_tok = try scanner.nextAllocMax(allocator, .alloc_always, content.len);
        switch (key_tok) {
            .object_end => break,
            .allocated_string => |key| {
                if (std.mem.eql(u8, key, "jsonrpc")) {
                    allocator.free(key);
                    try takeJsonrpc(allocator, &scanner, content.len);
                } else if (std.mem.eql(u8, key, "id")) {
                    allocator.free(key);
                    if (msg.id != null) return error.DuplicateField;
                    msg.id = try takeId(allocator, &scanner, content.len);
                } else if (std.mem.eql(u8, key, "method")) {
                    allocator.free(key);
                    if (msg.method != null) return error.DuplicateField;
                    msg.method = try takeString(allocator, &scanner, content.len);
                } else if (std.mem.eql(u8, key, "params")) {
                    allocator.free(key);
                    if (msg.params != null) return error.DuplicateField;
                    msg.params = try takeValue(allocator, &scanner, content.len);
                } else if (std.mem.eql(u8, key, "result")) {
                    allocator.free(key);
                    if (msg.result != null) return error.DuplicateField;
                    msg.result = try takeValue(allocator, &scanner, content.len);
                } else if (std.mem.eql(u8, key, "error")) {
                    allocator.free(key);
                    if (msg.err != null) return error.DuplicateField;
                    msg.err = try takeError(allocator, &scanner, content.len);
                } else {
                    // Unknown field: skip its value.
                    allocator.free(key);
                    try scanner.skipValue();
                }
            },
            else => {
                // Defensive: free any allocated token before failing.
                freeTokenPayload(allocator, key_tok);
                return error.InvalidMessage;
            },
        }
    }
    return msg;
}

const ErrorObject = std.meta.Child(@FieldType(Message, "err"));

/// Free the payload of an allocated token, if any (used before erroring out).
fn freeTokenPayload(allocator: std.mem.Allocator, tok: std.json.Token) void {
    switch (tok) {
        .allocated_string => |s| allocator.free(s),
        .allocated_number => |s| allocator.free(s),
        else => {},
    }
}

/// Consume the value of the "jsonrpc" field; must be the string "2.0".
fn takeJsonrpc(allocator: std.mem.Allocator, scanner: *std.json.Scanner, max: usize) !void {
    const tok = try scanner.nextAllocMax(allocator, .alloc_if_needed, max);
    switch (tok) {
        .string => |s| if (!std.mem.eql(u8, s, "2.0")) return error.InvalidVersion,
        .allocated_string => |s| {
            defer allocator.free(s);
            if (!std.mem.eql(u8, s, "2.0")) return error.InvalidVersion;
        },
        else => return error.InvalidMessage,
    }
}

/// Consume the next value as a JSON string; returns an allocator-owned copy.
fn takeString(allocator: std.mem.Allocator, scanner: *std.json.Scanner, max: usize) ![]u8 {
    const tok = try scanner.nextAllocMax(allocator, .alloc_always, max);
    switch (tok) {
        .allocated_string => |s| return s,
        .allocated_number => |s| {
            allocator.free(s);
            return error.InvalidMessage;
        },
        else => return error.InvalidMessage,
    }
}

/// Consume the "id" value. JSON integers become the id; null or string ids
/// are treated as absent (null); other values are an error.
fn takeId(allocator: std.mem.Allocator, scanner: *std.json.Scanner, max: usize) !?u64 {
    const tok = try scanner.nextAllocMax(allocator, .alloc_always, max);
    switch (tok) {
        .allocated_number => |s| {
            defer allocator.free(s);
            return std.fmt.parseInt(u64, s, 10) catch null;
        },
        .allocated_string => |s| {
            allocator.free(s);
            return null;
        },
        .null => return null,
        else => return error.InvalidMessage,
    }
}

/// Consume the next value as a `std.json.Value` (allocator-owned tree).
///
/// `parse_numbers` is disabled so that every allocation stays reachable in
/// the tree and `freeValue`/`Message.deinit` can reclaim it: with
/// `parse_numbers = true`, `Value.jsonParse` converts number tokens to
/// `.integer`/`.float` and drops the intermediate number buffer, which only
/// an arena (std's `Parsed`) can reclaim. Consequence: JSON numbers inside
/// `params`/`result` arrive as `.number_string` (raw text) rather than
/// parsed integers/floats.
fn takeValue(allocator: std.mem.Allocator, scanner: *std.json.Scanner, max: usize) !std.json.Value {
    const options = std.json.ParseOptions{ .max_value_len = max, .parse_numbers = false };
    return std.json.Value.jsonParse(allocator, scanner, options);
}

/// Consume the value of the "error" field: an object with an integer `code`
/// and a string `message` (both required).
fn takeError(allocator: std.mem.Allocator, scanner: *std.json.Scanner, max: usize) !ErrorObject {
    switch (try scanner.nextAllocMax(allocator, .alloc_always, max)) {
        .object_begin => {},
        else => |tok| {
            freeTokenPayload(allocator, tok);
            return error.InvalidMessage;
        },
    }
    var code: i64 = 0;
    var code_seen = false;
    var message: ?[]u8 = null;
    errdefer if (message) |m| allocator.free(m);

    while (true) {
        const key_tok = try scanner.nextAllocMax(allocator, .alloc_always, max);
        switch (key_tok) {
            .object_end => break,
            .allocated_string => |key| {
                if (std.mem.eql(u8, key, "code")) {
                    allocator.free(key);
                    const tok = try scanner.nextAllocMax(allocator, .alloc_always, max);
                    switch (tok) {
                        .allocated_number => |s| {
                            defer allocator.free(s);
                            if (code_seen) return error.DuplicateField;
                            code = std.fmt.parseInt(i64, s, 10) catch
                                return error.InvalidMessage;
                            code_seen = true;
                        },
                        else => {
                            freeTokenPayload(allocator, tok);
                            return error.InvalidMessage;
                        },
                    }
                } else if (std.mem.eql(u8, key, "message")) {
                    allocator.free(key);
                    if (message != null) return error.DuplicateField;
                    message = try takeString(allocator, scanner, max);
                } else {
                    allocator.free(key);
                    try scanner.skipValue();
                }
            },
            else => {
                freeTokenPayload(allocator, key_tok);
                return error.InvalidMessage;
            },
        }
    }

    if (message) |m| {
        if (!code_seen) {
            allocator.free(m);
            message = null; // avoid the errdefer above double-freeing
            return error.InvalidMessage;
        }
        return .{ .code = code, .message = m };
    }
    return error.InvalidMessage;
}

/// Build the full JSON text for a request {id, method, params}.
/// Caller owns the returned slice (free with `allocator`).
/// Fails only with error.OutOfMemory (see `unmapWriteFailed`).
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: std.json.Value,
) ![]u8 {
    return unmapWriteFailed(encodeRequestImpl(allocator, id, method, params));
}

/// std.json.Stringify over an Io.Writer.Allocating reports allocation
/// failure as error.WriteFailed (the Writer drain contract); for an
/// in-memory encode that failure IS OutOfMemory, and callers should not
/// have to know about the Writer plumbing to handle it.
fn unmapWriteFailed(result: error{ OutOfMemory, WriteFailed }![]u8) error{OutOfMemory}![]u8 {
    return result catch |e| switch (e) {
        error.WriteFailed => error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn encodeRequestImpl(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: std.json.Value,
) error{ OutOfMemory, WriteFailed }![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    try s.endObject();

    return out.toOwnedSlice();
}

/// Build the full JSON text for a notification {method, params} (no id).
/// Caller owns the returned slice (free with `allocator`).
/// Fails only with error.OutOfMemory (see `unmapWriteFailed`).
pub fn encodeNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
) error{OutOfMemory}![]u8 {
    return unmapWriteFailed(encodeNotificationImpl(allocator, method, params));
}

fn encodeNotificationImpl(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
) error{ OutOfMemory, WriteFailed }![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    try s.endObject();

    return out.toOwnedSlice();
}

/// Build the full JSON text for a response {id, result}.
/// Caller owns the returned slice (free with `allocator`).
/// Fails only with error.OutOfMemory (see `unmapWriteFailed`).
pub fn encodeResponse(
    allocator: std.mem.Allocator,
    id: u64,
    result: std.json.Value,
) error{OutOfMemory}![]u8 {
    return unmapWriteFailed(encodeResponseImpl(allocator, id, result));
}

fn encodeResponseImpl(
    allocator: std.mem.Allocator,
    id: u64,
    result: std.json.Value,
) error{ OutOfMemory, WriteFailed }![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();

    return out.toOwnedSlice();
}

/// Build the full JSON text for an error response {id, error:{code,message}}.
/// Caller owns the returned slice (free with `allocator`).
/// Fails only with error.OutOfMemory (see `unmapWriteFailed`).
pub fn encodeError(
    allocator: std.mem.Allocator,
    id: u64,
    code: i64,
    message: []const u8,
) error{OutOfMemory}![]u8 {
    return unmapWriteFailed(encodeErrorImpl(allocator, id, code, message));
}

fn encodeErrorImpl(
    allocator: std.mem.Allocator,
    id: u64,
    code: i64,
    message: []const u8,
) error{ OutOfMemory, WriteFailed }![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeFrame + readFrame roundtrip" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const content = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    try writeFrame(&out.writer, content);

    var reader = std.Io.Reader.fixed(out.written());
    const body = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(body.?);
    try testing.expectEqualStrings(content, body.?);

    // The stream is now cleanly exhausted at a message boundary.
    try testing.expectEqual(@as(?[]u8, null), try readFrame(testing.allocator, &reader));
}

test "readFrame: multiple frames, extra headers, blank lines between frames" {
    const input =
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "Content-Length: 5\r\n\r\n" ++
        "hello\r\n" ++
        "\r\n" ++
        "Content-Length: 3\r\n\r\n" ++
        "abc";
    var reader = std.Io.Reader.fixed(input);
    const f1 = (try readFrame(testing.allocator, &reader)).?;
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings("hello", f1);
    const f2 = (try readFrame(testing.allocator, &reader)).?;
    defer testing.allocator.free(f2);
    try testing.expectEqualStrings("abc", f2);
    try testing.expectEqual(@as(?[]u8, null), try readFrame(testing.allocator, &reader));
}

test "readFrame: LF-only and case-insensitive Content-Length" {
    const input = "content-length:4\n\ntest";
    var reader = std.Io.Reader.fixed(input);
    const body = (try readFrame(testing.allocator, &reader)).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("test", body);
}

test "readFrame: header value with spaces" {
    const input = "Content-Length:   6   \r\n\r\nabcdef";
    var reader = std.Io.Reader.fixed(input);
    const body = (try readFrame(testing.allocator, &reader)).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("abcdef", body);
}

test "readFrame: malformed framing errors" {
    // No Content-Length header.
    {
        const input = "Content-Type: x\r\n\r\nabc";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.MissingContentLength, readFrame(testing.allocator, &r));
    }
    // Non-numeric Content-Length.
    {
        const input = "Content-Length: abc\r\n\r\nx";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.InvalidContentLength, readFrame(testing.allocator, &r));
    }
    // Header line without a colon.
    {
        const input = "Content-Length 5\r\n\r\nx";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.InvalidHeader, readFrame(testing.allocator, &r));
    }
    // Duplicate Content-Length.
    {
        const input = "Content-Length: 1\r\nContent-Length: 2\r\n\r\nx";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.InvalidHeader, readFrame(testing.allocator, &r));
    }
    // EOF in the middle of the header section.
    {
        const input = "Content-Length: 5\r";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.UnexpectedEof, readFrame(testing.allocator, &r));
    }
    // EOF in the middle of the body.
    {
        const input = "Content-Length: 5\r\n\r\nhe";
        var r = std.Io.Reader.fixed(input);
        try testing.expectError(error.EndOfStream, readFrame(testing.allocator, &r));
    }
}

test "readFrame: empty body and clean EOF" {
    // Zero-length body.
    {
        const input = "Content-Length: 0\r\n\r\n";
        var r = std.Io.Reader.fixed(input);
        const body = (try readFrame(testing.allocator, &r)).?;
        defer testing.allocator.free(body);
        try testing.expectEqual(@as(usize, 0), body.len);
    }
    // Empty stream: clean EOF.
    {
        const input = "";
        var r = std.Io.Reader.fixed(input);
        try testing.expectEqual(@as(?[]u8, null), try readFrame(testing.allocator, &r));
    }
    // Only blank lines then EOF: also clean.
    {
        const input = "\r\n\r\n";
        var r = std.Io.Reader.fixed(input);
        try testing.expectEqual(@as(?[]u8, null), try readFrame(testing.allocator, &r));
    }
}

test "parseMessage: request" {
    const content = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.txt\",\"version\":1}}}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 7), msg.id);
    try testing.expectEqualStrings("textDocument/didOpen", msg.method.?);
    const params = msg.params.?;
    try testing.expect(params == .object);
    const td = params.object.get("textDocument").?;
    try testing.expectEqualStrings("file:///a.txt", td.object.get("uri").?.string);
    // Numbers stay raw (.number_string); see takeValue's note.
    try testing.expectEqualStrings("1", td.object.get("version").?.number_string);
    try testing.expect(msg.result == null);
    try testing.expect(msg.err == null);
}

test "parseMessage: notification (no id, and explicit null id)" {
    {
        const content = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
        var msg = try parseMessage(testing.allocator, content);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(@as(?u64, null), msg.id);
        try testing.expectEqualStrings("initialized", msg.method.?);
        try testing.expect(msg.params != null);
    }
    {
        const content = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"exit\"}";
        var msg = try parseMessage(testing.allocator, content);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(@as(?u64, null), msg.id);
        try testing.expectEqualStrings("exit", msg.method.?);
        try testing.expect(msg.params == null);
    }
}

test "parseMessage: response with result" {
    const content = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 3), msg.id);
    try testing.expect(msg.method == null);
    const result = msg.result.?;
    try testing.expect(result == .object);
    const caps = result.object.get("capabilities").?;
    try testing.expectEqual(true, caps.object.get("hoverProvider").?.bool);
    try testing.expect(msg.err == null);
}

test "parseMessage: error response" {
    const content = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 1), msg.id);
    const err = msg.err.?;
    try testing.expectEqual(@as(i64, -32700), err.code);
    try testing.expectEqualStrings("Parse error", err.message);
    try testing.expect(msg.result == null);
}

test "parseMessage: field order independent, unknown fields skipped" {
    const content = "{\"id\":9,\"unknown\":{\"nested\":[1,2,3]},\"method\":\"x\",\"result\":null}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 9), msg.id);
    try testing.expectEqualStrings("x", msg.method.?);
    try testing.expect(msg.result != null);
    try testing.expect(msg.result.? == .null);
}

test "parseMessage: params as array" {
    const content = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"m\",\"params\":[1,\"two\",true,null]}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    const arr = msg.params.?.array;
    try testing.expectEqual(@as(usize, 4), arr.items.len);
    try testing.expectEqualStrings("1", arr.items[0].number_string);
    try testing.expectEqualStrings("two", arr.items[1].string);
    try testing.expectEqual(true, arr.items[2].bool);
    try testing.expect(arr.items[3] == .null);
}

test "parseMessage: escaped method string is decoded" {
    // "te\u0073t" decodes to "test" (exercises the allocated-string path).
    const content = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"te\\u0073t\"}";
    var msg = try parseMessage(testing.allocator, content);
    defer msg.deinit(testing.allocator);
    try testing.expectEqualStrings("test", msg.method.?);
}

test "parseMessage: string id and negative id treated as absent" {
    {
        const content = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"m\"}";
        var msg = try parseMessage(testing.allocator, content);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(@as(?u64, null), msg.id);
    }
    {
        const content = "{\"id\":-1,\"method\":\"m\"}";
        var msg = try parseMessage(testing.allocator, content);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(@as(?u64, null), msg.id);
    }
}

test "parseMessage: malformed input errors" {
    // Top level is not an object.
    try testing.expectError(error.InvalidMessage, parseMessage(testing.allocator, "[1,2,3]"));
    try testing.expectError(error.InvalidMessage, parseMessage(testing.allocator, "\"str\""));
    try testing.expectError(error.InvalidMessage, parseMessage(testing.allocator, "null"));
    // Wrong jsonrpc version.
    try testing.expectError(error.InvalidVersion, parseMessage(testing.allocator, "{\"jsonrpc\":\"1.0\",\"method\":\"x\"}"));
    // Error object missing "message" or "code".
    try testing.expectError(error.InvalidMessage, parseMessage(testing.allocator, "{\"id\":1,\"error\":{\"code\":1}}"));
    try testing.expectError(error.InvalidMessage, parseMessage(testing.allocator, "{\"id\":1,\"error\":{\"message\":\"x\"}}"));
    // Duplicate known field.
    try testing.expectError(error.DuplicateField, parseMessage(testing.allocator, "{\"method\":\"a\",\"method\":\"b\"}"));
    // Truncated JSON.
    try testing.expectError(error.UnexpectedEndOfInput, parseMessage(testing.allocator, "{\"method\":"));
}

test "encodeRequest / encodeNotification / encodeResponse / encodeError" {
    const allocator = testing.allocator;

    const params = std.json.Value{ .object = .empty };
    const req = try encodeRequest(allocator, 42, "initialize", params);
    defer allocator.free(req);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"initialize\",\"params\":{}}", req);

    const notif = try encodeNotification(allocator, "initialized", params);
    defer allocator.free(notif);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", notif);

    const result_value = std.json.Value{ .bool = true };
    const resp = try encodeResponse(allocator, 7, result_value);
    defer allocator.free(resp);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":true}", resp);

    const err = try encodeError(allocator, 9, -32700, "Parse error");
    defer allocator.free(err);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", err);
}

test "encode -> writeFrame -> readFrame -> parseMessage roundtrip (request)" {
    const allocator = testing.allocator;
    const params = std.json.Value{ .object = .empty };
    const req = try encodeRequest(allocator, 42, "initialize", params);
    defer allocator.free(req);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeFrame(&out.writer, req);

    var reader = std.Io.Reader.fixed(out.written());
    const body = (try readFrame(allocator, &reader)).?;
    defer allocator.free(body);
    try testing.expectEqualStrings(req, body);

    var msg = try parseMessage(allocator, body);
    defer msg.deinit(allocator);
    try testing.expectEqual(@as(?u64, 42), msg.id);
    try testing.expectEqualStrings("initialize", msg.method.?);
    try testing.expect(msg.params != null);
    try testing.expect(msg.params.? == .object);
}

test "encodeError -> writeFrame -> readFrame -> parseMessage roundtrip (error response)" {
    const allocator = testing.allocator;
    const err_json = try encodeError(allocator, 5, -32601, "Method not found");
    defer allocator.free(err_json);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeFrame(&out.writer, err_json);

    var reader = std.Io.Reader.fixed(out.written());
    const body = (try readFrame(allocator, &reader)).?;
    defer allocator.free(body);

    var msg = try parseMessage(allocator, body);
    defer msg.deinit(allocator);
    try testing.expectEqual(@as(?u64, 5), msg.id);
    const e = msg.err.?;
    try testing.expectEqual(@as(i64, -32601), e.code);
    try testing.expectEqualStrings("Method not found", e.message);
}

test "encode*: allocation failure surfaces as error.OutOfMemory" {
    // The Allocating writer behind Stringify maps allocation failure to
    // error.WriteFailed (Writer drain contract); callers of the encode*
    // helpers must see a plain error.OutOfMemory instead.
    const params = std.json.Value{ .object = .empty };
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    try testing.expectError(error.OutOfMemory, encodeRequest(a, 1, "m", params));
    try testing.expectError(error.OutOfMemory, encodeNotification(a, "m", params));
    try testing.expectError(error.OutOfMemory, encodeResponse(a, 1, params));
    try testing.expectError(error.OutOfMemory, encodeError(a, 1, -32601, "x"));
}
