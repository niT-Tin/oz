//! Note store (DESIGN.md §18.4, M2b1): the on-disk markdown notes behind
//! the navigator's Notes tab.
//!
//! Notes are ordinary `.md` files in one global data directory (notes are
//! project-independent). This module owns the pure model + filesystem scan
//! and is deliberately App/vaxis-independent; `src/app/notes.zig` owns the
//! App-facing cache, keys and focus.
//!
//! ## Storage
//!
//! Resolution precedence (first non-empty wins):
//!   1. `OZ_NOTES_DIR` (documented user override, also the e2e seam)
//!   2. `$XDG_DATA_HOME/oz/notes`
//!   3. `$HOME/.local/share/oz/notes`
//!
//! The directory is created lazily by the first list/create; nothing here
//! runs at editor startup. New files are `<smallest free note-N>.md` with
//! `O_EXCL` creation, so an existing note is never overwritten.
//!
//! ## Ordering and titles
//!
//! The list is sorted by modification time descending, ties broken by
//! filename descending (newest-created first). That total order is
//! deterministic for equal filesystem timestamps and puts a just-created
//! note at the top. A note's display title is its first ATX markdown
//! heading (`# heading`), else its filename; its snippet is the first
//! non-blank, non-heading line. Files are read head-only (8 KiB) for these.

const std = @import("std");

/// New-note template (exactly this file content, DESIGN §18.4).
pub const note_template = "# Untitled note\n\n";

/// Bytes read from each note for title/snippet extraction. A note whose
/// heading is past this window falls back to its filename.
pub const head_bytes: usize = 8 * 1024;

/// Longest stored snippet (UTF-8 boundary respected). The renderer
/// truncates further to the 28-cell sidebar.
pub const max_snippet_bytes: usize = 160;

/// One note as shown in the navigator list. All fields are owned strings;
/// `path` is absolute when `scanDir` was given an absolute directory.
pub const Note = struct {
    path: []u8,
    filename: []u8,
    title: []u8,
    snippet: []u8,
    mtime_ns: i128,

    pub fn deinit(self: *Note, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.filename);
        alloc.free(self.title);
        alloc.free(self.snippet);
    }
};

/// Cached navigator Notes state. A plain value on App (all owned memory is
/// freed by `deinit`), so the store is project/workspace independent.
pub const Store = struct {
    /// Resolved absolute notes directory; null until the first Notes use
    /// (no startup filesystem work, no startup directory creation).
    dir: ?[]u8 = null,
    items: std.ArrayList(Note) = .empty,
    /// True once a refresh finished (successfully or with `err`). The tab
    /// entry/create/save/r paths refresh explicitly; frames never scan.
    loaded: bool = false,
    /// Human-readable load/create failure shown in the Notes tab.
    err: ?[]u8 = null,
    /// Selected note index and scroll top, both in note units (two rows
    /// per note). Clamped by the renderer.
    sel: usize = 0,
    top: usize = 0,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        self.clearItems(alloc);
        self.items.deinit(alloc);
        if (self.dir) |d| alloc.free(d);
        if (self.err) |e| alloc.free(e);
        self.* = undefined;
    }

    /// Free the cached notes but keep the list/selection allocation.
    pub fn clearItems(self: *Store, alloc: std.mem.Allocator) void {
        for (self.items.items) |*n| n.deinit(alloc);
        self.items.clearRetainingCapacity();
    }

    pub fn setError(self: *Store, alloc: std.mem.Allocator, text: []const u8) void {
        if (self.err) |e| alloc.free(e);
        self.err = alloc.dupe(u8, text) catch null;
    }

    pub fn clearError(self: *Store, alloc: std.mem.Allocator) void {
        if (self.err) |e| alloc.free(e);
        self.err = null;
    }

    /// Path of the selected note, or null when the list is empty/stale.
    pub fn selectedPath(self: *const Store) ?[]const u8 {
        if (self.sel >= self.items.items.len) return null;
        return self.items.items[self.sel].path;
    }

    /// Restore the selection by path after a refresh; falls back to the
    /// clamped numeric index (or 0) when the file disappeared.
    pub fn selectPath(self: *Store, path: []const u8) void {
        for (self.items.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.path, path)) {
                self.sel = i;
                return;
            }
        }
        self.sel = 0;
    }
};

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    if (s.len == 0) return null;
    return s;
}

