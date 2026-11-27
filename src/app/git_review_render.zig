//! Responsive change lists, commit graph, and shared numbered patch pane.
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const theme = @import("../theme.zig");
const util = @import("util.zig");
const data = @import("git_review_data.zig");
const review = @import("git_review.zig");
const patch = @import("git_review_patch.zig");
const Window = vaxis.Window;

const Canvas = struct {
    a: std.mem.Allocator,
    win: Window,
    t: theme.Theme,

    fn area(c: Canvas, x: usize, y: usize, width: usize, height: usize) Canvas {
        var out = c;
        out.win = c.win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = @intCast(width), .height = @intCast(height) });
        return out;
    }

    fn line(c: Canvas, y: usize, text: []const u8, fg: theme.Rgb, selected: bool) !void {
        if (y >= c.win.height or c.win.width == 0) return;
        const style: vaxis.Style = .{ .fg = .{ .rgb = fg }, .bg = .{ .rgb = if (selected) c.t.bg_sel else c.t.bg }, .bold = selected };
        if (selected) c.area(0, y, c.win.width, 1).win.fill(.{ .style = style });
        // Paths, blobs, and messages are arbitrary Git bytes. Limit work to a
        // visible prefix and replace controls/invalid UTF-8 before vaxis sees it.
        const budget = @as(usize, c.win.width) * 8;
        const safe = try c.sanitize(text[0..@min(text.len, budget)]);
        const fit = util.cellFitPrefix(c.win, safe, c.win.width);
        _ = c.win.print(&.{.{ .text = fit.slice, .style = style }}, .{ .row_offset = @intCast(y), .wrap = .none });
    }

    fn sanitize(c: Canvas, src: []const u8) ![]const u8 {
        var safe: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (pos < src.len) {
            const b = src[pos];
            if (b < 0x80) {
                if (b == '\t') try safe.appendSlice(c.a, "    ") else try safe.append(c.a, if (b >= ' ' and b < 127) b else '?');
                pos += 1;
            } else {
                const n: usize = std.unicode.utf8ByteSequenceLength(b) catch 0;
                if (n >= 2 and n <= src.len - pos and std.unicode.utf8ValidateSlice(src[pos..][0..n])) {
                    const sequence = src[pos..][0..n];
                    if (b == 0xc2 and sequence[1] < 0xa0) try safe.append(c.a, '?') else try safe.appendSlice(c.a, sequence);
                    pos += n;
                } else {
                    try safe.append(c.a, '?');
                    pos += 1;
                }
            }
        }
        return safe.items;
    }

    fn fmt(c: Canvas, y: usize, comptime format: []const u8, args: anytype, fg: theme.Rgb, selected: bool) !void {
        return c.line(y, try std.fmt.allocPrint(c.a, format, args), fg, selected);
    }

    fn sub(c: Canvas, y: usize) Canvas {
        return c.area(0, y, c.win.width, c.win.height -| y);
    }
};

fn groupName(g: data.Group) []const u8 {
    return switch (g) {
        .staged => "Staged",
        .unstaged => "Unstaged",
        .untracked => "Untracked",
        .conflicts => "Conflicts",
        .comparison, .commit => "Changed files",
    };
}

fn fileName(a: std.mem.Allocator, f: data.File) ![]const u8 {
    if (f.old_path) |old| return std.fmt.allocPrint(a, "{s} → {s}", .{ old, f.path });
    return f.path;
}

fn fileRow(c: Canvas, y: usize, f: data.File, selected: bool) !void {
    const counts = if (f.binary) "binary" else if (f.added != null and f.removed != null)
        try std.fmt.allocPrint(c.a, "+{d} -{d}", .{ f.added.?, f.removed.? })
    else
        "";
    const w: usize = c.win.width;
    const right = @min(counts.len + 1, w / 2);
    try c.area(0, 0, w - right, c.win.height).fmt(y, "{s}{c} {s}", .{ if (selected) "› " else "  ", f.status, try fileName(c.a, f) }, c.t.fg, selected);
    try c.area(w - right, 0, right, c.win.height).line(y, counts, c.t.fg_dim, selected);
}

