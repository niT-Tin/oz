//! Pure chart renderer for per-tool latency over time (DESIGN.md §18.4, M3b).
//!
//! Deliberately App/vaxis-independent: this module owns only layout, scaling
//! and braille/sparkline rasterisation. The M3b Tools workbox (`src/app/...`)
//! supplies the series and copies the returned cells into vaxis; nothing here
//! knows about an editor, a terminal or a frame loop.
//!
//! ## Output
//!
//! `render` returns a row-major `Canvas` of `Cell`s. Every row is exactly
//! `width` terminal cells:
//!
//!   - `Cell.width == 1` is a blank (`text = " "`) or narrow glyph;
//!   - `Cell.width == 2` is a wide glyph (CJK etc.);
//!   - `Cell.width == 0` is the right half of the wide glyph to its left
//!     (`text` is empty). Integrators skip width-0 cells.
//!
//! Labels and legends are measured with `buffer/utf8.zig` (`displayWidth` /
//! `truncateWidth`), never bytes, so a CJK tool name can never overflow the
//! row or be split mid-glyph. Colors are opaque caller values (for oz, the
//! packed RGB a theme resolves to); this module does not interpret them.
//!
//! ## Modes
//!
//! Full braille chart when `width >= 24` and `height >= 4`: optional legend
//! row, 2×4-dot-per-cell plot, two y labels (`0ms` / `y_max`) and an x row
//! (`older` … `now`). Otherwise a sparkline fallback (`▁▂▃▄▅▆▇█`), one row
//! per series, with the same optional legend and x labels when height allows.
//! The fallback also covers `height == 1`.
//!
//! ## Scaling and recent samples
//!
//! `y_max` overrides the automatic `0..max(sample)` range. Values above the
//! range clamp to the top; all-zero series sit on the bottom row. Only the
//! most recent `max_points` samples are considered. A full chart further
//! limits itself to `2 * plot_width` recent samples so one sample is never
//! drawn twice; the sparkline limits itself to `plot_width` recent samples.
//! One point is drawn at the right edge ("now"). Two or more full-chart
//! samples span the full plot width; the sparkline instead uses one cell per
//! sample, right-aligned, so a short history is not stretched into fake
//! intermediate samples.
//!
//! ## Allocation / bounds
//!
//! All memory comes from the caller's allocator: exactly one `Cell` array
//! (`width * height`) and, in full-chart axis mode, one small byte buffer for
//! the top y label (at most `max_label_bytes`). No per-cell allocation, no
//! global state, no clock/randomness. `max_series` and `max_points_limit`
//! bound the work; invalid sizes fail with a typed error before allocation.
//! The valid range is `1..max_width` × `1..max_height` (a 1×1 sparkline is
//! legal); zero and over-cap values are errors. Use an arena when rendering
//! per frame, or call `Canvas.deinit`.
//!
//! ## Known limitations
//!
//! - Braille U+2800..U+28FF and the block-eighths sparkline require a font
//!   with those glyphs (the same assumption as most TUI charts). Braille
//!   dots are one cell wide; no attempt is made to find a fallback glyph.
//! - The y axis has exactly two ticks (bottom `0ms`, top `y_max`); there are
//!   no intermediate/grid lines and no nice-number rounding. A label that
//!   does not fit the gutter is clipped from the right (prefix retained).
//! - A braille cell has one foreground color. The first series to light a
//!   cell owns its dots and color; later series are clipped at that cell.
//!   Use distinct colors to distinguish series.
//! - `bg` is always null; the host paints the panel background.
//! - No animation, tooltip, cursor or horizontal panning; the x axis is the
//!   most recent fixed sample window.

const std = @import("std");
const utf8 = @import("buffer/utf8.zig");

/// Hard caps. Larger inputs fail fast with a typed error instead of
/// allocating an unbounded grid or looping over an attacker-sized series.
pub const max_series: usize = 8;
pub const max_points_limit: usize = 4096;
pub const max_width: u16 = 1024;
pub const max_height: u16 = 512;
pub const max_cells: usize = 65_536;

/// Full-chart thresholds; below either dimension the sparkline fallback is
/// used (this includes every height-1 context).
pub const chart_min_width: u16 = 24;
pub const chart_min_height: u16 = 4;

/// Top y-label scratch bound: `4294967295ms` is 12 bytes.
pub const max_label_bytes: usize = 16;

/// One tool's latency history. `samples` is caller-owned and borrowed only
/// for the duration of `render`; `color` is opaque to this module.
pub const Series = struct {
    name: []const u8,
    color: u32,
    samples: []const u32,
};

/// One chart. `max_points` is the recent-sample window; `y_max` null means
/// "use the maximum sample across all series".
pub const Options = struct {
    width: u16,
    height: u16,
    max_points: usize,
    y_max: ?u32 = null,
    show_legend: bool = true,
    show_axis: bool = true,
};

/// One terminal cell. See the module docs for the `width == 0` continuation
/// convention. `text` is borrowed from static tables, a series name or the
/// canvas-owned label buffer, and stays valid until `Canvas.deinit`.
pub const Cell = struct {
    text: []const u8 = " ",
    fg: ?u32 = null,
    bg: ?u32 = null,
    width: u8 = 1,
};

/// Row-major rendered chart. Rows are exactly `width` cells wide.
pub const Canvas = struct {
    width: u16,
    height: u16,
    cells: []Cell,
    /// Owned storage for numeric y labels referenced by `cells`.
    text: []u8,

    pub fn row(self: *const Canvas, y: usize) []Cell {
        if (y >= self.height) return &.{};
        const w = @as(usize, self.width);
        return self.cells[y * w ..][0..w];
    }

    pub fn cellAt(self: *Canvas, x: usize, y: usize) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * @as(usize, self.width) + x];
    }

    pub fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) allocator.free(self.cells);
        if (self.text.len > 0) allocator.free(self.text);
        self.* = undefined;
    }
};