/// Resolve and normalize a path to absolute form (also strips a trailing
/// slash and `.`/`..` segments without requiring the path to exist).
fn normalizeDir(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    return std.Io.Dir.path.resolve(alloc, &.{raw});
}

/// Resolve the notes directory for `env`, a map-like object with
/// `get(key) ?[]const u8` (`std.process.Environ.Map`, `StringHashMap`, …).
/// Returns an owned absolute path. Error.NotesDirUnavailable when no source
/// is configured (the App turns that into a visible navigator error).
pub fn resolveDir(alloc: std.mem.Allocator, env: anytype) ![]u8 {
    if (nonEmpty(env.get("OZ_NOTES_DIR"))) |dir| return normalizeDir(alloc, dir);
    if (nonEmpty(env.get("XDG_DATA_HOME"))) |xdg| {
        const joined = try std.fs.path.join(alloc, &.{ xdg, "oz", "notes" });
        defer alloc.free(joined);
        return normalizeDir(alloc, joined);
    }
    if (nonEmpty(env.get("HOME"))) |home| {
        const joined = try std.fs.path.join(alloc, &.{ home, ".local", "share", "oz", "notes" });
        defer alloc.free(joined);
        return normalizeDir(alloc, joined);
    }
    return error.NotesDirUnavailable;
}

/// True when `path` is a file directly under the notes directory `dir`.
/// Used to keep opening a note from re-rooting the workspace at the data
/// directory and to refresh the list after saving a note.
pub fn isPathInside(dir: []const u8, path: []const u8) bool {
    if (path.len <= dir.len) return false;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path[dir.len] == '/';
}

/// Extract the first ATX heading text from `line`, or null. Accepts 1-6
/// leading '#' followed by a space; trailing closing '#' runs are removed.
fn headingText(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '#' and i < 7) : (i += 1) {}
    if (i == 0 or i > 6) return null;
    if (i >= line.len or line[i] != ' ') return null;
    var text = std.mem.trim(u8, line[i + 1 ..], " \t\r");
    // ATX closing sequence: "## Heading ##" -> "Heading"
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    if (end < text.len) {
        var trim_end = end;
        while (trim_end > 0 and (text[trim_end - 1] == ' ' or text[trim_end - 1] == '\t')) trim_end -= 1;
        if (trim_end == 0) return null; // "###" only
        text = text[0..trim_end];
    }
    if (text.len == 0) return null;
    return text;
}

/// Strip the light markdown decoration that would otherwise dominate a
/// one-line snippet (blockquote/list markers). Content is kept verbatim.
fn cleanSnippet(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t\r");
    if (s.len >= 2 and (s[0] == '>' or s[0] == '-' or s[0] == '*' or s[0] == '+') and s[1] == ' ') {
        s = std.mem.trimStart(u8, s[2..], " \t");
    } else {
        var digits: usize = 0;
        while (digits < 3 and digits < s.len and s[digits] >= '0' and s[digits] <= '9') : (digits += 1) {}
        if (digits > 0 and digits + 1 < s.len and s[digits] == '.' and s[digits + 1] == ' ') {
            s = std.mem.trimStart(u8, s[digits + 2 ..], " \t");
        }
    }
    return s;
}

/// Duplicate at most `max` bytes of `s` without splitting a UTF-8 sequence.
fn dupeBounded(alloc: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    var end = @min(s.len, max);
    if (end < s.len) {
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    }
    return alloc.dupe(u8, s[0..end]);
}

