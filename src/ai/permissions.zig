//! Conservative convenience policy, not a shell sandbox. Unknown operations
//! require review; /auto never grants a persistent harness permission.
const std = @import("std");

pub const Mode = enum { manual, auto };

pub fn readOnlyCommand(command: []const u8) bool {
    if (command.len == 0 or command.len > 16384) return false;
    // No substitution, redirection, compound commands, escaping or control
    // bytes. Quoted literal spaces are sufficient for normal read requests.
    for (command) |c| if (c < 32 or c == 127 or std.mem.indexOfScalar(u8, "$`\\;|&<>(){}", c) != null) return false;
    var tokens: [128][]const u8 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < command.len) {
        while (i < command.len and command[i] == ' ') : (i += 1) {}
        if (i == command.len) break;
        if (count == tokens.len) return false;
        const start = i;
        var quote: u8 = 0;
        while (i < command.len) : (i += 1) {
            const c = command[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == ' ') break;
        }
        if (quote != 0) return false;
        tokens[count] = command[start..i];
        count += 1;
    }
    if (count == 0) return false;
    const name = tokens[0];
    var known = false;
    for ([_][]const u8{ "pwd", "ls", "cat", "head", "tail", "wc", "rg" }) |allowed| {
        if (std.mem.eql(u8, name, allowed)) {
            known = true;
            break;
        }
    }
    if (!known) return false;
    // ripgrep has external preprocessor/hostname helpers. Reject quoted or
    // concatenated option spellings too, rather than parsing shell words.
    if (std.mem.eql(u8, name, "rg")) {
        var plain: [16384]u8 = undefined;
        var n: usize = 0;
        for (command) |c| if (c != '\'' and c != '"' and c != ' ') {
            plain[n] = c;
            n += 1;
        };
        for ([_][]const u8{ "--pre", "--hostname-bin" }) |bad| if (std.mem.indexOf(u8, plain[0..n], bad) != null) return false;
    }
    return true;
}

const V = std.json.Value;
fn field(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn str(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
fn eq(v: V, text: []const u8) bool {
    return std.mem.eql(u8, str(v), text);
}

pub fn readOnlyAcp(alloc: std.mem.Allocator, raw: []const u8) bool {
    if (raw.len > 16384) return false;
    var parsed = std.json.parseFromSlice(V, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    const v = parsed.value;
    const kind = field(v, "kind");
    const read = eq(kind, "read") or eq(kind, "search");
    if (!read and !eq(kind, "execute")) return false;
    const input = field(v, "rawInput");
    if (input == .null) return read;
    if (input != .object) return false;
    if (input.object.get("command")) |cmd| {
        // Extra script/argv/etc fields might execute a different operation.
        if (input.object.count() != 1 or cmd != .string) return false;
        return readOnlyCommand(cmd.string);
    }
    if (!read) return false;
    var it = input.object.iterator();
    while (it.next()) |entry| {
        var known = false;
        for ([_][]const u8{ "path", "file_path", "filePath", "uri", "pattern", "query", "glob", "limit", "offset", "start_line", "end_line", "recursive", "case_sensitive" }) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) {
                known = true;
                break;
            }
        }
        if (!known) return false;
        switch (entry.value_ptr.*) {
            .string, .integer, .bool => {},
            else => return false,
        }
    }
    return true;
}

/// Human-readable review with captured workspace. Raw JSON remains escaped
/// on a final line so unknown harness fields are visible for a decision.
pub fn describeAcp(alloc: std.mem.Allocator, raw: []const u8, root: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(V, alloc, raw, .{}) catch return alloc.dupe(u8, "ACP operation: invalid details; reject or cancel");
    defer parsed.deinit();
    const v = parsed.value;
    const title = try @import("terminal_tool.zig").escapeCommand(alloc, str(field(v, "title")));
    defer alloc.free(title);
    const kind = try @import("terminal_tool.zig").escapeCommand(alloc, str(field(v, "kind")));
    defer alloc.free(kind);
    const cwd = try @import("terminal_tool.zig").escapeCommand(alloc, root);
    defer alloc.free(cwd);
    return std.fmt.allocPrint(alloc, "Action: {s}\nKind: {s}\nWorkspace: {s}\nDetails: {s}", .{ title, kind, cwd, raw });
}

test "auto policy: read-only allowlist rejects shell execution and write disguises" {
    for ([_][]const u8{ "pwd", "ls -la", "cat 'src/main.zig'", "head -n 20 README.md", "tail -n 2 a", "wc -l a", "rg --line-number 'fn main' src" }) |cmd| try std.testing.expect(readOnlyCommand(cmd));
    for ([_][]const u8{ "", "rm a", "cp a b", "mv a b", "touch a", "cat a > b", "ls; rm a", "ls && rm a", "ls | sh", "cat $(touch a)", "cat `touch a`", "cat a\nrm b", "rg --pre=sh x", "rg --hostname-bin sh x", "find . -delete", "find . -exec sh {} ;", "git diff", "python -c 'print(1)'", "FOO=x cat a", "cat 'unterminated", "cat a\\;rm b" }) |cmd| try std.testing.expect(!readOnlyCommand(cmd));
}

test "auto policy: ACP reads accept bounded known input; kind alone cannot hide a command or write" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        \\{"title":"Read source","kind":"read","rawInput":{"path":"src/main.zig","start_line":1}}
        ,
        \\{"kind":"search","rawInput":{"pattern":"main","path":"src"}}
        ,
        \\{"kind":"execute","rawInput":{"command":"pwd"}}
    }) |raw| try std.testing.expect(readOnlyAcp(a, raw));
    for ([_][]const u8{
        \\{"kind":"read","rawInput":{"command":"rm README.md"}}
        ,
        \\{"kind":"read","rawInput":{"path":"a","newText":"overwrite"}}
        ,
        \\{"kind":"edit","rawInput":{"path":"a"}}
        ,
        \\{"title":"Read only","rawInput":{"command":"pwd"}}
        ,
        \\{"kind":"execute","rawInput":{"command":"pwd","script":"rm a"}}
        ,
        "null",
        "{broken",
    }) |raw| try std.testing.expect(!readOnlyAcp(a, raw));
}