fn changeList(c: Canvas, s: *review.State) !void {
    const files = s.files();
    if (files.len == 0) return c.line(0, s.status(s.listingSlot(), if (s.ref_index == 0) "Working tree clean" else "No changed files"), c.t.fg_dim, false);
    const cur = &s.change;
    // Count back from the selection only as far as a single screen.
    var first = cur.file;
    var used: usize = 2;
    while (first > cur.top and used < c.win.height) {
        const cost: usize = if (files[first].group == files[first - 1].group) 1 else 2;
        if (used + cost > c.win.height) break;
        used += cost;
        first -= 1;
    }
    cur.top = first;
    var y: usize = 0;
    for (files[first..], first..) |f, i| {
        if (y >= c.win.height) break;
        if (i == first or files[i - 1].group != f.group) {
            try c.line(y, groupName(f.group), c.t.accent_alt, false);
            y += 1;
        }
        try fileRow(c, y, f, i == cur.file);
        y += 1;
    }
}

fn graphHeight(c: data.Commit) usize {
    return 2 + std.mem.count(u8, c.graph, "\n") + @intFromBool(c.labels.len > 0);
}

fn timeline(c: Canvas, s: *review.State) !void {
    const history = s.result(.history);
    const entries = if (history) |r| r.commits else &.{};
    if (entries.len == 0) return c.line(0, s.status(.history, "No commits"), c.t.fg_dim, false);
    var first = s.timeline;
    var used = graphHeight(entries[first]);
    while (first > s.timeline_top) {
        const cost = graphHeight(entries[first - 1]);
        if (used + cost > c.win.height) break;
        used += cost;
        first -= 1;
    }
    s.timeline_top = first;
    var y: usize = 0;
    for (entries[first..], first..) |commit, i| {
        if (y >= c.win.height) break;
        var graph = std.mem.splitScalar(u8, commit.graph, '\n');
        const glyph = graph.next() orelse "*";
        const selected = i == s.timeline;
        try c.fmt(y, "{s} {s} {s}", .{ glyph, commit.short_hash, commit.subject }, c.t.fg, selected);
        y += 1;
        // Insert metadata before Git's transition rows, on the same lanes as
        // this node. Edges and their destination columns stay exactly as Git printed.
        const continuation = try c.a.dupe(u8, glyph);
        for (continuation) |*b| {
            if (b.* == '*') b.* = if (commit.parents.len == 0) ' ' else '|';
        }
        try c.fmt(y, "{s} {s}  {s}", .{ continuation, commit.author, commit.date }, c.t.fg_dim, false);
        y += 1;
        if (commit.labels.len > 0) {
            try c.fmt(y, "{s} {s}", .{ continuation, commit.labels }, c.t.accent_alt, false);
            y += 1;
        }
        while (graph.next()) |edge| {
            if (y >= c.win.height) break;
            try c.line(y, edge, c.t.fg_dim, false);
            y += 1;
        }
    }
}

fn refPicker(c: Canvas, s: *review.State) !void {
    try c.line(0, "Compare against", c.t.accent, false);
    const result = s.result(.changes) orelse return;
    const height = @max(@as(usize, c.win.height) -| 1, 1);
    s.pick_top = @min(s.pick_top, s.pick);
    if (s.pick - s.pick_top >= height) s.pick_top = s.pick - height + 1;
    for (s.pick_top..@min(result.refs.len + 1, s.pick_top + height)) |i| {
        const name = if (i == 0) "Working tree" else result.refs[i - 1];
        try c.fmt(1 + i - s.pick_top, "{s}{s}", .{ if (i == s.pick) "› " else "  ", name }, c.t.fg, i == s.pick);
    }
}

fn num(a: std.mem.Allocator, n: ?u32) ![]const u8 {
    return if (n) |v| std.fmt.allocPrint(a, "{d:>4}", .{v}) else "    ";
}

fn patchLine(c: Canvas, y: usize, row: patch.Row, side: enum { old, new, unified }, selected: bool) !void {
    const mark: u8 = switch (row.kind) {
        .add => '+',
        .remove => '-',
        else => ' ',
    };
    const fg = switch (row.kind) {
        .add => c.t.git_add,
        .remove => c.t.git_del,
        else => c.t.fg,
    };
    const prefix = switch (side) {
        .old => try std.fmt.allocPrint(c.a, "{s} {c} ", .{ try num(c.a, row.old), mark }),
        .new => try std.fmt.allocPrint(c.a, "{s} {c} ", .{ try num(c.a, row.new), mark }),
        .unified => try std.fmt.allocPrint(c.a, "{s} {s} {c} ", .{ try num(c.a, row.old), try num(c.a, row.new), mark }),
    };
    const inset = @min(prefix.len, c.win.width);
    try c.area(0, 0, inset, c.win.height).line(y, prefix, fg, selected);
    try c.area(inset, 0, c.win.width - inset, c.win.height).line(y, row.text, fg, selected);
}

