//! Comment toggling (DESIGN.md §1.3): gcc toggles the current line,
//! visual-mode gc toggles a range of lines. Markers per filetype.
//!
//! Pure logic: computes the replacement text for the line range; the caller
//! applies it through the History.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

pub const Style = struct {
    line: []const u8, // e.g. "//" or "#"
};

/// Marker table (M0): filetypes oz knows comment markers for. Everything else
/// (json/md/html/...) has no marker yet.
///   "//": zig rust go ts tsx js jsx c cpp cs
///   "#":  python py bash sh yaml yml
///   "--": lua
pub fn styleForFiletype(ft: []const u8) ?Style {
    const slash = [_][]const u8{ "zig", "rust", "go", "ts", "tsx", "js", "jsx", "c", "cpp", "cs" };
    for (slash) |f| {
        if (std.mem.eql(u8, ft, f)) return .{ .line = "//" };
    }
    const hash = [_][]const u8{ "python", "py", "bash", "sh", "yaml", "yml" };
    for (hash) |f| {
        if (std.mem.eql(u8, ft, f)) return .{ .line = "#" };
    }
    if (std.mem.eql(u8, ft, "lua")) return .{ .line = "--" };
    return null;
}

/// Result of toggling: the new text for the whole line range, and whether the
/// range WAS fully commented (so gcc un-comments when everything is
/// commented and comments otherwise).
///
/// Ownership: `text` is allocated with `allocator` and is owned by the
/// caller — the History copies it (piece_table.replace appends into its own
/// add buffer), then the caller frees it with `allocator`.
pub const Toggle = struct {
    text: []u8,
    was_commented: bool,
};

fn isLeadingWs(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// End of the line's TEXT: a `\r` that is the CR half of a CRLF terminator
/// (i.e. any non-final line) is not content.
fn lineTextEnd(buf: []const u8, line: u32, line_count: u32) usize {
    if (line + 1 < line_count and buf.len > 0 and buf[buf.len - 1] == '\r') {
        return buf.len - 1;
    }
    return buf.len;
}

/// A blank line has no content other than spaces/tabs. Vim's `gc` ignores
/// blank lines when deciding whether the range is already commented.
fn isBlankLine(text: []const u8) bool {
    for (text) |b| {
        if (!isLeadingWs(b)) return false;
    }
    return true;
}

/// Compute the toggled content for lines [start_line, end_line] inclusive.
/// Lines are examined ignoring leading whitespace; a line is "commented" when
/// its first non-blank bytes are exactly the marker ("// foo", "//foo" and
/// "  // foo" all count; a missing space after the marker is fine).
///
/// The operation is uniform over the range (vim gcc semantics):
///   was_commented == true  (every selected NON-BLANK line is commented)
///                             -> strip the marker and one following space
///                                (if any) from each commented line; blank
///                                lines are left byte-for-byte unchanged.
///   was_commented == false (any selected non-blank line is un-commented)
///                             -> comment every line: insert marker + " "
///                                right after the leading whitespace (indent
///                                kept); already-commented lines get a second
///                                marker, like vim gc on a mixed selection.
/// Blank lines (only spaces/tabs) never decide the direction, mirroring vim
/// gc / nvim: a selection of ["// foo", ""] un-comments instead of
/// double-commenting, and an all-blank selection is a no-op (vacuous
/// "all non-blank lines are commented" -> nothing to strip).
/// The returned text replaces [lineStart(start_line),
/// lineStart(end_line) + lineLen(end_line)) and keeps '\n' separators (a CRLF
/// line's '\r' stays part of the line, so CRLF survives unchanged).
pub fn toggleLines(
    allocator: std.mem.Allocator,
    pt: *const PieceTable,
    start_line: u32,
    end_line: u32,
    style: Style,
) !Toggle {
    std.debug.assert(start_line <= end_line);
    std.debug.assert(end_line < pt.lineCount());

    // Read every line once and record whether it is commented (first
    // non-blank bytes are exactly the marker). was_commented is the AND over
    // all NON-BLANK lines, mirroring vim gc: blank lines are ignored (a blank
    // line must not turn "all commented -> uncomment" into "comment
    // everything"), and only when every non-blank line is commented does the
    // toggle un-comment.
    const line_count = pt.lineCount();
    var line_bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (line_bufs.items) |b| allocator.free(b);
        line_bufs.deinit(allocator);
    }

    var was_commented = true;
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        const len = pt.lineLen(line);
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        pt.copyRange(pt.lineStart(line), buf);
        try line_bufs.append(allocator, buf);

        const text_end = lineTextEnd(buf, line, line_count);
        if (isBlankLine(buf[0..text_end])) continue;
        var i: usize = 0;
        while (i < text_end and isLeadingWs(buf[i])) i += 1;
        was_commented = was_commented and std.mem.startsWith(u8, buf[i..], style.line);
    }

    // Second pass: build the replacement text. The operation is uniform —
    // strip every line when the range was fully commented, otherwise comment
    // every line (a line that is already commented gets a second marker,
    // exactly like vim gc on a mixed selection).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (line_bufs.items, 0..) |buf, k| {
        if (k > 0) try out.append(allocator, '\n');
        const actual_line = start_line + @as(u32, @intCast(k));
        const text_end = lineTextEnd(buf, actual_line, line_count);
        var i: usize = 0;
        while (i < text_end and isLeadingWs(buf[i])) i += 1;
        if (was_commented) {
            // Blank lines carry no marker: leave them byte-for-byte as they
            // are (this also keeps a CRLF blank line's '\r').
            if (isBlankLine(buf[0..text_end])) {
                try out.appendSlice(allocator, buf);
                continue;
            }
            // Keep the indentation, drop the marker and one following space.
            // was_commented guarantees the marker; guard anyway so a future
            // invariant change can never slice past the line.
            if (!std.mem.startsWith(u8, buf[i..], style.line)) {
                try out.appendSlice(allocator, buf);
                continue;
            }
            try out.appendSlice(allocator, buf[0..i]);
            var j = i + style.line.len;
            if (j < buf.len and buf[j] == ' ') j += 1;
            try out.appendSlice(allocator, buf[j..]);
        } else {
            // Keep the indentation, insert marker + " " after it.
            try out.appendSlice(allocator, buf[0..i]);
            try out.appendSlice(allocator, style.line);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, buf[i..]);
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator), .was_commented = was_commented };
}