/// Integer mean latency in ms, rounded half up. Null for an empty series.
/// Summed in u64 so `maxInt(u32)` samples cannot overflow.
pub fn average(samples: []const u32) ?u32 {
    if (samples.len == 0) return null;
    var sum: u64 = 0;
    for (samples) |v| sum += v;
    const n: u64 = @intCast(samples.len);
    return @intCast((sum + n / 2) / n);
}

/// The most recent `max_points` samples (all of them when the slice is
/// shorter). Zero selects an empty slice; the caller normally validates
/// `max_points > 0` in `Options`.
pub fn recent(samples: []const u32, max_points: usize) []const u32 {
    if (samples.len <= max_points) return samples;
    return samples[samples.len - max_points ..];
}

/// Maximum sample across every series (0 for no series / empty series).
pub fn maxSample(series: []const Series) u32 {
    var m: u32 = 0;
    for (series) |s| {
        for (s.samples) |v| m = @max(m, v);
    }
    return m;
}

/// Effective y range: the explicit override or the observed maximum.
pub fn effectiveYMax(series: []const Series, explicit: ?u32) u32 {
    return explicit orelse maxSample(series);
}

/// Scale `value` into `0..max_level`, clamping above `y_max` and rounding
/// half up. A zero range or zero levels returns 0 (bottom row).
pub fn scaleToLevel(value: u32, y_max: u32, max_level: u32) u32 {
    if (y_max == 0 or max_level == 0) return 0;
    const clamped = @min(value, y_max);
    const scaled = (@as(u64, clamped) * max_level + y_max / 2) / y_max;
    return @intCast(@min(scaled, max_level));
}

/// Format a latency tick ("0ms", "80ms"). No allocation; the caller owns
/// `buf`. Returns `error.NoSpaceLeft` when the buffer is too small.
pub fn format_ms(buf: []u8, ms: u32) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "{d}ms", .{ms});
}

/// Render one chart. See the module docs for layout, scaling and allocation
/// bounds. Errors are deliberate and typed: the renderer never panics on a
/// bad size, an oversized series set or an empty series.
pub fn render(allocator: std.mem.Allocator, series: []const Series, opts: Options) !Canvas {
    try validate(series, opts);

    const w: usize = opts.width;
    const h: usize = opts.height;
    const cells = try allocator.alloc(Cell, w * h);
    errdefer allocator.free(cells);
    for (cells) |*cell| cell.* = .{};

    const y_max = effectiveYMax(series, opts.y_max);
    var label_text: []u8 = &.{};
    errdefer if (label_text.len > 0) allocator.free(label_text);

    var canvas = Canvas{
        .width = opts.width,
        .height = opts.height,
        .cells = cells,
        .text = label_text,
    };

    if (w >= chart_min_width and h >= chart_min_height) {
        label_text = try renderFull(allocator, &canvas, series, opts, y_max);
        canvas.text = label_text;
    } else {
        renderSparkline(&canvas, series, opts, y_max);
    }
    return canvas;
}

