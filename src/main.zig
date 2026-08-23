//! oz entry point: vaxis event loop + M0 integration (DESIGN.md §5).
//!
//! Loop:
//!   nextEvent → Mode state machine → execute result against PieceTable
//!   → render frame (line numbers + text + status bar) → vaxis diff output.
const std = @import("std");
const vaxis = @import("vaxis");

const buffer = @import("buffer/root.zig");
const editor = @import("editor/root.zig");

// Silence vaxis's per-frame debug logging (pollutes the tty byte stream and
// interferes with e2e screen reconstruction).
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .err }},
};

const status_row_count: u32 = 1;

const App = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    tty_buffer: []u8,
    loop: vaxis.Loop(vaxis.Event),

    state: editor.Mode.State,
    pt: buffer.PieceTable,
    history: buffer.History,
    cursor: u32 = 0, // byte offset
    view_top: u32 = 0, // first visible line
    in_insert: bool = false,
    quit: bool = false,

    // command line (':') state
    cmdline: std.ArrayList(u8),
    cmd_history: std.ArrayList([]u8),
    cmd_hist_idx: ?usize = null,
    prev_insert_key: ?vaxis.Key = null,
    file_path: ?[]u8 = null,
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
            .vx = vx,
            .tty = tty,
            .tty_buffer = tty_buffer,
            .loop = undefined,
            .state = editor.Mode.State.init(),
            .pt = try buffer.PieceTable.init(init.gpa, ""),
            .history = buffer.History.init(init.gpa),
            .cmdline = .empty,
            .cmd_history = .empty,
        };
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
        self.history.deinit();
        self.pt.deinit();
        self.cmdline.deinit(self.alloc);
        for (self.cmd_history.items) |h| self.alloc.free(h);
        self.cmd_history.deinit(self.alloc);
        if (self.file_path) |p| self.alloc.free(p);
        if (self.msg) |m| self.alloc.free(m);
        if (self.yank_buffer) |b| self.alloc.free(b);
        if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
    }

    // ---- input ----

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // EasyMotion capture: query char, then a label to jump to
        if (self.em_active) {
            try self.handleEasyMotionKey(key);
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
                    if (self.cursor > 0 and self.pt.byteAt(self.cursor - 1) == 'j') {
                        try self.history.record(&self.pt, self.cursor - 1, 1, "");
                        self.cursor -= 1;
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
                var cur = self.cursor;
                editor.Motion.apply(&self.pt, m.motion, m.args, &cur, m.count);
                self.cursor = cur;
            },
            .op_motion => |m| {
                // text object (diw / ci( / yaw …): resolve at the cursor
                if (m.text_object) |kind| {
                    const rng = editor.TextObject.range(&self.pt, kind, self.cursor);
                    try self.applyOpRange(m.op, rng.start, rng.end, false);
                    return;
                }
                // visual mode: the operator acts on the selection
                if (self.isVisual()) {
                    if (self.visual_anchor) |anchor| {
                        try self.applyOpRangeEx(m.op, anchor, self.cursor, false, .inclusive_cursor);
                    }
                    self.exitVisual();
                    return;
                }
                // normal mode: d/c/y over [cursor, target)
                const target_pos = editor.Motion.target(&self.pt, m.motion, m.args, self.cursor, m.count);
                try self.applyOpRange(m.op, self.cursor, target_pos, m.exclusive_end);
            },
            .command_mode => {
                // ':' pressed: open the command line (Mode already set .command)
                self.cmdline.clearRetainingCapacity();
                self.cmd_hist_idx = null;
                try self.setMsg(try self.alloc.dupe(u8, ""));
            },
            .to_normal => {
                self.state.mode = .normal;
                if (self.in_insert) {
                    self.history.endGroup();
                    self.in_insert = false;
                }
            },
        }
    }

    fn exitInsert(self: *App) void {
        self.state.mode = .normal;
        self.history.endGroup();
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
                self.em_matches = try editor.easymotion.find(self.alloc, &self.pt, &q);
                self.em_labels = true;
            }
            return;
        }
        // label key: jump to the match carrying this label
        const ch = key.codepoint;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            for (self.em_matches) |m| {
                if (m.label == ch) {
                    self.cursor = m.pos;
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
        if (self.cursor == 0) return;
        const start = buffer.ops.prevCharStart(&self.pt, self.cursor);
        try self.history.record(&self.pt, start, self.cursor - start, "");
        self.cursor = start;
    }

    /// Delete the word before the cursor (Ctrl-w). Vim semantics: walk back
    /// over whitespace then word characters; deletes [start, cursor).
    fn deleteWordBefore(self: *App) !void {
        if (self.cursor == 0) return;
        const start = buffer.ops.wordStartBefore(&self.pt, self.cursor);
        if (start == self.cursor) return;
        try self.history.record(&self.pt, start, self.cursor - start, "");
        self.cursor = start;
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
                self.cmdline.clearRetainingCapacity();
                try self.execCommand(cmd);
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
            .buffer_next, .buffer_prev, .buffer_delete => try self.setMsg(try self.alloc.dupe(u8, "M0: single buffer")),
            .buffer_list => try self.setMsg(try self.alloc.dupe(u8, "M0: single buffer (1)")),
            .noh => try self.setMsg(try self.alloc.dupe(u8, "")),
            .set => |opt| try self.setMsg(try std.fmt.allocPrint(self.alloc, "set {s} (M0: accepted, no-op)", .{opt})),
            .unknown => try self.setMsg(try self.alloc.dupe(u8, "E492: Not an editor command")),
        }
    }

    fn setMsg(self: *App, owned: []u8) !void {
        if (self.msg) |m| self.alloc.free(m);
        self.msg = owned;
    }

    fn writeBuffer(self: *App) !void {
        const path = self.file_path orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E32: No file name"));
            return;
        };
        self.saveFile(path) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "write failed: {s}", .{@errorName(e)}));
            return;
        };
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "written: {s}", .{path}));
    }

    fn saveFile(self: *App, path: []const u8) !void {
        var f = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer f.close(self.io);
        const len = self.pt.len();
        const buf = try self.alloc.alloc(u8, len);
        defer self.alloc.free(buf);
        self.pt.copyRange(0, buf);
        try f.writeStreamingAll(self.io, buf);
    }

    fn openFile(self: *App, path: []const u8) !void {
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ path, @errorName(e) }));
            return;
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        const bytes = try self.alloc.alloc(u8, @intCast(size));
        defer self.alloc.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);

        self.pt.deinit();
        self.pt = try buffer.PieceTable.init(self.alloc, bytes);
        self.history.deinit();
        self.history = buffer.History.init(self.alloc); // undo history belongs to the buffer
        if (self.file_path) |p| self.alloc.free(p);
        self.file_path = try self.alloc.dupe(u8, path);
        self.cursor = 0;
        self.view_top = 0;
    }

    fn insertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.history.beginGroup();
            self.in_insert = true;
        }
        // record() snapshots the pre-edit state and applies the edit itself
        try self.history.record(&self.pt, self.cursor, 0, text);
        self.cursor += @intCast(text.len);
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
        if (sel == .inclusive_cursor and end < self.pt.len()) end += 1;
        if (end <= start) {
            if (op == .change) {
                self.state.mode = .insert;
                self.in_insert = true;
            }
            return;
        }
        switch (op) {
            .delete => {
                self.history.beginGroup();
                try self.history.record(&self.pt, start, end - start, "");
                self.history.endGroup();
                self.cursor = start;
            },
            .change => {
                self.cursor = start;
                self.history.beginGroup();
                try self.history.record(&self.pt, start, end - start, "");
                self.state.mode = .insert;
                self.in_insert = true; // keep the group open; exitInsert closes it
            },
            .yank => {
                if (self.yank_buffer) |b| self.alloc.free(b);
                const buf = try self.alloc.alloc(u8, end - start);
                self.pt.copyRange(start, buf);
                self.yank_buffer = buf;
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked {d} bytes", .{buf.len}));
            },
            else => {},
        }
    }

    fn isVisual(self: *const App) bool {
        return switch (self.state.mode) {
            .visual_char, .visual_line, .visual_block => true,
            else => false,
        };
    }

    fn exitVisual(self: *App) void {
        self.state.mode = .normal;
        self.visual_anchor = null;
    }

    fn execAction(self: *App, action: editor.KeyEvent.ActionId, count: u32) !void {
        _ = count;
        switch (action) {
            .undo => {
                if (self.in_insert) {
                    self.history.endGroup();
                    self.in_insert = false;
                }
                _ = self.history.undo(&self.pt);
                self.cursor = @min(self.cursor, self.pt.len());
            },
            .redo => {
                _ = self.history.redo(&self.pt);
                self.cursor = @min(self.cursor, self.pt.len());
            },
            .insert_mode => self.state.mode = .insert,
            .append => {
                // a: insert after the character under the cursor
                const line = self.pt.lineOf(self.cursor);
                const end = self.pt.lineStart(line) + self.pt.lineLen(line);
                if (self.cursor < end) {
                    var i = self.cursor + 1;
                    while (i < end and (self.pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                    self.cursor = i;
                }
                self.state.mode = .insert;
            },
            .insert_before => {
                // I: first non-blank of the line
                const line = self.pt.lineOf(self.cursor);
                const ls = self.pt.lineStart(line);
                const end = ls + self.pt.lineLen(line);
                var pos = ls;
                while (pos < end) {
                    const c = self.pt.byteAt(pos);
                    if (c != ' ' and c != '\t') break;
                    pos += 1;
                }
                self.cursor = pos;
                self.state.mode = .insert;
            },
            .append_end => {
                // A: end of the line
                const line = self.pt.lineOf(self.cursor);
                self.cursor = self.pt.lineStart(line) + self.pt.lineLen(line);
                self.state.mode = .insert;
            },
            .insert_line_after => {
                // o: new line below, cursor on it
                const line = self.pt.lineOf(self.cursor);
                const pos = self.pt.lineStart(line) + self.pt.lineLen(line);
                self.history.beginGroup();
                try self.history.record(&self.pt, pos, 0, "\n");
                self.history.endGroup();
                self.cursor = pos + 1;
                self.state.mode = .insert;
            },
            .insert_line_before => {
                // O: new line above, cursor on it
                const line = self.pt.lineOf(self.cursor);
                const pos = self.pt.lineStart(line);
                self.history.beginGroup();
                try self.history.record(&self.pt, pos, 0, "\n");
                self.history.endGroup();
                self.cursor = pos;
                self.state.mode = .insert;
            },
            .visual_char => {
                self.state.mode = .visual_char;
                self.visual_anchor = self.cursor;
            },
            .visual_line => {
                self.state.mode = .visual_line;
                self.visual_anchor = self.cursor;
            },
            .visual_block => {
                self.state.mode = .visual_block;
                self.visual_anchor = self.cursor;
            },
            .delete, .change, .yank => {
                // visual mode: the operator acts on the selection directly
                if (self.isVisual()) {
                    if (self.visual_anchor) |anchor| {
                        try self.applyOpRangeEx(action, anchor, self.cursor, false, .inclusive_cursor);
                    }
                    self.exitVisual();
                }
            },
            .paste => try self.pasteBuffer(false),
            .paste_before => try self.pasteBuffer(true),
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
        var pos = self.cursor;
        if (!before) {
            // p: after the character under the cursor (or at line end)
            const line = self.pt.lineOf(self.cursor);
            const line_end = self.pt.lineStart(line) + self.pt.lineLen(line);
            if (self.cursor < line_end) {
                var i = self.cursor + 1;
                while (i < line_end and (self.pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                pos = i;
            }
        }
        self.history.beginGroup();
        try self.history.record(&self.pt, pos, 0, buf);
        self.history.endGroup();
        self.cursor = pos + @as(u32, @intCast(buf.len));
    }

    // ---- rendering ----

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

        const cursor_line = self.pt.lineOf(self.cursor);
        const line_count = self.pt.lineCount();

        // keep cursor line visible, centered-ish
        if (self.cursor < self.pt.lineStart(self.view_top)) {
            self.view_top = cursor_line;
        }
        const view_bottom = self.view_top + content_rows;
        if (cursor_line >= view_bottom) {
            self.view_top = cursor_line - content_rows + 1;
        }
        if (self.view_top + content_rows > line_count and line_count > content_rows) {
            self.view_top = line_count - content_rows;
        }

        var row: u32 = 0;
        var line = self.view_top;
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

            const line_len = self.pt.lineLen(line);
            const line_start = self.pt.lineStart(line);
            const n: u32 = @min(line_len, win.width);
            const text = try a.alloc(u8, n);
            self.pt.copyRange(line_start, text);

            // visual selection highlight (M1: char-wise range; line/block
            // kinds reuse the char range)
            var segs: [4]vaxis.Segment = undefined;
            var nseg: usize = 0;
            segs[nseg] = .{ .text = num_str };
            nseg += 1;
            if (self.visual_anchor) |anchor| {
                const sel_start = @min(anchor, self.cursor);
                const sel_end = @max(anchor, self.cursor);
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
                .col_offset = 0,
                .wrap = .none,
            });
        }

        // easymotion labels: overwrite the matched cells with jump labels
        if (self.em_labels) {
            for (self.em_matches) |m| {
                const mline = self.pt.lineOf(m.pos);
                if (mline < self.view_top or mline >= self.view_top + content_rows) continue;
                const col_in_line = m.pos - self.pt.lineStart(mline);
                const label = try a.dupe(u8, &[_]u8{m.label});
                win.writeCell(@intCast(5 + col_in_line), @intCast(mline - self.view_top), .{
                    .char = .{ .grapheme = label, .width = 1 },
                    .style = .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bg = .{ .rgb = .{ 54, 74, 130 } } },
                });
            }
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
                .{ mode_str, cursor_line + 1, line_count, self.cursor - self.pt.lineStart(cursor_line), m },
            )
        else
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}",
                .{ mode_str, cursor_line + 1, line_count, self.cursor - self.pt.lineStart(cursor_line) },
            );
        const status_seg = [_]vaxis.Segment{.{
            .text = status,
            .style = .{ .fg = .{ .rgb = .{ 192, 202, 245 } }, .bg = .{ .rgb = .{ 41, 46, 66 } } },
        }};
        _ = win.print(&status_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });

        // cursor position
        const cursor_col = self.cursor - self.pt.lineStart(cursor_line);
        const cursor_row = cursor_line - self.view_top;
        self.vx.screen.cursor = .{
            .row = @intCast(cursor_row),
            .col = @intCast(5 + cursor_col), // 4-digit number + space gutter
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
            app.pt.deinit();
            app.pt = try buffer.PieceTable.init(app.alloc, bytes);
            if (app.file_path) |p| app.alloc.free(p);
            app.file_path = try app.alloc.dupe(u8, file_path);
        }
        break; // M0: first file only
    }
    if (target_line > 0) {
        app.cursor = app.pt.lineStart(@min(target_line - 1, app.pt.lineCount() - 1));
    }

    try app.run();
}
