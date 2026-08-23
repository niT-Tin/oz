//! Ex command line parsing (DESIGN.md §6.7). Pure logic: a command-line string
//! like "wq" or "e src/main.zig" becomes a Command. M0 minimal set only.
const std = @import("std");

pub const Command = union(enum) {
    /// Empty line (just closes the command line, no-op).
    empty,
    /// :w — write the current buffer.
    write,
    /// :q — quit (fails if the buffer is modified; caller decides).
    quit,
    /// :q! — quit without writing.
    quit_force,
    /// :wq — write then quit.
    write_quit,
    /// :e <file> — open file (replacing the current buffer).
    edit: []const u8,
    /// :bn / :bp / :bd / :ls — buffer management (M0: single buffer).
    buffer_next,
    buffer_prev,
    buffer_list,
    buffer_delete,
    /// :noh — clear search highlight (M0: no-op).
    noh,
    /// :set <option> — M0: accepted, applied if recognized, else ignored.
    set: []const u8,
    /// Anything unrecognized.
    unknown,
};

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

/// Parse a command line (without the leading ':').
pub fn parse(line: []const u8) Command {
    const t = trim(line);
    if (t.len == 0) return .empty;

    // split into command word and arguments at the first space/tab
    var split: usize = 0;
    while (split < t.len and t[split] != ' ' and t[split] != '\t') : (split += 1) {}
    const word = t[0..split];
    const args = trim(t[split..]);

    if (std.mem.eql(u8, word, "w") or std.mem.eql(u8, word, "write")) {
        return if (args.len == 0) .write else .unknown;
    }
    if (std.mem.eql(u8, word, "q") or std.mem.eql(u8, word, "quit")) {
        return if (args.len == 0) .quit else .unknown;
    }
    if (std.mem.eql(u8, word, "q!")) return .quit_force;
    if (std.mem.eql(u8, word, "wq") or std.mem.eql(u8, word, "x")) {
        return if (args.len == 0) .write_quit else .unknown;
    }
    if (std.mem.eql(u8, word, "e") or std.mem.eql(u8, word, "edit")) {
        return if (args.len == 0) .unknown else .{ .edit = args };
    }
    if (std.mem.eql(u8, word, "bn") or std.mem.eql(u8, word, "bnext")) return .buffer_next;
    if (std.mem.eql(u8, word, "bp") or std.mem.eql(u8, word, "bprev")) return .buffer_prev;
    if (std.mem.eql(u8, word, "ls") or std.mem.eql(u8, word, "buffers")) return .buffer_list;
    if (std.mem.eql(u8, word, "bd") or std.mem.eql(u8, word, "bdelete")) return .buffer_delete;
    if (std.mem.eql(u8, word, "noh") or std.mem.eql(u8, word, "nohlsearch")) return .noh;
    if (std.mem.eql(u8, word, "set")) return .{ .set = args };

    return .unknown;
}

test "parse: write/quit family" {
    try std.testing.expect(parse("w") == .write);
    try std.testing.expect(parse("  w  ") == .write);
    try std.testing.expect(parse("q") == .quit);
    try std.testing.expect(parse("q!") == .quit_force);
    try std.testing.expect(parse("wq") == .write_quit);
    try std.testing.expect(parse("") == .empty);
    try std.testing.expect(parse("   ") == .empty);
}

test "parse: edit with and without args" {
    try std.testing.expect(parse("e") == .unknown);
    const c = parse("e  src/main.zig  ");
    try std.testing.expect(c == .edit);
    try std.testing.expectEqualStrings("src/main.zig", c.edit);
}

test "parse: buffers, noh, set, unknown" {
    try std.testing.expect(parse("bn") == .buffer_next);
    try std.testing.expect(parse("bp") == .buffer_prev);
    try std.testing.expect(parse("ls") == .buffer_list);
    try std.testing.expect(parse("bd") == .buffer_delete);
    try std.testing.expect(parse("noh") == .noh);
    const c = parse("set tabstop=2");
    try std.testing.expect(c == .set);
    try std.testing.expectEqualStrings("tabstop=2", c.set);
    try std.testing.expect(parse("foobar") == .unknown);
    try std.testing.expect(parse("w extra") == .unknown);
    try std.testing.expect(parse("q extra") == .unknown);
}