/// Input validation, kept separate so every error is reachable without an
/// allocation and tests can assert exact error tags.
pub fn validate(series: []const Series, opts: Options) !void {
    if (opts.width == 0 or opts.width > max_width) return error.InvalidWidth;
    if (opts.height == 0 or opts.height > max_height) return error.InvalidHeight;
    if (opts.max_points == 0 or opts.max_points > max_points_limit) return error.InvalidMaxPoints;
    if (series.len > max_series) return error.TooManySeries;
    const cells = @as(usize, opts.width) * @as(usize, opts.height);
    if (cells > max_cells) return error.ChartTooLarge;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Full braille chart. Returns the allocated top-label storage (possibly
/// empty when axes are off), which the Canvas owns.
fn renderFull(allocator: std.mem.Allocator, canvas: *Canvas, series: []const Series, opts: Options, y_max: u32) ![]u8 {
    const w: usize = canvas.width;
    const h: usize = canvas.height;
    const legend_h: usize = if (opts.show_legend and series.len > 0) 1 else 0;
    const axis_h: usize = if (opts.show_axis) 1 else 0;
    const plot_y = legend_h;
    const plot_h = h - legend_h - axis_h;

    const top_label_buf = try formatTopLabel(y_max);
    var gutter: usize = 0;
    if (opts.show_axis) {
        const widest = @max(utf8.displayWidth(top_label_buf.slice()), utf8.displayWidth("0ms"));
        // Keep the plot readable: labels may never eat more than a quarter
        // of the width (with a 4-cell floor for "0ms").
        const gutter_cap = @max(@as(usize, 4), w / 4);
        gutter = @min(@as(usize, widest) + 1, gutter_cap);
    }
    const plot_w = w - gutter;
    const dot_w = plot_w * 2;
    const dot_h = plot_h * 4;

    if (legend_h == 1) drawLegend(canvas, series, w, 0);

    var label_text: []u8 = &.{};
    if (opts.show_axis) {
        label_text = try allocLabel(allocator, top_label_buf.slice());
        drawTextRight(canvas, gutter - 1, plot_y, label_text, gutter - 1, null);
        drawTextRight(canvas, gutter - 1, plot_y + plot_h - 1, "0ms", gutter - 1, null);
    }

    for (series) |s| {
        drawSeries(canvas, s, gutter, plot_y, plot_w, plot_h, dot_w, dot_h, y_max, opts.max_points);
    }

    if (opts.show_axis) drawXLabels(canvas, gutter, plot_w, h - 1);
    return label_text;
}

/// Formatted top tick without allocation. Returns a local fixed buffer; the
/// caller copies it into the canvas-owned storage before returning.
const TopLabel = struct {
    buf: [max_label_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TopLabel) []const u8 {
        return self.buf[0..self.len];
    }
};

fn formatTopLabel(y_max: u32) !TopLabel {
    var result = TopLabel{};
    const text = try format_ms(&result.buf, y_max);
    result.len = text.len;
    return result;
}

/// Copy `text` into canvas-owned storage so cells can reference it after the
/// formatting stack frame is gone.
fn allocLabel(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return &.{};
    const out = try allocator.alloc(u8, text.len);
    @memcpy(out, text);
    return out;
}

/// Sparkline fallback for narrow/short contexts. One row per series (up to
/// the available data rows); optional legend above and x labels below.
fn renderSparkline(canvas: *Canvas, series: []const Series, opts: Options, y_max: u32) void {
    const w: usize = canvas.width;
    const h: usize = canvas.height;
    const legend_h: usize = if (opts.show_legend and series.len > 0 and h >= 2) 1 else 0;
    const x_h: usize = if (opts.show_axis and h - legend_h >= 2) 1 else 0;
    const data_h = h - legend_h - x_h;

    if (legend_h == 1) drawLegend(canvas, series, w, 0);

    var row: usize = 0;
    while (row < data_h and row < series.len) : (row += 1) {
        drawSparkRow(canvas, series[row], w, legend_h + row, y_max, opts.max_points);
    }

    if (x_h == 1) drawXLabels(canvas, 0, w, h - 1);
}

fn drawSparkRow(canvas: *Canvas, series: Series, width: usize, y: usize, y_max: u32, max_points: usize) void {
    const visible = recent(series.samples, @min(max_points, width));
    if (visible.len == 0) return;
    const start_x = width - visible.len;
    for (visible, 0..) |value, i| {
        const level = scaleToLevel(value, y_max, spark_glyphs.len - 1);
        setGlyph(canvas, start_x + i, y, spark_glyphs[level], 1, series.color, null);
    }
}

fn drawXLabels(canvas: *Canvas, x: usize, plot_w: usize, y: usize) void {
    const now = "now";
    const now_w = utf8.displayWidth(now);
    const older_max: usize = if (plot_w > now_w) plot_w - now_w - 1 else 0;
    _ = drawText(canvas, x, y, "older", older_max, null, null);
    drawTextRight(canvas, x + plot_w, y, now, plot_w, null);
}

// ---------------------------------------------------------------------------
// Series / rasterisation
// ---------------------------------------------------------------------------

fn drawSeries(
    canvas: *Canvas,
    series: Series,
    plot_x: usize,
    plot_y: usize,
    plot_w: usize,
    plot_h: usize,
    dot_w: usize,
    dot_h: usize,
    y_max: u32,
    max_points: usize,
) void {
    const visible_all = recent(series.samples, max_points);
    const n = @min(visible_all.len, dot_w);
    if (n == 0) return;
    const visible = visible_all[visible_all.len - n ..];

    var prev_x: usize = 0;
    var prev_y: usize = 0;
    for (visible, 0..) |value, i| {
        // Newest sample is always exactly at the right edge; older samples
        // spread evenly up to it. With n <= dot_w no two samples share a dot
        // column, and n == 1 sits at "now".
        const x: usize = if (n == 1)
            dot_w - 1
        else
            (i * (dot_w - 1) + (n - 1) / 2) / (n - 1);
        const y = scaleToLevel(value, y_max, @intCast(dot_h - 1));
        if (i == 0) {
            setDot(canvas, plot_x, plot_y, plot_w, plot_h, x, y, series.color);
        } else {
            drawDotLine(canvas, plot_x, plot_y, plot_w, plot_h, prev_x, prev_y, x, y, series.color);
        }
        prev_x = x;
        prev_y = y;
    }
}

/// Bresenham in braille-dot space, including both endpoints. Dot y counts
/// from the bottom, so a rising latency line moves up on screen.
fn drawDotLine(
    canvas: *Canvas,
    plot_x: usize,
    plot_y: usize,
    plot_w: usize,
    plot_h: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    color: u32,
) void {
    var x: i32 = @intCast(x0);
    var y: i32 = @intCast(y0);
    const x1i: i32 = @intCast(x1);
    const y1i: i32 = @intCast(y1);
    const dx: i32 = if (x1i >= x) x1i - x else x - x1i;
    const dy: i32 = -if (y1i >= y) y1i - y else y - y1i;
    const sx: i32 = if (x < x1i) 1 else -1;
    const sy: i32 = if (y < y1i) 1 else -1;
    var err: i32 = dx + dy;
    while (true) {
        setDot(canvas, plot_x, plot_y, plot_w, plot_h, @intCast(x), @intCast(y), color);
        if (x == x1i and y == y1i) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Light one braille dot. The first series to touch a cell owns its color;
/// later series are ignored in that cell (see module limitations).
fn setDot(
    canvas: *Canvas,
    plot_x: usize,
    plot_y: usize,
    plot_w: usize,
    plot_h: usize,
    dot_x: usize,
    dot_y: usize,
    color: u32,
) void {
    if (dot_x >= plot_w * 2 or dot_y >= plot_h * 4) return;
    const cell_x = plot_x + dot_x / 2;
    const cell_y = plot_y + (plot_h - 1 - dot_y / 4);
    const local_x = dot_x % 2;
    const local_top = 3 - (dot_y % 4);
    const bit = brailleBit(local_x, local_top);

    const cell = canvas.cellAt(cell_x, cell_y) orelse return;
    if (cell.fg) |owner| {
        if (owner != color) return;
        const bits = brailleBitsOf(cell.*) | bit;
        cell.text = brailleGlyph(bits);
    } else {
        cell.fg = color;
        cell.text = brailleGlyph(bit);
        cell.width = 1;
    }
}

fn brailleBit(local_x: usize, local_top: usize) u8 {
    return switch (local_top) {
        0 => if (local_x == 0) 0x01 else 0x08,
        1 => if (local_x == 0) 0x02 else 0x10,
        2 => if (local_x == 0) 0x04 else 0x20,
        else => if (local_x == 0) 0x40 else 0x80,
    };
}

fn brailleBitsOf(cell: Cell) u8 {
    if (cell.text.len != 3) return 0;
    const d = utf8.decodeAt(cell.text, 0);
    if (d.cp < 0x2800 or d.cp > 0x28FF) return 0;
    return @intCast(d.cp - 0x2800);
}

fn brailleGlyph(bits: u8) []const u8 {
    return braille_glyphs[bits][0..];
}

// ---------------------------------------------------------------------------
// Text drawing (cell-exact, UTF-8 aware)
// ---------------------------------------------------------------------------

/// Draw `text` at `x0/y`, clipped to at most `max_cols` cells. Returns the
/// number of columns consumed. Wide glyphs are never split: a glyph that
/// does not fit is dropped whole. Combining marks extend the preceding glyph
/// when they are contiguous in `text`.
fn drawText(canvas: *Canvas, x0: usize, y: usize, text: []const u8, max_cols: usize, fg: ?u32, bg: ?u32) usize {
    if (y >= canvas.height or x0 >= canvas.width or max_cols == 0) return 0;
    const row = canvas.row(y);
    const limit = @min(max_cols, row.len - x0);
    var col: usize = 0;
    var i: usize = 0;
    var last_start: usize = 0;
    var last_cell_x: ?usize = null;

    while (i < text.len) {
        const d = utf8.decodeAt(text, i);
        const cw = utf8.charWidth(d.cp);
        if (cw == 0) {
            // Combining mark: keep it attached to the base glyph's cell. The
            // slice still points into the caller's text, so extending it is
            // enough to make the grapheme render correctly.
            if (last_cell_x) |cell_x| {
                if (cell_x < row.len) row[cell_x].text = text[last_start .. i + d.len];
            }
            i += d.len;
            continue;
        }
        if (col + cw > limit) break;
        const cell_x = x0 + col;
        row[cell_x].text = text[i .. i + d.len];
        row[cell_x].fg = fg;
        row[cell_x].bg = bg;
        row[cell_x].width = @intCast(cw);
        var k: usize = 1;
        while (k < cw) : (k += 1) {
            row[cell_x + k].text = "";
            row[cell_x + k].fg = fg;
            row[cell_x + k].bg = bg;
            row[cell_x + k].width = 0;
        }
        last_start = i;
        last_cell_x = cell_x;
        col += cw;
        i += d.len;
    }
    return col;
}

/// Right-align `text` so its last cell is at `x_end - 1`, clipping to
/// `max_cols` cells. Used for y ticks and the "now" label.
fn drawTextRight(canvas: *Canvas, x_end: usize, y: usize, text: []const u8, max_cols: usize, fg: ?u32) void {
    if (x_end == 0 or max_cols == 0) return;
    const budget: u32 = @intCast(@min(max_cols, std.math.maxInt(u32)));
    const fit = utf8.truncateWidth(text, budget);
    const width = utf8.displayWidth(fit);
    if (width == 0 or width > x_end) return;
    const start = x_end - width;
    _ = drawText(canvas, start, y, fit, width, fg, null);
}

fn drawLegend(canvas: *Canvas, series: []const Series, width: usize, y: usize) void {
    var col: usize = 0;
    for (series, 0..) |s, i| {
        if (i > 0 and col < width) {
            // One uncolored gap between entries: "─ read_file ─ grep".
            _ = drawText(canvas, col, y, " ", width - col, null, null);
            col += 1;
        }
        if (col >= width) break;
        col += drawText(canvas, col, y, "─ ", width - col, s.color, null);
        if (col >= width) break;
        col += drawText(canvas, col, y, s.name, width - col, s.color, null);
    }
}

fn setGlyph(canvas: *Canvas, x: usize, y: usize, text: []const u8, width: u8, fg: ?u32, bg: ?u32) void {
    const cell = canvas.cellAt(x, y) orelse return;
    cell.text = text;
    cell.width = width;
    cell.fg = fg;
    cell.bg = bg;
}

// ---------------------------------------------------------------------------
// Static glyph tables
// ---------------------------------------------------------------------------

/// Block-eighths sparkline, one glyph per level (0 = lowest).
const spark_glyphs = [8][]const u8{
    "▁",
    "▂",
    "▃",
    "▄",
    "▅",
    "▆",
    "▇",
    "█",
};

/// UTF-8 encoding of U+2800 + bits for every braille pattern. Generated at
/// comptime; no runtime state and no allocation for glyphs.
const braille_glyphs = blk: {
    var table: [256][3]u8 = undefined;
    for (0..256) |bits| {
        table[bits] = .{
            0xE2,
            0xA0 + @as(u8, @intCast(bits >> 6)),
            0x80 + @as(u8, @intCast(bits & 0x3F)),
        };
    }
    break :blk table;
};

// ---------------------------------------------------------------------------
// Tests (DESIGN.md §12.2 L1 unit + L2 text snapshots)
// ---------------------------------------------------------------------------

/// Row text with trailing blank cells trimmed and wide-glyph continuation
/// cells skipped. The invariant tests separately prove every row is exactly
/// `width` terminal cells.
fn dump(allocator: std.mem.Allocator, canvas: *const Canvas) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (0..canvas.height) |y| {
        const row = canvas.row(y);
        var end = row.len;
        while (end > 0 and row[end - 1].width == 1 and std.mem.eql(u8, row[end - 1].text, " ")) end -= 1;
        for (row[0..end]) |cell| {
            if (cell.width == 0) continue;
            try out.appendSlice(allocator, cell.text);
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// One row's visible text (wide-glyph continuations skipped).
fn rowText(allocator: std.mem.Allocator, canvas: *const Canvas, y: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const row = canvas.row(y);
    var end = row.len;
    while (end > 0 and row[end - 1].width == 1 and std.mem.eql(u8, row[end - 1].text, " ")) end -= 1;
    for (row[0..end]) |cell| {
        if (cell.width == 0) continue;
        try out.appendSlice(allocator, cell.text);
    }
    return out.toOwnedSlice(allocator);
}

/// Compare against a trailing-newline-trimmed frame.
fn expectSnapshot(expected: []const u8, actual: []const u8) !void {
    try std.testing.expect(actual.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), actual[actual.len - 1]);
    try std.testing.expectEqualStrings(expected, actual[0 .. actual.len - 1]);
}

/// Every row must be exactly `width` cells, every wide glyph must have its
/// continuation cell, and no glyph may be a partial UTF-8 sequence.
fn expectCellInvariants(canvas: *const Canvas) !void {
    try std.testing.expectEqual(@as(usize, @as(usize, canvas.width) * @as(usize, canvas.height)), canvas.cells.len);
    for (0..canvas.height) |y| {
        const row = canvas.row(y);
        try std.testing.expectEqual(@as(usize, canvas.width), row.len);
        var total: usize = 0;
        for (row) |cell| {
            if (cell.width == 0) {
                try std.testing.expectEqualStrings("", cell.text);
            } else {
                try std.testing.expect(cell.width == 1 or cell.width == 2);
                try std.testing.expect(cell.text.len > 0);
                try std.testing.expectEqual(@as(u32, cell.width), utf8.displayWidth(cell.text));
                try std.testing.expect(utf8.isBoundary(cell.text, cell.text.len));
            }
            total += cell.width;
        }
        try std.testing.expectEqual(@as(usize, canvas.width), total);
    }
}

fn expectColor(canvas: *const Canvas, color: u32) !void {
    for (canvas.cells) |cell| {
        if (cell.fg) |fg| {
            if (fg == color) return;
        }
    }
    return error.TestUnexpectedResult;
}

test "chart: 40x8 single series snapshot" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "read_file",
        .color = 0xE06C75,
        .samples = &.{ 0, 10, 40, 80 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 32 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ read_file
        \\80ms                                ⣀⠤⠒⠉
        \\                                ⣀⠤⠒⠉
        \\                           ⢀⣀⠤⠒⠉
        \\                      ⢀⣀⠤⠒⠊⠁
        \\                 ⢀⡠⠤⠒⠉⠁
        \\ 0ms ⣀⣀⠤⠤⠤⠤⠒⠒⠒⠒⠉⠉⠁
        \\     older                           now
    ,
        text,
    );
}

test "chart: 80x10 multi-series legend snapshot and colors" {
    const allocator = std.testing.allocator;
    const series = [_]Series{
        .{ .name = "read_file", .color = 0xE06C75, .samples = &.{ 0, 10, 40, 80 } },
        .{ .name = "grep", .color = 0x61AFEF, .samples = &.{ 5, 20, 30, 60 } },
    };
    var canvas = try render(allocator, &series, .{ .width = 80, .height = 10, .max_points = 64 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    try expectColor(&canvas, 0xE06C75);
    try expectColor(&canvas, 0x61AFEF);

    // The legend is exactly "─ read_file ─ grep", each entry in its series
    // color.
    const row = canvas.row(0);
    try std.testing.expectEqualStrings("─", row[0].text);
    try std.testing.expectEqual(@as(?u32, 0xE06C75), row[0].fg);
    try std.testing.expectEqualStrings("r", row[2].text);
    try std.testing.expectEqual(@as(?u32, 0xE06C75), row[2].fg);
    try std.testing.expectEqualStrings("─", row[12].text);
    try std.testing.expectEqual(@as(?u32, 0x61AFEF), row[12].fg);
    try std.testing.expectEqualStrings("g", row[14].text);
    const legend = try rowText(allocator, &canvas, 0);
    defer allocator.free(legend);
    try std.testing.expectEqualStrings("─ read_file ─ grep", legend);

    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ read_file ─ grep
        \\80ms                                                                      ⣀⡠⠤⠒⠒⠉
        \\                                                                   ⣀⣀⠤⠔⠒⠉⠉
        \\                                                            ⢀⣀⠤⠤⠒⠊⠉     ⣀⣀⠤⠤⠔⠒⠊⠉
        \\                                                     ⢀⣀⡠⠤⠒⠒⠉⠁ ⢀⣀⣀⠤⠤⠒⠒⠊⠉⠉
        \\                                             ⢀⣀⡠⠤⠔⠒⠊⠉⠁⣀⣀⠤⠤⠒⠒⠊⠉⠁
        \\                            ⣀⣀⣀⣀⣀⡠⠤⠤⠤⢀⣀⡠⠤⠔⠒⠊⠉⠁⠉⠉⠉⠉⠉⠁
        \\           ⢀⣀⣀⣀⡠⠤⠤⠤⠤⠒⠒⠒⠒⠉⠉⠉⣀⣀⣀⣀⡠⠤⠔⠒⠊⠉⠁
        \\ 0ms ⣀⣀⣀⡠⠤⠤⠤⠤⠤⠔⠒⠒⠒⠒⠒⠒⠉⠉⠉⠉⠉⠉
        \\     older                                                                   now
    ,
        text,
    );
}

test "chart: all-zero series stays on the baseline" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "noop",
        .color = 0x98C379,
        .samples = &.{ 0, 0, 0, 0 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 32 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    // Both ticks are 0ms; every plot row above the bottom stays blank.
    const bottom = canvas.row(6);
    try std.testing.expectEqualStrings("0", bottom[0].text);
    try std.testing.expectEqualStrings("m", bottom[1].text);
    try std.testing.expectEqualStrings("s", bottom[2].text);
    try std.testing.expectEqualStrings(" ", bottom[3].text);
    try std.testing.expectEqualStrings("⣀", bottom[4].text);
    for (2..6) |y| {
        for (canvas.row(y)) |cell| {
            if (cell.width != 0) try std.testing.expectEqualStrings(" ", cell.text);
        }
    }
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ noop
        \\0ms
        \\
        \\
        \\
        \\
        \\0ms ⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀
        \\    older                            now
    ,
        text,
    );
}

test "chart: single point renders at the right edge" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "one",
        .color = 0xE5C07B,
        .samples = &.{42},
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 32 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    // Top-right braille dot (dot 4 = U+2808).
    const dot = canvas.cellAt(39, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("⠈", dot.text);
    try std.testing.expectEqual(@as(?u32, 0xE5C07B), dot.fg);
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ one
        \\42ms                                   ⠈
        \\
        \\
        \\
        \\
        \\ 0ms
        \\     older                           now
    ,
        text,
    );
}

test "chart: more than max_points keeps the recent window" {
    const allocator = std.testing.allocator;
    var samples: [20]u32 = undefined;
    for (&samples, 0..) |*v, i| v.* = @intCast(i);
    const series = [_]Series{.{
        .name = "recent",
        .color = 0xC678DD,
        .samples = &samples,
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 5 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    // y_max is 19 (all samples, including the dropped old ones). The five
    // recent samples 15..19 are all near the top, and the last one is at the
    // right edge.
    const top_right = canvas.cellAt(39, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(top_right.fg == 0xC678DD);
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ recent
        \\19ms            ⣀⣀⣀⣀⡠⠤⠤⠤⠤⠤⠤⠒⠒⠒⠒⠒⠒⠒⠒⠊⠉⠉⠉⠉
        \\     ⠒⠒⠒⠒⠊⠉⠉⠉⠉⠉⠉
        \\
        \\
        \\
        \\ 0ms
        \\     older                           now
    ,
        text,
    );
}

test "chart: 20x3 sparkline fallback snapshot" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "read_file",
        .color = 0xE06C75,
        .samples = &.{ 0, 10, 40, 80 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 20, .height = 3, .max_points = 32 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    // 0,10,40,80 with y_max=80 and 8 levels: ▁ ▂ ▅ █, right aligned.
    try expectSnapshot(
        \\─ read_file
        \\                ▁▂▅█
        \\older            now
    ,
        text,
    );
}

test "chart: CJK legend uses display width and continuation cells" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "读取文件",
        .color = 0x56B6C2,
        .samples = &.{ 0, 20, 60 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 32, .height = 6, .max_points = 16 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);

    const row = canvas.row(0);
    try std.testing.expectEqualStrings("─", row[0].text);
    try std.testing.expectEqualStrings(" ", row[1].text);
    try std.testing.expectEqualStrings("读", row[2].text);
    const legend = try rowText(allocator, &canvas, 0);
    defer allocator.free(legend);
    try std.testing.expectEqualStrings("─ 读取文件", legend);
    try std.testing.expectEqual(@as(u8, 2), row[2].width);
    try std.testing.expectEqualStrings("", row[3].text);
    try std.testing.expectEqual(@as(u8, 0), row[3].width);
    try std.testing.expectEqualStrings("件", row[8].text);

    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ 读取文件
        \\60ms                       ⣀⡠⠤⠒⠉
        \\                      ⣀⡠⠔⠒⠉
        \\              ⢀⣀⣀⡠⠤⠔⠊⠉
        \\ 0ms ⣀⡠⠤⠤⠔⠒⠒⠉⠉⠁
        \\     older                   now
    ,
        text,
    );
}

test "chart: long legend truncates at the cell boundary" {
    const allocator = std.testing.allocator;
    const long_name = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const series = [_]Series{.{
        .name = long_name,
        .color = 0xE06C75,
        .samples = &.{ 1, 2, 3 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 10 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);

    const row = canvas.row(0);
    var used: usize = 0;
    for (row) |cell| used += cell.width;
    try std.testing.expectEqual(@as(usize, 40), used);
    try std.testing.expectEqualStrings("a", row[2].text);
    try std.testing.expectEqualStrings("L", row[39].text); // name[37]
    const legend = try rowText(allocator, &canvas, 0);
    defer allocator.free(legend);
    try std.testing.expectEqualStrings("─ abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL", legend);

    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL
        \\3ms                             ⣀⣀⡠⠤⠔⠒⠊⠉
        \\                       ⢀⣀⡠⠤⠔⠒⠒⠉⠉
        \\             ⣀⣀⣀⠤⠤⠔⠒⠒⠉⠉⠁
        \\    ⣀⡠⠤⠤⠒⠒⠊⠉⠉
        \\
        \\0ms
        \\    older                            now
    ,
        text,
    );
}

test "chart: wide y label clips in the gutter without overflowing" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "read_file",
        .color = 0xE06C75,
        .samples = &.{ 0, 10, 40, 80 },
    }};
    var canvas = try render(allocator, &series, .{
        .width = 24,
        .height = 8,
        .max_points = 10,
        .y_max = std.math.maxInt(u32),
    });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    // The gutter is capped at 6 cells; "4294967295ms" keeps only its 5-cell
    // prefix ("42949") and one padding cell before the plot.
    const top_label = try rowText(allocator, &canvas, 1);
    defer allocator.free(top_label);
    try std.testing.expectEqualStrings("42949", top_label);
    const text = try dump(allocator, &canvas);
    defer allocator.free(text);
    try expectSnapshot(
        \\─ read_file
        \\42949
        \\
        \\
        \\
        \\
        \\  0ms ⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀
        \\      older          now
    ,
        text,
    );
}

test "chart: invalid sizes and series counts are typed errors" {
    const allocator = std.testing.allocator;
    const one = [_]Series{.{ .name = "x", .color = 1, .samples = &.{ 1, 2 } }};
    var nine: [9]Series = undefined;
    for (&nine) |*s| s.* = .{ .name = "x", .color = 1, .samples = &.{} };

    try std.testing.expectError(error.InvalidWidth, render(allocator, &one, .{ .width = 0, .height = 8, .max_points = 4 }));
    try std.testing.expectError(error.InvalidWidth, render(allocator, &one, .{ .width = max_width + 1, .height = 8, .max_points = 4 }));
    try std.testing.expectError(error.InvalidHeight, render(allocator, &one, .{ .width = 40, .height = 0, .max_points = 4 }));
    try std.testing.expectError(error.InvalidHeight, render(allocator, &one, .{ .width = 40, .height = max_height + 1, .max_points = 4 }));
    try std.testing.expectError(error.InvalidMaxPoints, render(allocator, &one, .{ .width = 40, .height = 8, .max_points = 0 }));
    try std.testing.expectError(error.InvalidMaxPoints, render(allocator, &one, .{ .width = 40, .height = 8, .max_points = max_points_limit + 1 }));
    try std.testing.expectError(error.TooManySeries, render(allocator, &nine, .{ .width = 40, .height = 8, .max_points = 4 }));
    try std.testing.expectError(error.ChartTooLarge, render(allocator, &one, .{ .width = max_width, .height = max_height, .max_points = 4 }));
    // Validation is also reachable directly (used by the future panel to
    // reject a layout before touching its arena).
    try std.testing.expectError(error.InvalidWidth, validate(&one, .{ .width = 0, .height = 8, .max_points = 4 }));
}

test "chart: average and format_ms" {
    try std.testing.expectEqual(@as(?u32, null), average(&.{}));
    try std.testing.expectEqual(@as(?u32, 10), average(&.{10}));
    try std.testing.expectEqual(@as(?u32, 15), average(&.{ 10, 20 }));
    try std.testing.expectEqual(@as(?u32, 2), average(&.{ 1, 2 }));
    try std.testing.expectEqual(@as(?u32, 0), average(&.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), average(&.{ std.math.maxInt(u32), std.math.maxInt(u32) }));
    try std.testing.expectEqual(@as(?u32, 2_147_483_648), average(&.{
        std.math.maxInt(u32), std.math.maxInt(u32), 0, 0,
    }));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0ms", try format_ms(&buf, 0));
    try std.testing.expectEqualStrings("80ms", try format_ms(&buf, 80));
    try std.testing.expectEqualStrings("4294967295ms", try format_ms(&buf, std.math.maxInt(u32)));
    try std.testing.expectError(error.NoSpaceLeft, format_ms(buf[0..3], 1234));
}

test "chart: scaling rounds, clamps and handles a zero range" {
    try std.testing.expectEqual(@as(u32, 0), scaleToLevel(0, 80, 7));
    try std.testing.expectEqual(@as(u32, 1), scaleToLevel(10, 80, 7));
    try std.testing.expectEqual(@as(u32, 4), scaleToLevel(40, 80, 7));
    try std.testing.expectEqual(@as(u32, 7), scaleToLevel(80, 80, 7));
    try std.testing.expectEqual(@as(u32, 7), scaleToLevel(100, 80, 7)); // clamp
    try std.testing.expectEqual(@as(u32, 0), scaleToLevel(50, 0, 7)); // zero range
    try std.testing.expectEqual(@as(u32, 0), scaleToLevel(50, 80, 0)); // no levels
    try std.testing.expectEqual(@as(u32, 1), scaleToLevel(1, 2, 1)); // half rounds up
    try std.testing.expectEqual(@as(u32, 0), scaleToLevel(1, 3, 1));
    try std.testing.expectEqual(@as(u32, 1), scaleToLevel(2, 3, 1));
    try std.testing.expectEqual(@as(u32, 12), scaleToLevel(40, 80, 23)); // 11.5 -> 12
}

test "chart: recent keeps the newest samples and maxSample is bounded" {
    const values = [_]u32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqualSlices(u32, &.{}, recent(&values, 0));
    try std.testing.expectEqualSlices(u32, &.{5}, recent(&values, 1));
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, recent(&values, 3));
    try std.testing.expectEqualSlices(u32, &values, recent(&values, 99));

    const series = [_]Series{
        .{ .name = "a", .color = 1, .samples = &.{ 0, 80, 20 } },
        .{ .name = "b", .color = 2, .samples = &.{ 40, 10 } },
    };
    try std.testing.expectEqual(@as(u32, 80), maxSample(&series));
    try std.testing.expectEqual(@as(u32, 80), effectiveYMax(&series, null));
    try std.testing.expectEqual(@as(u32, 40), effectiveYMax(&series, 40));
    try std.testing.expectEqual(@as(u32, 0), maxSample(&.{}));
}

