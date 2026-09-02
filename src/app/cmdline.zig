//! cmdline — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const editor = @import("../editor/root.zig");
const theme = @import("../theme.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");

// ---- command line (':') ----

pub fn handleCommandKey(self: *App, key: vaxis.Key) !void {
    // cancel
    if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
        self.state.mode = .normal;
        // Esc cancelling ':' from visual mode must drop the anchor too
        // (it was kept so :'<,'>s could resolve the range on Enter).
        self.visual_anchor = null;
        self.pending_rename = false;
        self.cmdline_kind = .ex;
        self.cmdline.clearRetainingCapacity();
        self.cmd_hist_idx = null;
        self.cmd_complete_idx = 0;
        self.clearCmdCompleteNames();
        return;
    }
    switch (key.codepoint) {
        vaxis.Key.enter => {
            const from_visual = self.visual_anchor != null;
            if (self.pending_rename) {
                // <leader>rn collected the new name — send the rename
                self.state.mode = .normal;
                self.cmd_hist_idx = null;
                try self.execRename();
                self.cmdline.clearRetainingCapacity();
                return;
            }
            const line = self.cmdline.items;
            if (self.cmdline_kind != .ex) {
                // '/' / '?' search: Enter jumps to the first match after
                // (before) the cursor, wrapping; remembers the query for
                // n/N. The text borrows the cmdline buffer — execSearch
                // dupes what it keeps.
                const bwd = self.cmdline_kind == .search_bwd;
                self.state.mode = .normal;
                self.cmdline_kind = .ex;
                self.cmd_hist_idx = null;
                self.cmd_complete_idx = 0;
                self.clearCmdCompleteNames();
                if (line.len > 0) try self.pushHistory(line);
                try self.execSearch(line, bwd);
                self.cmdline.clearRetainingCapacity();
                return;
            }
            const cmd = editor.ex_command.parse(line);
            if (cmd != .empty) try self.pushHistory(line);
            self.state.mode = .normal;
            self.cmd_hist_idx = null;
            self.cmd_complete_idx = 0;
            self.clearCmdCompleteNames();
            // execCommand must run BEFORE clearing: Command slices borrow
            // the cmdline buffer (pattern/replacement/edit paths)
            try self.execCommand(cmd);
            if (from_visual) self.exitVisual();
            self.cmdline.clearRetainingCapacity();
        },
        vaxis.Key.backspace => {
            if (self.cmdline.items.len > 0) _ = self.cmdline.pop();
        },
        vaxis.Key.up => {
            self.cmd_hist_idx = if (self.cmd_hist_idx) |i|
                if (i > 0) i - 1 else i
            else if (self.cmd_history.items.len > 0)
                self.cmd_history.items.len - 1
            else
                null;
            try self.loadHistory();
        },
        vaxis.Key.down => {
            self.cmd_hist_idx = if (self.cmd_hist_idx) |i|
                if (i + 1 < self.cmd_history.items.len) i + 1 else null
            else
                null;
            try self.loadHistory();
        },
        else => {},
    }
    // Tab: complete the command name (":w" → ":write") or, after
    // ":e " / ":edit ", the file path.
    if (key.codepoint == vaxis.Key.tab) {
        const line = self.cmdline.items;
        const is_path_ctx = (line.len >= 2 and (std.mem.eql(u8, line[0..2], "e ") or
            (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit "))));
        if (is_path_ctx) {
            try self.completeCommandPath();
        } else {
            try self.completeCommandName();
        }
        return;
    }

    // Ctrl-w: delete the word before the cursor (M0: back to last space)
    if (key.codepoint == 'w' and key.mods.ctrl) {
        var i = self.cmdline.items.len;
        while (i > 0 and self.cmdline.items[i - 1] != ' ') : (i -= 1) {}
        self.cmdline.shrinkRetainingCapacity(i);
        return;
    }
    if (key.text) |text| {
        try self.cmdline.appendSlice(self.alloc, text);
    }
}

/// Tab in command mode: complete the command NAME (":w" → ":write",
/// ":b" → cycles ":bnext/:bprev/:buffers/:bdelete", …). The prefix is
/// the token before the first space; repeated Tabs cycle through the
/// ORIGINAL match list (stored, since the line becomes a full command
/// name after the first Tab), advancing the completion cursor.
pub fn completeCommandName(self: *App) !void {
    const line = self.cmdline.items;
    // the command token is up to the first space (or the whole line)
    var split: usize = 0;
    while (split < line.len and line[split] != ' ') : (split += 1) {}
    const prefix = line[0..split];
    if (prefix.len == 0) return;

    // first Tab: compute the match list for the typed prefix; later Tabs
    // reuse the stored list so cycling keeps working after completion
    if (self.cmd_complete_names.items.len == 0) {
        // canonical command names, matching ex_command.zig's parser
        const commands = [_][]const u8{
            "write",   "quit",       "quitall", "wq",    "edit",
            "vsplit",  "split",      "bnext",   "bprev", "buffers",
            "bdelete", "nohlsearch", "set",     "theme", "colorscheme",
            "noh",
        };
        for (commands) |c| {
            if (std.mem.startsWith(u8, c, prefix)) {
                const copy = try self.alloc.dupe(u8, c);
                errdefer self.alloc.free(copy);
                try self.cmd_complete_names.append(self.alloc, copy);
            }
        }
        if (self.cmd_complete_names.items.len == 0) return;
        self.cmd_complete_idx = 0;
    }
    const matches = self.cmd_complete_names.items;
    const chosen = matches[self.cmd_complete_idx % matches.len];
    self.cmd_complete_idx += 1;

    // replace the command token with the full name
    self.cmdline.shrinkRetainingCapacity(0);
    try self.cmdline.appendSlice(self.alloc, chosen);
    // keep any existing argument (e.g. ":set " arg)
    if (split < line.len) {
        try self.cmdline.appendSlice(self.alloc, line[split..]);
    }
}

/// Tab in command mode: complete the path prefix after ":e ".
/// Cycles through matches on repeated Tab.
pub fn completeCommandPath(self: *App) !void {
    const line = self.cmdline.items;
    // find the token after "e " / "edit " (the leading ':' isn't stored)
    var skip: usize = 0;
    if (line.len >= 2 and std.mem.eql(u8, line[0..2], "e ")) {
        skip = 2;
    } else if (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit ")) {
        skip = 5;
    } else return;
    const prefix = line[skip..];

    var matches = std.ArrayList([]const u8).empty;
    defer {
        for (matches.items) |m| self.alloc.free(m);
        matches.deinit(self.alloc);
    }
    var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
    defer root.close(self.io);
    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |f| self.alloc.free(f);
        files.deinit(self.alloc);
    }
    try self.walkInto(root, "", &files);
    for (files.items) |f| {
        if (std.mem.startsWith(u8, f, prefix)) {
            const c = try self.alloc.dupe(u8, f);
            try matches.append(self.alloc, c);
        }
    }
    if (matches.items.len == 0) return;

    // cycle: self.cmd_complete_idx is the completion cursor
    // cycle through the matches: the FIRST Tab picks the first match,
    // further Tabs advance (the cursor is reset on command-line entry)
    const chosen = matches.items[self.cmd_complete_idx % matches.items.len];
    self.cmd_complete_idx += 1;

    // rebuild "e <chosen>" preserving the user's command form (e/edit)
    self.clearCmdCompleteNames();
    const cmd = if (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit ")) "edit" else "e";
    self.cmdline.clearRetainingCapacity();
    try self.cmdline.appendSlice(self.alloc, cmd);
    try self.cmdline.appendSlice(self.alloc, " ");
    try self.cmdline.appendSlice(self.alloc, chosen);
}

/// Drop the stored command-name completion matches (owned strings).
pub fn clearCmdCompleteNames(self: *App) void {
    for (self.cmd_complete_names.items) |n| self.alloc.free(n);
    self.cmd_complete_names.clearRetainingCapacity();
}

pub fn pushHistory(self: *App, line: []const u8) !void {
    if (self.cmd_history.items.len > 0 and
        std.mem.eql(u8, self.cmd_history.items[self.cmd_history.items.len - 1], line))
        return;
    const copy = try self.alloc.dupe(u8, line);
    errdefer self.alloc.free(copy);
    try self.cmd_history.append(self.alloc, copy);
    while (self.cmd_history.items.len > 100) {
        self.alloc.free(self.cmd_history.orderedRemove(0));
    }
}

pub fn loadHistory(self: *App) !void {
    self.cmdline.clearRetainingCapacity();
    if (self.cmd_hist_idx) |i| {
        try self.cmdline.appendSlice(self.alloc, self.cmd_history.items[i]);
    }
}

pub fn execCommand(self: *App, cmd: editor.ex_command.Command) !void {
    switch (cmd) {
        .empty => {},
        .write => _ = try self.writeBuffer(),
        .quit => {
            // vim E37: refuse to quit when the current buffer has
            // unsaved changes — data loss is worse than a message.
            if (self.cur().dirty) {
                try self.setMsg(try self.alloc.dupe(u8, "E37: No write since last change (add ! to override)"));
                return;
            }
            self.closeWindow(); // :q closes the focused window (or its buffer when it is the last window)
        },
        .quit_force => self.closeWindow(),
        .quit_all => self.quit = true,
        .vsplit => try self.splitWindow(.vertical),
        .split => try self.splitWindow(.horizontal),
        .write_quit => {
            // only quit when the write actually succeeded
            if (try self.writeBuffer()) self.quit = true;
        },
        .edit => |path| try self.openFile(path),
        .buffer_next => try self.switchBuffer(1),
        .buffer_prev => try self.switchBuffer(-1),
        .buffer_delete => self.closeCurrentBuffer(),
        .buffer_list => try self.listBuffers(),
        .noh => try self.setMsg(try self.alloc.dupe(u8, "")),
        .goto_line => |ln| {
            // :<number> — vim: 1-based, clamped to the last line (:0
            // and :1 both land on the first line)
            const target = @min(ln -| 1, self.cur().pt.lineCount() - 1);
            self.curCursor().* = self.cur().pt.lineStart(target);
            self.clearHover();
        },
        .set => |opt| try self.setMsg(try std.fmt.allocPrint(self.alloc, "set {s} (M0: accepted, no-op)", .{opt})),
        .theme => |name| try self.execTheme(name),
        .substitute => |sub| try self.execSubstitute(sub),
        .unknown => try self.setMsg(try self.alloc.dupe(u8, "E492: Not an editor command")),
    }
}

/// :theme [name] — switch the color theme. With no argument, list the
/// available themes (Tab in the command line cycles suggestions).
pub fn execTheme(self: *App, name: []const u8) !void {
    if (name.len == 0) {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "themes: ");
        for (theme.themes, 0..) |t, i| {
            if (i > 0) try out.appendSlice(self.alloc, ", ");
            try out.appendSlice(self.alloc, t.name);
        }
        try self.setMsg(try out.toOwnedSlice(self.alloc));
        return;
    }
    const t = theme.byName(name) orelse {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "unknown theme: {s} (see :theme)", .{name}));
        return;
    };
    self.theme = t;
    try self.setMsg(try std.fmt.allocPrint(self.alloc, "theme: {s}", .{t.name}));
}

