//! picker — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const util = @import("../util/root.zig");
const syntax = @import("../syntax.zig");
const lsp_types = @import("../lsp/types.zig");
const theme = @import("../theme.zig");
const keymap_list = @import("../editor/keymap_list.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");

pub const GrepResult = struct { path: []u8, line: u32, text: []u8 };

// ---- fuzzy picker (<leader>sf) ----

pub fn openPicker(self: *App) !void {
    if (self.picker_files.items.len == 0) {
        // cwd() has fd == AT.FDCWD (-100), which the dir iterator can't
        // getdents on — open a real directory handle first.
        var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
        defer root.close(self.io);
        try self.walkDir(root, "");
    }
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    try self.pickerRefilter();
    self.picker_active = true;
}

pub fn walkDir(self: *App, dir: std.Io.Dir, prefix: []const u8) !void {
    try self.walkInto(dir, prefix, &self.picker_files);
}

pub fn walkInto(self: *App, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]u8)) !void {
    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
        const path = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, name });
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(self.io, name, .{ .iterate = true });
                defer sub.close(self.io);
                const sub_prefix = try std.fmt.allocPrint(self.alloc, "{s}/", .{path});
                try self.walkInto(sub, sub_prefix, out);
                self.alloc.free(sub_prefix);
                self.alloc.free(path);
            },
            .file => try out.append(self.alloc, path),
            else => self.alloc.free(path),
        }
    }
}

pub fn openBufferPicker(self: *App) !void {
    self.picker_mode = .buffers;
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    try self.pickerRefilter();
    self.picker_active = true;
}

pub fn openRecentPicker(self: *App) !void {
    self.picker_mode = .recent;
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    try self.pickerRefilter();
    self.picker_active = true;
}

pub fn openKeymapPicker(self: *App) !void {
    self.picker_mode = .keymaps;
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    try self.pickerRefilter();
    self.picker_active = true;
}

/// <leader>sp — theme picker with LIVE preview: remember the current
/// theme (Esc restores it), then every selection change applies the
/// highlighted theme to the whole UI until Enter confirms or Esc cancels.
pub fn openThemePicker(self: *App) !void {
    self.theme_saved = self.theme;
    self.picker_mode = .themes;
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    try self.pickerRefilter();
    self.picker_active = true;
}

pub fn bufferName(self: *const App, i: usize) []const u8 {
    const buf = &self.buffers.items[i];
    return if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
}

pub fn openGrepPicker(self: *App) !void {
    self.picker_mode = .grep;
    self.picker_input.clearRetainingCapacity();
    self.picker_sel = 0;
    self.picker_top = 0;
    // fresh session: drop stale results (and their owned strings) from a
    // previous grep — an empty query must show "no matches", not the
    // last search's leftovers
    for (self.grep_results.items) |g| {
        self.alloc.free(g.path);
        self.alloc.free(g.text);
    }
    self.grep_results.clearRetainingCapacity();
    self.picker_active = true;
    self.refreshGrepPreview();
}

/// Run rg for the current query and store results (path:line:text).
pub fn runGrep(self: *App) !void {
    for (self.grep_results.items) |g| {
        self.alloc.free(g.path);
        self.alloc.free(g.text);
    }
    self.grep_results.clearRetainingCapacity();

    const query = self.picker_input.items;
    if (query.len == 0) return;

    var child = std.process.spawn(self.io, .{
        // -F: the query is a literal string, not a regex; "--": a query
        // starting with '-' must not be parsed as an rg flag
        .argv = &.{ "rg", "--no-heading", "-n", "-F", "--", query },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return;
    // Child.kill cleans up and nulls child.id, so wait() after a kill
    // would trip its `child.id != null` assert — track that.
    var child_killed = false;
    defer {
        if (!child_killed) _ = child.wait(self.io) catch {};
    }

    // Read ALL of rg's output until EOF — stopping early deadlocks: the
    // kernel pipe buffer fills, rg blocks writing, and wait() never
    // returns. Cap at ~1MB for sanity.
    var out = std.ArrayList(u8).empty;
    defer out.deinit(self.alloc);
    var tmp: [4096]u8 = undefined;
    while (out.items.len < 1024 * 1024) {
        const n = child.stdout.?.readStreaming(self.io, &.{&tmp}) catch break;
        if (n == 0) break;
        try out.appendSlice(self.alloc, tmp[0..n]);
    }
    if (out.items.len >= 1024 * 1024) {
        _ = child.kill(self.io);
        child_killed = true;
    }
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // path:line:text
        const c1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ':') orelse continue;
        const path = line[0..c1];
        const line_no = std.fmt.parseUnsigned(u32, line[c1 + 1 .. c2], 10) catch continue;
        const text = line[c2 + 1 ..];
        const path_c = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(path_c);
        const text_c = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_c);
        try self.grep_results.append(self.alloc, .{ .path = path_c, .line = line_no, .text = text_c });
        if (self.grep_results.items.len >= 50) break;
    }
    if (self.picker_sel >= self.grep_results.items.len) self.picker_sel = 0;
    self.refreshGrepPreview();
}