test "chart: explicit y_max clamps values and labels the override" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "spike",
        .color = 0x123456,
        .samples = &.{ 0, 500 },
    }};
    var canvas = try render(allocator, &series, .{ .width = 40, .height = 8, .max_points = 4, .y_max = 50 });
    defer canvas.deinit(allocator);
    try expectCellInvariants(&canvas);
    // Top label reports the explicit range, not the 500ms sample.
    const top = canvas.row(1);
    try std.testing.expectEqualStrings("5", top[0].text);
    try std.testing.expectEqualStrings("0", top[1].text);
    try std.testing.expectEqualStrings("m", top[2].text);
    try std.testing.expectEqualStrings("s", top[3].text);
    // The rightmost cell is at the top of the plot (clamped).
    const dot = canvas.cellAt(39, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(dot.fg == 0x123456);
}

test "chart: empty series and no series render the honest empty chart" {
    const allocator = std.testing.allocator;
    const empty = [_]Series{.{ .name = "empty", .color = 7, .samples = &.{} }};
    var no_series = try render(allocator, &.{}, .{ .width = 40, .height = 8, .max_points = 8 });
    defer no_series.deinit(allocator);
    try expectCellInvariants(&no_series);
    const no_series_top = try rowText(allocator, &no_series, 0);
    defer allocator.free(no_series_top);
    try std.testing.expectEqualStrings("0ms", no_series_top);
    const no_series_bottom = try rowText(allocator, &no_series, 6);
    defer allocator.free(no_series_bottom);
    try std.testing.expectEqualStrings("0ms", no_series_bottom);
    // No legend when there is no series.
    for (no_series.cells) |cell| {
        try std.testing.expect(!std.mem.eql(u8, cell.text, "─"));
    }

    var one_empty = try render(allocator, &empty, .{ .width = 40, .height = 8, .max_points = 8 });
    defer one_empty.deinit(allocator);
    try expectCellInvariants(&one_empty);
    const empty_legend = try rowText(allocator, &one_empty, 0);
    defer allocator.free(empty_legend);
    try std.testing.expectEqualStrings("─ empty", empty_legend);
}

