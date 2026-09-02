const std = @import("std");
const vaxis = @import("vaxis");
const syntax = @import("../syntax.zig");
const theme = @import("../theme.zig");

/// Append `haystack` with every occurrence of `pat` replaced by `rep`
/// (all if `global`, else only the first). Returns the replacement count.
pub fn replaceLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, haystack: []const u8, pat: []const u8, rep: []const u8, global: bool) usize {
    if (pat.len == 0) {
        out.appendSlice(allocator, haystack) catch {};
        return 0;
    }
    var count: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, i, pat)) |pos| {
            out.appendSlice(allocator, haystack[i..pos]) catch return count;
            out.appendSlice(allocator, rep) catch return count;
            count += 1;
            i = pos + pat.len;
            if (!global) {
                out.appendSlice(allocator, haystack[i..]) catch return count;
                return count;
            }
        } else {
            out.appendSlice(allocator, haystack[i..]) catch return count;
            return count;
        }
    }
    return count;
}

/// Number of syntax.Style variants — sizes the per-frame style palette used
/// by the grep picker preview (styles keyed by the enum's ordinal).
pub const syntax_style_count = @typeInfo(syntax.Style).@"enum".fields.len;

/// Snap a byte offset back to the start of the UTF-8 char containing it.
/// fzy match positions are byte indices that can land on a continuation byte
/// when the query contains multi-byte chars; segment splits must only happen
/// at char boundaries or vaxis's grapheme iterator emits garbage.
pub fn utf8CharStart(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

/// Byte length of the UTF-8 char starting at `pos` (must be a char start).
pub fn utf8CharLenAt(s: []const u8, pos: usize) usize {
    const b = s[pos];
    if (b < 0x80) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// Byte offset where 0-based `line` starts in `text` (text.len when the line
/// doesn't exist).
pub fn lineStartByte(text: []const u8, line: usize) usize {
    var pos: usize = 0;
    var l: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return text.len;
        pos = nl + 1;
    }
    return @min(pos, text.len);
}

/// Byte offset of 0-based `line`'s end (the '\n' position, or text.len for a
/// final line without a trailing newline). Line content is text[start..end].
pub fn lineEndByte(text: []const u8, line: usize) usize {
    const s = lineStartByte(text, line);
    return std.mem.indexOfScalarPos(u8, text, s, '\n') orelse text.len;
}

/// Display width (terminal cells) of `text`, measured the way Window.print
/// lays text out: per grapheme cluster via gwidth (CJK = 2 cells, combining
/// marks and zero-width joiners = 0). A byte length is NOT a width —
/// truncating/padding by bytes overflows the row and shifts box borders on
/// any non-ASCII text.
pub fn cellWidth(win: vaxis.Window, text: []const u8) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: usize = 0;
    while (iter.next()) |g| cells += win.gwidth(g.bytes(text));
    return cells;
}

/// A grapheme-aligned slice of a string plus its display width in cells.
pub const CellFit = struct { slice: []const u8, cells: usize };

/// Longest prefix of `text` whose display width fits in `max_cells` cells.
/// Grapheme-aligned: never splits a UTF-8 sequence or cluster, and a wide
/// grapheme that would straddle the limit is dropped whole (a half-drawn
/// CJK char corrupts the row anyway).
pub fn cellFitPrefix(win: vaxis.Window, text: []const u8, max_cells: usize) CellFit {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: usize = 0;
    var len: usize = 0;
    while (iter.next()) |g| {
        const w: usize = win.gwidth(g.bytes(text));
        if (cells + w > max_cells) break;
        cells += w;
        len = g.start + g.len;
    }
    return .{ .slice = text[0..len], .cells = cells };
}

/// Shortest suffix of `text` whose display width fits in `max_cells` cells
/// (grapheme-aligned), for left-truncated paths ("…tail" keeps the
/// informative end).
pub fn cellFitSuffix(win: vaxis.Window, text: []const u8, max_cells: usize) CellFit {
    const total = cellWidth(win, text);
    if (total <= max_cells) return .{ .slice = text, .cells = total };
    var iter = vaxis.unicode.graphemeIterator(text);
    var dropped: usize = 0;
    var start: usize = 0;
    while (total - dropped > max_cells) {
        const g = iter.next() orelse break;
        dropped += win.gwidth(g.bytes(text));
        start = g.start + g.len;
    }
    return .{ .slice = text[start..], .cells = total - dropped };
}

