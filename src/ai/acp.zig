//! ACP v1 newline-delimited JSON-RPC. Each editor thread owns a connection.
//! No client filesystem/terminal capabilities: harnesses execute their own tools.
const std = @import("std");
const V = std.json.Value;
pub const max_frame = 8 * 1024 * 1024;
pub fn field(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn eq(v: V, s: []const u8) bool {
    return std.mem.eql(u8, str(v), s);
}
pub fn preset(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "kimi")) return "[\"kimi\",\"acp\"]";
    if (std.mem.eql(u8, name, "codex")) return "[\"npx\",\"-y\",\"@agentclientprotocol/codex-acp\"]";
    if (std.mem.eql(u8, name, "deepseek")) return "[\"pnpm\",\"--silent\",\"dsh\",\"--profile\",\"acp\"]";
    return error.InvalidAcpAgent;
}
pub fn validateCommand(a: std.mem.Allocator, json: []const u8) !void {
    const p = try std.json.parseFromSlice(V, a, json, .{});
    defer p.deinit();
    if (p.value != .array or p.value.array.items.len == 0) return error.InvalidAcpCommand;
    for (p.value.array.items) |v| if (v != .string or v.string.len == 0 or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidAcpCommand;
}
pub const Connection = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    root: ?[]u8 = null,
    session: ?[]u8 = null,
    next_id: u64 = 0,
    input: std.ArrayList(u8) = .empty,
    scratch: [4096]u8 = undefined,
    used: usize = 0,
    pos: usize = 0,

    pub fn start(a: std.mem.Allocator, io: std.Io, command: []const u8, cwd: []const u8) !Connection {
        try validateCommand(a, command);
        const p = try std.json.parseFromSlice(V, a, command, .{});
        defer p.deinit();
        const argv = try a.alloc([]const u8, p.value.array.items.len);
        defer a.free(argv);
        for (p.value.array.items, 0..) |v, i| argv[i] = v.string;
        const child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .pgid = 0 });
        return .{ .alloc = a, .io = io, .child = child };
    }
    pub fn deinit(self: *Connection) void {
        if (self.child.id) |pid| std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        self.child.kill(self.io);
        if (self.root) |s| self.alloc.free(s);
        if (self.session) |s| self.alloc.free(s);
        self.input.deinit(self.alloc);
    }
    pub fn send(self: *Connection, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
        defer self.alloc.free(bytes);
        try self.child.stdin.?.writeStreamingAll(self.io, bytes);
        try self.child.stdin.?.writeStreamingAll(self.io, "\n");
    }
    fn request(self: *Connection, method: []const u8, params: anytype) !u64 {
        self.next_id += 1;
        try self.send(.{ .jsonrpc = "2.0", .id = self.next_id, .method = method, .params = params });
        return self.next_id;
    }
    fn read(self: *Connection) !std.json.Parsed(V) {
        self.input.clearRetainingCapacity();
        while (true) {
            if (self.pos == self.used) {
                self.used = self.child.stdout.?.readStreaming(self.io, &.{&self.scratch}) catch |e| {
                    if (e == error.EndOfStream) return error.AcpDisconnected;
                    return e;
                };
                self.pos = 0;
                if (self.used == 0) return error.AcpDisconnected;
            }
            const byte = self.scratch[self.pos];
            self.pos += 1;
            if (byte == '\n') {
                if (self.input.items.len == 0) continue;
                return std.json.parseFromSlice(V, self.alloc, self.input.items, .{ .allocate = .alloc_always });
            }
            if (self.input.items.len >= max_frame) return error.AcpFrameTooLarge;
            try self.input.append(self.alloc, byte);
        }
    }
    // Host supplies owned transcript events and an explicit permission decision.
    fn wait(self: *Connection, id: u64, host: anytype) !std.json.Parsed(V) {
        while (true) {
            var p = try self.read();
            errdefer p.deinit();
            const v = p.value;
            const mid = field(v, "id");
            if (mid == .integer and mid.integer == id and field(v, "method") == .null) {
                if (field(v, "error") != .null) {
                    try host.acpText("\nACP error: ");
                    try host.acpText(str(field(field(v, "error"), "message")));
                    return error.AcpRemoteError;
                }
                return p;
            }
            if (eq(field(v, "method"), "session/update")) {
                const params = field(v, "params");
                if (self.session) |s| {
                    if (!eq(field(params, "sessionId"), s)) {
                        p.deinit();
                        continue;
                    }
                }
                const u = field(params, "update");
                const kind = field(u, "sessionUpdate");
                if (eq(kind, "agent_message_chunk")) {
                    const c = field(u, "content");
                    if (eq(field(c, "type"), "text")) try host.acpText(str(field(c, "text")));
                } else if (eq(kind, "tool_call") or eq(kind, "tool_call_update")) {
                    const text = try std.fmt.allocPrint(self.alloc, "\n[tool {s}] {s} {s}\n", .{ str(field(u, "toolCallId")), str(field(u, "title")), str(field(u, "status")) });
                    defer self.alloc.free(text);
                    try host.acpText(text);
                }
            } else if (eq(field(v, "method"), "session/request_permission")) {
                const params = field(v, "params");
                var selected: ?V = null;
                const options = field(params, "options");
                const detail = try std.json.Stringify.valueAlloc(self.alloc, field(params, "toolCall"), .{});
                defer self.alloc.free(detail);
                const same_session = if (self.session) |s| eq(field(params, "sessionId"), s) else false;
                const allowed = if (same_session and detail.len <= 16384) try host.acpPermission(detail) else false;
                if (options == .array) for (options.array.items) |option| {
                    if (eq(field(option, "kind"), if (allowed) "allow_once" else "reject_once")) {
                        selected = field(option, "optionId");
                        break;
                    }
                };
                if (selected) |option| {
                    try self.send(.{ .jsonrpc = "2.0", .id = mid, .result = .{ .outcome = .{ .outcome = "selected", .optionId = option } } });
                } else try self.send(.{ .jsonrpc = "2.0", .id = mid, .result = .{ .outcome = .{ .outcome = "cancelled" } } });
            } else if (mid != .null and field(v, "method") != .null) {
                try self.send(.{ .jsonrpc = "2.0", .id = mid, .@"error" = .{ .code = @as(i32, -32601), .message = "Method not supported by oz" } });
            }
            p.deinit();
        }
    }
    pub fn prompt(self: *Connection, cwd: []const u8, text: []const u8, host: anytype) !void {
        if (self.root) |root| if (!std.mem.eql(u8, root, cwd)) return error.AcpWorkspaceChangedCreateNewThread;
        if (self.root == null) self.root = try self.alloc.dupe(u8, cwd);
        if (self.session == null) {
            var init = try self.wait(try self.request("initialize", .{ .protocolVersion = 1, .clientCapabilities = struct {}{}, .clientInfo = .{ .name = "oz", .version = "0.1.0" } }), host);
            defer init.deinit();
            const ver = field(field(init.value, "result"), "protocolVersion");
            if (ver != .integer or ver.integer != 1) return error.UnsupportedAcpVersion;
            var session = try self.wait(try self.request("session/new", .{ .cwd = cwd, .mcpServers = [0]V{} }), host);
            defer session.deinit();
            const sid = field(field(session.value, "result"), "sessionId");
            if (sid != .string or sid.string.len == 0) return error.InvalidAcpSession;
            self.session = try self.alloc.dupe(u8, sid.string);
        }
        var result = try self.wait(try self.request("session/prompt", .{ .sessionId = self.session.?, .prompt = .{.{ .type = "text", .text = text }} }), host);
        defer result.deinit();
        const reason = field(field(result.value, "result"), "stopReason");
        if (reason != .string or reason.string.len == 0) return error.InvalidAcpStopReason;
        if (!eq(reason, "end_turn")) {
            try host.acpText("\n[ACP stop: ");
            try host.acpText(str(reason));
            try host.acpText("]\n");
        }
    }
};
test "ACP presets and argv validation" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "kimi", "codex", "deepseek" }) |name| try validateCommand(a, try preset(name));
    try std.testing.expectError(error.InvalidAcpAgent, preset("unknown"));
    for ([_][]const u8{ "[]", "[1]", "[\"\"]", "{}", "[\"a\\u0000b\"]" }) |bad| try std.testing.expectError(error.InvalidAcpCommand, validateCommand(a, bad));
    try validateCommand(a, "[\"/path with spaces/kimi\",\"acp\"]");
}