test "chart: row width and continuation invariants across layouts" {
    const allocator = std.testing.allocator;
    const ascii = [_]Series{.{ .name = "read_file", .color = 0xE06C75, .samples = &.{ 0, 10, 40, 80 } }};
    const cjk = [_]Series{.{ .name = "读取文件", .color = 0x56B6C2, .samples = &.{ 0, 30, 60 } }};
    const two = [_]Series{
        .{ .name = "a", .color = 1, .samples = &.{ 5, 20, 30, 60 } },
        .{ .name = "很长很长很长的工具名字", .color = 2, .samples = &.{ 1, 2, 3 } },
    };
    const empty = [_]Series{.{ .name = "", .color = 3, .samples = &.{} }};
    const widths = [_]u16{ 1, 2, 3, 7, 8, 15, 16, 20, 23, 24, 25, 40, 80, 120 };
    const heights = [_]u16{ 1, 2, 3, 4, 5, 8, 12 };

    for (widths) |width| {
        for (heights) |height| {
            for ([_][]const Series{ &ascii, &cjk, &two, &empty, &.{} }) |series| {
                for ([_]bool{ true, false }) |axis| {
                    var canvas = try render(allocator, series, .{
                        .width = width,
                        .height = height,
                        .max_points = 64,
                        .show_axis = axis,
                    });
                    defer canvas.deinit(allocator);
                    try expectCellInvariants(&canvas);
                }
            }
        }
    }
}

