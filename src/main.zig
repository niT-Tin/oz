//! oz entry point: vaxis event loop + M0 integration (DESIGN.md §5).
//!
//! Loop:
//!   nextEvent → Mode state machine → execute result against PieceTable
//!   → render frame (line numbers + text + status bar) → vaxis diff output.
const std = @import("std");
const vaxis = @import("vaxis");

const buffer = @import("buffer/root.zig");
const editor = @import("editor/root.zig");
const util = @import("util/root.zig");

// Silence vaxis's per-frame debug logging (pollutes the tty byte stream and
// interferes with e2e screen reconstruction).
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .err }},
};

const status_row_count: u32 = 1;

const App = struct {
    /// One open document. `pt`/`history` own their allocations; the struct is
    /// moved between the list and the active slots (never copied-and-deinit'd).
    const Buffer = struct {
        pt: buffer.PieceTable,
        history: buffer.History,
        cursor: u32 = 0,
        view_top: u32 = 0,
        path: ?[]u8 = null,
        dirty: bool = false,
    };

    const GrepResult = struct { path: []u8, line: u32, text: []u8 };

    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    tty_buffer: []u8,
    loop: vaxis.Loop(vaxis.Event),

    state: editor.Mode.State,
    buffers: std.ArrayList(Buffer) = .empty,
    current: usize = 0,
    in_insert: bool = false,
    quit: bool = false,

    // command line (':') state
    cmdline: std.ArrayList(u8),
    cmd_history: std.ArrayList([]u8),
    cmd_hist_idx: ?usize = null,
    prev_insert_key: ?vaxis.Key = null,
    msg: ?[]u8 = null, // transient status message (owned)

    // visual selection
    visual_anchor: ?u32 = null,
    // yank buffer (M0: in-memory; OSC52 system clipboard is a later step)
    yank_buffer: ?[]u8 = null,

    // easymotion (s / <leader>f) state
    em_active: bool = false,
    em_query: u8 = 0, // single-char query (M1: 1-char only)
    em_labels: bool = false, // matches computed, labels shown
    em_matches: []editor.easymotion.Match = &.{},

    // multi-cursor (Ctrl+n)
    mc: editor.MultiCursor = undefined,
    mc_active: bool = false,

    // recent files (dashboard)
    recent_files: std.ArrayList([]u8) = .empty,
    recent_sel: usize = 0,

    // file tree (<leader>e)
    filetree_active: bool = false,
    filetree_sel: usize = 0,
    filetree_files: std.ArrayList([]u8) = .empty,

    // fuzzy picker (<leader>sf / <leader>st)
    picker_mode: enum { files, grep } = .files,
    picker_active: bool = false,
    picker_files: std.ArrayList([]u8) = .empty, // owned paths
    picker_input: std.ArrayList(u8) = .empty,
    picker_matches: std.ArrayList(usize) = .empty, // indices into picker_files
    picker_sel: usize = 0,
    // grep mode: one result per line from rg
    grep_results: std.ArrayList(GrepResult) = .empty,

    /// The active buffer (all per-buffer state lives here).
    fn cur(self: *App) *Buffer {
        return &self.buffers.items[self.current];
    }

    fn create(init: std.process.Init) !*App {
        const self = try init.gpa.create(App);
        errdefer init.gpa.destroy(self);

        const tty_buffer = try init.gpa.alloc(u8, 4096);
        errdefer init.gpa.free(tty_buffer);
        var tty = vaxis.Tty.init(init.io, tty_buffer) catch |e| {
            init.gpa.free(tty_buffer);
            std.process.fatal("oz: tty init failed: {s}", .{@errorName(e)});
        };
        const opts: vaxis.Vaxis.Options = .{
            .kitty_keyboard_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_alternate_keys = true,
                .report_all_as_ctl_seqs = true,
                .report_text = true,
            },
            .system_clipboard_allocator = init.gpa,
        };
        var vx = try vaxis.init(init.io, init.gpa, init.environ_map, opts);
        errdefer vx.deinit(init.gpa, tty.writer());

        self.* = .{
            .io = init.io,
            .alloc = init.gpa,
            .env_map = init.environ_map,
            .vx = vx,
            .tty = tty,
            .tty_buffer = tty_buffer,
            .loop = undefined,
            .state = editor.Mode.State.init(),
            .buffers = .empty,
            .cmdline = .empty,
            .cmd_history = .empty,
            .mc = editor.MultiCursor.init(init.gpa),
            .picker_files = .empty,
            .picker_input = .empty,
            .picker_matches = .empty,
        };
        try self.buffers.append(init.gpa, .{
            .pt = try buffer.PieceTable.init(init.gpa, ""),
            .history = buffer.History.init(init.gpa),
        });
        // NOTE: loop holds pointers to self.tty / self.vx, so the App must
        // stay at a stable address (heap) — never move it after this.
        self.loop = vaxis.Loop(vaxis.Event).init(init.io, &self.tty, &self.vx);
        try self.loop.installResizeHandler();
        return self;
    }

    fn destroy(self: *App) void {
        self.deinit();
        self.alloc.destroy(self);
    }

    fn deinit(self: *App) void {
        self.loop.stop();
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.alloc.free(self.tty_buffer);
        for (self.buffers.items) |*buf| {
            buf.history.deinit();
            buf.pt.deinit();
            if (buf.path) |p| self.alloc.free(p);
        }
        self.buffers.deinit(self.alloc);
        self.cmdline.deinit(self.alloc);
        for (self.cmd_history.items) |h| self.alloc.free(h);
        self.cmd_history.deinit(self.alloc);
        if (self.msg) |m| self.alloc.free(m);
        if (self.yank_buffer) |b| self.alloc.free(b);
        if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
        self.mc.deinit();
        for (self.filetree_files.items) |f| self.alloc.free(f);
        self.filetree_files.deinit(self.alloc);
        for (self.recent_files.items) |f| self.alloc.free(f);
        self.recent_files.deinit(self.alloc);
        for (self.picker_files.items) |f| self.alloc.free(f);
        self.picker_files.deinit(self.alloc);
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.deinit(self.alloc);
        self.picker_input.deinit(self.alloc);
        self.picker_matches.deinit(self.alloc);
    }

    // ---- input ----

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // File tree navigation (j/k/Enter/Esc); other keys fall through
        if (self.filetree_active) {
            if (try self.filetreeKey(key)) return;
        }

        // Dashboard (no file open): j/k/Enter navigate recent files
        if (self.isDashboard()) {
            if (try self.dashboardKey(key)) return;
        }

        // EasyMotion capture: query char, then a label to jump to
        if (self.em_active) {
            try self.handleEasyMotionKey(key);
            return;
        }

        // Fuzzy picker input
        if (self.picker_active) {
            try self.handlePickerKey(key);
            return;
        }

        // Esc cancels an active multi-cursor selection
        if (self.mc_active and key.codepoint == vaxis.Key.escape) {
            self.mc.clear();
            self.mc_active = false;
            return;
        }

        // 'd' with an active multi-cursor selection deletes the selected word
        // at every cursor (normal-mode 'd' would pend for a motion instead);
        // cursors sit at word starts, so the word is [pos, pos+wlen)
        if (self.mc_active and key.codepoint == 'd' and !key.mods.ctrl and !key.mods.alt) {
            const w = self.mc.wordRange(&self.cur().pt, self.mc.cursors.items[self.mc.main]);
            if (w.end > w.start) {
                const wlen = w.end - w.start;
                self.cur().history.beginGroup();
                var i = self.mc.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const pos = self.mc.cursors.items[i];
                    try self.cur().history.record(&self.cur().pt, pos, wlen, "");
                }
                self.cur().history.endGroup();
            }
            self.mc.clear();
            self.mc_active = false;
            return;
        }

        // Command mode: the ':' command line
        if (self.state.mode == .command) {
            try self.handleCommandKey(key);
            return;
        }

        // Insert mode: characters insert directly; jk exits (removing the
        // just-typed 'j'), backspace and Ctrl-w delete before the cursor.
        if (self.state.mode == .insert) {
            if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
                self.exitInsert();
                return;
            }
            // jk → drop the 'j' we just inserted, then exit (no chars left)
            if (self.prev_insert_key) |p| {
                if (p.codepoint == 'j' and key.codepoint == 'k' and
                    !key.mods.ctrl and !key.mods.alt and !key.mods.super)
                {
                    if (self.cur().cursor > 0 and self.cur().pt.byteAt(self.cur().cursor - 1) == 'j') {
                        try self.cur().history.record(&self.cur().pt, self.cur().cursor - 1, 1, "");
                        self.cur().cursor -= 1;
                    }
                    self.exitInsert();
                    return;
                }
            }
            if (key.codepoint == vaxis.Key.backspace) {
                try self.deleteBeforeCursor();
                return;
            }
            if (key.codepoint == 'w' and key.mods.ctrl) {
                try self.deleteWordBefore();
                return;
            }
            self.prev_insert_key = key;
            if (key.text) |text| {
                try self.insertText(text);
                return;
            }
            return;
        }

        const keymap: editor.KeyEvent.KeyMap = switch (self.state.mode) {
            .normal => editor.Keymaps.normal,
            .insert => editor.Keymaps.insert,
            .visual_char, .visual_line, .visual_block, .command => editor.Keymaps.normal,
        };
        const res = editor.Mode.handle(&self.state, key, keymap);
        switch (res) {
            .pending => {},
            .action => |a| try self.execAction(a.action, a.count),
            .motion => |m| {
                var new_cursor = self.cur().cursor;
                editor.Motion.apply(&self.cur().pt, m.motion, m.args, &new_cursor, m.count);
                self.cur().cursor = new_cursor;
            },
            .op_motion => |m| {
                // text object (diw / ci( / yaw …): resolve at the cursor
                if (m.text_object) |kind| {
                    const rng = editor.TextObject.range(&self.cur().pt, kind, self.cur().cursor);
                    try self.applyOpRange(m.op, rng.start, rng.end, false);
                    return;
                }
                // visual mode: the operator acts on the selection
                if (self.isVisual()) {
                    if (self.visual_anchor) |anchor| {
                        try self.applyOpRangeEx(m.op, anchor, self.cur().cursor, false, .inclusive_cursor);
                    }
                    self.exitVisual();
                    return;
                }
                // normal mode: d/c/y over [cursor, target)
                const target_pos = editor.Motion.target(&self.cur().pt, m.motion, m.args, self.cur().cursor, m.count);
                try self.applyOpRange(m.op, self.cur().cursor, target_pos, m.exclusive_end);
            },
            .surround => |s| try self.execSurround(s),
            .align_lines => |a| try self.execAlign(a),
            .command_mode => {
                // ':' pressed: open the command line (Mode already set .command)
                self.cmdline.clearRetainingCapacity();
                self.cmd_hist_idx = null;
                try self.setMsg(try self.alloc.dupe(u8, ""));
            },
            .to_normal => {
                self.state.mode = .normal;
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
            },
        }
    }

    fn exitInsert(self: *App) void {
        self.state.mode = .normal;
        self.cur().history.endGroup();
        self.in_insert = false;
        self.prev_insert_key = null;
    }

    // ---- easymotion (s / <leader>f) ----

    fn handleEasyMotionKey(self: *App, key: vaxis.Key) !void {
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.endEasyMotion();
            return;
        }
        if (!self.em_labels) {
            // first key = the 1-char query
            if (key.codepoint >= 0x20 and key.codepoint <= 0xFF and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super)
            {
                self.em_query = @intCast(key.codepoint);
                if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
                const q = [1]u8{self.em_query};
                self.em_matches = try editor.easymotion.find(self.alloc, &self.cur().pt, &q);
                self.em_labels = true;
            }
            return;
        }
        // label key: jump to the match carrying this label
        const ch = key.codepoint;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            for (self.em_matches) |m| {
                if (m.label == ch) {
                    self.cur().cursor = m.pos;
                    break;
                }
            }
        }
        self.endEasyMotion();
    }

    fn endEasyMotion(self: *App) void {
        if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
        self.em_matches = &.{};
        self.em_active = false;
        self.em_labels = false;
        self.em_query = 0;
    }

    /// Delete the character before the cursor (backspace). The edit lands in
    /// the open insert undo group so it stays part of the insert session.
    fn deleteBeforeCursor(self: *App) !void {
        if (self.cur().cursor == 0) return;
        const start = buffer.ops.prevCharStart(&self.cur().pt, self.cur().cursor);
        try self.cur().history.record(&self.cur().pt, start, self.cur().cursor - start, "");
        self.cur().cursor = start;
    }

    /// Delete the word before the cursor (Ctrl-w). Vim semantics: walk back
    /// over whitespace then word characters; deletes [start, cursor).
    fn deleteWordBefore(self: *App) !void {
        if (self.cur().cursor == 0) return;
        const start = buffer.ops.wordStartBefore(&self.cur().pt, self.cur().cursor);
        if (start == self.cur().cursor) return;
        try self.cur().history.record(&self.cur().pt, start, self.cur().cursor - start, "");
        self.cur().cursor = start;
    }

    // ---- command line (':') ----

    fn handleCommandKey(self: *App, key: vaxis.Key) !void {
        // cancel
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.state.mode = .normal;
            self.cmdline.clearRetainingCapacity();
            self.cmd_hist_idx = null;
            return;
        }
        switch (key.codepoint) {
            vaxis.Key.enter => {
                const line = self.cmdline.items;
                const cmd = editor.ex_command.parse(line);
                if (cmd != .empty) try self.pushHistory(line);
                self.state.mode = .normal;
                self.cmd_hist_idx = null;
                // execCommand must run BEFORE clearing: Command slices borrow
                // the cmdline buffer (pattern/replacement/edit paths)
                try self.execCommand(cmd);
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
        // Tab: complete the file path after ":e "
        if (key.codepoint == vaxis.Key.tab) {
            try self.completeCommandPath();
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

    /// Tab in command mode: complete the path prefix after ":e ".
    /// Cycles through matches on repeated Tab.
    fn completeCommandPath(self: *App) !void {
        const line = self.cmdline.items;
        // find the token after "e " / ":e " (the leading ':' isn't stored)
        if (line.len < 3 or line[0] != 'e' or line[1] != ' ') return;
        const prefix = line[2..];

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

        // cycle: self.cmd_hist_idx doubles as a completion cursor
        const cycle = (self.cmd_hist_idx orelse 0) + 1;
        const chosen = matches.items[cycle % matches.items.len];
        self.cmd_hist_idx = cycle % matches.items.len;

        self.cmdline.clearRetainingCapacity();
        try self.cmdline.appendSlice(self.alloc, "e ");
        try self.cmdline.appendSlice(self.alloc, chosen);
    }

    fn pushHistory(self: *App, line: []const u8) !void {
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

    fn loadHistory(self: *App) !void {
        self.cmdline.clearRetainingCapacity();
        if (self.cmd_hist_idx) |i| {
            try self.cmdline.appendSlice(self.alloc, self.cmd_history.items[i]);
        }
    }

    fn execCommand(self: *App, cmd: editor.ex_command.Command) !void {
        switch (cmd) {
            .empty => {},
            .write => try self.writeBuffer(),
            .quit => self.quit = true, // M0: no dirty tracking; :q behaves like :q!
            .quit_force => self.quit = true,
            .write_quit => {
                try self.writeBuffer();
                self.quit = true;
            },
            .edit => |path| try self.openFile(path),
            .buffer_next => try self.switchBuffer(1),
            .buffer_prev => try self.switchBuffer(-1),
            .buffer_delete => self.closeCurrent(),
            .buffer_list => try self.listBuffers(),
            .noh => try self.setMsg(try self.alloc.dupe(u8, "")),
            .set => |opt| try self.setMsg(try std.fmt.allocPrint(self.alloc, "set {s} (M0: accepted, no-op)", .{opt})),
            .substitute => |sub| try self.execSubstitute(sub),
            .unknown => try self.setMsg(try self.alloc.dupe(u8, "E492: Not an editor command")),
        }
    }

    /// :s/pat/rep[/g] — literal substitution on the current line or whole
    /// file (M1: no regex). The replacement lands in one undo group.
    fn execSubstitute(self: *App, sub: anytype) !void {
        const start_line = if (sub.whole_file) 0 else self.cur().pt.lineOf(self.cur().cursor);
        const end_line = if (sub.whole_file) self.cur().pt.lineCount() - 1 else start_line;

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var changed: bool = false;
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const ll = self.cur().pt.lineLen(line);
            const ls = self.cur().pt.lineStart(line);
            const buf = try self.alloc.alloc(u8, ll);
            defer self.alloc.free(buf);
            self.cur().pt.copyRange(ls, buf);

            const n = replaceLiteral(&out, self.alloc, buf, sub.pattern, sub.replacement, sub.global);
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
    fn listBuffers(self: *App) !void {
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

    fn setMsg(self: *App, owned: []u8) !void {
        if (self.msg) |m| self.alloc.free(m);
        self.msg = owned;
    }

    fn writeBuffer(self: *App) !void {
        const path = self.cur().path orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E32: No file name"));
            return;
        };
        self.saveFile(path) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "write failed: {s}", .{@errorName(e)}));
            return;
        };
        self.cur().dirty = false;
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "written: {s}", .{path}));
    }

    fn saveFile(self: *App, path: []const u8) !void {
        var f = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer f.close(self.io);
        const len = self.cur().pt.len();
        const buf = try self.alloc.alloc(u8, len);
        defer self.alloc.free(buf);
        self.cur().pt.copyRange(0, buf);
        try f.writeStreamingAll(self.io, buf);
    }

    fn openFile(self: *App, path: []const u8) !void {
        // Multi-buffer semantics: open in a new buffer (or switch if open).
        try self.openInBuffer(path);
    }

    fn insertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        // record() snapshots the pre-edit state and applies the edit itself
        try self.cur().history.record(&self.cur().pt, self.cur().cursor, 0, text);
        self.cur().cursor += @intCast(text.len);
        self.markDirty();
    }

    /// Visual-selection end semantics: vim's character-wise selection includes
    /// the character under the cursor.
    const SelEnd = enum { exclusive_cursor, inclusive_cursor };

    /// Apply an operator (d/c/y) over a range. `exclusive` trims the end char
    /// (vim exclusive motions); text objects and selections pass false with an
    /// already-exact range.
    fn applyOpRange(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool) !void {
        try self.applyOpRangeEx(op, from, to, exclusive, .exclusive_cursor);
    }

    fn applyOpRangeEx(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool, sel: SelEnd) !void {
        const start = @min(from, to);
        var end = @max(from, to);
        if (exclusive and end > start) end -= 1;
        if (sel == .inclusive_cursor and end < self.cur().pt.len()) end += 1;
        if (end <= start) {
            if (op == .change) {
                self.state.mode = .insert;
                self.in_insert = true;
            }
            return;
        }
        switch (op) {
            .delete => {
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, start, end - start, "");
                self.cur().history.endGroup();
                self.cur().cursor = start;
                self.markDirty();
            },
            .change => {
                self.cur().cursor = start;
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, start, end - start, "");
                self.state.mode = .insert;
                self.in_insert = true; // keep the group open; exitInsert closes it
                self.markDirty();
            },
            .yank => {
                if (self.yank_buffer) |b| self.alloc.free(b);
                const buf = try self.alloc.alloc(u8, end - start);
                self.cur().pt.copyRange(start, buf);
                self.yank_buffer = buf;
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked {d} bytes", .{buf.len}));
            },
            else => {},
        }
    }

    // ---- surround (ys / ds / cs) ----

    fn execSurround(self: *App, s: anytype) !void {
        switch (s.op) {
            .add => {
                const rng = self.surroundRange(s.motion, s.args, s.count, s.text_object) orelse return;
                const res = try editor.surround.add(self.alloc, &self.cur().pt, .{ .start = rng.start, .end = rng.end }, s.ch);
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
            },
            .delete => {
                const res = (try editor.surround.delete(self.alloc, &self.cur().pt, self.cur().cursor)) orelse {
                    try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                    return;
                };
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
                self.cur().cursor = res.start;
            },
            .change => {
                const res = (try editor.surround.change(self.alloc, &self.cur().pt, self.cur().cursor, s.ch)) orelse {
                    try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                    return;
                };
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
                self.cur().cursor = res.start;
            },
        }
    }

    /// Range covered by a surround-add motion/text object; trailing whitespace
    /// is trimmed so ysw wraps the word, not "word " (vim-surround behavior).
    fn surroundRange(self: *App, motion: ?editor.Motion.Motion, args: editor.Motion.Args, count: u32, text_object: ?editor.TextObject.Kind) ?editor.TextObject.Range {
        var rng: editor.TextObject.Range = undefined;
        if (text_object) |kind| {
            const r = editor.TextObject.range(&self.cur().pt, kind, self.cur().cursor);
            rng = .{ .start = r.start, .end = r.end };
        } else if (motion) |m| {
            const target = editor.Motion.target(&self.cur().pt, m, args, self.cur().cursor, count);
            rng = .{ .start = @min(self.cur().cursor, target), .end = @max(self.cur().cursor, target) };
        } else return null;
        // trim trailing spaces/tabs (not newlines)
        while (rng.end > rng.start) {
            const c = self.cur().pt.byteAt(rng.end - 1);
            if (c != ' ' and c != '\t') break;
            rng.end -= 1;
        }
        return rng;
    }

    /// ga: align lines [start_line, end_line] on the first `char`.
    fn execAlign(self: *App, a: anytype) !void {
        var start_line: u32 = undefined;
        var end_line: u32 = undefined;
        if (a.selection) {
            const anchor = self.visual_anchor orelse return;
            const s = @min(anchor, self.cur().cursor);
            const e = @max(anchor, self.cur().cursor);
            start_line = self.cur().pt.lineOf(s);
            end_line = self.cur().pt.lineOf(e);
            self.exitVisual();
        } else {
            var rng: editor.TextObject.Range = undefined;
            if (a.text_object) |kind| {
                const r = editor.TextObject.range(&self.cur().pt, kind, self.cur().cursor);
                rng = .{ .start = r.start, .end = r.end };
            } else if (a.motion) |m| {
                const target = editor.Motion.target(&self.cur().pt, m, a.args, self.cur().cursor, a.count);
                rng = .{ .start = @min(self.cur().cursor, target), .end = @max(self.cur().cursor, target) };
            } else return;
            start_line = self.cur().pt.lineOf(rng.start);
            end_line = self.cur().pt.lineOf(rng.end);
            if (rng.end > rng.start and rng.end == self.cur().pt.lineStart(rng.end)) end_line -|= 1;
        }
        const text = try editor.align_text.alignLines(self.alloc, &self.cur().pt, start_line, end_line, a.char);
        defer self.alloc.free(text);
        const start = self.cur().pt.lineStart(start_line);
        var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
        if (end_line + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
        try self.applyEdit(start, end, text);
        self.cur().cursor = start;
    }

    fn applyEdit(self: *App, start: u32, end: u32, text: []const u8) !void {
        self.cur().history.beginGroup();
        try self.cur().history.record(&self.cur().pt, start, end - start, text);
        self.cur().history.endGroup();
        self.markDirty();
    }

    fn isVisual(self: *const App) bool {
        return switch (self.state.mode) {
            .visual_char, .visual_line, .visual_block => true,
            else => false,
        };
    }

    /// gcc: comment/uncomment the current line (vim semantics: fully commented
    /// lines get uncommented, otherwise everything is commented).
    fn toggleCommentLine(self: *App) !void {
        const ft = filetypeOf(self.cur().path);
        const style = editor.comment.styleForFiletype(ft) orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E505: No comment style for filetype"));
            return;
        };
        const line = self.cur().pt.lineOf(self.cur().cursor);
        const toggle = try editor.comment.toggleLines(self.alloc, &self.cur().pt, line, line, style);
        defer self.alloc.free(toggle.text);
        const start = self.cur().pt.lineStart(line);
        const end = start + self.cur().pt.lineLen(line); // toggleLines text excludes the trailing '\n'
        try self.applyEdit(start, end, toggle.text);
        self.cur().cursor = start;
    }

    fn exitVisual(self: *App) void {
        self.state.mode = .normal;
        self.visual_anchor = null;
    }

    /// Ctrl+n: first press selects the word under the cursor, later presses
    /// add the next matching word as another cursor.
    fn mcSelectNext(self: *App) !void {
        if (!self.mc_active) {
            self.mc.clear();
            _ = try self.mc.add(self.cur().cursor);
            self.mc_active = true;
        } else {
            _ = try self.mc.addNextMatch(&self.cur().pt);
        }
    }

    // ---- file tree (<leader>e / <leader>E) ----

    fn toggleFiletree(self: *App) !void {
        if (self.filetree_active) {
            self.filetree_active = false;
            return;
        }
        if (self.filetree_files.items.len == 0) {
            var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
            defer root.close(self.io);
            try self.walkInto(root, "", &self.filetree_files);
            std.mem.sort([]u8, self.filetree_files.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
        }
        self.filetree_active = true;
    }

    fn locateInFiletree(self: *App) !void {
        if (self.filetree_files.items.len == 0) {
            try self.toggleFiletree();
        }
        if (self.cur().path) |p| {
            for (self.filetree_files.items, 0..) |f, i| {
                if (std.mem.eql(u8, f, p)) {
                    self.filetree_sel = i;
                    break;
                }
            }
        }
        self.filetree_active = true;
    }

    /// j/k/Enter/Esc for the tree; returns true if consumed.
    fn filetreeKey(self: *App, key: vaxis.Key) !bool {
        switch (key.codepoint) {
            'j', vaxis.Key.down => {
                if (self.filetree_sel + 1 < self.filetree_files.items.len) self.filetree_sel += 1;
                return true;
            },
            'k', vaxis.Key.up => {
                if (self.filetree_sel > 0) self.filetree_sel -= 1;
                return true;
            },
            vaxis.Key.enter => {
                if (self.filetree_files.items.len > 0) {
                    const f = self.filetree_files.items[self.filetree_sel];
                    self.filetree_active = false;
                    try self.openFile(f);
                }
                return true;
            },
            vaxis.Key.escape => {
                self.filetree_active = false;
                return true;
            },
            else => return false,
        }
    }

    // ---- fuzzy picker (<leader>sf) ----

    fn openPicker(self: *App) !void {
        if (self.picker_files.items.len == 0) {
            // cwd() has fd == AT.FDCWD (-100), which the dir iterator can't
            // getdents on — open a real directory handle first.
            var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
            defer root.close(self.io);
            try self.walkDir(root, "");
        }
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn walkDir(self: *App, dir: std.Io.Dir, prefix: []const u8) !void {
        try self.walkInto(dir, prefix, &self.picker_files);
    }

    fn walkInto(self: *App, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]u8)) !void {
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

    fn openGrepPicker(self: *App) !void {
        self.picker_mode = .grep;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_active = true;
    }

    /// Run rg for the current query and store results (path:line:text).
    fn runGrep(self: *App) !void {
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.clearRetainingCapacity();

        const query = self.picker_input.items;
        if (query.len == 0) return;

        var child = std.process.spawn(self.io, .{
            .argv = &.{ "rg", "--no-heading", "-n", query },
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return;
        defer _ = child.wait(self.io) catch {};

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
    }

    fn handlePickerKey(self: *App, key: vaxis.Key) !void {
        switch (key.codepoint) {
            vaxis.Key.escape => self.closePicker(),
            vaxis.Key.enter => {
                if (self.picker_mode == .grep) {
                    if (self.grep_results.items.len > 0) {
                        const r = self.grep_results.items[self.picker_sel];
                        self.closePicker();
                        try self.openFile(r.path);
                        const line = @min(r.line - 1, self.cur().pt.lineCount() - 1);
                        self.cur().cursor = self.cur().pt.lineStart(line);
                        self.cur().view_top = line;
                    }
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
                }
            },
            vaxis.Key.down => {
                const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
                if (self.picker_sel + 1 < n) self.picker_sel += 1;
            },
            vaxis.Key.up => {
                if (self.picker_sel > 0) self.picker_sel -= 1;
            },
            else => {
                if (key.codepoint == 'n' and key.mods.ctrl) {
                    const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
                    if (self.picker_sel + 1 < n) self.picker_sel += 1;
                } else if (key.codepoint == 'p' and key.mods.ctrl) {
                    if (self.picker_sel > 0) self.picker_sel -= 1;
                } else if (key.text) |t| {
                    try self.picker_input.appendSlice(self.alloc, t);
                    self.picker_sel = 0;
                    if (self.picker_mode == .grep) {
                        try self.runGrep();
                    } else {
                        try self.pickerRefilter();
                    }
                }
            },
        }
    }

    fn pickerRefilter(self: *App) !void {
        self.picker_matches.clearRetainingCapacity();
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

    fn closePicker(self: *App) void {
        self.picker_active = false;
        self.picker_sel = 0;
        self.picker_mode = .files;
    }

    // ---- dashboard ----

    fn isDashboard(self: *App) bool {
        return self.cur().path == null and self.cur().pt.len() == 0 and
            self.state.mode == .normal and !self.picker_active and !self.em_active;
    }

    /// j/k/Enter for the recent-files list; returns true if consumed.
    fn dashboardKey(self: *App, key: vaxis.Key) !bool {
        switch (key.codepoint) {
            'j' => {
                if (self.recent_sel + 1 < self.recent_files.items.len) self.recent_sel += 1;
                return true;
            },
            'k' => {
                if (self.recent_sel > 0) self.recent_sel -= 1;
                return true;
            },
            vaxis.Key.enter => {
                if (self.recent_files.items.len > 0) {
                    try self.openFile(self.recent_files.items[self.recent_sel]);
                    self.recent_sel = 0;
                }
                return true;
            },
            else => return false,
        }
    }

    fn addRecent(self: *App, path: []const u8) !void {
        for (self.recent_files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f, path)) {
                _ = self.recent_files.orderedRemove(i);
                break;
            }
        }
        const copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(copy);
        try self.recent_files.insert(self.alloc, 0, copy);
        while (self.recent_files.items.len > 10) {
            if (self.recent_files.pop()) |f| self.alloc.free(f);
        }
    }

    // ---- multi-buffer ----

    /// Switch to the buffer at index `i` (clamped, wraps).
    fn switchTo(self: *App, i: usize) void {
        if (self.buffers.items.len == 0) return;
        self.current = i % self.buffers.items.len;
        self.state.mode = .normal;
        self.in_insert = false;
        self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
    }

    /// Move `delta` buffers (wrapping). gt / gT.
    fn switchBuffer(self: *App, delta: i32) !void {
        const n = self.buffers.items.len;
        if (n == 0) return;
        var next = @as(i32, @intCast(self.current)) + delta;
        if (next < 0) next += @as(i32, @intCast(n));
        self.switchTo(@intCast(@mod(next, @as(i32, @intCast(n)))));
    }

    /// Open `path` in a new buffer unless it is already open (then switch).
    fn openInBuffer(self: *App, path: []const u8) !void {
        for (self.buffers.items, 0..) |*buf, i| {
            if (buf.path) |p| {
                if (std.mem.eql(u8, p, path)) {
                    self.switchTo(i);
                    return;
                }
            }
        }
        // load the file
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ path, @errorName(e) }));
            return;
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        const bytes = try self.alloc.alloc(u8, @intCast(size));
        defer self.alloc.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);

        try self.buffers.append(self.alloc, .{
            .pt = try buffer.PieceTable.init(self.alloc, bytes),
            .history = buffer.History.init(self.alloc),
            .path = try self.alloc.dupe(u8, path),
        });
        try self.addRecent(path);
        self.switchTo(self.buffers.items.len - 1);
    }

    /// Close the current buffer; switch to a neighbor. The last buffer stays.
    fn closeCurrent(self: *App) void {
        if (self.buffers.items.len <= 1) return;
        var buf = self.buffers.orderedRemove(self.current);
        buf.history.deinit();
        buf.pt.deinit();
        if (buf.path) |p| self.alloc.free(p);
        if (self.current >= self.buffers.items.len) self.current = self.buffers.items.len - 1;
        self.state.mode = .normal;
        self.in_insert = false;
    }

    fn markDirty(self: *App) void {
        self.cur().dirty = true;
    }

    /// Load recent files from ~/.cache/oz/recent (one path per line).
    fn loadRecent(self: *App) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = self.env_map.get("HOME") orelse return;
        const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch return;
        defer dir.close(self.io);
        const file = dir.openFile(self.io, "recent", .{ .mode = .read_only }) catch return;
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size == 0) return;
        const content = try self.alloc.alloc(u8, @intCast(size));
        defer self.alloc.free(content);
        _ = try file.readPositionalAll(self.io, content, 0);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const copy = try self.alloc.dupe(u8, line);
            errdefer self.alloc.free(copy);
            self.recent_files.append(self.alloc, copy) catch {};
        }
    }

    /// Persist recent files to ~/.cache/oz/recent.
    fn saveRecent(self: *App) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = self.env_map.get("HOME") orelse return;
        const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch blk: {
            try std.Io.Dir.cwd().createDirPath(self.io, dir_path);
            break :blk try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        };
        defer dir.close(self.io);
        const file = try dir.createFile(self.io, "recent", .{ .truncate = true });
        defer file.close(self.io);
        for (self.recent_files.items) |f| {
            try file.writeStreamingAll(self.io, f);
            try file.writeStreamingAll(self.io, "\n");
        }
    }

    fn execAction(self: *App, action: editor.KeyEvent.ActionId, count: u32) !void {
        _ = count;
        switch (action) {
            .undo => {
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
                _ = self.cur().history.undo(&self.cur().pt);
                self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
            },
            .redo => {
                _ = self.cur().history.redo(&self.cur().pt);
                self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
            },
            .insert_mode => self.state.mode = .insert,
            .append => {
                // a: insert after the character under the cursor
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const end = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                if (self.cur().cursor < end) {
                    var i = self.cur().cursor + 1;
                    while (i < end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                    self.cur().cursor = i;
                }
                self.state.mode = .insert;
            },
            .insert_before => {
                // I: first non-blank of the line
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const ls = self.cur().pt.lineStart(line);
                const end = ls + self.cur().pt.lineLen(line);
                var pos = ls;
                while (pos < end) {
                    const c = self.cur().pt.byteAt(pos);
                    if (c != ' ' and c != '\t') break;
                    pos += 1;
                }
                self.cur().cursor = pos;
                self.state.mode = .insert;
            },
            .append_end => {
                // A: end of the line
                const line = self.cur().pt.lineOf(self.cur().cursor);
                self.cur().cursor = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                self.state.mode = .insert;
            },
            .insert_line_after => {
                // o: new line below, cursor on it
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const pos = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                self.cur().history.endGroup();
                self.cur().cursor = pos + 1;
                self.state.mode = .insert;
            },
            .insert_line_before => {
                // O: new line above, cursor on it
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const pos = self.cur().pt.lineStart(line);
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                self.cur().history.endGroup();
                self.cur().cursor = pos;
                self.state.mode = .insert;
            },
            .visual_char => {
                self.state.mode = .visual_char;
                self.visual_anchor = self.cur().cursor;
            },
            .visual_line => {
                self.state.mode = .visual_line;
                self.visual_anchor = self.cur().cursor;
            },
            .visual_block => {
                self.state.mode = .visual_block;
                self.visual_anchor = self.cur().cursor;
            },
            .delete, .change, .yank => {
                // multi-cursor: d deletes the selected word at every cursor
                if (self.mc_active and action == .delete) {
                    const w = self.mc.wordRange(&self.cur().pt, self.mc.cursors.items[self.mc.main]);
                    if (w.end > w.start) {
                        _ = try self.mc.applyDelete(&self.cur().pt, w.end - w.start);
                    }
                    self.mc.clear();
                    self.mc_active = false;
                    return;
                }
                // visual mode: the operator acts on the selection directly
                if (self.isVisual()) {
                    if (self.visual_anchor) |anchor| {
                        try self.applyOpRangeEx(action, anchor, self.cur().cursor, false, .inclusive_cursor);
                    }
                    self.exitVisual();
                }
            },
            .mc_add => try self.mcSelectNext(),
            .next_buffer => try self.switchBuffer(1),
            .prev_buffer => try self.switchBuffer(-1),
            .picker_file => try self.openPicker(),
            .picker_grep => try self.openGrepPicker(),
            .filetree_toggle => try self.toggleFiletree(),
            .filetree_locate => try self.locateInFiletree(),
            .paste => try self.pasteBuffer(false),
            .paste_before => try self.pasteBuffer(true),
            .toggle_comment_line => try self.toggleCommentLine(),
            .easymotion, .leader_find => {
                // start the EasyMotion capture flow
                self.em_active = true;
                self.em_labels = false;
                self.em_query = 0;
            },
            .enter_command_mode => {},
            else => {},
        }
    }

    /// p / P: insert the yank buffer at the cursor (M1 simplification: p
    /// inserts after the current char when not at line end, P at the cursor).
    fn pasteBuffer(self: *App, before: bool) !void {
        const buf = self.yank_buffer orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E353: Nothing in register"));
            return;
        };
        var pos = self.cur().cursor;
        if (!before) {
            // p: after the character under the cursor (or at line end)
            const line = self.cur().pt.lineOf(self.cur().cursor);
            const line_end = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
            if (self.cur().cursor < line_end) {
                var i = self.cur().cursor + 1;
                while (i < line_end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                pos = i;
            }
        }
        self.cur().history.beginGroup();
        try self.cur().history.record(&self.cur().pt, pos, 0, buf);
        self.cur().history.endGroup();
        self.cur().cursor = pos + @as(u32, @intCast(buf.len));
    }

    // ---- rendering ----

    const filetree_width: u32 = 24;
    const tab_bar_rows: u32 = 1;

    /// Row where the editor content starts (below the tab bar).
    fn contentTop(self: *const App) u32 {
        _ = self;
        return tab_bar_rows;
    }

    fn contentCol(self: *const App) u32 {
        return if (self.filetree_active) filetree_width else 0;
    }

    fn render(self: *App) !void {
        // vaxis cells reference the text slices passed to print, so all text
        // must stay alive until vx.render(); a per-frame arena handles that.
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const win = self.vx.window();
        win.clear();

        const height: u32 = win.height;
        if (height <= status_row_count) return;
        const content_rows = height - status_row_count;

        const cursor_line = self.cur().pt.lineOf(self.cur().cursor);
        const line_count = self.cur().pt.lineCount();

        // tab bar: one entry per buffer, current highlighted, + dirty marker
        {
            var tab_i: usize = 0;
            var col: u16 = 0;
            while (tab_i < self.buffers.items.len) : (tab_i += 1) {
                const buf = &self.buffers.items[tab_i];
                const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
                const dirty = if (buf.dirty) "\u{25cf}" else " ";
                const label = try std.fmt.allocPrint(a, " {s}{s} ", .{ name, dirty });
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (tab_i == self.current)
                        .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bold = true }
                    else
                        .{ .fg = .{ .rgb = .{ 86, 95, 137 } } },
                }};
                _ = win.print(&seg, .{ .row_offset = 0, .col_offset = col, .wrap = .none });
                col +|= @intCast(label.len);
                if (col >= win.width) break;
            }
        }

        // dashboard (no file open): title + recent files + hints
        if (self.isDashboard()) {
            const title_seg = [_]vaxis.Segment{.{
                .text = " oz  ",
                .style = .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bold = true },
            }};
            _ = win.print(&title_seg, .{ .row_offset = @intCast(self.contentTop() + 2), .col_offset = 2, .wrap = .none });
            const sub_seg = [_]vaxis.Segment{.{
                .text = " 终端文本编辑器  —  j/k 选择 · Enter 打开 · <leader>sf 找文件 · :e 打开 · :q 退出",
                .style = .{ .fg = .{ .rgb = .{ 86, 95, 137 } } },
            }};
            _ = win.print(&sub_seg, .{ .row_offset = @intCast(self.contentTop() + 3), .col_offset = 2, .wrap = .none });
            var ri: usize = 0;
            while (ri < @min(self.recent_files.items.len, 8)) : (ri += 1) {
                const fname = self.recent_files.items[ri];
                const row: u32 = 5 + @as(u32, @intCast(ri));
                const seg = [_]vaxis.Segment{.{
                    .text = fname,
                    .style = if (ri == self.recent_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{ .fg = .{ .rgb = .{ 122, 162, 247 } } },
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(self.contentTop() + row), .col_offset = 2, .wrap = .none });
            }
            self.vx.screen.cursor = .{
                .row = @intCast(self.contentTop() + 5 + @as(u32, @intCast(@min(self.recent_sel, 7)))),
                .col = 2,
            };
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // keep cursor line visible, centered-ish
        if (self.cur().cursor < self.cur().pt.lineStart(self.cur().view_top)) {
            self.cur().view_top = cursor_line;
        }
        const view_bottom = self.cur().view_top + content_rows;
        if (cursor_line >= view_bottom) {
            self.cur().view_top = cursor_line - content_rows + 1;
        }
        if (self.cur().view_top + content_rows > line_count and line_count > content_rows) {
            self.cur().view_top = line_count - content_rows;
        }

        var row: u32 = 0;
        var line = self.cur().view_top;
        while (row < content_rows and line < line_count) : ({
            line += 1;
            row += 1;
        }) {
            const rel: u32 = if (line == cursor_line)
                line + 1
            else if (line > cursor_line)
                line - cursor_line
            else
                cursor_line - line;
            const num_str = try std.fmt.allocPrint(a, "{d:>4} ", .{rel});

            const line_len = self.cur().pt.lineLen(line);
            const line_start = self.cur().pt.lineStart(line);
            const n: u32 = @min(line_len, win.width);
            const text = try a.alloc(u8, n);
            self.cur().pt.copyRange(line_start, text);

            // visual selection highlight (M1: char-wise range; line/block
            // kinds reuse the char range)
            var segs: [4]vaxis.Segment = undefined;
            var nseg: usize = 0;
            segs[nseg] = .{ .text = num_str };
            nseg += 1;
            if (self.visual_anchor) |anchor| {
                const sel_start = @min(anchor, self.cur().cursor);
                const sel_end = @max(anchor, self.cur().cursor);
                const line_end = line_start + line_len;
                if (sel_start < line_end and sel_end > line_start) {
                    const s = @max(sel_start, line_start) - line_start;
                    const e = @min(sel_end, line_end) - line_start;
                    if (s > 0) {
                        segs[nseg] = .{ .text = text[0..s] };
                        nseg += 1;
                    }
                    segs[nseg] = .{
                        .text = text[s..e],
                        .style = .{ .bg = .{ .rgb = .{ 54, 74, 130 } } },
                    };
                    nseg += 1;
                    if (e < n) {
                        segs[nseg] = .{ .text = text[e..n] };
                        nseg += 1;
                    }
                } else {
                    segs[nseg] = .{ .text = text };
                    nseg += 1;
                }
            } else {
                segs[nseg] = .{ .text = text };
                nseg += 1;
            }

            _ = win.print(segs[0..nseg], .{
                .row_offset = @intCast(row),
                .col_offset = @intCast(self.contentCol()),
                .wrap = .none,
            });
        }

        // file tree sidebar
        if (self.filetree_active) {
            const title_seg = [_]vaxis.Segment{.{
                .text = " files ",
                .style = .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bold = true },
            }};
            _ = win.print(&title_seg, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
            var ri: usize = 0;
            while (ri < @min(self.filetree_files.items.len, @as(usize, content_rows))) : (ri += 1) {
                const f = self.filetree_files.items[ri];
                const label = if (f.len > filetree_width) f[f.len - filetree_width ..] else f;
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (ri == self.filetree_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{ .fg = .{ .rgb = .{ 122, 162, 247 } } },
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(1 + ri), .col_offset = 0, .wrap = .none });
            }
        }

        // multi-cursor word highlights (overlay)
        if (self.mc_active) {
            for (self.mc.cursors.items) |cpos| {
                const w = self.mc.wordRange(&self.cur().pt, cpos);
                if (w.end <= w.start) continue;
                const wline = self.cur().pt.lineOf(w.start);
                if (wline < self.cur().view_top or wline >= self.cur().view_top + content_rows) continue;
                const ls = self.cur().pt.lineStart(wline);
                var p = w.start;
                while (p < w.end) {
                    const col = p - ls;
                    if (col >= win.width - 5) break;
                    var clen: u32 = 1;
                    while (p + clen < w.end and (self.cur().pt.byteAt(p + clen) & 0xC0) == 0x80) : (clen += 1) {}
                    var char_buf: [4]u8 = undefined;
                    self.cur().pt.copyRange(p, char_buf[0..clen]);
                    const g = try a.dupe(u8, char_buf[0..clen]);
                    win.writeCell(@intCast(self.contentCol() + 5 + col), @intCast(self.contentTop() + wline - self.cur().view_top), .{
                        .char = .{ .grapheme = g, .width = 1 },
                        .style = .{ .bg = .{ .rgb = .{ 54, 74, 130 } } },
                    });
                    p += clen;
                }
            }
        }

        // easymotion labels: overwrite the matched cells with jump labels
        if (self.em_labels) {
            for (self.em_matches) |m| {
                const mline = self.cur().pt.lineOf(m.pos);
                if (mline < self.cur().view_top or mline >= self.cur().view_top + content_rows) continue;
                const col_in_line = m.pos - self.cur().pt.lineStart(mline);
                const label = try a.dupe(u8, &[_]u8{m.label});
                win.writeCell(@intCast(self.contentCol() + 5 + col_in_line), @intCast(self.contentTop() + mline - self.cur().view_top), .{
                    .char = .{ .grapheme = label, .width = 1 },
                    .style = .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bg = .{ .rgb = .{ 54, 74, 130 } } },
                });
            }
        }

        // fuzzy picker overlay
        if (self.picker_active) {
            const total = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
            const list_rows = @min(@as(usize, 10), total);
            const start_row = height - 1 - @as(u32, @intCast(list_rows)) - 1;
            var ri: usize = 0;
            while (ri < list_rows) : (ri += 1) {
                const label: []const u8 = if (self.picker_mode == .grep) blk: {
                    const r = self.grep_results.items[ri];
                    break :blk std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ r.path, r.line, r.text }) catch "…";
                } else self.picker_files.items[self.picker_matches.items[ri]];
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (ri == self.picker_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{},
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(start_row + ri), .wrap = .none });
            }
            const prompt = try std.fmt.allocPrint(a, "> {s}", .{self.picker_input.items});
            const prompt_seg = [_]vaxis.Segment{.{
                .text = prompt,
                .style = .{ .fg = .{ .rgb = .{ 192, 202, 245 } }, .bg = .{ .rgb = .{ 41, 46, 66 } } },
            }};
            _ = win.print(&prompt_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
            self.vx.screen.cursor = .{
                .row = @intCast(height - 1),
                .col = @intCast(2 + self.picker_input.items.len),
            };
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // status bar (or command line in command mode)
        if (self.state.mode == .command) {
            const prompt = try std.fmt.allocPrint(a, ":{s}", .{self.cmdline.items});
            const cmd_seg = [_]vaxis.Segment{.{
                .text = prompt,
                .style = .{ .fg = .{ .rgb = .{ 192, 202, 245 } }, .bg = .{ .rgb = .{ 41, 46, 66 } } },
            }};
            _ = win.print(&cmd_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
            self.vx.screen.cursor = .{
                .row = @intCast(height - 1),
                .col = @intCast(1 + self.cmdline.items.len),
            };
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        const mode_str = switch (self.state.mode) {
            .normal => " NORMAL ",
            .insert => " INSERT ",
            .visual_char, .visual_line, .visual_block => " VISUAL ",
            .command => " COMMAND ",
        };
        const status = if (self.msg) |m|
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}  {s}",
                .{ mode_str, cursor_line + 1, line_count, self.cur().cursor - self.cur().pt.lineStart(cursor_line), m },
            )
        else
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}",
                .{ mode_str, cursor_line + 1, line_count, self.cur().cursor - self.cur().pt.lineStart(cursor_line) },
            );
        const status_seg = [_]vaxis.Segment{.{
            .text = status,
            .style = .{ .fg = .{ .rgb = .{ 192, 202, 245 } }, .bg = .{ .rgb = .{ 41, 46, 66 } } },
        }};
        _ = win.print(&status_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });

        // cursor position
        const cursor_col = self.cur().cursor - self.cur().pt.lineStart(cursor_line);
        const cursor_row = cursor_line - self.cur().view_top;
        self.vx.screen.cursor = .{
            .row = @intCast(cursor_row),
            .col = @intCast(self.contentCol() + 5 + cursor_col), // gutter offset
        };
        self.vx.screen.cursor_shape = if (self.state.mode == .insert) .beam else .block;

        try self.vx.render(self.tty.writer());
    }

    fn run(self: *App) !void {
        try self.vx.enterAltScreen(self.tty.writer());
        try self.loop.start();
        defer self.loop.stop();

        while (!self.quit) {
            const event = try self.loop.nextEvent();
            switch (event) {
                .key_press => |key| try self.handleKey(key),
                .paste => |text| {
                    if (self.state.mode == .insert) try self.insertText(text);
                },
                .winsize => |ws| {
                    try self.vx.resize(self.alloc, self.tty.writer(), ws);
                },
                else => {},
            }
            try self.render();
        }

        try self.vx.exitAltScreen(self.tty.writer());
    }
};