// =============================== tests ======================================

fn expectDocEqual(pt: *PieceTable, allocator: std.mem.Allocator, expected: []const u8) !void {
    const buf = try allocator.alloc(u8, pt.len());
    defer allocator.free(buf);
    pt.copyRange(0, buf);
    try std.testing.expectEqualStrings(expected, buf);
}

fn checkToggle(
    alloc: std.mem.Allocator,
    pt: *const PieceTable,
    start_line: u32,
    end_line: u32,
    style: Style,
    exp_was_commented: bool,
    exp_text: []const u8,
) !void {
    const t = try toggleLines(alloc, pt, start_line, end_line, style);
    defer alloc.free(t.text);
    try std.testing.expectEqual(exp_was_commented, t.was_commented);
    try std.testing.expectEqualStrings(exp_text, t.text);
}

test "comment: styleForFiletype table" {
    // "//" family
    const slash = [_][]const u8{ "zig", "rust", "go", "ts", "tsx", "js", "jsx", "c", "cpp", "cs" };
    for (slash) |f| try std.testing.expectEqualStrings("//", styleForFiletype(f).?.line);
    // "#" family
    const hash = [_][]const u8{ "python", "py", "bash", "sh", "yaml", "yml" };
    for (hash) |f| try std.testing.expectEqualStrings("#", styleForFiletype(f).?.line);
    // "--" family
    try std.testing.expectEqualStrings("--", styleForFiletype("lua").?.line);
    // unknown / unsupported -> null
    const none = [_][]const u8{ "json", "md", "html", "txt", "toml", "" };
    for (none) |f| try std.testing.expectEqual(@as(?Style, null), styleForFiletype(f));
}

