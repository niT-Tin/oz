//! Git integration (M3a) — pure parsing of `git diff` / `git blame` /
//! `git status` output into editor-consumable values. No subprocess code
//! here: the App runs git (asynchronously, in a worker thread) and feeds the
//! raw bytes in, so every parser is unit-testable with fixture strings.

const std = @import("std");

/// Per-line git status, as shown in the sign gutter.
pub const LineKind = enum {
    /// Line exists in the working tree but not in the index (a pure '+' run).
    added,
    /// Line exists in both but differs (a run with both '-' and '+' lines).
    modified,
    /// A deletion happened just ABOVE this line (this line follows the
    /// removed run, which had no '+' lines of its own).
    removed_above,
    /// A deletion happened just BELOW this line (this line precedes the
    /// removed run, which had no '+' lines of its own).
    removed_below,
};

/// One parsed diff hunk: the final-file lines it touches plus the raw patch
/// text (header + this hunk) needed for `git apply`.
pub const Hunk = struct {
    /// 0-based final-file line of the hunk's first marked line (the first
    /// added/modified line, or the line adjacent to a pure removal) — the
    /// target of ]c/[c.
    start_line: u32,
    /// Marks per final-file line, indexed by the ABSOLUTE 0-based line
    /// number (null = clean). Absolute indexing lets a pure-removal hunk
    /// mark the neighbor line that sits outside its own body range.
    lines: []?LineKind, // owned
    /// Raw patch text: the shared `diff --git` header + `---`/`+++` lines +
    /// this hunk's `@@` line + body. Pipe this to `git apply --cached`
    /// (stage) or `git apply -R` (reset).
    patch: []u8, // owned
    /// Parse-time only: 0-based final line of the hunk's first body line.
    /// Not part of the public contract (start_line is the marked target).
    new_start: u32 = 0,

    pub fn markAt(self: *const Hunk, line: u32) ?LineKind {
        if (line >= self.lines.len) return null;
        return self.lines[line];
    }

    fn deinit(self: *Hunk, alloc: std.mem.Allocator) void {
        alloc.free(self.lines);
        alloc.free(self.patch);
    }
};

/// Parsed `git diff` for one file.
pub const FileDiff = struct {
    hunks: std.ArrayList(Hunk) = .empty,
    /// True when the file is untracked (`git status --porcelain` starts with
    /// "??"): the whole file reads as added, and there are no hunks to apply.
    untracked: bool = false,

    pub fn deinit(self: *FileDiff, alloc: std.mem.Allocator) void {
        for (self.hunks.items) |*h| h.deinit(alloc);
        self.hunks.deinit(alloc);
    }

    /// Gutter mark for final-file line `line` (0-based), or null when clean.
    /// An untracked file reads as fully added.
    pub fn markAt(self: *const FileDiff, line: u32) ?LineKind {
        if (self.untracked) return .added;
        for (self.hunks.items) |*h| {
            if (h.markAt(line)) |k| return k;
        }
        return null;
    }

    /// Index of the first hunk whose marked region starts at/after `line`,
    /// or null when there is none. Used by ]c/[c navigation.
    pub fn hunkAtOrAfter(self: *const FileDiff, line: u32) ?usize {
        for (self.hunks.items, 0..) |*h, i| {
            if (h.start_line >= line) return i;
        }
        return null;
    }

    /// Index of the last hunk whose marked region starts strictly before
    /// `line`, or null when there is none.
    pub fn hunkBefore(self: *const FileDiff, line: u32) ?usize {
        var best: ?usize = null;
        for (self.hunks.items, 0..) |*h, i| {
            if (h.start_line < line) best = i;
        }
        return best;
    }

    /// Index of the hunk whose marked range CONTAINS `line` (start_line <=
    /// line < start_line + marks span), or null when the cursor sits on a
    /// clean line. Used by hunk stage/reset/preview.
    pub fn hunkAt(self: *const FileDiff, line: u32) ?usize {
        for (self.hunks.items, 0..) |*h, i| {
            if (line >= h.start_line and line < h.start_line + h.lines.len) return i;
        }
        return null;
    }
};