/// Append `haystack` with every occurrence of `pat` replaced by `rep`
/// (all if `global`, else only the first). Returns the replacement count.
fn replaceLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, haystack: []const u8, pat: []const u8, rep: []const u8, global: bool) usize {
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

/// Filetype from a file path's extension ("src/main.zig" → "zig").
fn filetypeOf(path: ?[]const u8) []const u8 {
    const p = path orelse return "";
    const base = std.fs.path.basename(p);
    const ext = std.fs.path.extension(base);
    if (ext.len <= 1) return "";
    return ext[1..];
}

fn parseLineArg(arg: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, arg, ':')) |idx| {
        return std.fmt.parseUnsigned(u32, arg[idx + 1 ..], 10) catch null;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var app = try App.create(init);
    defer app.destroy();

    // args: oz [file[:line]] ...
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    var target_line: u32 = 0;
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        const content = arg[0 .. arg.len - 0];
        if (parseLineArg(content)) |ln| {
            target_line = ln;
        }
        const file_path = if (parseLineArg(content) != null) content[0..std.mem.lastIndexOfScalar(u8, content, ':').?] else content;
        if (file_path.len > 0) {
            var file = std.Io.Dir.cwd().openFile(app.io, file_path, .{ .mode = .read_only }) catch continue;
            defer file.close(app.io);
            const size = (try file.stat(app.io)).size;
            const bytes = try app.alloc.alloc(u8, @intCast(size));
            defer app.alloc.free(bytes);
            _ = try file.readPositionalAll(app.io, bytes, 0);
            app.cur().pt.deinit();
            app.cur().pt = try buffer.PieceTable.init(app.alloc, bytes);
            if (app.cur().path) |p| app.alloc.free(p);
            app.cur().path = try app.alloc.dupe(u8, file_path);
            try app.addRecent(file_path);
        }
        break; // M0: first file only
    }
    if (target_line > 0) {
        app.cur().cursor = app.cur().pt.lineStart(@min(target_line - 1, app.cur().pt.lineCount() - 1));
    }

    try app.loadRecent();
    defer app.saveRecent() catch {};
    try app.run();
}