fn patchPane(c: Canvas, s: *review.State, aligned: bool) !void {
    const f = s.file() orelse return;
    const cur = s.cursor();
    const v = s.view();
    const limited = if (s.result(s.patchSlot())) |r| r.patch_truncated else false;
    try c.fmt(0, "{c}  {s}{s}", .{ f.status, try fileName(c.a, f), if (limited) "  (preview limited)" else "" }, c.t.accent, false);
    const half = c.win.width / 2;
    if (aligned) {
        try c.line(1, " Old", c.t.fg_dim, false);
        try c.area(half, 0, c.win.width - half, c.win.height).line(1, " New", c.t.fg_dim, false);
    } else try c.line(1, " Old  New", c.t.fg_dim, false);
    if (c.win.height <= 2) return;
    if (v.rows.len == 0) return c.line(2, s.status(s.patchSlot(), "No textual changes"), c.t.fg_dim, false);
    try patchRows(c.sub(2), v, cur.row, aligned, s.detail_open or s.change_focus);
}

fn patchRows(c: Canvas, v: patch.View, cursor: usize, aligned: bool, highlight: bool) !void {
    const row = @min(cursor, v.rows.len - 1);
    const display = if (aligned) v.rows[row].pair else row;
    const count = if (aligned) v.pairs.len else v.rows.len;
    const height: usize = c.win.height;
    const half = c.win.width / 2;
    // Keep several preceding lines of context without hiding a newly requested hunk.
    const start = if (v.rows[row].kind == .header) display else display -| (height / 3);
    const left = c.area(0, 0, half -| 1, c.win.height);
    const right = c.area(half, 0, c.win.width - half, c.win.height);
    for (start..@min(start + height, count)) |index| {
        const y = index - start;
        const selected = index == display and highlight;
        const primary = if (aligned) v.pairs[index].preferred() else index;
        const r = v.rows[primary];
        if (r.kind == .header or r.kind == .note) {
            try c.line(y, r.text, if (r.kind == .header) c.t.accent_alt else c.t.fg_dim, selected);
        } else if (aligned) {
            const pair = v.pairs[index];
            if (pair.left) |i| try patchLine(left, y, v.rows[i], .old, selected);
            if (pair.right) |i| try patchLine(right, y, v.rows[i], .new, selected);
        } else try patchLine(c, y, r, .unified, selected);
    }
}

fn fileDiffLabel(c: Canvas, y: usize, label: []const u8, path: []const u8) !void {
    const width = c.win.width -| label.len;
    if (width == 0) return c.line(y, label, c.t.accent_alt, false);
    const safe = try c.sanitize(path);
    const fits = util.cellFitPrefix(c.win, safe, width).slice.len == safe.len;
    if (fits) return c.fmt(y, "{s}{s}", .{ label, safe }, c.t.accent_alt, false);
    const suffix = util.cellFitSuffix(c.win, safe, width - 1).slice;
    try c.fmt(y, "{s}…{s}", .{ label, suffix }, c.t.accent_alt, false);
}

fn fileDiff(c: Canvas, s: *review.State, files: data.FilePair) !void {
    const v = s.view();
    const limited = if (s.result(s.patchSlot())) |result| result.patch_truncated else false;
    try c.line(0, if (limited) " File diff · preview limited" else " File diff", c.t.accent, false);
    const aligned = s.aligned(c.win.width);
    const first_row: usize = if (aligned) 2 else 3;
    if (aligned) {
        const half = c.win.width / 2;
        try fileDiffLabel(c.area(0, 0, half -| 1, c.win.height), 1, " Left  ", files.left);
        try fileDiffLabel(c.area(half, 0, c.win.width - half, c.win.height), 1, " Right  ", files.right);
        const divider = c.area(half - 1, 0, 1, c.win.height);
        for (1..@max(c.win.height -| 1, 1)) |y| try divider.line(y, "│", c.t.win_sep, false);
    } else {
        try fileDiffLabel(c, 1, " Left   ", files.left);
        try fileDiffLabel(c, 2, " Right  ", files.right);
    }
    if (c.win.height <= first_row + 1) return;
    if (v.rows.len == 0) {
        try c.line(first_row, s.status(s.patchSlot(), "Files are identical"), c.t.fg_dim, false);
    } else {
        try patchRows(c.area(0, first_row, c.win.width, c.win.height - first_row - 1), v, s.change.row, aligned, true);
    }
    try c.line(c.win.height - 1, s.notice orelse "[c/]c hunks   j/k scroll   v layout   o/O open left/right   q quit", c.t.fg_dim, false);
}