/// Split `text` into lines without the trailing '\n' (or "\r\n") — an empty
/// final segment (file ends with '\n') does NOT produce a trailing entry, so
/// iterating the result over a file's lines matches the line count.
fn splitLines(text: []const u8, out: *std.ArrayList([]const u8), alloc: std.mem.Allocator) !void {
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            try out.append(alloc, rest);
            return;
        };
        var line = rest[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.append(alloc, line);
        rest = rest[nl + 1 ..];
    }
}

/// Parse `git diff --no-color --no-ext-diff -- <path>` output. Produces one
/// Hunk per `@@` block; each hunk carries its own patch text (shared header
/// lines + hunk body) so stage/reset can feed a single hunk to git apply.
/// Empty output (no changes) parses to zero hunks. Unparseable output is
/// best-effort: malformed sections are skipped, never fatal — a git version
/// emitting unexpected headers degrades to "clean", not a crash.
pub fn parseDiff(alloc: std.mem.Allocator, text: []const u8) !FileDiff {
    var diff = FileDiff{};
    errdefer diff.deinit(alloc);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(alloc);
    try splitLines(text, &lines, alloc);

    // Patch header = everything between the "diff --git" line and the first
    // hunk header ("@@ "). No changes → git prints nothing at all.
    var header_start: ?usize = null;
    var header_end: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            header_start = i;
        } else if (std.mem.startsWith(u8, line, "@@ -")) {
            header_end = i;
            break;
        }
    }
    const hs = header_start orelse return diff;
    if (header_end <= hs) return diff; // header without any hunk (binary etc.)
    const header = lines.items[hs..header_end];

    i = header_end;
    while (i < lines.items.len) {
        if (!std.mem.startsWith(u8, lines.items[i], "@@ -")) {
            i += 1;
            continue;
        }
        var hunk = parseOneHunk(alloc, lines.items, header, &i) catch continue;
        if (hunk.lines.len == 0) { // no marked lines — nothing to show
            hunk.deinit(alloc);
            continue;
        }
        diff.hunks.append(alloc, hunk) catch |e| {
            hunk.deinit(alloc);
            return e;
        };
    }
    return diff;
}