/// Display title for a note: first markdown heading, else the filename.
pub fn titleFor(alloc: std.mem.Allocator, filename: []const u8, content: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        if (headingText(raw)) |h| return alloc.dupe(u8, h);
    }
    return alloc.dupe(u8, filename);
}

/// First non-blank non-heading line, decorated markers stripped and bytes
/// bounded. Empty string when the note has no body yet (a new note).
pub fn snippetFor(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (headingText(raw) != null) continue;
        const s = cleanSnippet(raw);
        if (s.len == 0) continue;
        return dupeBounded(alloc, s, max_snippet_bytes);
    }
    return alloc.dupe(u8, "");
}

/// Parse the number of `<prefix>note-<N>.md` (the only names `createNoteFile`
/// allocates), or null. Kept narrow so unrelated markdown files are never
/// mistaken for a collision.
pub fn noteNameNumber(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "note-")) return null;
    if (!std.mem.endsWith(u8, name, ".md")) return null;
    const digits = name["note-".len .. name.len - ".md".len];
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// Smallest unused `note-N.md` for the given existing filenames. The rule
/// is "smallest free number ≥ 1", so the result is deterministic and a
/// deleted number is reused only when no file occupies it.
pub fn nextNameFromNames(alloc: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var n: u64 = 1;
    while (n < std.math.maxInt(u32)) : (n += 1) {
        var taken = false;
        for (names) |name| {
            if (noteNameNumber(name)) |x| {
                if (x == n) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) return std.fmt.allocPrint(alloc, "note-{d}.md", .{n});
    }
    return error.NoteNameExhausted;
}

fn noteLess(_: void, a: Note, b: Note) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.order(u8, a.filename, b.filename) == .gt;
}

/// Sort in place: modification time descending, filename descending on
/// ties (deterministic; newest-created first).
pub fn sortNotes(items: []Note) void {
    std.mem.sort(Note, items, {}, noteLess);
}

fn readHead(dir: std.Io.Dir, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
    var f = try dir.openFile(io, name, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const want: usize = @intCast(@min(st.size, buf.len));
    if (want == 0) return "";
    const got = try f.readPositionalAll(io, buf[0..want], 0);
    return buf[0..got];
}

/// Scan `dir_path` (absolute) for `.md` files and build the sorted note
/// list. A missing directory is an empty list (it is created lazily on
/// create/list by the App); unreadable individual files still list with
/// their filename and an empty snippet. The caller owns the returned list
/// and every `Note`.
pub fn scanDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(Note) {
    var out: std.ArrayList(Note) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(alloc);
        out.deinit(alloc);
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (!std.mem.endsWith(u8, name, ".md")) continue;
        const st = dir.statFile(io, name, .{}) catch continue;

        var head_buf: [head_bytes]u8 = undefined;
        const head = readHead(dir, io, name, &head_buf) catch "";

        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        errdefer alloc.free(path);
        const filename = try alloc.dupe(u8, name);
        errdefer alloc.free(filename);
        const title = try titleFor(alloc, name, head);
        errdefer alloc.free(title);
        const snippet = try snippetFor(alloc, head);
        errdefer alloc.free(snippet);
        try out.append(alloc, .{
            .path = path,
            .filename = filename,
            .title = title,
            .snippet = snippet,
            .mtime_ns = st.mtime.nanoseconds,
        });
    }
    sortNotes(out.items);
    return out;
}

/// List the `.md` filenames in `dir_path` (owned slices; sorted for stable
/// tests/messages). Missing directory = empty.
pub fn listNames(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

/// Create the notes directory if needed and write a new note with
/// `note_template`. Returns the owned absolute path. Uses O_EXCL so an
/// existing file is never overwritten; the smallest free `note-N.md` is
/// chosen deterministically (bounded retries cover a concurrent create).
pub fn createNoteFile(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        var names = try listNames(io, alloc, dir_path);
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        const name = try nextNameFromNames(alloc, names.items);
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        errdefer alloc.free(path);
        var f = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return e,
        };
        defer f.close(io);
        try f.writeStreamingAll(io, note_template);
        return path;
    }
    return error.NoteNameCollision;
}

