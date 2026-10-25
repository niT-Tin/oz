//! Cell-level golden frames for the pty end-to-end harness.
//!
//! A golden is *text*, not a PNG/OCR oracle: one screen cell grid serialized
//! as text rows plus run-length encoded packed-RGB foreground/background
//! grids. It captures exactly what the terminal received, is diffable in a
//! review, and needs no image decoder.
//!
//! Updates are explicit opt-in only:
//!   OZ_UPDATE_GOLDEN=1 zig build e2e -Dtest-filter="golden"
//! A normal run never rewrites `test/golden/`. On mismatch the actual frame
//! and a line diff are written under `.verify/golden/` for CI upload.
//!
//! Format (version 1):
//!   # oz-cell-golden v1
//!   # name: <test name>
//!   # size: <rows> rows x <cols> cols
//!   size 30 120
//!   row 00 |<row text with trailing blank cells trimmed>|
//!   bg  00 <rrggbb>*<cells> ...     ("-" is the default/unpainted color)
//!   fg  00 <rrggbb>*<cells> ...
//!
//! The fg/bg run rows always cover all `cols` cells, so a style-only change
//! is visible even when the text is unchanged.
const std = @import("std");

pub const format_version = 1;
pub const update_env = "OZ_UPDATE_GOLDEN";

fn cellText(grid: anytype, row: usize, col: usize) []const u8 {
    if (row >= grid.rows or col >= grid.cols) return "";
    const slot = grid.buf[(row * grid.cols + col) * 4 ..][0..4];
    var n: usize = 0;
    while (n < 4 and slot[n] != 0) : (n += 1) {}
    return slot[0..n];
}

fn appendStyleLine(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    row: usize,
    values: []const u32,
) !void {
    const prefix = try std.fmt.allocPrint(alloc, "{s} {d:0>2} ", .{ label, row });
    defer alloc.free(prefix);
    try out.appendSlice(alloc, prefix);
    var c: usize = 0;
    var first = true;
    while (c < values.len) {
        const color = values[c];
        var n: usize = 1;
        while (c + n < values.len and values[c + n] == color) : (n += 1) {}
        if (!first) try out.append(alloc, ' ');
        first = false;
        if (color == 0) {
            const run = try std.fmt.allocPrint(alloc, "-*{d}", .{n});
            defer alloc.free(run);
            try out.appendSlice(alloc, run);
        } else {
            const run = try std.fmt.allocPrint(alloc, "{x:0>6}*{d}", .{ color, n });
            defer alloc.free(run);
            try out.appendSlice(alloc, run);
        }
        c += n;
    }
    try out.append(alloc, '\n');
}

/// Serialize one grid into the golden text format. Caller owns the result.
pub fn serialize(alloc: std.mem.Allocator, grid: anytype, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "# oz-cell-golden v" ++ std.fmt.comptimePrint("{d}", .{format_version}) ++ "\n");
    const name_line = try std.fmt.allocPrint(alloc, "# name: {s}\n", .{name});
    defer alloc.free(name_line);
    try out.appendSlice(alloc, name_line);
    const size_line = try std.fmt.allocPrint(alloc, "# size: {d} rows x {d} cols\nsize {d} {d}\n", .{
        grid.rows, grid.cols, grid.rows, grid.cols,
    });
    defer alloc.free(size_line);
    try out.appendSlice(alloc, size_line);

    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        var end = grid.cols;
        while (end > 0) {
            const t = cellText(grid, r, end - 1);
            if (t.len == 0 or std.mem.eql(u8, t, " ")) {
                end -= 1;
            } else break;
        }
        const prefix = try std.fmt.allocPrint(alloc, "row {d:0>2} |", .{r});
        defer alloc.free(prefix);
        try out.appendSlice(alloc, prefix);
        var c: usize = 0;
        while (c < end) : (c += 1) {
            const t = cellText(grid, r, c);
            if (t.len == 0) {
                try out.append(alloc, ' ');
            } else {
                try out.appendSlice(alloc, t);
            }
        }
        try out.appendSlice(alloc, "|\n");

        try appendStyleLine(alloc, &out, "bg", r, grid.bg_buf[r * grid.cols ..][0..grid.cols]);
        try appendStyleLine(alloc, &out, "fg", r, grid.fg_buf[r * grid.cols ..][0..grid.cols]);
    }
    return out.toOwnedSlice(alloc);
}