/// :s/pat/rep[/g] — literal substitution on the current line, the whole
/// file (:%), or the visual selection (:'<,'>, M1: no regex). The
/// replacement lands in one undo group.
pub fn execSubstitute(self: *App, sub: anytype) !void {
    var start_line: u32 = undefined;
    var end_line: u32 = undefined;
    if (sub.visual) {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.curCursor().*);
        const e = @max(anchor, self.curCursor().*);
        start_line = self.cur().pt.lineOf(s);
        end_line = self.cur().pt.lineOf(e);
    } else if (sub.whole_file) {
        start_line = 0;
        end_line = self.cur().pt.lineCount() - 1;
    } else {
        start_line = self.cur().pt.lineOf(self.curCursor().*);
        end_line = start_line;
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(self.alloc);
    // The parser keeps an escaped separator `\/` verbatim; restore it so
    // literal matching sees the real slash (ex_command.unescapeSubSep).
    const pat = try editor.ex_command.unescapeSubSep(self.alloc, sub.pattern);
    defer self.alloc.free(pat);
    const rep = try editor.ex_command.unescapeSubSep(self.alloc, sub.replacement);
    defer self.alloc.free(rep);
    var changed: bool = false;
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        const ll = self.cur().pt.lineLen(line);
        const ls = self.cur().pt.lineStart(line);
        const buf = try self.alloc.alloc(u8, ll);
        defer self.alloc.free(buf);
        self.cur().pt.copyRange(ls, buf);

        const n = autil.replaceLiteral(&out, self.alloc, buf, pat, rep, sub.global);
        if (n > 0) changed = true;
        if (line < self.cur().pt.lineCount() - 1) try out.append(self.alloc, '\n');
    }

    if (!changed) {
        try self.setMsg(try self.alloc.dupe(u8, "E486: Pattern not found"));
        return;
    }
    const start = self.cur().pt.lineStart(start_line);
    var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
    if (end_line + 1 < self.cur().pt.lineCount()) end += 1;
    try self.applyEdit(start, end, out.items);
}

/// :ls — list buffers in the status message.
pub fn listBuffers(self: *App) !void {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(self.alloc);
    for (self.buffers.items, 0..) |*buf, i| {
        if (i > 0) try list.append(self.alloc, ' ');
        const marker = if (buf.dirty) "+" else " ";
        const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
        const part = try std.fmt.allocPrint(self.alloc, "{s}{d} {s}", .{ marker, i + 1, name });
        defer self.alloc.free(part);
        try list.appendSlice(self.alloc, part);
    }
    try self.setMsg(try list.toOwnedSlice(self.alloc));
}

pub fn setMsg(self: *App, owned: []u8) !void {
    if (self.msg) |m| self.alloc.free(m);
    self.msg = owned;
}