/// Relative age for the list: `now` (<1m), `Nm`, `Nh`, `Nd`. Pure so the
/// renderer can format per visible row without touching the clock itself
/// more than once per frame.
pub fn formatAge(now_ns: i128, mtime_ns: i128, buf: []u8) []const u8 {
    const delta = if (now_ns > mtime_ns) now_ns - mtime_ns else 0;
    const secs = @divTrunc(delta, std.time.ns_per_s);
    if (secs < 60) return "now";
    const mins = @divTrunc(secs, 60);
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "now";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "now";
    const days = @divTrunc(hours, 24);
    return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "now";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn deinitList(alloc: std.mem.Allocator, list: *std.ArrayList(Note)) void {
    for (list.items) |*n| n.deinit(alloc);
    list.deinit(alloc);
}

test "notes: dir resolution precedence OZ_NOTES_DIR > XDG > HOME" {
    const alloc = testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();

    try map.put("HOME", "/home/ada");
    try map.put("XDG_DATA_HOME", "/home/ada/.local/state");
    try map.put("OZ_NOTES_DIR", "/tmp/oz-notes-test");
    const a = try resolveDir(alloc, &map);
    defer alloc.free(a);
    try testing.expectEqualStrings("/tmp/oz-notes-test", a);

    _ = map.remove("OZ_NOTES_DIR");
    const b = try resolveDir(alloc, &map);
    defer alloc.free(b);
    try testing.expectEqualStrings("/home/ada/.local/state/oz/notes", b);

    _ = map.remove("XDG_DATA_HOME");
    const c = try resolveDir(alloc, &map);
    defer alloc.free(c);
    try testing.expectEqualStrings("/home/ada/.local/share/oz/notes", c);
}

test "notes: empty env values fall through; no source is an explicit error" {
    const alloc = testing.allocator;
    var map = std.StringHashMap([]const u8).init(alloc);
    defer map.deinit();
    try map.put("HOME", "");
    try map.put("XDG_DATA_HOME", "");
    try map.put("OZ_NOTES_DIR", "");
    try testing.expectError(error.NotesDirUnavailable, resolveDir(alloc, &map));

    try map.put("HOME", "/home/ada");
    const d = try resolveDir(alloc, &map);
    defer alloc.free(d);
    try testing.expectEqualStrings("/home/ada/.local/share/oz/notes", d);
}

test "notes: isPathInside only matches direct children" {
    try testing.expect(isPathInside("/data/oz/notes", "/data/oz/notes/note-1.md"));
    try testing.expect(!isPathInside("/data/oz/notes", "/data/oz/notes"));
    try testing.expect(!isPathInside("/data/oz/notes", "/data/oz/notes-backup/note-1.md"));
    try testing.expect(!isPathInside("/data/oz/notes", "/data/oz/notesX/note-1.md"));
}

test "notes: title prefers the first heading, else the filename" {
    const alloc = testing.allocator;
    const cases = [_]struct { content: []const u8, want: []const u8 }{
        .{ .content = "# Groceries\n\nmilk\n", .want = "Groceries" },
        .{ .content = "intro\n## Deep heading ##\n", .want = "Deep heading" },
        .{ .content = "###   spaced   ###\n", .want = "spaced" },
        .{ .content = "plain text only\n", .want = "note-7.md" },
        .{ .content = "#\n# Real\n", .want = "Real" },
        .{ .content = "", .want = "note-7.md" },
    };
    for (cases) |case| {
        const got = try titleFor(alloc, "note-7.md", case.content);
        defer alloc.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "notes: snippet is the first non-heading body line, markers stripped" {
    const alloc = testing.allocator;
    const cases = [_]struct { content: []const u8, want: []const u8 }{
        .{ .content = "# Title\n\n  milk and eggs  \n", .want = "milk and eggs" },
        .{ .content = "# Title\n- first bullet\nsecond\n", .want = "first bullet" },
        .{ .content = "# Title\n> quoted\n", .want = "quoted" },
        .{ .content = "# Title\n1. ordered\n", .want = "ordered" },
        .{ .content = "# Title\n\n", .want = "" },
        .{ .content = "", .want = "" },
    };
    for (cases) |case| {
        const got = try snippetFor(alloc, case.content);
        defer alloc.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "notes: snippet is bounded on a UTF-8 boundary" {
    const alloc = testing.allocator;
    var content = std.ArrayList(u8).empty;
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "# T\n");
    // 100 CJK chars = 300 bytes; stored snippet must not split one.
    var i: usize = 0;
    while (i < 100) : (i += 1) try content.appendSlice(alloc, "笔");
    const got = try snippetFor(alloc, content.items);
    defer alloc.free(got);
    try testing.expect(got.len <= max_snippet_bytes);
    try testing.expect(got.len > 0);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "notes: note name parsing is narrow" {
    try testing.expectEqual(@as(?u64, 1), noteNameNumber("note-1.md"));
    try testing.expectEqual(@as(?u64, 42), noteNameNumber("note-42.md"));
    try testing.expectEqual(@as(?u64, null), noteNameNumber("note-.md"));
    try testing.expectEqual(@as(?u64, null), noteNameNumber("note-a.md"));
    try testing.expectEqual(@as(?u64, null), noteNameNumber("Note-3.md"));
    try testing.expectEqual(@as(?u64, null), noteNameNumber("note-3.markdown"));
    try testing.expectEqual(@as(?u64, null), noteNameNumber("other-3.md"));
}

test "notes: next filename is the smallest free number" {
    const alloc = testing.allocator;
    const empty = [_][]const u8{};
    const one = [_][]const u8{"note-1.md"};
    const gap = [_][]const u8{ "note-1.md", "note-3.md" };
    const dense = [_][]const u8{ "note-1.md", "note-2.md", "other.md" };

    const a = try nextNameFromNames(alloc, &empty);
    defer alloc.free(a);
    try testing.expectEqualStrings("note-1.md", a);
    const b = try nextNameFromNames(alloc, &one);
    defer alloc.free(b);
    try testing.expectEqualStrings("note-2.md", b);
    const c = try nextNameFromNames(alloc, &gap);
    defer alloc.free(c);
    try testing.expectEqualStrings("note-2.md", c);
    const d = try nextNameFromNames(alloc, &dense);
    defer alloc.free(d);
    try testing.expectEqualStrings("note-3.md", d);
}

test "notes: age formatting buckets" {
    var buf: [16]u8 = undefined;
    const now: i128 = 1_000_000_000_000;
    try testing.expectEqualStrings("now", formatAge(now, now, &buf));
    try testing.expectEqualStrings("now", formatAge(now, now + 5_000_000_000, &buf)); // future
    try testing.expectEqualStrings("5m", formatAge(now, now - 5 * std.time.ns_per_min, &buf));
    try testing.expectEqualStrings("3h", formatAge(now, now - 3 * std.time.ns_per_hour, &buf));
    try testing.expectEqualStrings("9d", formatAge(now, now - 9 * std.time.ns_per_day, &buf));
}

test "notes: sorting is mtime desc then filename desc" {
    const alloc = testing.allocator;
    var list: std.ArrayList(Note) = .empty;
    defer deinitList(alloc, &list);
    const mk = struct {
        fn add(l: *std.ArrayList(Note), a: std.mem.Allocator, name: []const u8, mtime: i128) !void {
            try l.append(a, .{
                .path = try a.dupe(u8, name),
                .filename = try a.dupe(u8, name),
                .title = try a.dupe(u8, name),
                .snippet = try a.dupe(u8, ""),
                .mtime_ns = mtime,
            });
        }
    }.add;
    try mk(&list, alloc, "note-1.md", 100);
    try mk(&list, alloc, "note-2.md", 300);
    try mk(&list, alloc, "note-3.md", 200);
    try mk(&list, alloc, "note-10.md", 300);
    sortNotes(list.items);
    const want = [_][]const u8{ "note-2.md", "note-10.md", "note-3.md", "note-1.md" };
    for (want, list.items) |w, got| try testing.expectEqualStrings(w, got.filename);
}

test "notes: scan+create round-trip in a temp dir" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..n];

    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.md", .data = "# Alpha note\n\nfirst body\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.md", .data = "no heading here\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignore.txt", .data = "not a note\n" });

    var list = try scanDir(io, alloc, dir);
    defer deinitList(alloc, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    // deterministic ordering invariant
    var i: usize = 1;
    while (i < list.items.len) : (i += 1) {
        const prev = list.items[i - 1];
        const cur = list.items[i];
        const ordered = prev.mtime_ns > cur.mtime_ns or
            (prev.mtime_ns == cur.mtime_ns and
                std.mem.order(u8, prev.filename, cur.filename) == .gt);
        try testing.expect(ordered);
    }
    var seen_alpha = false;
    var seen_beta = false;
    for (list.items) |note| {
        if (std.mem.eql(u8, note.filename, "alpha.md")) {
            seen_alpha = true;
            try testing.expectEqualStrings("Alpha note", note.title);
            try testing.expectEqualStrings("first body", note.snippet);
        } else if (std.mem.eql(u8, note.filename, "beta.md")) {
            seen_beta = true;
            try testing.expectEqualStrings("beta.md", note.title);
            try testing.expectEqualStrings("no heading here", note.snippet);
        }
    }
    try testing.expect(seen_alpha and seen_beta);

    const p1 = try createNoteFile(io, alloc, dir);
    defer alloc.free(p1);
    try testing.expect(std.mem.endsWith(u8, p1, "/note-1.md"));
    const p2 = try createNoteFile(io, alloc, dir);
    defer alloc.free(p2);
    try testing.expect(std.mem.endsWith(u8, p2, "/note-2.md"));
    const p3 = try createNoteFile(io, alloc, dir);
    defer alloc.free(p3);
    try testing.expect(std.mem.endsWith(u8, p3, "/note-3.md"));

    // The template is exact and an existing note is never overwritten.
    const created = try std.Io.Dir.cwd().readFileAlloc(io, p1, alloc, .limited(4096));
    defer alloc.free(created);
    try testing.expectEqualStrings(note_template, created);
    var alpha_path: ?[]const u8 = null;
    for (list.items) |note| {
        if (std.mem.eql(u8, note.filename, "alpha.md")) alpha_path = note.path;
    }
    const alpha = try std.Io.Dir.cwd().readFileAlloc(io, alpha_path.?, alloc, .limited(4096));
    defer alloc.free(alpha);
    try testing.expectEqualStrings("# Alpha note\n\nfirst body\n", alpha);

    // createNoteFile also creates a missing nested directory lazily.
    const nested_joined = try std.fs.path.join(alloc, &.{ dir, "nested", "deep" });
    defer alloc.free(nested_joined);
    const p4 = try createNoteFile(io, alloc, nested_joined);
    defer alloc.free(p4);
    try testing.expect(std.mem.endsWith(u8, p4, "/note-1.md"));
}

test "notes: scan of a missing directory is an empty list" {
    const alloc = testing.allocator;
    var list = try scanDir(testing.io, alloc, "/tmp/oz-notes-does-not-exist-12345");
    defer deinitList(alloc, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "notes: store selection survives a refresh by path" {
    const alloc = testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);
    // empty store
    try testing.expect(store.selectedPath() == null);
    store.selectPath("/x/note-1.md");
    try testing.expectEqual(@as(usize, 0), store.sel);
}