fn writeArtifact(io: std.Io, alloc: std.mem.Allocator, name: []const u8, suffix: []const u8, bytes: []const u8) !void {
    const dir = ".verify/golden";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.{s}.txt", .{ dir, name, suffix });
    defer alloc.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn buildDiff(alloc: std.mem.Allocator, expected: []const u8, actual: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var exp = std.mem.splitScalar(u8, expected, '\n');
    var act = std.mem.splitScalar(u8, actual, '\n');
    var line: usize = 1;
    var differing: usize = 0;
    while (true) : (line += 1) {
        const e = exp.next();
        const a = act.next();
        if (e == null and a == null) break;
        const es = e orelse "<missing line>";
        const as = a orelse "<missing line>";
        if (std.mem.eql(u8, es, as)) continue;
        differing += 1;
        const block = try std.fmt.allocPrint(alloc, "line {d}:\n  expected: {s}\n  actual:   {s}\n", .{
            line, es, as,
        });
        defer alloc.free(block);
        try out.appendSlice(alloc, block);
    }
    const footer = try std.fmt.allocPrint(alloc, "{d} differing line(s)\n", .{differing});
    defer alloc.free(footer);
    try out.appendSlice(alloc, footer);
    return out.toOwnedSlice(alloc);
}

fn reportMismatch(io: std.Io, alloc: std.mem.Allocator, name: []const u8, expected: []const u8, actual: []const u8) !void {
    try writeArtifact(io, alloc, name, "actual", actual);
    const diff = try buildDiff(alloc, expected, actual);
    defer alloc.free(diff);
    try writeArtifact(io, alloc, name, "diff", diff);

    std.debug.print("golden mismatch: {s}\n", .{name});
    std.debug.print("  actual frame: .verify/golden/{s}.actual.txt\n", .{name});
    std.debug.print("  line diff:    .verify/golden/{s}.diff.txt\n", .{name});
    // Show the first differing lines inline so CI logs are actionable
    // without downloading the artifact.
    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        std.debug.print("  {s}\n", .{line});
        shown += 1;
        if (shown >= 30) break;
    }
    std.debug.print(
        "  update with: OZ_UPDATE_GOLDEN=1 zig build e2e -Dtest-filter=\"golden\"\n",
        .{},
    );
}

fn updateRequested() bool {
    const value = std.testing.environ.getPosix(update_env) orelse return false;
    return std.mem.eql(u8, value, "1");
}

/// Compare the current grid against `golden_rel_path`; write the golden only
/// when `OZ_UPDATE_GOLDEN=1`. Returns error.GoldenMismatch / error.MissingGolden
/// (after writing actual/diff artifacts) on failure.
pub fn check(io: std.Io, alloc: std.mem.Allocator, grid: anytype, name: []const u8, golden_rel_path: []const u8) !void {
    const actual = try serialize(alloc, grid, name);
    defer alloc.free(actual);

    if (updateRequested()) {
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(golden_rel_path) orelse "test/golden") catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_rel_path, .data = actual });
        std.debug.print("updated golden: {s}\n", .{golden_rel_path});
        return;
    }

    const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_rel_path, alloc, .limited(1 << 20)) catch |err| {
        std.debug.print("missing golden: {s} ({s})\n", .{ golden_rel_path, @errorName(err) });
        try writeArtifact(io, alloc, name, "actual", actual);
        std.debug.print(
            "  create it with: OZ_UPDATE_GOLDEN=1 zig build e2e -Dtest-filter=\"golden\"\n",
            .{},
        );
        return error.MissingGolden;
    };
    defer alloc.free(expected);

    if (std.mem.eql(u8, expected, actual)) return;
    try reportMismatch(io, alloc, name, expected, actual);
    return error.GoldenMismatch;
}
