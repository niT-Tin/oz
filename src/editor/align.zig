//! Align lines by a delimiter (DESIGN.md §1.3): ga{motion}{delim} — e.g.
//! `gaip=` aligns the first '=' of every line in the paragraph.
//! Pure logic: returns the replacement text for a line range.
const std = @import("std");
const PieceTable = @import("../buffer/piece_table.zig").PieceTable;

/// Compute the aligned content of lines [start_line, end_line] inclusive:
/// the first occurrence of `delim` on each line is padded (spaces before the
/// delimiter) so all delimiters sit in the same column (the max column).
/// Lines without the delimiter keep their leading whitespace and are not
/// padded. The returned text replaces the whole range.
///
/// Padding is inserted *after* each line's leading whitespace, so line
/// indentation is preserved while the delimiters line up. Columns are byte
/// columns (no wide-char handling, mirroring motion.zig's M0 scope).
///
/// The returned slice covers [lineStart(start_line), lineStart(end_line+1))
/// (or the end of the document for the last line): the whole lines including
/// the '\n' that terminates `end_line` when one exists. The caller owns the
/// allocation and must free it.
pub fn alignLines(
    allocator: std.mem.Allocator,
    pt: *const PieceTable,
    start_line: u32,
    end_line: u32,
    delim: u8,
) ![]u8 {
    std.debug.assert(end_line < pt.lineCount());
    std.debug.assert(start_line <= end_line);

    // Document span covered by the replacement: from the first byte of
    // start_line to the first byte of the line after end_line (== len for
    // the last line of the document).
    const start_off = pt.lineStart(start_line);
    const end_off = if (end_line + 1 < pt.lineCount()) pt.lineStart(end_line + 1) else pt.len();
    const orig_len: usize = end_off - start_off;

    // Pass 1: max byte offset of the first delim over all lines that have one.
    var max_col: u32 = 0;
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        if (firstDelim(pt, line, delim)) |d| {
            if (d > max_col) max_col = d;
        }
    }

    // Pass 2: total number of padding spaces to add.
    var total_pad: u32 = 0;
    line = start_line;
    while (line <= end_line) : (line += 1) {
        if (firstDelim(pt, line, delim)) |d| total_pad += max_col - d;
    }

    const out = try allocator.alloc(u8, orig_len + total_pad);
    errdefer allocator.free(out);

    // Pass 3: copy the lines, padding each delimiter to `max_col`.
    var w: usize = 0;
    line = start_line;
    while (line <= end_line) : (line += 1) {
        const ls = pt.lineStart(line);
        const ll = pt.lineLen(line);

        if (firstDelim(pt, line, delim)) |d| {
            // Leading whitespace stays put; the padding goes right after it.
            var indent: usize = 0;
            while (indent < d) : (indent += 1) {
                const b = pt.byteAt(ls + @as(u32, @intCast(indent)));
                if (b != ' ' and b != '\t') break;
            }
            const pad: usize = max_col - d;
            pt.copyRange(ls, out[w .. w + indent]);
            w += indent;
            @memset(out[w .. w + pad], ' ');
            w += pad;
            pt.copyRange(ls + @as(u32, @intCast(indent)), out[w .. w + (ll - indent)]);
            w += ll - indent;
        } else {
            pt.copyRange(ls, out[w .. w + ll]);
            w += ll;
        }

        // Preserve the '\n' after this line: every line before end_line has
        // one; end_line has one iff the original range did.
        if (line < end_line or (line == end_line and end_off > ls + ll)) {
            out[w] = '\n';
            w += 1;
        }
    }
    std.debug.assert(w == out.len);
    return out;
}

/// Byte offset of the first `delim` in `line` relative to its start, or null
/// when the line has no occurrence.
fn firstDelim(pt: *const PieceTable, line: u32, delim: u8) ?u32 {
    const ls = pt.lineStart(line);
    const ll = pt.lineLen(line);
    var d: u32 = 0;
    while (d < ll) : (d += 1) {
        if (pt.byteAt(ls + d) == delim) return d;
    }
    return null;
}

// ================================= tests =====================================

const testing = std.testing;