fn detailPane(c: Canvas, s: *review.State, aligned: bool) !void {
    const result = s.result(.detail) orelse return c.line(0, s.status(.detail, ""), c.t.fg_dim, false);
    const commit = result.commit orelse return c.line(0, s.status(.detail, "Commit unavailable"), c.t.fg_dim, false);
    try c.line(0, commit.hash, c.t.accent_alt, false);
    try c.fmt(1, "{s}  {s}", .{ commit.author, commit.date }, c.t.fg_dim, false);
    var y: usize = 2;
    if (s.message_open) {
        var pos = s.message_offset;
        while (pos < commit.message.len and y < c.win.height) : (y += 1) {
            const line = review.messageRow(commit.message, pos, c.win, c.win.width);
            try c.line(y, line.text, c.t.fg, false);
            pos = line.next;
        }
        return;
    }
    var lines = std.mem.splitScalar(u8, commit.message, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try c.line(y, line, c.t.fg, false);
        y += 1;
        if (y >= 4) break;
    }
    try c.fmt(y, "{d} files  +{d} -{d}", .{ result.files.len, result.added, result.removed }, c.t.accent, false);
    y += 1;
    if (result.files.len == 0) return;
    const visible = @min(result.files.len, @min(4, @as(usize, c.win.height) / 6));
    const start = s.commit.file + 1 -| visible;
    for (start..@min(start + visible, result.files.len)) |i| {
        try fileRow(c, y, result.files[i], s.commit.file == i);
        y += 1;
    }
    try patchPane(c.sub(y), s, aligned);
}

fn help(c: Canvas) !void {
    const cmds = [_][]const u8{
        "Git Review keys",                                                         "Tab          Switch Changes / History",
        "j k / ↑ ↓    Select a file, commit, or patch line",
        "PgUp PgDn    Move one page",                                              "Enter / l    Open a patch or the selected commit",
        "[ ]          Previous / next hunk",                                       "K J          Previous / next changed file",
        "o            Open selected line in the worktree",                         "b            Compare with a local branch",
        "p            Cycle the parent of a merge commit",                         "m            Read the full commit message",
        "v            Toggle aligned / unified diff on wide screens",              "Esc / h      Back",
        "q            Close Git Review",                                           ", .          Newer / older history page",
        "M modified   A added   D deleted   R renamed   U conflict   ? untracked",
    };
    for (cmds, 0..) |line, i| try c.line(i, line, if (i == 0) c.t.accent else c.t.fg, false);
}

