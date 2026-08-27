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
    /// :qa / :qa! — quit every window/buffer (exit the editor).
    quit_all,
    /// :vs — vertical split (side-by-side windows).
    vsplit,
    /// :sp — horizontal split (stacked windows).
    split,
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
    /// :theme [name] — switch color theme (no arg lists available themes).
    theme: []const u8,
    /// :<number> — jump to that line (1-based; the caller clamps).
    goto_line: u32,
    /// :s/pat/rep[/g] — substitute on the current line; :%s for the whole
    /// file; :'<,'>s for the visual selection. M1: literal substring
    /// matching (no regex).
    substitute: struct {
        whole_file: bool,
        /// True when the command came from visual mode (:'<,'>s) — the
        /// caller applies it to the visual line range.
        visual: bool,
        pattern: []const u8,
        replacement: []const u8,
        global: bool,
    },
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
    var t = trim(line);
    if (t.len == 0) return .empty;

    // vim auto-types :'<,'> when ':' is pressed in visual mode. Strip the
    // range marks; only :s uses them (the caller resolves the range).
    var visual = false;
    if (t.len >= 5 and std.mem.eql(u8, t[0..5], "'<,'>")) {
        visual = true;
        t = t[5..];
    }
    if (t.len == 0) return .empty;

    // split into command word and arguments at the first space/tab
    var split: usize = 0;
    while (split < t.len and t[split] != ' ' and t[split] != '\t') : (split += 1) {}
    const word = t[0..split];
    const args = trim(t[split..]);

    // :<number> jumps to that line (vim); :0 behaves like :1 there.
    var all_digits = true;
    for (word) |c| {
        if (c < '0' or c > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits and args.len == 0) {
        const n = std.fmt.parseInt(u32, word, 10) catch std.math.maxInt(u32);
        return .{ .goto_line = n };
    }

    if (std.mem.eql(u8, word, "w") or std.mem.eql(u8, word, "write")) {
        return if (args.len == 0) .write else .unknown;
    }
    if (std.mem.eql(u8, word, "q") or std.mem.eql(u8, word, "quit")) {
        return if (args.len == 0) .quit else .unknown;
    }
    if (std.mem.eql(u8, word, "q!") or std.mem.eql(u8, word, "quit!")) return .quit_force;
    if (std.mem.eql(u8, word, "qa") or std.mem.eql(u8, word, "qall") or
        std.mem.eql(u8, word, "qa!") or std.mem.eql(u8, word, "qall!")) return .quit_all;
    if (std.mem.eql(u8, word, "vs") or std.mem.eql(u8, word, "vsplit") or
        std.mem.eql(u8, word, "vnew")) return .vsplit;
    if (std.mem.eql(u8, word, "sp") or std.mem.eql(u8, word, "split") or
        std.mem.eql(u8, word, "new")) return .split;
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
    if (std.mem.eql(u8, word, "theme") or std.mem.eql(u8, word, "colorscheme")) return .{ .theme = args };

    // :s/pat/rep/g and :%s/pat/rep/g
    if (t[0] == 's' or (t.len >= 2 and t[0] == '%' and t[1] == 's')) {
        const whole_file = t[0] == '%';
        const i: usize = if (whole_file) 1 else 0;
        if (i + 1 >= t.len or t[i] != 's' or t[i + 1] != '/') return .unknown;
        // pattern: up to unescaped '/'
        var j = i + 2;
        var pat_end: ?usize = null;
        while (j < t.len) : (j += 1) {
            if (t[j] == '\\') {
                j += 1;
                continue;
            }
            if (t[j] == '/') {
                pat_end = j;
                break;
            }
        }
        const pe = pat_end orelse return .unknown;
        // replacement: up to unescaped '/' or end
        var k = pe + 1;
        var rep_end: usize = t.len;
        while (k < t.len) : (k += 1) {
            if (t[k] == '\\') {
                k += 1;
                continue;
            }
            if (t[k] == '/') {
                rep_end = k;
                break;
            }
        }
        // flags follow the closing '/'; with none the replacement runs to
        // the end of the line and there are no flags (":s/a/b" is valid).
        const flags = if (rep_end < t.len) t[rep_end + 1 ..] else t[t.len..];
        const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
        return .{ .substitute = .{
            .whole_file = whole_file,
            .visual = visual,
            .pattern = t[i + 2 .. pe],
            .replacement = t[pe + 1 .. rep_end],
            .global = global,
        } };
    }

    return .unknown;
}