/// Drop the grep preview's file content / highlighter / path. Called on
/// close, on empty results and whenever the selected path changes.
pub fn freeGrepPreview(self: *App) void {
    if (self.preview_hl) |*h| h.deinit();
    self.preview_hl = null;
    if (self.preview_text) |t| self.alloc.free(t);
    self.preview_text = null;
    if (self.preview_path) |p| self.alloc.free(p);
    self.preview_path = null;
}

/// (Re)build the split preview for the SELECTED grep result. Best-effort:
/// a failed read or a file over syntax.SIZE_LIMIT leaves preview_text
/// null and the renderer shows "preview unavailable".
pub fn refreshGrepPreview(self: *App) void {
    if (self.picker_mode != .grep or !self.picker_active) return;
    if (self.grep_results.items.len == 0) {
        self.freeGrepPreview();
        return;
    }
    self.loadPreview(self.grep_results.items[self.picker_sel].path);
}

/// (Re)build the split-preview file + highlighter for the SELECTED
/// nav-list location (gr/gI list row, or an outline row — those pack
/// "label\x00line" into uri and target the current buffer).
pub fn refreshNavPreview(self: *App) void {
    if (!self.nav_list_active or self.nav_locations.items.len == 0) {
        self.freeGrepPreview();
        return;
    }
    const loc = self.nav_locations.items[@min(self.nav_list_sel, self.nav_locations.items.len - 1)];
    if (std.mem.indexOfScalar(u8, loc.uri, 0) != null) {
        if (self.cur().path) |p| self.loadPreview(p) else self.freeGrepPreview();
        return;
    }
    const path = lsp_types.fileUriToPath(self.alloc, loc.uri) catch {
        self.freeGrepPreview();
        return;
    };
    defer self.alloc.free(path);
    self.loadPreview(path);
}

/// Load (or keep, while the path is unchanged) the shared preview file +
/// highlighter used by the grep panel and the nav list. The unchanged-path
/// early-out is what keeps the panels from re-reading files / re-parsing
/// on every frame.
pub fn loadPreview(self: *App, path: []const u8) void {
    if (self.preview_path) |pp| {
        if (std.mem.eql(u8, pp, path)) return;
    }
    self.freeGrepPreview();
    self.preview_path = self.alloc.dupe(u8, path) catch return;
    const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(syntax.SIZE_LIMIT)) catch return;
    self.preview_text = text;
    const ft = autil.filetypeOf(path);
    if (syntax.languageFor(ft)) |lang| {
        var hl = syntax.Highlighter.init(self.alloc, lang) catch return;
        hl.reparse(text) catch {
            hl.deinit();
            return;
        };
        self.preview_hl = hl;
    }
}