/// Append one picker row's colored segments: `text` (truncated to `total_w`
/// CELLS, grapheme-aligned) split into runs by the per-byte style ids in
/// `ids` (`styles[id]` per run), then space-padded to `total_w` cells with
/// `pad_style`. `text`/`ids`/`styles` must outlive vx.render() — pass arena
/// strings (or App-owned preview_text). `ids` is indexed by BYTE offset and
/// must cover the whole of `text`.
pub fn appendRowSegs(
    segs: *std.ArrayList(vaxis.Segment),
    a: std.mem.Allocator,
    win: vaxis.Window,
    text: []const u8,
    ids: []const u8,
    styles: []const vaxis.Style,
    total_w: usize,
    pad_style: vaxis.Style,
) !void {
    const fit = cellFitPrefix(win, text, total_w);
    const n = @min(fit.slice.len, ids.len);
    const cells = if (n == fit.slice.len) fit.cells else cellWidth(win, text[0..n]);
    var i: usize = 0;
    while (i < n) {
        const id = ids[i];
        var j = i + 1;
        while (j < n and ids[j] == id) : (j += 1) {}
        try segs.append(a, .{ .text = text[i..j], .style = styles[id] });
        i = j;
    }
    if (cells < total_w) {
        const pad = try a.alloc(u8, total_w - cells);
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = pad_style });
    }
}

/// Filetype from a file path's extension ("src/main.zig" → "zig").
pub fn filetypeOf(path: ?[]const u8) []const u8 {
    const p = path orelse return "";
    const base = std.fs.path.basename(p);
    const ext = std.fs.path.extension(base);
    if (ext.len <= 1) return "";
    return ext[1..];
}

/// "```" or "~~~" markdown code fence opener: returns the language after the
/// fence ("" for a bare fence with no language); null when the line isn't a
/// fence. Bare fences still count so the closing fence is recognized.
pub fn isFenceLine(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    const c = line[0];
    if (c != '`' and c != '~') return null;
    if (line[1] != c or line[2] != c) return null;
    var i: usize = 3;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return "";
    return line[i..];
}

/// Theme palette for the tree-sitter capture groups (src/syntax.zig Style).
/// One dedicated semantic color per token class (theme.Theme), so distinct
/// token kinds no longer collapse onto a shared color — and rainbow brackets
/// (bracket0..bracket6) map to the theme's 7-color rainbow by ordinal.
pub fn syntaxStyle(style: syntax.Style, t: theme.Theme) vaxis.Style {
    return switch (style) {
        .default => .{ .fg = .{ .rgb = t.fg } },
        .comment => .{ .fg = .{ .rgb = t.comment } },
        .keyword => .{ .fg = .{ .rgb = t.keyword } }, // gold
        .string => .{ .fg = .{ .rgb = t.string } }, // green
        .number => .{ .fg = .{ .rgb = t.number } },
        .constant => .{ .fg = .{ .rgb = t.constant } },
        // kanagawa's Boolean links to Constant; bold sets it apart
        .boolean => .{ .fg = .{ .rgb = t.boolean }, .bold = true },
        .character => .{ .fg = .{ .rgb = t.character } },
        .function => .{ .fg = .{ .rgb = t.function } },
        .tag => .{ .fg = .{ .rgb = t.tag } },
        .namespace => .{ .fg = .{ .rgb = t.namespace } },
        .constructor => .{ .fg = .{ .rgb = t.constructor } },
        .type => .{ .fg = .{ .rgb = t.type } },
        .label => .{ .fg = .{ .rgb = t.label } },
        .operator => .{ .fg = .{ .rgb = t.operator } },
        .variable => .{ .fg = .{ .rgb = t.variable } },
        .parameter => .{ .fg = .{ .rgb = t.parameter } },
        .property => .{ .fg = .{ .rgb = t.property } },
        .attribute => .{ .fg = .{ .rgb = t.attribute } },
        .builtin => .{ .fg = .{ .rgb = t.builtin } },
        .punctuation => .{ .fg = .{ .rgb = t.punctuation } },
        // rainbow brackets: bracketN -> rainbow[N] (ordinal offset from
        // bracket0, exactly the bracket depth % 7 the highlighter assigned)
        .bracket0, .bracket1, .bracket2, .bracket3, .bracket4, .bracket5, .bracket6 => blk: {
            const idx: usize = @as(usize, @intFromEnum(style)) - @as(usize, @intFromEnum(syntax.Style.bracket0));
            break :blk .{ .fg = .{ .rgb = t.rainbow[idx] } };
        },
    };
}

pub fn parseLineArg(arg: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, arg, ':')) |idx| {
        return std.fmt.parseUnsigned(u32, arg[idx + 1 ..], 10) catch null;
    }
    return null;
}