/// Restore a `/` that was escaped as `\/` inside an :s pattern/replacement.
/// The scanner keeps the backslash so the slash doesn't terminate the field;
/// substitute matching treats the pattern literally, so `a\/b` must mean
/// `a/b`. Any other `\x` pair is kept verbatim (vim regex escapes, which a
/// literal matcher does not interpret).
pub fn unescapeSubSep(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '/') {
            try out.append(alloc, '/');
            i += 1;
        } else {
            try out.append(alloc, src[i]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

test "parse: write/quit family" {
    try std.testing.expect(parse("w") == .write);
    try std.testing.expect(parse("  w  ") == .write);
    try std.testing.expect(parse("q") == .quit);
    try std.testing.expect(parse("q!") == .quit_force);
    try std.testing.expect(parse("wq") == .write_quit);
    try std.testing.expect(parse("") == .empty);
    try std.testing.expect(parse("   ") == .empty);
    try std.testing.expect(parse("qa") == .quit_all);
    try std.testing.expect(parse("qall!") == .quit_all);
    try std.testing.expect(parse("vs") == .vsplit);
    try std.testing.expect(parse("vsplit") == .vsplit);
    try std.testing.expect(parse("sp") == .split);
    try std.testing.expect(parse("split") == .split);
}

test "parse: edit with and without args" {
    try std.testing.expect(parse("e") == .unknown);
    const c = parse("e  src/main.zig  ");
    try std.testing.expect(c == .edit);
    try std.testing.expectEqualStrings("src/main.zig", c.edit);
}

test "parse: substitute without a trailing separator or flags" {
    // ":s/a/b" (no trailing '/') is valid vim — it must not crash the parser.
    const sub = parse("s/a/b");
    try std.testing.expect(sub == .substitute);
    try std.testing.expect(!sub.substitute.whole_file);
    try std.testing.expectEqualStrings("a", sub.substitute.pattern);
    try std.testing.expectEqualStrings("b", sub.substitute.replacement);
    try std.testing.expect(!sub.substitute.global);

    // a trailing escape in the replacement must not run the flag scan out
    // of bounds either
    const sub2 = parse("s/a/b\\");
    try std.testing.expect(sub2 == .substitute);
    try std.testing.expectEqualStrings("b\\", sub2.substitute.replacement);

    const sub3 = parse("%s/x/y");
    try std.testing.expect(sub3 == .substitute);
    try std.testing.expect(sub3.substitute.whole_file);
    try std.testing.expect(!sub3.substitute.global);
}

test "substitute: unescapeSubSep restores \\/ but keeps other escapes" {
    const a = std.testing.allocator;
    const p = try unescapeSubSep(a, "a\\/b");
    defer a.free(p);
    try std.testing.expectEqualStrings("a/b", p);

    const q = try unescapeSubSep(a, "a\\tb\\/c");
    defer a.free(q);
    try std.testing.expectEqualStrings("a\\tb/c", q);

    // trailing lone backslash survives untouched
    const r = try unescapeSubSep(a, "x\\");
    defer a.free(r);
    try std.testing.expectEqualStrings("x\\", r);

    const s = try unescapeSubSep(a, "plain");
    defer a.free(s);
    try std.testing.expectEqualStrings("plain", s);
}

test "parse: bare number is goto-line" {
    const c = parse("42");
    try std.testing.expect(c == .goto_line);
    try std.testing.expectEqual(@as(u32, 42), c.goto_line);
    try std.testing.expect(parse("0") == .goto_line);
    try std.testing.expect(parse("7 ") == .goto_line);
    // digits with an argument are not a line jump
    try std.testing.expect(parse("12 x") == .unknown);
    try std.testing.expect(parse("1a") == .unknown);
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
    const sub = parse("%s/foo/bar/g");
    try std.testing.expect(sub == .substitute);
    try std.testing.expect(sub.substitute.whole_file);
    try std.testing.expectEqualStrings("foo", sub.substitute.pattern);
    try std.testing.expectEqualStrings("bar", sub.substitute.replacement);
    try std.testing.expect(sub.substitute.global);
    const sub2 = parse("s/a/b/");
    try std.testing.expect(sub2 == .substitute);
    try std.testing.expect(!sub2.substitute.whole_file);
    try std.testing.expect(!sub2.substitute.global);
    const vsub = parse("'<,'>s/foo/bar/");
    try std.testing.expect(vsub == .substitute);
    try std.testing.expect(vsub.substitute.visual);
    try std.testing.expect(!vsub.substitute.whole_file);
    try std.testing.expectEqualStrings("foo", vsub.substitute.pattern);
    try std.testing.expectEqualStrings("bar", vsub.substitute.replacement);
    try std.testing.expect(parse("'<,'>") == .empty);
    try std.testing.expect(parse("'<,'>w") == .write);
    try std.testing.expect(parse("foobar") == .unknown);
    try std.testing.expect(parse("w extra") == .unknown);
    try std.testing.expect(parse("q extra") == .unknown);
}