/// Parse one hunk starting at `lines.items[*i]` (the "@@ " line); advances
/// *i past the hunk body. Returns a hunk with absolute-indexed marks (a
/// context-only hunk yields an empty marks list — caller drops it). On
/// error, all partial state is freed and the error propagates.
fn parseOneHunk(
    alloc: std.mem.Allocator,
    lines: []const []const u8,
    header: []const []const u8,
    i: *usize,
) !Hunk {
    const hdr_line = lines[i.*];
    var hunk = Hunk{
        .start_line = 0,
        .lines = &.{},
        .patch = &.{},
    };
    errdefer hunk.deinit(alloc);
    {
        // "@@ -old_start[,old_count] +new_start[,new_count] @@ ..."
        const plus = std.mem.indexOfScalar(u8, hdr_line, '+') orelse return error.BadHunkHeader;
        const after_plus = hdr_line[plus + 1 ..];
        const comma = std.mem.indexOfScalar(u8, after_plus, ',');
        const space = std.mem.indexOfScalar(u8, after_plus, ' ');
        const end = if (comma) |c| @min(c, space orelse after_plus.len) else (space orelse after_plus.len);
        const new_str = after_plus[0..end];
        const new_start_1based = std.fmt.parseInt(u32, new_str, 10) catch return error.BadHunkHeader;
        hunk.new_start = new_start_1based -| 1;
    }
    i.* += 1;
    const body_start = i.*;

    var marks = std.ArrayList(?LineKind).empty;
    errdefer marks.deinit(alloc);
    var final_line: u32 = hunk.new_start; // 0-based final line of the next body line
    // Current change region: a run of '-'/'+' lines between context lines.
    var in_region = false;
    var region_adds: u32 = 0;
    var region_dels: u32 = 0;
    var region_add_start: u32 = 0; // final line of the region's first '+'
    var region_first_final: ?u32 = null; // last final line before the region
    while (i.* < lines.len) {
        const body = lines[i.*];
        if (body.len == 0) break; // stray blank ends the hunk defensively
        switch (body[0]) {
            ' ' => {
                if (in_region) {
                    try resolveRegion(&marks, alloc, region_adds, region_dels, region_add_start, region_first_final, final_line);
                    in_region = false;
                    // the region's added lines occupy final lines — advance
                    // past them so the arriving context line lands on the
                    // right index (without this, every line after the first
                    // region is off by the region's add count)
                    final_line += region_adds;
                }
                final_line += 1;
            },
            '-' => {
                if (!in_region) {
                    in_region = true;
                    region_adds = 0;
                    region_dels = 0;
                    region_add_start = 0;
                    region_first_final = if (final_line > 0) final_line - 1 else null;
                }
                region_dels += 1;
            },
            '+' => {
                if (!in_region) {
                    in_region = true;
                    region_adds = 0;
                    region_dels = 0;
                    region_add_start = 0;
                    region_first_final = if (final_line > 0) final_line - 1 else null;
                }
                // The region's '+' lines are consecutive in the final file,
                // starting at the region's first '+' (final_line never moves
                // inside a region — only context lines advance it).
                if (region_adds == 0) region_add_start = final_line;
                region_adds += 1;
            },
            '\\' => {}, // "\ No newline at end of file"
            else => break, // next hunk's "@@" or trailing garbage
        }
        i.* += 1;
    }
    if (in_region) {
        try resolveRegion(&marks, alloc, region_adds, region_dels, region_add_start, region_first_final, final_line);
    }

    // start_line = first marked final line (absolute)
    for (marks.items, 0..) |m, idx| {
        if (m != null) {
            hunk.start_line = @intCast(idx);
            break;
        }
    }
    hunk.lines = try marks.toOwnedSlice(alloc);
    if (hunk.lines.len == 0) return hunk; // context-only hunk; caller drops

    // patch = header + hunk header + body lines
    var patch = std.ArrayList(u8).empty;
    errdefer patch.deinit(alloc);
    for (header) |h| {
        try patch.appendSlice(alloc, h);
        try patch.append(alloc, '\n');
    }
    try patch.appendSlice(alloc, hdr_line);
    try patch.append(alloc, '\n');
    const body_end = i.*;
    var bi = body_start;
    while (bi < body_end) : (bi += 1) {
        try patch.appendSlice(alloc, lines[bi]);
        try patch.append(alloc, '\n');
    }
    hunk.patch = try patch.toOwnedSlice(alloc);
    return hunk;
}

/// Mark the final-file lines touched by a change region (a run of '-'/'+'
/// lines). `final_line` = the first final line AFTER the region; the region's
/// '+' lines occupy final lines [region_add_start, region_add_start+adds).
/// Marks are absolute 0-based final-line indices into `marks` (grown with
/// nulls as needed).
fn resolveRegion(
    marks: *std.ArrayList(?LineKind),
    alloc: std.mem.Allocator,
    region_adds: u32,
    region_dels: u32,
    region_add_start: u32,
    region_first_final: ?u32,
    final_line_after: u32,
) !void {
    const kind: LineKind = if (region_dels > 0) .modified else .added;
    var k: u32 = 0;
    while (k < region_adds) : (k += 1) {
        const abs = region_add_start + k;
        try growTo(marks, alloc, abs + 1);
        marks.items[abs] = kind;
    }
    if (region_dels > 0 and region_adds == 0) {
        // pure removal: the removed lines exist in no final line — mark the
        // neighbors (skip when the removal touches the file's start/end).
        // Never overwrite an existing mark: a line that is BOTH added and
        // right above a deletion shows "added" (the more specific status).
        if (region_first_final) |prev| {
            try growTo(marks, alloc, prev + 1);
            if (marks.items[prev] == null) marks.items[prev] = .removed_below;
        }
        try growTo(marks, alloc, final_line_after + 1);
        if (marks.items[final_line_after] == null) marks.items[final_line_after] = .removed_above;
    }
}