/// Render one preview-column row of a split panel — the grep picker's
/// right column and the nav list's (gr/gI/outline) right column both use
/// it. k = 0 is the "basename:line" header (of `path` / `line`, 1-based);
/// k > 0 a syntax-highlighted content line from the previewed file, a
/// ±(content_rows/2) window around the selected line. Every segment is
/// arena-allocated so the text outlives vx.render(). The file itself is
/// read / reparsed only in loadPreview — here we just run the (already
/// built) highlighter over the visible byte range.
pub fn renderGrepPreviewRow(
    self: *App,
    segs: *std.ArrayList(vaxis.Segment),
    a: std.mem.Allocator,
    win: vaxis.Window,
    k: usize,
    list_rows: usize,
    preview_w: u32,
    path: []const u8,
    line: u32,
) !void {
    const float_bg: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float } };
    const pw: usize = @intCast(preview_w);
    if (k == 0) {
        // header: basename (fg) + ":line" (fg_dim), then padding; widths
        // are cells (a CJK basename is 2 cells/char, 3-4 bytes)
        const base = std.fs.path.basename(path);
        const line_str = try std.fmt.allocPrint(a, ":{d}", .{line});
        const f1 = autil.cellFitPrefix(win, base, pw);
        try segs.append(a, .{ .text = f1.slice, .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float } } });
        const f2 = autil.cellFitPrefix(win, line_str, pw -| f1.cells);
        if (f2.slice.len > 0) try segs.append(a, .{ .text = f2.slice, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } } });
        if (f1.cells + f2.cells < pw) {
            const pad = try a.alloc(u8, pw - f1.cells - f2.cells);
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = float_bg });
        }
        return;
    }
    const text = self.preview_text orelse {
        // unavailable (>100KB / read failed): dim hint on the first
        // content row, blank rows below
        if (k == 1) {
            const hint = "preview unavailable";
            const ids = [_]u8{0} ** 64;
            try autil.appendRowSegs(segs, a, win, hint, &ids, &[_]vaxis.Style{.{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = float_bg.bg }}, preview_w, float_bg);
        } else {
            try autil.appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
        }
        return;
    };
    const sel_line: usize = line -| 1; // callers pass 1-based lines
    const line_count = std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0);
    if (sel_line >= line_count) {
        try autil.appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
        return;
    }
    const content_rows = list_rows - 1;
    const ci = k - 1;
    const win_start = @min(@max(sel_line -| (content_rows / 2), 0), line_count -| content_rows);
    const file_line = win_start + ci;
    if (file_line >= line_count) {
        try autil.appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
        return;
    }
    // gutter: relative offset from the selected line ("-4".." 0".."+4");
    // arena-allocated — Segment.text must outlive vx.render()
    const off: i32 = @as(i32, @intCast(file_line)) - @as(i32, @intCast(sel_line));
    const gutter = if (off < 0)
        try std.fmt.allocPrint(a, "-{d}", .{@as(u32, @intCast(-off))})
    else if (off > 0)
        try std.fmt.allocPrint(a, "+{d}", .{@as(u32, @intCast(off))})
    else
        try std.fmt.allocPrint(a, " 0", .{});
    const row_s = autil.lineStartByte(text, file_line);
    const row_e = autil.lineEndByte(text, file_line);
    // content width: gutter (2) + space (1) leaves the rest of the
    // column. Truncate in CELLS on grapheme boundaries — a byte count
    // overflows the column on CJK (2 cells/char) and pushes the row's
    // padding/border out of place.
    const fit = autil.cellFitPrefix(win, text[row_s..row_e], pw -| 3);
    const n = fit.slice.len;
    // syntax spans for THIS line's byte range (O(visible) query; the
    // highlighter itself is only reparsed when the selection's path
    // changes, in loadPreview)
    var spans = std.ArrayList(syntax.Span).empty;
    if (self.preview_hl) |*hl| {
        var raw = std.ArrayList(syntax.Span).empty;
        hl.spansInRange(@intCast(row_s), @intCast(row_e), a, &raw) catch {};
        // merge overlaps like visibleSpansFor (later spans win)
        for (raw.items) |sp| {
            while (spans.items.len > 0) {
                var last = &spans.items[spans.items.len - 1];
                if (sp.start >= last.end) break;
                if (sp.start <= last.start) {
                    _ = spans.pop();
                    continue;
                }
                last.end = sp.start;
                break;
            }
            try spans.append(a, sp);
        }
    }
    // per-byte style ids: 0 = base fg, 1+ = syntax palette (Style ordinal
    // + 1), so spans map straight onto a per-frame palette
    var style_palette: [autil.syntax_style_count]vaxis.Style = undefined;
    for (0..style_palette.len) |i| style_palette[i] = autil.syntaxStyle(@enumFromInt(i), self.theme);
    const selected_line = (file_line == sel_line);
    const base_bg: vaxis.Style = if (selected_line)
        .{ .bg = .{ .rgb = self.theme.bg_sel } }
    else
        float_bg;
    const gutter_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg.bg };
    // per-byte ids for the visible prefix; arena-sized (a cell-capped
    // prefix can still be many bytes — up to ~4 per cell for CJK)
    const ids_buf = try a.alloc(u8, n);
    @memset(ids_buf, 0);
    for (spans.items) |sp| {
        if (sp.end <= row_s or sp.start >= row_e) continue;
        const cs = @max(sp.start, @as(u32, @intCast(row_s)));
        const ce = @min(sp.end, @as(u32, @intCast(row_e)));
        const sid: u8 = @intCast(@intFromEnum(sp.style) + 1);
        for (cs..ce) |bi| {
            if (bi - row_s >= n) break;
            ids_buf[bi - row_s] = sid;
        }
    }
    try segs.append(a, .{ .text = gutter, .style = gutter_style });
    try segs.append(a, .{ .text = " ", .style = gutter_style });
    const base_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = base_bg.bg };
    var i: usize = 0;
    while (i < n) {
        const sid = ids_buf[i];
        var j = i + 1;
        while (j < n and ids_buf[j] == sid) : (j += 1) {}
        const st: vaxis.Style = if (sid == 0)
            base_style
        else blk: {
            var s2 = style_palette[sid - 1];
            s2.bg = base_bg.bg;
            break :blk s2;
        };
        try segs.append(a, .{ .text = text[row_s + i .. row_s + j], .style = st });
        i = j;
    }
    const used = autil.cellWidth(win, gutter) + 1 + fit.cells;
    if (used < pw) {
        const pad = try a.alloc(u8, pw - used);
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = base_bg });
    }
}