test "comment: un-commented lines get commented" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "foo\nbar");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 1, style, false, "// foo\n// bar");
}

test "comment: commented lines get un-commented" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "// foo\n// bar");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 1, style, true, "foo\nbar");
}

test "comment: mixed lines count as not-commented (comment all)" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "foo\n// bar");
    defer pt.deinit();
    // vim gc semantics: already-commented line gets commented again
    try checkToggle(alloc, &pt, 0, 1, style, false, "// foo\n// // bar");
}

test "comment: indentation is preserved both ways" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "    foo\n\tbar");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 1, style, false, "    // foo\n\t// bar");

    var pt2 = try PieceTable.init(alloc, "    // foo\n\t// bar");
    defer pt2.deinit();
    try checkToggle(alloc, &pt2, 0, 1, style, true, "    foo\n\tbar");
}

test "comment: empty lines are not commented and still get a marker" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "foo\n\nbar");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 2, style, false, "// foo\n// \n// bar");
}

test "comment: marker without a following space is still recognized" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "//foo");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 0, style, true, "foo");

    const hash_style = Style{ .line = "#" };
    var pt2 = try PieceTable.init(alloc, "# foo");
    defer pt2.deinit();
    try checkToggle(alloc, &pt2, 0, 0, hash_style, true, "foo");
}

test "comment: wrong marker for the style is not a comment" {
    // "# foo" is not a "//" comment -> gets a "// " prefix
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "# foo");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 0, style, false, "// # foo");
}

test "comment: single line within a larger buffer" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "a\nb\nc");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 1, 1, style, false, "// b");
}

test "comment: replacement range covers exactly the selected lines" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "a\nbb\nccc");
    defer pt.deinit();
    const t = try toggleLines(alloc, &pt, 1, 2, style);
    defer alloc.free(t.text);
    try std.testing.expectEqualStrings("// bb\n// ccc", t.text);

    // [lineStart(1), lineStart(2)+lineLen(2)) = "bb\nccc"
    const rstart = pt.lineStart(1);
    const rend = pt.lineStart(2) + pt.lineLen(2);
    try std.testing.expectEqual(@as(u32, 2), rstart);
    try std.testing.expectEqual(@as(u32, 8), rend);
    _ = try pt.replace(rstart, rend - rstart, t.text);
    try expectDocEqual(&pt, alloc, "a\n// bb\n// ccc");
}

test "comment: trailing newline doc (vim line semantics)" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "#" };
    var pt = try PieceTable.init(alloc, "a\n");
    defer pt.deinit();
    // lines 0..1: "a" and the trailing empty line
    try checkToggle(alloc, &pt, 0, 1, style, false, "# a\n# ");
}

test "comment: toggle round trip restores the original" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    const original = "  alpha\nbeta\n  // gamma";
    var pt = try PieceTable.init(alloc, original);
    defer pt.deinit();

    // mixed range: comment everything (was_commented == false)
    const t = try toggleLines(alloc, &pt, 0, 2, style);
    defer alloc.free(t.text); // History copies; caller frees
    try std.testing.expectEqual(false, t.was_commented);
    _ = try pt.replace(0, pt.len(), t.text);

    // now fully commented: un-commenting restores the original
    const t2 = try toggleLines(alloc, &pt, 0, 2, style);
    defer alloc.free(t2.text);
    try std.testing.expectEqual(true, t2.was_commented);
    _ = try pt.replace(0, pt.len(), t2.text);

    try expectDocEqual(&pt, alloc, original);
}

/// Replace exactly the selected lines (no trailing '\n') with `toggle.text`,
/// mirroring what App.toggleCommentLine does with the pure result.
fn applyToggle(
    alloc: std.mem.Allocator,
    pt: *PieceTable,
    start_line: u32,
    end_line: u32,
    style: Style,
) !Toggle {
    const t = try toggleLines(alloc, pt, start_line, end_line, style);
    errdefer alloc.free(t.text);
    const start = pt.lineStart(start_line);
    const end = pt.lineStart(end_line) + pt.lineLen(end_line);
    _ = try pt.replace(start, end - start, t.text);
    return t;
}

