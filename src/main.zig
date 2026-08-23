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
    }

    // ---- input ----

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // TEMP(M0): quit until command mode lands (vim: :q)
        if (self.state.mode == .normal and key.codepoint == 'q' and key.mods.ctrl == false and key.mods.alt == false) {
            self.quit = true;
            return;
        }

        // Insert mode: characters insert directly (jk handled via Mode).
        if (self.state.mode == .insert) {
            if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
                self.state.mode = .normal;
                self.history.endGroup();
                self.in_insert = false;
                return;
            }
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
                // M0: d/c/y over [cursor, target)
                const target_pos = editor.Motion.target(&self.pt, m.motion, m.args, self.cursor, m.count);
                switch (m.op) {
                    .delete => try self.deleteRange(self.cursor, target_pos, m.exclusive_end),
                    else => {}, // change/yank wired in later milestones
                }
            },
            .command_mode => {
                // M0: no command line yet; swallow ':'
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

    fn insertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.history.beginGroup();
            self.in_insert = true;
        }
        // record() snapshots the pre-edit state and applies the edit itself
        try self.history.record(&self.pt, self.cursor, 0, text);
        self.cursor += @intCast(text.len);
    }

    fn deleteRange(self: *App, from: u32, to: u32, exclusive: bool) !void {
        const start = @min(from, to);
        var end = @max(from, to);
        if (exclusive and end > start) end -= 1;
        if (end <= start) return;
        self.history.beginGroup();
        try self.history.record(&self.pt, start, end - start, "");
        self.history.endGroup();
        self.cursor = start;
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
            .insert_mode, .append, .insert_before, .append_end, .insert_line_after, .insert_line_before => {
                self.state.mode = .insert;
            },
            .visual_char => self.state.mode = .visual_char,
            .visual_line => self.state.mode = .visual_line,
            .visual_block => self.state.mode = .visual_block,
            .enter_command_mode => {},
            else => {},
        }
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

            const segs = [_]vaxis.Segment{
                .{ .text = num_str },
                .{ .text = text },
            };
            _ = win.print(&segs, .{
                .row_offset = @intCast(row),
                .col_offset = 0,
                .wrap = .none,
            });
        }

        // status bar
        const mode_str = switch (self.state.mode) {
            .normal => " NORMAL ",
            .insert => " INSERT ",
            .visual_char, .visual_line, .visual_block => " VISUAL ",
            .command => " COMMAND ",
        };
        const status = try std.fmt.allocPrint(
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
            var file = std.Io.Dir.openFileAbsolute(app.io, file_path, .{ .mode = .read_only }) catch continue;
            defer file.close(app.io);
            const size = (try file.stat(app.io)).size;
            const bytes = try app.alloc.alloc(u8, @intCast(size));
            defer app.alloc.free(bytes);
            _ = try file.readPositionalAll(app.io, bytes, 0);
            app.pt.deinit();
            app.pt = try buffer.PieceTable.init(app.alloc, bytes);
        }
        break; // M0: first file only
    }
    if (target_line > 0) {
        app.cursor = app.pt.lineStart(@min(target_line - 1, app.pt.lineCount() - 1));
    }

    try app.run();
}
