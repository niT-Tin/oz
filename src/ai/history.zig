//! Workspace-scoped, private conversation journals. Each committed newline
//! commits only added or changed messages. A partial last write is invisible on replay.
const std = @import("std");
const ws = @import("workspace.zig");
const config = @import("config.zig");
const utf8 = @import("../buffer/utf8.zig");
const A = std.mem.Allocator;
const Io = std.Io;

const max_bytes = 8 * 1024 * 1024;
const recent_limit = 24;

pub fn directory(a: A, env: anytype) !?[]u8 {
    if (env.get("OZ_AGENT_DIR")) |path| return if (path.len != 0) try a.dupe(u8, path) else null;
    if (env.get("XDG_DATA_HOME")) |xdg| if (xdg.len > 0) return try std.fs.path.join(a, &.{ xdg, "oz", "agent" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(a, &.{ home, ".local/share/oz/agent" });
}

pub fn now(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

pub fn newKey(io: Io) [32]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn subject(a: A, prompt: []const u8) ![]u8 {
    const first = std.mem.sliceTo(prompt, '\n');
    const clipped = utf8.truncateWidth(first, 48);
    const copy = try a.dupe(u8, clipped);
    for (copy) |*c| if (c.* < 32 or c.* == 127) {
        c.* = ' ';
    };
    return copy;
}

fn workspaceDir(a: A, base: []const u8, root: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    return std.fs.path.join(a, &.{ base, "sessions", &std.fmt.bytesToHex(digest[0..16].*, .lower) });
}

/// Provider credentials and environment-dependent settings are freshly read
/// from the editor environment. Only the user's thread selections are saved.
const Profile = struct {
    model: []const u8,
    acp_command: ?[]const u8 = null,
    acp_cwd: ?[]const u8 = null,
};

const Patch = struct { index: usize, message: ws.Message };

fn fingerprint(message: ws.Message) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, .{ message.role, message.tool_status, message.tool_ms, message.display_only });
    inline for (.{ "text", "api_text", "tool_call_id", "tool_calls_json", "tool_name", "tool_args" }) |field| {
        const bytes: ?[]const u8 = @field(message, field);
        std.hash.autoHash(&hasher, if (bytes) |s| s.len else std.math.maxInt(usize));
        if (bytes) |s| hasher.update(s);
    }
    return hasher.final();
}

const Record = struct {
    v: u8 = 1,
    key: []const u8,
    root: []const u8,
    title: []const u8,
    created_ms: i64,
    updated_ms: i64,
    profile: Profile,
    acp_session: ?[]const u8 = null,
    acp_local_only: bool = false,
    count: usize,
    patches: []const Patch,
};

pub fn save(a: A, io: Io, base: []const u8, t: *ws.Thread, cfg: *const config.Config, first_changed: ?usize) !void {
    if (t.subject == null) return;
    const path = try workspaceDir(a, base, t.root.?);
    defer a.free(path);
    var dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
    defer dir.close(io);
    var messages = t.messages.items;
    if (messages.len > 0) {
        const last = messages[messages.len - 1];
        if (last.role == .assistant and last.text.len == 0 and last.tool_calls_json == null) messages = messages[0 .. messages.len - 1];
    }
    var from: usize = messages.len;
    while (from > 0) {
        from -= 1;
        if (messages[from].role == .user) break;
    }
    if (first_changed) |pos| from = @min(from, pos);
    from = @min(from, t.journal_hashes.items.len);
    try t.journal_hashes.ensureTotalCapacity(a, messages.len);

    // Concurrent continuations fork on a version mismatch. Each process keeps
    // both transcripts and can finish its own turn without overwriting a peer.
    var key = t.key;
    while (true) {
        const filename = key ++ ".jsonl";
        const fresh = t.disk_size == 0 or !std.mem.eql(u8, &key, &t.key);
        const file = dir.createFile(io, filename, .{
            .truncate = false,
            .exclusive = fresh,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock, error.PathAlreadyExists => {
                key = newKey(io);
                continue;
            },
            else => return err,
        };
        defer file.close(io);
        const size = try file.length(io);
        if (!fresh and size != t.disk_size) {
            key = newKey(io);
            continue;
        }
        const offset = if (fresh) 0 else t.valid_size;
        if (fresh) from = 0;
        var patches: std.ArrayList(Patch) = .empty;
        defer patches.deinit(a);
        var hashes: std.ArrayList(u64) = .empty;
        defer hashes.deinit(a);
        for (messages[from..], from..) |message, i| {
            var stable = message;
            stable.tool_expanded = false;
            const hash = fingerprint(stable);
            try hashes.append(a, hash);
            if (fresh or i >= t.journal_hashes.items.len or t.journal_hashes.items[i] != hash)
                try patches.append(a, .{ .index = i, .message = stable });
        }
        const stamp = now(io);
        const record: Record = .{
            .key = &key,
            .root = t.root.?,
            .title = t.subject.?,
            .created_ms = t.created_ms,
            .updated_ms = stamp,
            .profile = .{ .model = cfg.model, .acp_command = cfg.acp_command, .acp_cwd = cfg.acp_cwd },
            .acp_session = t.acp_session,
            .acp_local_only = t.acp_local_only,
            .count = messages.len,
            .patches = patches.items,
        };
        var line: Io.Writer.Allocating = .init(a);
        defer line.deinit();
        try std.json.Stringify.value(record, .{}, &line.writer);
        try line.writer.writeByte('\n');
        const bytes = line.written();
        if (offset + bytes.len > max_bytes) return error.SessionSizeLimit;
        if (size != offset) try file.setLength(io, offset);
        try file.writePositionalAll(io, bytes, offset);
        t.journal_hashes.shrinkRetainingCapacity(from);
        t.journal_hashes.appendSliceAssumeCapacity(hashes.items);
        t.key = key;
        t.disk_size = offset + bytes.len;
        t.valid_size = t.disk_size;
        t.updated_ms = stamp;
        return;
    }
}

pub const Restored = struct {
    thread: ws.Thread,
    cfg: config.Config,

    pub fn deinit(self: *Restored, a: A) void {
        self.thread.deinit(a);
        self.cfg.deinit(a);
    }
};

fn ownedProfile(a: A, defaults: *const config.Config, profile: Profile) !config.Config {
    var cfg = try defaults.clone(a);
    errdefer cfg.deinit(a);
    inline for (.{ "acp_command", "acp_cwd" }) |f| {
        const copy = if (@field(profile, f)) |s| try a.dupe(u8, s) else null;
        if (@field(cfg, f)) |prev| a.free(prev);
        @field(cfg, f) = copy;
    }
    const model = try a.dupe(u8, profile.model);
    a.free(cfg.model);
    cfg.model = model;
    return cfg;
}

fn cloneMessage(a: A, m: ws.Message) !ws.Message {
    const interrupted = m.role == .tool and (m.tool_status == .running or m.tool_status == .approval_required);
    const content = if (interrupted) "Interrupted in previous session" else m.text;
    const text = try a.dupe(u8, content);
    errdefer a.free(text);
    const api = try a.dupe(u8, if (interrupted and m.tool_status == .running) content else m.api_text);
    var copy: ws.Message = .{ .role = m.role, .text = text, .api_text = api, .display_only = m.display_only, .tool_status = if (interrupted) .cancelled else m.tool_status, .tool_ms = m.tool_ms };
    errdefer {
        a.free(api);
        inline for (.{ "tool_calls_json", "tool_call_id", "tool_name", "tool_args" }) |f| if (@field(copy, f)) |s| a.free(s);
    }
    inline for (.{ "tool_calls_json", "tool_call_id", "tool_name", "tool_args" }) |f| if (@field(m, f)) |s| {
        @field(copy, f) = try a.dupe(u8, s);
    };
    return copy;
}

fn decode(a: A, bytes: []const u8, key: [32]u8, root: []const u8, defaults: *const config.Config) !Restored {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var messages: std.ArrayList(ws.Message) = .empty;
    defer messages.deinit(a);
    var last: ?Record = null;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |end| {
        const record = try std.json.parseFromSliceLeaky(Record, arena.allocator(), bytes[pos..end], .{ .ignore_unknown_fields = true });
        if (record.v != 1 or !std.mem.eql(u8, record.key, &key) or !std.mem.eql(u8, record.root, root)) return error.InvalidSession;
        if (record.count < messages.items.len) messages.shrinkRetainingCapacity(record.count);
        for (record.patches) |patch| {
            if (patch.index == messages.items.len) {
                try messages.append(a, patch.message);
            } else if (patch.index < messages.items.len) {
                messages.items[patch.index] = patch.message;
            } else return error.InvalidSession;
        }
        if (messages.items.len != record.count) return error.InvalidSession;
        last = record;
        pos = end + 1;
    }
    const meta = last orelse return error.InvalidSession;
    var t: ws.Thread = .{ .id = 0, .title = try a.dupe(u8, ""), .created_ms = meta.created_ms, .updated_ms = meta.updated_ms, .key = key, .valid_size = pos, .disk_size = bytes.len, .acp_local_only = meta.acp_local_only };
    errdefer t.deinit(a);
    t.root = try a.dupe(u8, root);
    t.subject = try subject(a, meta.title);
    if (meta.acp_session) |sid| t.acp_session = try a.dupe(u8, sid);
    try t.messages.ensureTotalCapacity(a, messages.items.len);
    try t.journal_hashes.ensureTotalCapacity(a, messages.items.len);
    for (messages.items) |m| {
        t.journal_hashes.appendAssumeCapacity(fingerprint(m));
        if (m.role == .tool and m.tool_call_id == null) return error.InvalidSession;
        if (m.tool_calls_json) |json| {
            const calls = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
            if (calls != .array or m.role != .assistant) return error.InvalidSession;
        }
        t.messages.appendAssumeCapacity(try cloneMessage(a, m));
    }
    return .{ .thread = t, .cfg = try ownedProfile(a, defaults, meta.profile) };
}

/// The journals are the index. Discover the most recently modified files,
/// then order the surviving sessions by their last committed update.
pub fn recent(a: A, io: Io, base: []const u8, root: []const u8, defaults: *const config.Config) ![]Restored {
    const path = try workspaceDir(a, base, root);
    defer a.free(path);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return a.alloc(Restored, 0),
        else => return e,
    };
    defer dir.close(io);
    const Candidate = struct { key: [32]u8, mtime: i96 };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(a);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (entry.kind != .file or name.len != 38 or !std.mem.endsWith(u8, name, ".jsonl")) continue;
        for (name[0..32]) |c| {
            if (!std.ascii.isHex(c)) break;
        } else {
            const stat = dir.statFile(io, name, .{}) catch continue;
            if (stat.size <= max_bytes) try candidates.append(a, .{ .key = name[0..32].*, .mtime = stat.mtime.nanoseconds });
        }
    }
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn less(_: void, l: Candidate, r: Candidate) bool {
            return l.mtime > r.mtime;
        }
    }.less);
    var items: std.ArrayList(Restored) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(a);
        items.deinit(a);
    }
    try items.ensureTotalCapacity(a, @min(candidates.items.len, recent_limit));
    for (candidates.items) |candidate| {
        const bytes = dir.readFileAlloc(io, candidate.key ++ ".jsonl", a, .limited(max_bytes)) catch continue;
        defer a.free(bytes);
        const item = decode(a, bytes, candidate.key, root, defaults) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        items.appendAssumeCapacity(item);
        if (items.items.len == recent_limit) break;
    }
    std.mem.sort(Restored, items.items, {}, struct {
        fn less(_: void, l: Restored, r: Restored) bool {
            return l.thread.updated_ms > r.thread.updated_ms;
        }
    }.less);
    return items.toOwnedSlice(a);
}