pub fn draw(app: *App, a: std.mem.Allocator, win: Window) !void {
    const s = &app.review;
    const c: Canvas = .{ .win = win, .a = a, .t = app.theme };
    if (win.width == 0 or win.height == 0) return;
    if (s.file_diff) |files| return fileDiff(c, s, files);
    try c.line(0, if (s.tab == .changes) " Git Review    [Changes]   History" else " Git Review     Changes   [History]", c.t.accent, false);
    const list = s.result(s.listingSlot());
    const label = if (s.tab == .history and !s.detail_open) blk: {
        const history = s.result(.history) orelse break :blk "Branch history";
        break :blk history.label;
    } else if (list) |r| blk: {
        if (s.tab == .changes and s.ref_index == 0) {
            if (s.file()) |f| break :blk f.label();
        }
        break :blk r.label;
    } else "Loading…";
    try c.fmt(1, " {s}", .{label}, c.t.accent_alt, false);
    if (win.height <= 3) return;
    const content = c.area(1, 3, win.width -| 2, win.height - 4);
    const wide = review.State.split(win.width);
    const aligned = s.aligned(win.width);
    const list_width = review.State.listWidth(win.width);
    const nav = content.area(0, 0, list_width, content.win.height);
    const x = if (wide) list_width + 2 else 0;
    const diff = content.area(x, 0, content.win.width - x, content.win.height);
    if (s.help) {
        try help(content);
    } else if (s.picker) {
        try refPicker(content, s);
    } else {
        if (wide) {
            const rule = content.area(list_width, 0, 1, content.win.height);
            for (0..rule.win.height) |i| try rule.line(i, "│", c.t.win_sep, false);
        }
        if (s.tab == .changes) {
            if (wide or !s.change_focus) try changeList(nav, s);
            if (wide or s.change_focus) try patchPane(diff, s, aligned);
        } else {
            if (wide or !s.detail_open) try timeline(nav, s);
            if (s.detail_open) {
                try detailPane(diff, s, aligned);
            } else if (wide) {
                if (s.selectedCommit()) |entry| {
                    try diff.line(0, entry.subject, c.t.fg, true);
                    try diff.line(1, entry.hash, c.t.accent_alt, false);
                    try diff.fmt(2, "{s}  {s}", .{ entry.author, entry.date }, c.t.fg_dim, false);
                    try diff.line(4, "Enter to review this commit", c.t.fg_dim, false);
                }
            }
        }
    }
    const hint = s.notice orelse if (s.help) "? / Esc back" else if (s.picker)
        "j/k select   Enter compare   Esc back"
    else if (s.tab == .history and s.detail_open and s.message_open)
        "j/k scroll   m patch   Esc back"
    else if (s.tab == .history and s.detail_open)
        "J/K files   [/] hunks   o source   p parent   m message   Esc back   ? keys"
    else if (s.tab == .history)
        "Tab tabs   j/k commits   Enter review commit   ,/. pages   q close   ? keys"
    else if (s.change_focus)
        "Tab tabs   J/K files   [/] hunks   o source   Esc back   ? keys"
    else
        "Tab tabs   j/k files   Enter diff   b compare   q close   ? keys";
    try c.line(win.height - 1, hint, c.t.fg_dim, false);
}

test "git review: patch viewport aligns numbered replacements, clips both sides, and preserves unified order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "@@ -9,2 +12,2 @@\n-before\n+after\n same\n";
    var listing: data.Job = undefined;
    listing.result = .{ .files = &.{.{ .group = .staged, .status = 'M', .path = "a.txt" }} };
    var content: data.Job = undefined;
    content.result = .{ .view = try patch.parse(a, raw) };
    var s: review.State = .{};
    s.cache.getPtr(.changes).job = &listing;
    s.cache.getPtr(.change_patch).job = &content;
    var screen = try vaxis.Screen.init(a, .{ .cols = 80, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    const w: Window = .{ .width = 80, .height = 12, .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .screen = &screen };
    const canvas: Canvas = .{ .a = a, .win = w, .t = theme.themes[0] };
    try patchPane(canvas, &s, true);
    const read = struct {
        fn row(alloc: std.mem.Allocator, win: Window, y: u16) ![]const u8 {
            var result: std.ArrayList(u8) = .empty;
            for (0..win.width) |x| try result.appendSlice(alloc, win.readCell(@intCast(x), y).?.char.grapheme);
            return result.items;
        }
    }.row;
    const aligned = try read(a, w, 3);
    try std.testing.expect(std.mem.indexOf(u8, aligned[0..40], "9 - before") != null);
    try std.testing.expect(std.mem.indexOf(u8, aligned[40..], "12 + after") != null);
    screen.clear();
    try patchPane(canvas, &s, false);
    try std.testing.expect(std.mem.indexOf(u8, try read(a, w, 3), "9      - before") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(a, w, 4), "12 + after") != null);

    screen.clear();
    try canvas.area(0, 0, 6, 1).line(0, "12345中\x1b[31m", canvas.t.fg, false);
    try std.testing.expectEqualStrings(" ", w.readCell(5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", w.readCell(6, 0).?.char.grapheme);
    const wrapped = review.messageRow("abcdef\nrest", 0, w, 5);
    try std.testing.expectEqualStrings("abcde", wrapped.text);
    try std.testing.expectEqual(@as(usize, 5), wrapped.next);
    try std.testing.expectEqual(@as(usize, 7), review.messageRow("abcdef\nrest", wrapped.next, w, 5).next);
}