/// Grow `marks` to at least `len` entries, filling with null (clean).
fn growTo(marks: *std.ArrayList(?LineKind), alloc: std.mem.Allocator, len: usize) !void {
    while (marks.items.len < len) try marks.append(alloc, null);
}

/// One blame entry for a final-file line.
pub const BlameEntry = struct {
    final_line: u32, // 0-based
    hash7: []u8, // first 7 chars of the commit hash (owned)
    author: []u8, // author name (owned)
    summary: []u8, // commit summary (owned)

    fn deinit(self: *BlameEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.hash7);
        alloc.free(self.author);
        alloc.free(self.summary);
    }
};

/// Parsed `git blame --line-porcelain` output, one entry per reported line.
pub const Blame = struct {
    entries: std.ArrayList(BlameEntry) = .empty,

    pub fn deinit(self: *Blame, alloc: std.mem.Allocator) void {
        for (self.entries.items) |*e| e.deinit(alloc);
        self.entries.deinit(alloc);
    }

    pub fn at(self: *const Blame, final_line: u32) ?*const BlameEntry {
        for (self.entries.items) |*e| {
            if (e.final_line == final_line) return e;
        }
        return null;
    }
};

/// Parse `git blame --line-porcelain -- <path>` output. Each line's block:
/// "<sha> <orig_line> <final_line> [<count>]", then "key value" headers,
/// then the content line (starts with '\t'). Malformed blocks are skipped —
/// a blame that fails mid-file still shows what parsed.
pub fn parseBlame(alloc: std.mem.Allocator, text: []const u8) !Blame {
    var blame = Blame{};
    errdefer blame.deinit(alloc);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(alloc);
    try splitLines(text, &lines, alloc);

    var i: usize = 0;
    while (i < lines.items.len) {
        const first = lines.items[i];
        var tok_it = std.mem.tokenizeScalar(u8, first, ' ');
        const sha = tok_it.next() orelse {
            i += 1;
            continue;
        };
        _ = tok_it.next() orelse {
            i += 1;
            continue;
        };
        const final_str = tok_it.next() orelse {
            i += 1;
            continue;
        };
        const final_line = std.fmt.parseInt(u32, final_str, 10) catch {
            i += 1;
            continue;
        };
        if (final_line < 1) {
            i += 1;
            continue;
        }
        var author: ?[]const u8 = null;
        var summary: ?[]const u8 = null;
        i += 1;
        while (i < lines.items.len) {
            const hdr = lines.items[i];
            if (hdr.len > 0 and hdr[0] == '\t') break; // content line
            if (std.mem.startsWith(u8, hdr, "author ")) {
                author = hdr["author ".len..];
            } else if (std.mem.startsWith(u8, hdr, "summary ")) {
                summary = hdr["summary ".len..];
            }
            i += 1;
        }
        if (i < lines.items.len) i += 1; // consume the content line
        const hash7 = if (sha.len >= 7) sha[0..7] else sha;
        const hash_copy = try alloc.dupe(u8, hash7);
        errdefer alloc.free(hash_copy);
        const author_copy = try alloc.dupe(u8, author orelse "");
        errdefer alloc.free(author_copy);
        const summary_copy = try alloc.dupe(u8, summary orelse "");
        errdefer alloc.free(summary_copy);
        try blame.entries.append(alloc, .{
            .final_line = final_line - 1,
            .hash7 = hash_copy,
            .author = author_copy,
            .summary = summary_copy,
        });
    }
    return blame;
}