test "agent history: private paths and Unicode subject width" {
    const t = std.testing;
    var env = std.StringHashMap([]const u8).init(t.allocator);
    defer env.deinit();
    for ([_][3][]const u8{
        .{ "HOME", "/user", "/user/.local/share/oz/agent" },
        .{ "XDG_DATA_HOME", "/data", "/data/oz/agent" },
        .{ "OZ_AGENT_DIR", "/override", "/override" },
    }) |row| {
        try env.put(row[0], row[1]);
        const dir = (try directory(t.allocator, &env)).?;
        defer t.allocator.free(dir);
        try t.expectEqualStrings(row[2], dir);
    }
    const title = try subject(t.allocator, "中中中中中中中中中中中中中中中中中中中中中中中中中中中中" ++ "\nignored");
    defer t.allocator.free(title);
    try t.expectEqualStrings("中中中中中中中中中中中中中中中中中中中中中中中中", title);
}

test "agent history: recover partial tail, fold tool changes and fork concurrent continuations" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var env = std.StringHashMap([]const u8).init(a);
    defer env.deinit();
    try env.put("OZ_AI_API_KEY", "SECRET_NEVER_STORED");
    var cfg = try config.fromEnv(a, &env);
    defer cfg.deinit(a);
    var threads: ws.Threads = .{};
    defer threads.deinit(a);
    const idx = try threads.create(a);
    const t = &threads.items.items[idx];
    t.key = newKey(io);
    t.root = try a.dupe(u8, "/project");
    t.subject = try subject(a, "first subject");
    try threads.appendUser(a, idx, "first subject", "user context");
    try save(a, io, base, t, &cfg, null);
    const card = try threads.appendToolMessage(a, idx, "call", "Bash", "pwd", .running, "");
    t.messages.items[card].display_only = true;
    try save(a, io, base, t, &cfg, null);
    const path = try workspaceDir(a, base, "/project");
    defer a.free(path);
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const filename = t.key ++ ".jsonl";
    var file = try dir.openFile(io, filename, .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, "{broken", t.disk_size);
    const wrong = try recent(a, io, base, "/other-project", &cfg);
    defer a.free(wrong);
    try std.testing.expectEqual(@as(usize, 0), wrong.len);
    const original = try recent(a, io, base, "/project", &cfg);
    defer {
        for (original) |*r| r.deinit(a);
        a.free(original);
    }
    try std.testing.expectEqual(@as(usize, 1), original.len);
    const restored = &original[0].thread;
    try std.testing.expectEqual(ws.ToolStatus.cancelled, restored.messages.items[card].tool_status);
    try std.testing.expect(restored.messages.items[card].display_only);
    try save(a, io, base, restored, &cfg, null);
    try std.testing.expectEqualStrings(&t.key, &restored.key);
    try threads.setToolOutcome(a, idx, card, .ok, "ok", "output", 3);
    try save(a, io, base, t, &cfg, null);
    try std.testing.expect(!std.mem.eql(u8, &t.key, &restored.key));
    const bytes = try dir.readFileAlloc(io, filename, a, .limited(max_bytes));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{broken") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "SECRET_NEVER_STORED") == null);
    try dir.writeFile(io, .{ .sub_path = "00000000000000000000000000000000.jsonl", .data = "{\"v\":99}\n" });
    const both = try recent(a, io, base, "/project", &cfg);
    defer {
        for (both) |*r| r.deinit(a);
        a.free(both);
    }
    try std.testing.expectEqual(@as(usize, 2), both.len);
    for (both) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.thread.messages.items.len);
        if (std.mem.eql(u8, &r.thread.key, &t.key))
            try std.testing.expectEqualStrings("output", r.thread.messages.items[card].api_text);
    }
}