test "chart: axis/legend toggles and height-1 sparkline" {
    const allocator = std.testing.allocator;
    const series = [_]Series{.{
        .name = "read_file",
        .color = 0xE06C75,
        .samples = &.{ 0, 10, 40, 80 },
    }};

    // No legend and no axis: the plot owns all eight rows, and no tick or
    // x-label text is drawn.
    var bare = try render(allocator, &series, .{
        .width = 40,
        .height = 8,
        .max_points = 32,
        .show_legend = false,
        .show_axis = false,
    });
    defer bare.deinit(allocator);
    try expectCellInvariants(&bare);
    try std.testing.expect(bare.row(0)[39].fg == 0xE06C75);
    for (bare.cells) |cell| {
        try std.testing.expect(!std.mem.eql(u8, cell.text, "─"));
        try std.testing.expect(!std.mem.eql(u8, cell.text, "o"));
    }

    // Height 1 is the extreme fallback: one sparkline row, no legend/x row.
    var thin = try render(allocator, &series, .{
        .width = 12,
        .height = 1,
        .max_points = 32,
        .show_legend = true,
        .show_axis = true,
    });
    defer thin.deinit(allocator);
    try expectCellInvariants(&thin);
    const text = try dump(allocator, &thin);
    defer allocator.free(text);
    try expectSnapshot("        ▁▂▅█", text);
}
