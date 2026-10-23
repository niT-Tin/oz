//! Incremental Server-Sent Events parser (M1 AI chat).
//!
//! Feed it arbitrary byte chunks (`feed`) and drain complete events with
//! `next`. Chunks may split anywhere: mid-line, mid-CRLF, mid-UTF-8 (SSE
//! payloads are opaque bytes to this parser). Per the SSE spec:
//!   - lines end with LF or CRLF,
//!   - `data:` values accumulate across consecutive data lines, joined by
//!     `\n` (a bare `data` with no colon is an empty value),
//!   - a blank line dispatches the accumulated event,
//!   - lines starting with ':' are comments; other fields are ignored.
//!
//! OpenAI's stream terminates with `data: [DONE]`; that becomes `Event.done`
//! after any accumulated data event (some servers omit the blank line before
//! it). `finish` flushes a final event when a server closes without a blank
//! line.
const std = @import("std");

pub const Event = union(enum) {
    /// One complete event's data (multi-line values joined with '\n').
    /// Owned by the caller; free with `deinit`.
    data: []u8,
    /// The OpenAI `[DONE]` sentinel.
    done,

    pub fn deinit(self: Event, alloc: std.mem.Allocator) void {
        switch (self) {
            .data => |d| alloc.free(d),
            .done => {},
        }
    }
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    /// Bytes of an incomplete line.
    line: std.ArrayList(u8) = .empty,
    /// Accumulated data payload of the event being built.
    data: std.ArrayList(u8) = .empty,
    /// Completed events, in arrival order.
    queue: std.ArrayList(Event) = .empty,
    done_seen: bool = false,
    /// A single line longer than this is discarded (defensive bound for a
    /// hostile/broken server); the rest of the stream can still be parsed.
    max_line: usize = 512 * 1024,

    pub const Error = error{ OutOfMemory, LineTooLong };

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        for (self.queue.items) |ev| ev.deinit(self.alloc);
        self.queue.deinit(self.alloc);
        self.line.deinit(self.alloc);
        self.data.deinit(self.alloc);
    }

    /// Feed raw stream bytes. Complete lines are parsed immediately; a
    /// trailing partial line is retained until the next feed.
    pub fn feed(self: *Parser, bytes: []const u8) Error!void {
        for (bytes) |c| {
            if (c == '\n') {
                try self.processLine(self.line.items);
                self.line.clearRetainingCapacity();
            } else {
                if (self.line.items.len >= self.max_line) return error.LineTooLong;
                try self.line.append(self.alloc, c);
            }
        }
    }

    /// Flush a pending event when the stream ended without a final blank
    /// line. Also parses the trailing line if it has no newline.
    pub fn finish(self: *Parser) Error!void {
        if (self.line.items.len > 0) {
            try self.processLine(self.line.items);
            self.line.clearRetainingCapacity();
        }
        try self.dispatch();
    }

    /// Next completed event (owned by the caller), or null.
    pub fn next(self: *Parser) ?Event {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn processLine(self: *Parser, raw: []const u8) Error!void {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            try self.dispatch();
            return;
        }
        if (line[0] == ':') return; // comment / keep-alive
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            // A field name with no value. "data" means an empty data line.
            if (std.mem.eql(u8, line, "data")) {
                if (self.data.items.len > 0) try self.data.append(self.alloc, '\n');
            }
            return;
        };
        const field = line[0..colon];
        if (!std.mem.eql(u8, field, "data")) return; // event:/id:/retry: ignored
        var value = line[colon + 1 ..];
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, value, "[DONE]")) {
            if (self.done_seen) return;
            // Flush a multi-line payload that directly precedes [DONE].
            try self.dispatch();
            self.done_seen = true;
            try self.queue.append(self.alloc, .done);
            return;
        }
        if (self.data.items.len > 0) try self.data.append(self.alloc, '\n');
        try self.data.appendSlice(self.alloc, value);
    }

    fn dispatch(self: *Parser) Error!void {
        if (self.data.items.len == 0) return;
        const copy = try self.alloc.dupe(u8, self.data.items);
        errdefer self.alloc.free(copy);
        try self.queue.append(self.alloc, .{ .data = copy });
        self.data.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Drain every event and return the data payloads joined with '|' (done
/// events as "[DONE]"). Caller owns the result.
fn drainAll(p: *Parser) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(p.alloc);
    var first = true;
    while (p.next()) |ev| {
        defer ev.deinit(p.alloc);
        if (!first) try out.append(p.alloc, '|');
        first = false;
        switch (ev) {
            .data => |d| try out.appendSlice(p.alloc, d),
            .done => try out.appendSlice(p.alloc, "[DONE]"),
        }
    }
    return out.toOwnedSlice(p.alloc);
}

test "sse: data events, CRLF and comments" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    try p.feed(": keep-alive\r\n\r\ndata: hello\r\n\r\ndata: world\r\n\r\n");
    const got = try drainAll(&p);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello|world", got);
}

test "sse: multi-line data joins with newline" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    try p.feed("data: a\ndata: b\ndata: c\n\n");
    const got = try drainAll(&p);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("a\nb\nc", got);
}

test "sse: [DONE] flushes pending data and is idempotent" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    try p.feed("data: tail\ndata: [DONE]\ndata: [DONE]\n\n");
    const got = try drainAll(&p);
    defer alloc.free(got);
    // The second [DONE] is ignored.
    try std.testing.expectEqualStrings("tail|[DONE]", got);
}

test "sse: split at every possible boundary (LF)" {
    const alloc = std.testing.allocator;
    const stream = "data: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\n\n";
    var split: usize = 0;
    while (split <= stream.len) : (split += 1) {
        var p = Parser.init(alloc);
        defer p.deinit();
        try p.feed(stream[0..split]);
        try p.feed(stream[split..]);
        const got = try drainAll(&p);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("{\"a\":1}|{\"b\":2}|[DONE]", got);
    }
}

test "sse: split at every possible boundary (CRLF)" {
    const alloc = std.testing.allocator;
    const stream = "data: one\r\n\r\ndata: two\r\n\r\ndata: [DONE]\r\n\r\n";
    var split: usize = 0;
    while (split <= stream.len) : (split += 1) {
        var p = Parser.init(alloc);
        defer p.deinit();
        try p.feed(stream[0..split]);
        try p.feed(stream[split..]);
        const got = try drainAll(&p);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("one|two|[DONE]", got);
    }
}

test "sse: byte-at-a-time feed" {
    const alloc = std.testing.allocator;
    const stream = "data: split-me\n\ndata: [DONE]\n\n";
    var p = Parser.init(alloc);
    defer p.deinit();
    for (stream) |c| try p.feed(&.{c});
    const got = try drainAll(&p);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("split-me|[DONE]", got);
}

test "sse: finish flushes an event without a trailing blank line" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    try p.feed("data: no-newline");
    try p.finish();
    const got = try drainAll(&p);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("no-newline", got);
}

test "sse: blank lines and non-data fields are ignored" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    try p.feed("\n\nevent: ping\nid: 7\nretry: 100\n\n:comment\n\ndata: x\n\n");
    const got = try drainAll(&p);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("x", got);
}

test "sse: line-too-long is an explicit error" {
    const alloc = std.testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();
    p.max_line = 4;
    try std.testing.expectError(error.LineTooLong, p.feed("data: 12345"));
}