test "comment: blank lines are ignored when deciding to uncomment (vim gc)" {
    // nvim 9.2 reference: `Vjgc` on "// foo\n\n" uncomments the line and
    // leaves the blank line untouched. A blank line alone must not flip the
    // range back to "comment" (that would double-comment real lines).
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "// foo\n\n");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 1, style, true, "foo\n");
}

test "comment: whitespace-only lines are ignored when deciding to uncomment" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "// foo\n   \n");
    defer pt.deinit();
    // Blank line is left exactly as it was (no marker to strip, no edit).
    try checkToggle(alloc, &pt, 0, 1, style, true, "foo\n   ");
}

test "comment: gc round trip restores empty lines" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    const original = "foo\n\nbar";
    var pt = try PieceTable.init(alloc, original);
    defer pt.deinit();

    // Commenting keeps a marker on the empty line (vim gc semantics).
    const t = try applyToggle(alloc, &pt, 0, 2, style);
    defer alloc.free(t.text);
    try std.testing.expectEqual(false, t.was_commented);
    try expectDocEqual(&pt, alloc, "// foo\n// \n// bar");

    // Toggling again must restore the original bytes exactly.
    const t2 = try applyToggle(alloc, &pt, 0, 2, style);
    defer alloc.free(t2.text);
    try std.testing.expectEqual(true, t2.was_commented);
    try expectDocEqual(&pt, alloc, original);
}

test "comment: all-blank range is a no-op (guard, no panic)" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    // Empty lines: uncomment path must not slice past the (empty) line.
    var pt = try PieceTable.init(alloc, "\n");
    defer pt.deinit();
    try checkToggle(alloc, &pt, 0, 1, style, true, "\n");

    // Whitespace-only lines keep their whitespace byte-for-byte.
    var pt2 = try PieceTable.init(alloc, "   \n");
    defer pt2.deinit();
    try checkToggle(alloc, &pt2, 0, 1, style, true, "   \n");
}

test "comment: CRLF range keeps CRLF and round-trips" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    const original = "foo\r\nbar\r\n";
    var pt = try PieceTable.init(alloc, original);
    defer pt.deinit();

    const t = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t.text);
    try std.testing.expectEqual(false, t.was_commented);
    try std.testing.expectEqualStrings("// foo\r\n// bar\r", t.text);
    try expectDocEqual(&pt, alloc, "// foo\r\n// bar\r\n");

    const t2 = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t2.text);
    try std.testing.expectEqual(true, t2.was_commented);
    try expectDocEqual(&pt, alloc, original);
}

test "comment: CRLF blank line counts as blank for the direction decision" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    var pt = try PieceTable.init(alloc, "// foo\r\n\r\n");
    defer pt.deinit();
    // The "\r" of the blank CRLF line is terminator, not line text: it must
    // not make the range look "not commented" and double-comment "// foo".
    try checkToggle(alloc, &pt, 0, 1, style, true, "foo\r\n\r");
}

test "comment: last line without a trailing newline" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "//" };
    const original = "foo\nbar";
    var pt = try PieceTable.init(alloc, original);
    defer pt.deinit();

    const t = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t.text);
    try std.testing.expectEqual(false, t.was_commented);
    try std.testing.expectEqualStrings("// foo\n// bar", t.text);
    try expectDocEqual(&pt, alloc, "// foo\n// bar");

    const t2 = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t2.text);
    try std.testing.expectEqual(true, t2.was_commented);
    try expectDocEqual(&pt, alloc, original);
}

test "comment: last real line of a trailing-newline doc keeps the newline" {
    const alloc = std.testing.allocator;
    const style = Style{ .line = "#" };
    var pt = try PieceTable.init(alloc, "a\nb\n");
    defer pt.deinit();

    const t = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t.text);
    try std.testing.expectEqualStrings("# a\n# b", t.text);
    try expectDocEqual(&pt, alloc, "# a\n# b\n");

    const t2 = try applyToggle(alloc, &pt, 0, 1, style);
    defer alloc.free(t2.text);
    try expectDocEqual(&pt, alloc, "a\nb\n");
}