fn alignAndCheck(
    allocator: std.mem.Allocator,
    input: []const u8,
    start_line: u32,
    end_line: u32,
    delim: u8,
    expected: []const u8,
) !void {
    var pt = try PieceTable.init(allocator, input);
    defer pt.deinit();
    const out = try alignLines(allocator, &pt, start_line, end_line, delim);
    defer allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "align: pads '=' to the max column, keeps indentation, leaves no-delim lines alone" {
    // Padding goes right AFTER the leading whitespace (DESIGN.md §1.3:
    // "补到原前导空白之后，即保持行首缩进"): a line without indentation gets
    // its padding at the line start.
    //   "a = 1"       pre=2  -> pad 5, no indent -> "     a = 1"
    //   "longer = 22" pre=7  (the max)           -> unchanged
    //   "  b = 3"     pre=4  -> pad 3 after "  " -> "     b = 3"
    //   "no delim here"                          -> unchanged
    const input = "a = 1\nlonger = 22\n  b = 3\nno delim here\n";
    const expected = "     a = 1\nlonger = 22\n     b = 3\nno delim here\n";
    try alignAndCheck(testing.allocator, input, 0, 3, '=', expected);
}

test "align: delimiter at column 0 is padded to the max column" {
    // "= 1" pre=0 -> pad 1 so '=' lands at column 1 like "x=2".
    const input = "= 1\nx=2\n";
    const expected = " = 1\nx=2\n";
    try alignAndCheck(testing.allocator, input, 0, 1, '=', expected);
}

test "align: no line has the delimiter -> the range is returned unchanged" {
    const input = "abc\n  def\nxyz";
    try alignAndCheck(testing.allocator, input, 0, 2, '=', input);
}

test "align: CJK lines are padded by bytes" {
    // "中文" is 6 bytes; '=' in "中文=1" sits at byte 6, so "ab=2" gets 4
    // spaces at the line start (no leading whitespace to pad after).
    const input = "中文=1\nab=2\n";
    const expected = "中文=1\n    ab=2\n";
    try alignAndCheck(testing.allocator, input, 0, 1, '=', expected);
}

test "align: only the first delimiter per line is aligned" {
    const input = "a = b = c\nx=y\n";
    const expected = "a = b = c\n x=y\n";
    try alignAndCheck(testing.allocator, input, 0, 1, '=', expected);
}

test "align: empty line inside the range is left alone" {
    const input = "a=1\n\nbb=2\n";
    const expected = " a=1\n\nbb=2\n";
    try alignAndCheck(testing.allocator, input, 0, 2, '=', expected);
}

test "align: sub-range replacement starts at the range's first line" {
    const input = "top\nx = 1\nyy=22\nbottom\n";
    const expected = "x = 1\nyy=22\n";
    try alignAndCheck(testing.allocator, input, 1, 2, '=', expected);
}

test "align: last line without a trailing newline stays newline-free" {
    const input = "a=1\nbb=2";
    const expected = " a=1\nbb=2";
    try alignAndCheck(testing.allocator, input, 0, 1, '=', expected);
}

test "align: aligned lines share one delimiter column (copyRange per line)" {
    const input = "x = 1\nyy = 2\nzzz=3\nplain line\n";
    var pt = try PieceTable.init(testing.allocator, input);
    defer pt.deinit();
    const out = try alignLines(testing.allocator, &pt, 0, 3, '=');
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(" x = 1\nyy = 2\nzzz=3\nplain line\n", out);

    // Verify the delimiter column directly against the aligned text.
    var result = try PieceTable.init(testing.allocator, out);
    defer result.deinit();
    try testing.expectEqual(@as(u32, 5), result.lineCount()); // trailing '\n' adds an empty line
    var line: u32 = 0;
    while (line < result.lineCount()) : (line += 1) {
        const ll = result.lineLen(line);
        const buf = try testing.allocator.alloc(u8, ll);
        defer testing.allocator.free(buf);
        result.copyRange(result.lineStart(line), buf);
        if (std.mem.indexOfScalar(u8, buf, '=')) |d| {
            try testing.expectEqual(@as(usize, 3), d); // every '=' at column 3
        }
    }
}