pub fn handlePickerKey(self: *App, key: vaxis.Key) !void {
    switch (key.codepoint) {
        vaxis.Key.escape => {
            // theme picker: Esc cancels the live preview — restore the
            // theme that was active when the picker opened
            if (self.picker_mode == .themes) {
                if (self.theme_saved) |t| self.theme = t;
            }
            self.closePicker();
        },
        vaxis.Key.enter => {
            // Confirming jumps into the target file: leave the file-tree
            // navigation mode so j/k/↑↓ control the buffer afterwards
            // (vim: picker confirm drops focus back to the buffer).
            self.filetree_active = false;
            self.focus = .buffer;
            if (self.picker_mode == .keymaps) {
                // keymap search has no jump target — Enter just closes
                self.closePicker();
                return;
            }
            if (self.picker_mode == .grep) {
                if (self.grep_results.items.len > 0) {
                    const r = self.grep_results.items[self.picker_sel];
                    self.closePicker();
                    try self.openFile(r.path);
                    const line = @min(r.line - 1, self.cur().pt.lineCount() - 1);
                    self.curCursor().* = self.cur().pt.lineStart(line);
                    self.curViewTop().* = line;
                }
                return;
            }
            if (self.picker_mode == .recent) {
                if (self.picker_matches.items.len > 0) {
                    const ri = self.picker_matches.items[self.picker_sel];
                    const path = self.recent_files.items[ri];
                    self.closePicker();
                    try self.openFile(path);
                }
                return;
            }
            if (self.picker_mode == .buffers) {
                if (self.picker_matches.items.len > 0) {
                    const bi = self.picker_matches.items[self.picker_sel];
                    self.closePicker();
                    self.switchTo(bi);
                }
                return;
            }
            if (self.picker_mode == .themes) {
                // Enter confirms the previewed theme: keep it, report it
                // and close (the preview already applied it on move).
                if (self.picker_matches.items.len > 0) {
                    const ti = self.picker_matches.items[self.picker_sel];
                    self.theme = theme.themes[ti];
                    try self.setMsg(try std.fmt.allocPrint(self.alloc, "theme: {s}", .{theme.themes[ti].name}));
                }
                self.closePicker();
                return;
            }
            if (self.picker_matches.items.len > 0) {
                const f = self.picker_files.items[self.picker_matches.items[self.picker_sel]];
                self.closePicker();
                try self.openFile(f);
            }
        },
        vaxis.Key.backspace => {
            if (self.picker_input.items.len > 0) {
                _ = self.picker_input.pop();
                self.picker_sel = 0;
                if (self.picker_mode == .grep) {
                    try self.runGrep();
                } else {
                    try self.pickerRefilter();
                }
                if (self.picker_mode == .themes) self.applyThemePreview();
            }
        },
        vaxis.Key.down => {
            const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
            if (self.picker_sel + 1 < n) {
                self.picker_sel += 1;
                if (self.picker_mode == .grep) self.refreshGrepPreview();
                if (self.picker_mode == .themes) self.applyThemePreview();
            }
        },
        vaxis.Key.up => {
            if (self.picker_sel > 0) {
                self.picker_sel -= 1;
                if (self.picker_mode == .grep) self.refreshGrepPreview();
                if (self.picker_mode == .themes) self.applyThemePreview();
            }
        },
        else => {
            if (key.codepoint == 'n' and key.mods.ctrl) {
                const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
                if (self.picker_sel + 1 < n) {
                    self.picker_sel += 1;
                    if (self.picker_mode == .grep) self.refreshGrepPreview();
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            } else if (key.codepoint == 'p' and key.mods.ctrl) {
                if (self.picker_sel > 0) {
                    self.picker_sel -= 1;
                    if (self.picker_mode == .grep) self.refreshGrepPreview();
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            } else if (key.text) |t| {
                try self.picker_input.appendSlice(self.alloc, t);
                self.picker_sel = 0;
                if (self.picker_mode == .grep) {
                    try self.runGrep();
                } else {
                    try self.pickerRefilter();
                }
                if (self.picker_mode == .themes) self.applyThemePreview();
            }
        },
    }
}

/// Theme picker live preview: apply the theme under the current
/// selection to the whole UI (the next render repaints with it).
pub fn applyThemePreview(self: *App) void {
    if (self.picker_mode != .themes or !self.picker_active) return;
    if (self.picker_matches.items.len == 0) return;
    const ti = self.picker_matches.items[self.picker_sel];
    self.theme = theme.themes[ti];
}

pub fn pickerRefilter(self: *App) !void {
    self.picker_matches.clearRetainingCapacity();
    if (self.picker_mode == .keymaps) {
        // match against "keys desc" via fzy; matches index into
        // keymap_list.entries (empty query hits every entry)
        const needle = self.picker_input.items;
        var ei: usize = 0;
        while (ei < keymap_list.entries.len) : (ei += 1) {
            if (try keymap_list.matches(self.alloc, keymap_list.entries[ei], needle)) {
                try self.picker_matches.append(self.alloc, ei);
                if (self.picker_matches.items.len >= 20) break;
            }
        }
        if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
        return;
    }
    if (self.picker_mode == .recent) {
        // match against recent-file paths; matches index into recent_files
        const needle = self.picker_input.items;
        var ri: usize = 0;
        while (ri < self.recent_files.items.len) : (ri += 1) {
            const path = self.recent_files.items[ri];
            if (needle.len == 0) {
                try self.picker_matches.append(self.alloc, ri);
                continue;
            }
            const m = try util.fzy.match(self.alloc, path, needle) orelse continue;
            defer self.alloc.free(m.positions);
            try self.picker_matches.append(self.alloc, ri);
            if (self.picker_matches.items.len >= 20) break;
        }
        if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
        return;
    }
    if (self.picker_mode == .buffers) {
        // match against buffer names; matches index into buffers
        const needle = self.picker_input.items;
        var bi: usize = 0;
        while (bi < self.buffers.items.len) : (bi += 1) {
            const name = self.bufferName(bi);
            if (needle.len == 0) {
                try self.picker_matches.append(self.alloc, bi);
                continue;
            }
            const m = try util.fzy.match(self.alloc, name, needle) orelse continue;
            defer self.alloc.free(m.positions);
            try self.picker_matches.append(self.alloc, bi);
            if (self.picker_matches.items.len >= 20) break;
        }
        if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
        return;
    }
    if (self.picker_mode == .themes) {
        // match against theme names; matches index into theme.themes
        // (empty query hits every theme)
        const needle = self.picker_input.items;
        var ti: usize = 0;
        while (ti < theme.themes.len) : (ti += 1) {
            const tname = theme.themes[ti].name;
            if (needle.len == 0) {
                try self.picker_matches.append(self.alloc, ti);
                continue;
            }
            const m = try util.fzy.match(self.alloc, tname, needle) orelse continue;
            defer self.alloc.free(m.positions);
            try self.picker_matches.append(self.alloc, ti);
            if (self.picker_matches.items.len >= 20) break;
        }
        if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
        return;
    }
    const needle = self.picker_input.items;
    if (needle.len == 0) {
        const n = @min(self.picker_files.items.len, 20);
        var i: usize = 0;
        while (i < n) : (i += 1) try self.picker_matches.append(self.alloc, i);
        return;
    }
    // top-20 by fzy score (small insertion-sort)
    var top: [20]struct { idx: usize, score: f64 } = undefined;
    var ntop: usize = 0;
    for (self.picker_files.items, 0..) |f, i| {
        const m = try util.fzy.match(self.alloc, f, needle) orelse continue;
        defer self.alloc.free(m.positions);
        var k = ntop;
        while (k > 0 and top[k - 1].score < m.score) : (k -= 1) {
            if (k < 20) top[k] = top[k - 1];
        }
        if (ntop < 20) ntop += 1;
        if (k < 20) top[k] = .{ .idx = i, .score = m.score };
    }
    var j: usize = 0;
    while (j < ntop) : (j += 1) try self.picker_matches.append(self.alloc, top[j].idx);
    if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
}

pub fn closePicker(self: *App) void {
    self.picker_active = false;
    self.picker_sel = 0;
    self.picker_mode = .files;
    self.freeGrepPreview();
}