// ---- tests ----

const testing = std.testing;

test "diff: clean file parses to no hunks" {
    const alloc = testing.allocator;
    var d = try parseDiff(alloc, "");
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), d.hunks.items.len);
    try testing.expectEqual(@as(?LineKind, null), d.markAt(0));
    try testing.expect(!d.untracked);
}

test "diff: single added line" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 0000000..1111111 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\ line1
        \\ line2
        \\+line3
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    try testing.expectEqual(@as(u32, 2), d.hunks.items[0].start_line);
    try testing.expectEqual(LineKind.added, d.markAt(2).?);
    try testing.expectEqual(@as(?LineKind, null), d.markAt(1));
    try testing.expectEqual(@as(usize, 0), d.hunkAtOrAfter(2).?);
    try testing.expectEqual(@as(?usize, null), d.hunkAtOrAfter(3));
}

test "diff: modified line (removal + addition)" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,3 @@
        \\ line1
        \\-line2
        \\+LINE2
        \\ line3
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    try testing.expectEqual(LineKind.modified, d.markAt(1).?);
    try testing.expectEqual(@as(?LineKind, null), d.markAt(0));
    try testing.expectEqual(@as(u32, 1), d.hunks.items[0].start_line);
}

test "diff: pure removal marks neighbors" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,4 +1,2 @@
        \\ line1
        \\-line2
        \\-line3
        \\ line4
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    // final lines: 0 (line1), 1 (line4). line1 precedes the removal, line4
    // follows it.
    try testing.expectEqual(LineKind.removed_below, d.markAt(0).?);
    try testing.expectEqual(LineKind.removed_above, d.markAt(1).?);
    try testing.expectEqual(@as(u32, 0), d.hunks.items[0].start_line);
}

test "diff: removal at file start marks only the line after" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,0 @@
        \\-x
        \\-y
        \\-z
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    try testing.expectEqual(LineKind.removed_above, d.markAt(0).?);
    try testing.expectEqual(@as(?LineKind, null), d.markAt(1));
}

test "diff: removal-only hunk with zero new count marks before and after" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -5,3 +4,0 @@
        \\-x
        \\-y
        \\-z
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    // new file has 4 lines (old lines 5-7 deleted): the line before the
    // deletion is 0-based 2, the line after it is 0-based 3.
    try testing.expectEqual(LineKind.removed_below, d.markAt(2).?);
    try testing.expectEqual(LineKind.removed_above, d.markAt(3).?);
    try testing.expectEqual(@as(?LineKind, null), d.markAt(4));
}

test "diff: multiple hunks, patch text round-trips for git apply" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,4 @@
        \\ a
        \\+b
        \\ c
        \\ d
        \\@@ -10,2 +11,2 @@
        \\-old
        \\+new
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), d.hunks.items.len);
    try testing.expectEqual(@as(u32, 1), d.hunks.items[0].start_line);
    try testing.expectEqual(LineKind.added, d.markAt(1).?);
    try testing.expectEqual(@as(u32, 10), d.hunks.items[1].start_line);
    try testing.expectEqual(LineKind.modified, d.markAt(10).?);
    // patch 0 = header + first hunk only
    try testing.expect(std.mem.startsWith(u8, d.hunks.items[0].patch, "diff --git a/a.txt b/a.txt\n"));
    try testing.expect(std.mem.indexOf(u8, d.hunks.items[0].patch, "@@ -1,3 +1,4 @@") != null);
    try testing.expect(std.mem.indexOf(u8, d.hunks.items[0].patch, "@@ -10,2 +11,2 @@") == null);
    // patch 1 contains the second hunk
    try testing.expect(std.mem.indexOf(u8, d.hunks.items[1].patch, "@@ -10,2 +11,2 @@") != null);
    // navigation between hunks
    try testing.expectEqual(@as(?usize, 1), d.hunkAtOrAfter(10));
    try testing.expectEqual(@as(?usize, null), d.hunkAtOrAfter(11));
    try testing.expectEqual(@as(?usize, 0), d.hunkBefore(10));
    try testing.expectEqual(@as(?usize, null), d.hunkBefore(1));
}

test "diff: CRLF line endings parse" {
    const alloc = testing.allocator;
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\ a
        \\+b
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    try testing.expectEqual(LineKind.added, d.markAt(1).?);
}

test "diff: added line above a deletion keeps the added mark" {
    const alloc = testing.allocator;
    // real-world shape: an insertion right above a trailing deletion —
    // the neighbor deletion marker must not override the added mark
    const j =
        \\diff --git a/a.txt b/a.txt
        \\index f62562a..d6936ec 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,8 +1,7 @@
        \\ line1
        \\ line2
        \\-line3
        \\+CHANGED
        \\ line4
        \\ line5
        \\+NEW
        \\ line6
        \\-line7
        \\-line8
        \\
    ;
    var d = try parseDiff(alloc, j);
    defer d.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    // final lines: line1=0 line2=1 CHANGED=2 line4=3 line5=4 NEW=5 line6=6
    try testing.expectEqual(LineKind.modified, d.markAt(2).?);
    try testing.expectEqual(LineKind.added, d.markAt(5).?);
    // line6 precedes the deleted line7/8 — the neighbor marker lands here
    try testing.expectEqual(LineKind.removed_below, d.markAt(6).?);
    // line5 (context right above the addition) stays clean
    try testing.expectEqual(@as(?LineKind, null), d.markAt(4));
}

test "blame: line-porcelain blocks parse into per-line entries" {
    const alloc = testing.allocator;
    // content lines start with a literal tab — multiline strings can't hold
    // tabs, so the fixture is assembled from normal (escape-aware) strings
    const j =
        "abcdef0123456789abcdef0123456789abcdef01 1 1\n" ++
        "author Alice\n" ++
        "author-mail <alice@example.com>\n" ++
        "author-time 1710000000\n" ++
        "author-tz +0800\n" ++
        "committer Alice\n" ++
        "committer-mail <alice@example.com>\n" ++
        "committer-time 1710000000\n" ++
        "committer-tz +0800\n" ++
        "summary Initial commit\n" ++
        "filename a.txt\n" ++
        "\thello\n" ++
        "0123456789abcdef0123456789abcdef01234567 1 2\n" ++
        "author Bob\n" ++
        "author-mail <bob@example.com>\n" ++
        "author-time 1710000001\n" ++
        "author-tz +0800\n" ++
        "committer Bob\n" ++
        "committer-mail <bob@example.com>\n" ++
        "committer-time 1710000001\n" ++
        "committer-tz +0800\n" ++
        "summary Add world\n" ++
        "filename a.txt\n" ++
        "\tworld\n";
    var b = try parseBlame(alloc, j);
    defer b.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), b.entries.items.len);
    const e0 = b.at(0).?;
    try testing.expectEqualStrings("abcdef0", e0.hash7);
    try testing.expectEqualStrings("Alice", e0.author);
    try testing.expectEqualStrings("Initial commit", e0.summary);
    const e1 = b.at(1).?;
    try testing.expectEqualStrings("0123456", e1.hash7);
    try testing.expectEqualStrings("Bob", e1.author);
    try testing.expect(b.at(2) == null);
}

test "blame: short hashes and missing headers survive" {
    const alloc = testing.allocator;
    const j = "abc1234 1 1\n" ++ "author Zed\n" ++ "\tcontent\n";
    var b = try parseBlame(alloc, j);
    defer b.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), b.entries.items.len);
    try testing.expectEqualStrings("abc1234", b.entries.items[0].hash7);
    try testing.expectEqualStrings("Zed", b.entries.items[0].author);
    try testing.expectEqualStrings("", b.entries.items[0].summary);
}
