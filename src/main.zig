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
const syntax = @import("syntax.zig");

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

    // tree-sitter syntax highlighting (src/syntax.zig). The highlighter
    // lives here (not in Buffer) so switching buffers just invalidates it.
    syntax_hl: ?syntax.Highlighter = null,
    /// Filetype the highlighter was built (or attempted) for. Remembered even
    /// on init failure so we don't retry the failed language every frame.
    syntax_ft: []const u8 = "",
    /// Buffer text changed since the last parse → reparse on next render.
    syntax_dirty: bool = true,
    /// history.revision at the last parse — incremental-parse bookkeeping.
    syntax_revision: u64 = 0,

    // file tree (<leader>e)
    filetree_active: bool = false,
    filetree_sel: usize = 0,
    /// Scroll-window top for the sidebar: the selection moves freely inside
    /// the window; the window scrolls only when it crosses an edge.
    filetree_top: usize = 0,
    /// Window focus (vim Ctrl-w hjkl): which pane receives hjkl — the
    /// file-tree sidebar or the buffer. The sidebar keeps rendering either
    /// way; only the focused pane reacts to keys.
    focus: enum { buffer, filetree } = .buffer,
    /// Ctrl-w seen, awaiting the window-motion key (h/l/j/k).
    pending_window: bool = false,
    /// Content hash at insert-session entry, so an insert session that ends
    /// with no net change can clear the dirty flag ("typed then deleted it
    /// all back" must not mark the buffer modified).
    insert_base_hash: u64 = 0,
    insert_was_dirty: bool = false,
    filetree_files: std.ArrayList([]u8) = .empty,

    // fuzzy picker (<leader>sf / <leader>st / <leader>sb / <leader>sr)
    picker_mode: enum { files, grep, buffers, recent } = .files,
    picker_active: bool = false,
    picker_files: std.ArrayList([]u8) = .empty, // owned paths
    picker_input: std.ArrayList(u8) = .empty,
    picker_matches: std.ArrayList(usize) = .empty, // indices into picker_files
    picker_sel: usize = 0,
    /// Scroll-window top for the picker list (same semantics as filetree_top).
    picker_top: usize = 0,
    // grep mode: one result per line from rg
    grep_results: std.ArrayList(GrepResult) = .empty,

    // insert-mode keyword completion (Ctrl+n)
    completion_active: bool = false,
    completion_words: std.ArrayList([]u8) = .empty, // owned candidate words
    completion_sel: usize = 0,
    /// Start of the word being typed when the menu opened; Enter replaces
    /// [completion_pos, cursor) with the selected word.
    completion_pos: u32 = 0,

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
        if (self.syntax_hl) |*h| h.deinit();
        for (self.picker_files.items) |f| self.alloc.free(f);
        self.picker_files.deinit(self.alloc);
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.deinit(self.alloc);
        self.picker_input.deinit(self.alloc);
        self.picker_matches.deinit(self.alloc);
        for (self.completion_words.items) |w| self.alloc.free(w);
        self.completion_words.deinit(self.alloc);
    }

    // ---- input ----

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // Command mode first: while the ':' command line is open, Enter/Esc
        // and the rest must reach it — the file-tree and picker overlays
        // would otherwise swallow Enter (opening a file / confirming) and
        // :q could never execute.
        if (self.state.mode == .command) {
            try self.handleCommandKey(key);
            return;
        }

        // Fuzzy picker input — the picker is a modal overlay, so its keys
        // must win over the file-tree sidebar (which sits behind it).
        if (self.picker_active) {
            try self.handlePickerKey(key);
            return;
        }

        // Ctrl-w window commands: switch keyboard focus between the file-tree
        // sidebar and the buffer (vim window navigation). Not in insert mode
        // — there Ctrl+w still deletes the word before the cursor.
        if (key.codepoint == 'w' and key.mods.ctrl and self.state.mode != .insert) {
            self.pending_window = true;
            return;
        }
        if (self.pending_window) {
            self.pending_window = false;
            if (key.codepoint == vaxis.Key.escape) return;
            switch (key.codepoint) {
                'h', 'l', 'j', 'k' => {
                    if (self.filetree_active) {
                        self.focus = if (self.focus == .filetree) .buffer else .filetree;
                    }
                },
                else => {},
            }
            return;
        }

        // File tree navigation (j/k/Enter/Esc); other keys fall through.
        // Only the focused pane reacts: with buffer focus the sidebar stays
        // visible but hjkl move the buffer cursor.
        if (self.filetree_active and self.focus == .filetree) {
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

        // Esc cancels an active multi-cursor selection (word cursors). In
        // insert mode Esc exits the insert session instead (see below).
        if (self.mc_active and self.state.mode != .insert and key.codepoint == vaxis.Key.escape) {
            self.mc.clear();
            self.mc_active = false;
            return;
        }

        // 'd' with an active multi-cursor selection deletes the selected word
        // at every cursor (normal-mode 'd' would pend for a motion instead);
        // cursors sit at word starts, so the word is [pos, pos+wlen)
        if (self.mc_active and self.state.mode != .insert and key.codepoint == 'd' and !key.mods.ctrl and !key.mods.alt) {
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

        // 'n' with an active multi-cursor selection extends the selection:
        // add the next matching word — the plain-key twin of Ctrl+n (which
        // carries mods.ctrl and is handled by the keymap as .mc_add).
        if (self.mc_active and self.state.mode != .insert and !self.isVisual() and
            key.codepoint == 'n' and !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.mcSelectNext();
            return;
        }

        // 'c' with an active multi-cursor selection changes every selected
        // word: delete each word and enter insert mode with the cursors on
        // the word-start slots; every typed key then applies at all cursors
        // via handleMcInsertKey (like visual-block I/A insert).
        if (self.mc_active and self.state.mode != .insert and !self.isVisual() and
            key.codepoint == 'c' and !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.mcChangeWords();
            return;
        }

        // Visual block (<C-v>) then I/A: fan one insert cursor out per line
        // of the block and enter insert mode (vim visual-block insert).
        // Intercepted before the mode state machine, whose I/A would only
        // move the single main cursor.
        if (self.state.mode == .visual_block and self.visual_anchor != null and
            (key.codepoint == 'I' or key.codepoint == 'A') and
            !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.blockInsert(key.codepoint == 'A');
            return;
        }

        // Insert mode: characters insert directly; jk exits (removing the
        // just-typed 'j'), backspace and Ctrl-w delete before the cursor.
        if (self.state.mode == .insert) {
            // Visual-block multi-cursor insert (I/A after <C-v>): every key
            // applies at every cursor. The single-cursor path below is
            // unchanged.
            if (self.mc_active) {
                try self.handleMcInsertKey(key);
                return;
            }
            // ---- insert-mode keyword completion (Ctrl+n) ----
            // Esc while the menu is open only dismisses it (stays in insert);
            // a second Esc exits the insert session as usual.
            if (self.completion_active and key.codepoint == vaxis.Key.escape) {
                self.closeCompletion();
                return;
            }
            // Ctrl+n: next candidate when the menu is open; otherwise collect
            // candidates and open the menu — but only when the cursor is
            // inside a word. Without a word prefix the key is swallowed.
            if (key.codepoint == 'n' and key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                if (self.completion_active) {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + 1) % n;
                } else {
                    try self.startCompletion();
                }
                return;
            }
            if (self.completion_active) {
                // Ctrl+p / ↑: previous candidate; ↓: next candidate
                if ((key.codepoint == 'p' and key.mods.ctrl and !key.mods.alt and !key.mods.super) or
                    key.codepoint == vaxis.Key.up)
                {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + n - 1) % n;
                    return;
                }
                if (key.codepoint == vaxis.Key.down) {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + 1) % n;
                    return;
                }
                // Enter / Tab: accept the selected word (replaces the typed
                // prefix), overriding the default newline / tab insert.
                if (key.codepoint == vaxis.Key.enter or key.codepoint == vaxis.Key.tab) {
                    try self.acceptCompletion();
                    return;
                }
                // anything else (typing, backspace, Ctrl+w, j/k, Ctrl+c…):
                // dismiss the menu, then fall through to the normal insert
                // handling so jk exit, Esc exit and text entry behave as usual.
                self.closeCompletion();
            }
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
            if (key.codepoint == vaxis.Key.enter) {
                try self.insertNewline();
                return;
            }
            if (key.codepoint == 'k' and key.mods.ctrl) {
                try self.deleteToEol();
                return;
            }
            if (key.codepoint == vaxis.Key.backspace) {
                try self.deleteBeforeCursor();
                return;
            }
            if (key.codepoint == 'w' and key.mods.ctrl) {
                try self.deleteWordBefore();
                return;
            }
            // Tab: insert indentation. Spaces, not a literal tab: a \t is a
            // terminal control character whose display width differs between
            // the terminal and vaxis's cell grid (causing the cursor/char
            // misalignment bug). vim default without expandtab is a tab, but
            // spaces are predictable here (M1).
            if (key.codepoint == vaxis.Key.tab) {
                self.prev_insert_key = key;
                try self.insertText("    ");
                return;
            }
            // Alt+b / Alt+f: emacs word motion. Pure cursor movement — no
            // text change, and prev_insert_key stays untouched (the jk exit
            // and backspace paths must not see these). vaxis parses ESC+b/f
            // as codepoint 'b'/'f' with mods.alt.
            if (key.mods.alt and !key.mods.ctrl and !key.mods.super) {
                if (key.codepoint == 'b') {
                    self.cur().cursor = buffer.ops.wordStartBefore(&self.cur().pt, self.cur().cursor);
                    return;
                }
                if (key.codepoint == 'f') {
                    var c = self.cur().cursor;
                    editor.Motion.apply(&self.cur().pt, .word_next_end, .{}, &c, 1);
                    self.cur().cursor = c;
                    return;
                }
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
                // dd / cc / yy: motion == .line_start + exclusive_end == false is
                // the whole-line sentinel (see mode.zig Result docs; d^ is
                // .line_start with exclusive_end == true, so unambiguous). Must
                // delete/change/yank `count` whole lines, not [cursor, line start).
                if (m.motion == .line_start and !m.exclusive_end) {
                    const line = self.cur().pt.lineOf(self.cur().cursor);
                    const n = @max(m.count, 1);
                    const start_line = @min(line, self.cur().pt.lineCount() - 1);
                    const end_line = @min(start_line + n - 1, self.cur().pt.lineCount() - 1);
                    const start = self.cur().pt.lineStart(start_line);
                    var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
                    if (end_line + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
                    try self.applyOpRange(m.op, start, end, false);
                    return;
                }
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
                // From visual mode vim auto-types :'<,'>; :s then applies to
                // the selection (the anchor survives until Enter).
                if (self.visual_anchor != null) {
                    try self.cmdline.appendSlice(self.alloc, "'<,'>");
                }
            },
            .to_normal => {
                self.state.mode = .normal;
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
                // Esc from visual mode must clear the selection anchor, or
                // the render loop keeps painting the stale selection
                // highlight (anchor is null on the insert-exit path anyway).
                self.visual_anchor = null;
            },
        }
    }

    fn exitInsert(self: *App) void {
        self.state.mode = .normal;
        self.cur().history.endGroup();
        self.in_insert = false;
        self.prev_insert_key = null;
        self.endInsertSession();
        // Force a full reparse on the next render: incremental edits during
        // the insert session may have drifted the highlight tree (the "some
        // characters turn comment-gray after jk" bug). A full reparse on
        // every insert exit guarantees correct colors once back in normal.
        self.syntax_dirty = true;
        self.syntax_revision = std.math.maxInt(u64);
    }

    // ---- visual-block multi-cursor insert (<C-v> block then I/A) ----

    /// I/A after a Ctrl+v block: place one insert cursor per line of the
    /// block and enter insert mode. I puts each cursor at the block's left
    /// edge; A (append) puts them one column past the block's right edge
    /// (vim: the right edge is the last selected column, so +1 inserts right
    /// after the selection's rightmost character). Both clamp to the end of
    /// the line, so short/empty lines get their cursor at end-of-line.
    /// The anchor line's cursor is added first so it becomes the main one.
    fn blockInsert(self: *App, append: bool) !void {
        const anchor = self.visual_anchor orelse return;
        const pt = &self.cur().pt;
        const a_line = pt.lineOf(anchor);
        const c_line = pt.lineOf(self.cur().cursor);
        const min_line = @min(a_line, c_line);
        const max_line = @max(a_line, c_line);
        const a_col = anchor - pt.lineStart(a_line);
        const c_col = self.cur().cursor - pt.lineStart(c_line);
        const left_col = @min(a_col, c_col);
        const right_col = @max(a_col, c_col);

        self.mc.clear();
        const anchor_col: u32 = if (append)
            @min(right_col + 1, pt.lineLen(a_line))
        else
            @min(left_col, pt.lineLen(a_line));
        _ = try self.mc.add(pt.lineStart(a_line) + anchor_col);
        var line = min_line;
        while (line <= max_line) : (line += 1) {
            if (line == a_line) continue;
            const col: u32 = if (append)
                @min(right_col + 1, pt.lineLen(line))
            else
                @min(left_col, pt.lineLen(line));
            _ = try self.mc.add(pt.lineStart(line) + col);
        }
        self.mc_active = true;
        self.visual_anchor = null; // the selection is consumed by I/A
        self.state.mode = .insert;
        // open the undo group immediately: the first key (backspace or
        // typing) must join the same session group
        self.cur().history.beginGroup();
        self.in_insert = true;
        self.prev_insert_key = null;
        self.mcSyncCursor();
    }

    /// Insert-mode keys with an active visual-block multi-cursor selection.
    /// Mirrors the single-cursor insert path, but every edit applies at every
    /// cursor (one history.record per cursor, right-to-left so the earlier
    /// positions stay valid) and the whole session lives in one undo group.
    fn handleMcInsertKey(self: *App, key: vaxis.Key) !void {
        // Esc / Ctrl-c: exit, one main cursor remains
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.exitMcInsert();
            return;
        }
        // jk → drop the just-typed 'j' at every cursor, then exit
        if (self.prev_insert_key) |p| {
            if (p.codepoint == 'j' and key.codepoint == 'k' and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super)
            {
                var i = self.mc.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const pos = self.mc.cursors.items[i];
                    if (pos > 0 and self.cur().pt.byteAt(pos - 1) == 'j') {
                        try self.cur().history.record(&self.cur().pt, pos - 1, 1, "");
                        // the deletion shifts every cursor at/after it back
                        for (self.mc.cursors.items[i..]) |*c| c.* -= 1;
                    }
                }
                self.exitMcInsert();
                return;
            }
        }
        // Enter at every cursor: insert a newline at each one. (No
        // indentation carry-over — M1 keeps the multi-cursor path simple.
        // Ctrl+k / Alt+b / Alt+f are intentionally not handled here.)
        if (key.codepoint == vaxis.Key.enter) {
            try self.mcInsertText("\n");
            return;
        }
        if (key.codepoint == vaxis.Key.backspace) {
            try self.mcBackspace();
            return;
        }
        if (key.codepoint == 'w' and key.mods.ctrl) {
            try self.mcDeleteWordBefore();
            return;
        }
        self.prev_insert_key = key;
        if (key.text) |text| {
            try self.mcInsertText(text);
        }
    }

    /// Insert `text` at every visual-block cursor. One history.record per
    /// cursor, applied right-to-left so earlier positions stay valid; every
    /// cursor at or after an insertion point moves forward by `text.len`
    /// (mirrors MultiCursor.applyInsert, but each edit lands in history).
    fn mcInsertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const tlen: u32 = @intCast(text.len);
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            try self.cur().history.record(&self.cur().pt, pos, 0, text);
            for (self.mc.cursors.items[i..]) |*c| c.* += tlen;
        }
        self.mcSyncCursor();
        self.markDirty();
    }

    /// Backspace at every visual-block cursor: delete one character before
    /// each cursor (right-to-left); cursors at/after a deletion shift back,
    /// ones inside its range clamp to its start.
    fn mcBackspace(self: *App) !void {
        // safety net: the deletion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            if (pos == 0) continue;
            const start = buffer.ops.prevCharStart(&self.cur().pt, pos);
            const del = pos - start;
            try self.cur().history.record(&self.cur().pt, start, del, "");
            var j: usize = 0;
            while (j < self.mc.cursors.items.len) : (j += 1) {
                const c = self.mc.cursors.items[j];
                if (c < start) continue;
                self.mc.cursors.items[j] = if (c >= pos) c - del else start;
            }
        }
        self.mcSyncCursor();
    }

    /// Ctrl-w at every visual-block cursor: delete the word before each
    /// cursor (right-to-left); cursors shift like backspace.
    fn mcDeleteWordBefore(self: *App) !void {
        // safety net: the deletion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            if (pos == 0) continue;
            const start = buffer.ops.wordStartBefore(&self.cur().pt, pos);
            if (start == pos) continue;
            const del = pos - start;
            try self.cur().history.record(&self.cur().pt, start, del, "");
            var j: usize = 0;
            while (j < self.mc.cursors.items.len) : (j += 1) {
                const c = self.mc.cursors.items[j];
                if (c < start) continue;
                self.mc.cursors.items[j] = if (c >= pos) c - del else start;
            }
        }
        self.mcSyncCursor();
    }

    /// Exit a visual-block multi-cursor insert session: close the undo group,
    /// drop the extra cursors and leave a single main cursor (the block's
    /// anchor-line cursor) in normal mode.
    fn exitMcInsert(self: *App) void {
        self.mcSyncCursor();
        self.mc.clear();
        self.mc_active = false;
        self.state.mode = .normal;
        self.cur().history.endGroup();
        self.in_insert = false;
        self.prev_insert_key = null;
        self.endInsertSession();
        self.syntax_dirty = true;
        self.syntax_revision = std.math.maxInt(u64);
    }

    /// Keep the visible (main) cursor on the main multi-cursor's position.
    fn mcSyncCursor(self: *App) void {
        if (self.mc.len() > 0) self.cur().cursor = self.mc.cursors.items[self.mc.main];
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
        // safety net: make sure the insert-session group is open even if a
        // future entry path forgets to open it (backspace is a deletion, and
        // history.record would otherwise auto-open/close its own group)
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const start = buffer.ops.prevCharStart(&self.cur().pt, self.cur().cursor);
        try self.cur().history.record(&self.cur().pt, start, self.cur().cursor - start, "");
        self.cur().cursor = start;
        self.markDirty();
    }

    /// Delete the word before the cursor (Ctrl-w). Vim semantics: walk back
    /// over whitespace then word characters; deletes [start, cursor).
    fn deleteWordBefore(self: *App) !void {
        if (self.cur().cursor == 0) return;
        const start = buffer.ops.wordStartBefore(&self.cur().pt, self.cur().cursor);
        if (start == self.cur().cursor) return;
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        try self.cur().history.record(&self.cur().pt, start, self.cur().cursor - start, "");
        self.cur().cursor = start;
        self.markDirty();
    }

    // ---- insert-mode keyword completion (Ctrl+n) ----

    /// Word characters for keyword completion: [a-zA-Z0-9_] plus any
    /// non-ASCII byte (mirrors editor/multicursor.zig's classification).
    fn isWordByte(b: u8) bool {
        return (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '_' or
            b >= 0x80;
    }

    /// Ctrl+n in insert mode with the cursor inside a word: collect keyword
    /// candidates from the whole buffer and open the completion menu. Without
    /// a word prefix the key is swallowed (no candidates, no side effect).
    fn startCompletion(self: *App) !void {
        if (self.completion_active) return;
        if (self.cur().cursor == 0) return;
        if (!isWordByte(self.cur().pt.byteAt(self.cur().cursor - 1))) return;
        try self.collectCompletionWords();
        if (self.completion_words.items.len > 0) {
            self.completion_active = true;
            self.completion_sel = 0;
        }
    }

    /// Scan the whole buffer for words and fill completion_words with the
    /// most frequent ones (ties broken alphabetically), capped at 20. The
    /// word currently being typed (from completion_pos to the cursor) is
    /// excluded from the candidates.
    fn collectCompletionWords(self: *App) !void {
        const pt = &self.cur().pt;
        const cursor = self.cur().cursor;
        // start of the word under/behind the cursor — the replacement anchor
        var pos = cursor;
        while (pos > 0 and isWordByte(pt.byteAt(pos - 1))) pos -= 1;
        if (pos == cursor) return; // cursor not inside a word
        self.completion_pos = pos;
        const typed_len = cursor - pos;
        const typed = try self.alloc.alloc(u8, typed_len);
        defer self.alloc.free(typed);
        if (typed_len > 0) pt.copyRange(pos, typed);

        var counts = std.StringHashMap(u32).init(self.alloc);
        defer {
            var it = counts.iterator();
            while (it.next()) |e| self.alloc.free(e.key_ptr.*);
            counts.deinit();
        }

        // Scan the document in chunks, stitching words that straddle a chunk
        // boundary: the word bytes are accumulated in `pending` until a
        // non-word byte ends them.
        var pending = std.ArrayList(u8).empty;
        defer pending.deinit(self.alloc);
        var chunk: [4096]u8 = undefined;
        var off: u32 = 0;
        const doc_len = pt.len();
        while (off < doc_len) {
            const n: usize = @intCast(@min(chunk.len, doc_len - off));
            pt.copyRange(off, chunk[0..n]);
            var i: usize = 0;
            while (i < n) {
                if (isWordByte(chunk[i])) {
                    var j = i;
                    while (j < n and isWordByte(chunk[j])) j += 1;
                    try pending.appendSlice(self.alloc, chunk[i..j]);
                    if (j == n) break; // may continue on the next chunk
                    try self.countCompletionWord(&counts, pending.items, typed);
                    pending.clearRetainingCapacity();
                    i = j;
                } else {
                    if (pending.items.len > 0) {
                        try self.countCompletionWord(&counts, pending.items, typed);
                        pending.clearRetainingCapacity();
                    }
                    i += 1;
                }
            }
            off += @intCast(n);
        }
        // a word running to the end of the document
        if (pending.items.len > 0) {
            try self.countCompletionWord(&counts, pending.items, typed);
            pending.clearRetainingCapacity();
        }

        // (word, count) pairs, sorted by count desc then word asc
        const Pair = struct { word: []const u8, count: u32 };
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(self.alloc);
        {
            var it = counts.iterator();
            while (it.next()) |e| {
                try pairs.append(self.alloc, .{ .word = e.key_ptr.*, .count = e.value_ptr.* });
            }
        }
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.word, b.word);
            }
        }.lt);

        const max_words: usize = 20;
        const limit = @min(max_words, pairs.items.len);
        try self.completion_words.ensureTotalCapacity(self.alloc, limit);
        errdefer {
            for (self.completion_words.items) |owned| self.alloc.free(owned);
            self.completion_words.clearRetainingCapacity();
        }
        var k: usize = 0;
        while (k < limit) : (k += 1) {
            const w = try self.alloc.dupe(u8, pairs.items[k].word);
            try self.completion_words.append(self.alloc, w);
        }
        self.completion_sel = 0;
    }

    /// Count one occurrence of `word` (skipping the word currently being
    /// typed). StringHashMap does not copy keys, and the scan buffers are
    /// reused, so keys are duplicated — the pending buffer can be overwritten
    /// by the very next word.
    fn countCompletionWord(self: *App, counts: *std.StringHashMap(u32), word: []const u8, typed: []const u8) !void {
        // prefix filter: only words starting with the typed prefix are
        // candidates (vim C-n keyword completion); the exact typed word is
        // excluded
        if (word.len < typed.len or !std.mem.startsWith(u8, word, typed)) return;
        if (word.len == typed.len and std.mem.eql(u8, word, typed)) return;
        // fast path: word already counted — no allocation
        if (counts.getPtr(word)) |p| {
            p.* += 1;
            return;
        }
        const key = try self.alloc.dupe(u8, word);
        errdefer self.alloc.free(key);
        const gop = try counts.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            self.alloc.free(key); // duplicate of an existing key — drop ours
            gop.value_ptr.* += 1;
        }
    }

    /// Enter/Tab while the menu is open: replace the typed prefix
    /// [completion_pos, cursor) with the selected word — one edit inside the
    /// open insert-session undo group — then close the menu (insert stays
    /// active, the session continues).
    fn acceptCompletion(self: *App) !void {
        if (self.completion_words.items.len == 0 or self.completion_sel >= self.completion_words.items.len) {
            self.closeCompletion();
            return;
        }
        const word = self.completion_words.items[self.completion_sel];
        const pt = &self.cur().pt;
        const cursor = self.cur().cursor;
        const pos = @min(self.completion_pos, cursor);
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        try self.cur().history.record(pt, pos, cursor - pos, word);
        self.cur().cursor = pos + @as(u32, @intCast(word.len));
        self.markDirty();
        self.closeCompletion();
    }

    /// Drop the completion menu and free its candidate words (the list keeps
    /// its capacity for the next trigger).
    fn closeCompletion(self: *App) void {
        if (!self.completion_active and self.completion_words.items.len == 0) return;
        for (self.completion_words.items) |w| self.alloc.free(w);
        self.completion_words.clearRetainingCapacity();
        self.completion_active = false;
        self.completion_sel = 0;
        self.completion_pos = 0;
    }

    /// Enter in insert mode (vim semantics): split the current line at the
    /// cursor and carry the original line's leading indentation (the run of
    /// spaces/tabs before the cursor) over to the new line. The cursor lands
    /// right after the carried indentation (insertText advances it). Done as
    /// one edit so it is a single undo step.
    fn insertNewline(self: *App) !void {
        // safety net: the '\n' insertion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const pt = &self.cur().pt;
        const cursor = self.cur().cursor;
        const line = pt.lineOf(cursor);
        const line_start = pt.lineStart(line);
        const col = cursor - line_start;
        // leading indentation of the original line, capped at the cursor
        var indent_end: u32 = 0;
        while (indent_end < col) : (indent_end += 1) {
            const b = pt.byteAt(line_start + indent_end);
            if (b != ' ' and b != '\t') break;
        }
        const indent = try self.alloc.alloc(u8, @intCast(indent_end));
        defer self.alloc.free(indent);
        pt.copyRange(line_start, indent);
        const text = try std.fmt.allocPrint(self.alloc, "\n{s}", .{indent});
        defer self.alloc.free(text);
        try self.insertText(text);
    }

    /// Ctrl+k in insert mode (emacs kill-line): delete from the cursor to the
    /// end of the line. When the cursor is already at the end of the line,
    /// delete the trailing newline instead, joining the next line (no-op on
    /// the last line).
    fn deleteToEol(self: *App) !void {
        // safety net: the kill must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const pt = &self.cur().pt;
        const cursor = self.cur().cursor;
        const line = pt.lineOf(cursor);
        const line_start = pt.lineStart(line);
        const line_end = line_start + pt.lineLen(line);
        if (cursor < line_end) {
            try self.cur().history.record(pt, cursor, line_end - cursor, "");
        } else if (line_end < pt.len()) {
            // at end of line: swallow the trailing newline (joins next line)
            try self.cur().history.record(pt, line_end, 1, "");
        } else {
            return; // last line, nothing to delete
        }
        self.markDirty();
    }

    // ---- command line (':') ----

    fn handleCommandKey(self: *App, key: vaxis.Key) !void {
        // cancel
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.state.mode = .normal;
            // Esc cancelling ':' from visual mode must drop the anchor too
            // (it was kept so :'<,'>s could resolve the range on Enter).
            self.visual_anchor = null;
            self.cmdline.clearRetainingCapacity();
            self.cmd_hist_idx = null;
            return;
        }
        switch (key.codepoint) {
            vaxis.Key.enter => {
                const from_visual = self.visual_anchor != null;
                const line = self.cmdline.items;
                const cmd = editor.ex_command.parse(line);
                if (cmd != .empty) try self.pushHistory(line);
                self.state.mode = .normal;
                self.cmd_hist_idx = null;
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

    /// :s/pat/rep[/g] — literal substitution on the current line, the whole
    /// file (:%), or the visual selection (:'<,'>, M1: no regex). The
    /// replacement lands in one undo group.
    fn execSubstitute(self: *App, sub: anytype) !void {
        var start_line: u32 = undefined;
        var end_line: u32 = undefined;
        if (sub.visual) {
            const anchor = self.visual_anchor orelse return;
            const s = @min(anchor, self.cur().cursor);
            const e = @max(anchor, self.cur().cursor);
            start_line = self.cur().pt.lineOf(s);
            end_line = self.cur().pt.lineOf(e);
        } else if (sub.whole_file) {
            start_line = 0;
            end_line = self.cur().pt.lineCount() - 1;
        } else {
            start_line = self.cur().pt.lineOf(self.cur().cursor);
            end_line = start_line;
        }

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
                // empty range (e.g. cc on an empty line): enter insert with
                // the undo group already open so typing joins one session
                self.cur().history.beginGroup();
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
                self.syntax_dirty = true;
                self.syntax_revision = std.math.maxInt(u64);
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

    /// 'c' with an active multi-cursor selection: delete the word under every
    /// cursor (right-to-left, so earlier positions stay valid) and enter
    /// insert mode with the cursors still on their word-start slots. Cursors
    /// at/after each deleted range shift back so every position stays valid
    /// (unlike the 'd' path — 'd' clears the cursors, 'c' keeps them for the
    /// synchronized insert session via handleMcInsertKey). The deletion is
    /// one undo group; typing opens the next one.
    fn mcChangeWords(self: *App) !void {
        const pt = &self.cur().pt;
        self.cur().history.beginGroup();
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            const w = self.mc.wordRange(pt, pos);
            if (w.end <= w.start) continue; // no word at this cursor → skip it
            const wlen = w.end - w.start;
            try self.cur().history.record(pt, pos, wlen, "");
            // shift every other cursor at/after the deleted range back; the
            // cursor at `pos` (a word start) stays put
            for (self.mc.cursors.items, 0..) |*c, j| {
                if (j == i) continue;
                if (c.* >= pos + wlen) {
                    c.* -= wlen;
                } else if (c.* > pos) {
                    c.* = pos; // inside the deleted word — clamp (never happens)
                }
            }
        }
        self.cur().history.endGroup();
        self.mc_active = true; // stays active: the insert session is synchronized
        self.state.mode = .insert;
        // open the insert-session group immediately (deletes or typing first);
        // the word deletions above are their own group (undo reverts typing
        // first, then the deletions — same as before)
        self.cur().history.beginGroup();
        self.in_insert = true;
        self.prev_insert_key = null;
        self.mcSyncCursor();
        self.markDirty();
    }

    // ---- file tree (<leader>e / <leader>E) ----

    fn toggleFiletree(self: *App) !void {
        if (self.filetree_active) {
            self.filetree_active = false;
            return;
        }
        self.filetree_top = 0;
        self.filetree_sel = 0;
        self.focus = .filetree;
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
        self.focus = .filetree;
        if (self.cur().path) |p| {
            for (self.filetree_files.items, 0..) |f, i| {
                if (std.mem.eql(u8, f, p)) {
                    self.filetree_sel = i;
                    self.filetree_top = 0;
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
            // h/l: no tree expansion/collapse in M1 — swallow so they don't
            // fall through to the buffer (pane switching is Ctrl-w hjkl).
            // 'h' deliberately does NOT close the tree.
            'h', 'l', vaxis.Key.left, vaxis.Key.right => return true,
            vaxis.Key.enter => {
                if (self.filetree_files.items.len > 0) {
                    const f = self.filetree_files.items[self.filetree_sel];
                    self.filetree_active = false;
                    self.focus = .buffer;
                    try self.openFile(f);
                }
                return true;
            },
            vaxis.Key.escape => {
                self.filetree_active = false;
                self.focus = .buffer;
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
        self.picker_top = 0;
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

    fn openBufferPicker(self: *App) !void {
        self.picker_mode = .buffers;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn openRecentPicker(self: *App) !void {
        self.picker_mode = .recent;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn bufferName(self: *const App, i: usize) []const u8 {
        const buf = &self.buffers.items[i];
        return if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
    }

    fn openGrepPicker(self: *App) !void {
        self.picker_mode = .grep;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
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
                // Confirming jumps into the target file: leave the file-tree
                // navigation mode so j/k/↑↓ control the buffer afterwards
                // (vim: picker confirm drops focus back to the buffer).
                self.filetree_active = false;
                self.focus = .buffer;
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
                self.alloc.free(self.recent_files.orderedRemove(i));
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
        // leaving the buffer invalidates any visual selection from it
        // (gt / :bn / :e / picker-enter all land here, some without the
        // command-line exitVisual fallback)
        self.visual_anchor = null;
        self.in_insert = false;
        self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
        // the highlighter tree belongs to the old buffer: force a full
        // reparse (revision sentinel makes the incremental check fail)
        self.syntax_dirty = true;
        self.syntax_revision = std.math.maxInt(u64);
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
        // closing the buffer also discards a visual selection anchored in it
        self.visual_anchor = null;
        self.in_insert = false;
        self.syntax_dirty = true;
        self.syntax_revision = std.math.maxInt(u64);
    }

    /// FNV-1a hash of the current buffer content (for dirty detection).
    fn contentHash(self: *App) u64 {
        var h: u64 = 0xcbf29ce484222325;
        var buf: [4096]u8 = undefined;
        var off: u32 = 0;
        const len = self.cur().pt.len();
        while (off < len) {
            const n: u32 = @intCast(@min(buf.len, len - off));
            self.cur().pt.copyRange(off, buf[0..n]);
            for (buf[0..n]) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            off += n;
        }
        return h;
    }

    /// Called when an insert session begins (all entry paths).
    fn beginInsertSession(self: *App) void {
        self.insert_base_hash = self.contentHash();
        self.insert_was_dirty = self.cur().dirty;
    }

    /// Called when an insert session ends (exitInsert / exitMcInsert): a
    /// session with zero net change clears the dirty flag.
    fn endInsertSession(self: *App) void {
        const now = self.contentHash();
        if (!self.insert_was_dirty and now == self.insert_base_hash) {
            self.cur().dirty = false;
        }
    }

    fn markDirty(self: *App) void {
        self.cur().dirty = true;
        self.syntax_dirty = true;
    }

    // ---- tree-sitter syntax highlighting ----

    /// Ensure the highlighter matches the current buffer's filetype. Returns
    /// null when the filetype has no grammar, the file is over the size
    /// limit, or init failed (remembered via syntax_ft — no retry storm).
    fn ensureSyntax(self: *App) ?*syntax.Highlighter {
        const ft = filetypeOf(self.cur().path);
        if (self.syntax_ft.len > 0 and std.mem.eql(u8, self.syntax_ft, ft)) {
            return if (self.syntax_hl) |*h| h else null;
        }
        // filetype changed (or first time): rebuild
        if (self.syntax_hl) |*h| h.deinit();
        self.syntax_hl = null;
        self.syntax_ft = ft;
        const lang = syntax.languageFor(ft) orelse return null;
        if (self.cur().pt.len() > syntax.SIZE_LIMIT) return null;
        self.syntax_hl = syntax.Highlighter.init(self.alloc, lang) catch null;
        if (self.syntax_hl != null) self.syntax_dirty = true;
        return if (self.syntax_hl) |*h| h else null;
    }

    /// Reparse the buffer text when it changed since the last parse.
    /// Single recorded edits take the incremental path (tree.edit + parse);
    /// everything else (undo/redo, multi-edit ops, first parse) falls back
    /// to a full reparse — the incremental bookkeeping must never guess.
    fn refreshSyntax(self: *App) !void {
        const hl = self.ensureSyntax() orelse return;
        if (!self.syntax_dirty) return;
        self.syntax_dirty = false;
        const hist = &self.cur().history;
        const rev = hist.revision;
        const parsed = hl.tree != null;
        if (parsed and rev == self.syntax_revision) return;
        const len = self.cur().pt.len();
        const text = try self.alloc.alloc(u8, len);
        defer self.alloc.free(text);
        self.cur().pt.copyRange(0, text);
        const incremental = parsed and
            rev > self.syntax_revision and
            rev - self.syntax_revision == 1 and
            hist.last_record != null;
        {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "refresh ft={s} rev={d} syncrev={d} parsed={} incremental={}\n", .{ self.syntax_ft, rev, self.syntax_revision, parsed, incremental }) catch "";
            const f0 = std.os.linux.openat(std.os.linux.AT.FDCWD, "/tmp/dbg.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
            if (f0 != std.math.maxInt(usize)) {
                const f: i32 = @intCast(f0);
                _ = std.os.linux.write(f, m.ptr, m.len);
                _ = std.os.linux.close(f);
            }
        }
        if (incremental) {
            const e = hist.last_record.?;
            try hl.reparseEdit(e.pos, e.pos + @as(u32, @intCast(e.before.len)), e.pos + @as(u32, @intCast(e.after.len)), text);
        } else {
            try hl.reparse(text);
        }
        self.syntax_revision = rev;
    }

    /// Merged non-overlapping spans for the visible byte range (later spans
    /// win overlaps), arena-allocated. Empty when highlighting is inactive.
    fn visibleSpans(self: *App, arena: std.mem.Allocator, view_top: u32, content_rows: u32) ![]syntax.Span {
        try self.refreshSyntax();
        _ = self.ensureSyntax() orelse return &.{};
        const line_count = self.cur().pt.lineCount();
        const start = self.cur().pt.lineStart(@min(view_top, line_count));
        const vbottom = @min(view_top + content_rows, line_count);
        // lineStart has no EOF sentinel: the last visible line's end is pt.len()
        const end: u32 = if (vbottom >= line_count) self.cur().pt.len() else self.cur().pt.lineStart(vbottom);
        var raw = std.ArrayList(syntax.Span).empty;
        try self.syntax_hl.?.spansInRange(@intCast(start), @intCast(end), arena, &raw);
        var out = std.ArrayList(syntax.Span).empty;
        for (raw.items) |sp| {
            while (out.items.len > 0) {
                var last = &out.items[out.items.len - 1];
                if (sp.start >= last.end) break; // disjoint
                if (sp.start <= last.start) {
                    _ = out.pop(); // covers the previous span wholly
                    continue;
                }
                last.end = sp.start; // later span wins the overlap
                break;
            }
            try out.append(arena, sp);
        }
        return out.items;
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
        switch (action) {
            .undo => {
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
                _ = self.cur().history.undo(&self.cur().pt);
                self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
                self.syntax_dirty = true;
            },
            .redo => {
                _ = self.cur().history.redo(&self.cur().pt);
                self.cur().cursor = @min(self.cur().cursor, self.cur().pt.len());
                self.syntax_dirty = true;
            },
            .insert_mode => {
                // open the undo group immediately so the whole insert session
                // (deletes first or not) is one undo step
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .append => {
                // a: insert after the character under the cursor
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const end = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                if (self.cur().cursor < end) {
                    var i = self.cur().cursor + 1;
                    while (i < end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                    self.cur().cursor = i;
                }
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
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
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .append_end => {
                // A: end of the line
                const line = self.cur().pt.lineOf(self.cur().cursor);
                self.cur().cursor = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .insert_line_after => {
                // o: new line below, cursor on it. The inserted '\n' joins the
                // insert-session undo group (left open until exitInsert), so
                // one undo reverts the whole o+typing session.
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const pos = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                self.cur().cursor = pos + 1;
                self.in_insert = true;
                self.state.mode = .insert;
                // structural edit (newline): force a full reparse next frame —
                // incremental parsing of a newline is where highlight drift
                // shows up ("o then type then jk leaves gray chars")
                self.syntax_dirty = true;
                self.syntax_revision = std.math.maxInt(u64);
            },
            .insert_line_before => {
                // O: new line above, cursor on it (same open-group semantics)
                const line = self.cur().pt.lineOf(self.cur().cursor);
                const pos = self.cur().pt.lineStart(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                self.cur().cursor = pos;
                self.in_insert = true;
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
            .increment, .decrement => {
                // Ctrl+a / Ctrl+x: a visual selection increments every number
                // in every selected line; otherwise the number at/after the
                // cursor. `count` is the delta (vim: 5<C-a> adds 5).
                const delta: i64 = if (action == .increment) @as(i64, count) else -@as(i64, count);
                if (self.isVisual()) {
                    try self.execSelectionNumberDelta(delta);
                    self.exitVisual();
                } else {
                    try self.execNumberDeltaAtCursor(delta);
                }
            },
            .increment_visual, .decrement_visual => {
                // g Ctrl+a / g Ctrl+x: visual column increment — each line's
                // first number gets ±(count + line offset, 1-based). Normal
                // mode g Ctrl+a is plain Ctrl+a (vim).
                const delta: i64 = if (action == .increment_visual) @as(i64, count) else -@as(i64, count);
                if (self.isVisual()) {
                    try self.execSelectionNumberColumn(delta);
                    self.exitVisual();
                } else {
                    try self.execNumberDeltaAtCursor(delta);
                }
            },
            .next_buffer => try self.switchBuffer(1),
            .prev_buffer => try self.switchBuffer(-1),
            .picker_file => try self.openPicker(),
            .picker_grep => try self.openGrepPicker(),
            .picker_buffers => try self.openBufferPicker(),
            .picker_recent => try self.openRecentPicker(),
            .close_buffer => self.closeCurrent(),
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

    // ---- number increment/decrement (Ctrl+a / Ctrl+x / g Ctrl+a / g Ctrl+x) ----

    /// One number occurrence in the document: byte range plus parsed value.
    const Number = struct {
        start: u32,
        end: u32, // exclusive
        value: i64,
    };

    fn isDigitByte(b: u8) bool {
        return b >= '0' and b <= '9';
    }

    /// Expand the digit run containing `digit_pos` into the whole number.
    /// A '-' immediately before the run is included as the sign, unless it is
    /// itself glued to a preceding digit ("1-5" with the cursor on 5 is the
    /// number 5, while "-5" is -5). Returns null when the digits do not fit
    /// i64 (the number is then left untouched).
    fn numberAtDigit(self: *App, digit_pos: u32) ?Number {
        const pt = &self.cur().pt;
        const len = pt.len();
        var start = digit_pos;
        while (start > 0 and isDigitByte(pt.byteAt(start - 1))) start -= 1;
        if (start > 0 and pt.byteAt(start - 1) == '-' and
            (start == 1 or !isDigitByte(pt.byteAt(start - 2))))
        {
            start -= 1;
        }
        var end = digit_pos + 1;
        while (end < len and isDigitByte(pt.byteAt(end))) end += 1;
        var v: i64 = 0;
        var i = start;
        const neg = if (i < end and pt.byteAt(i) == '-') blk: {
            i += 1;
            break :blk true;
        } else false;
        while (i < end) : (i += 1) {
            const d = pt.byteAt(i) - '0';
            if (v > @divTrunc(std.math.maxInt(i64) - @as(i64, d), 10)) return null; // overflow
            v = v * 10 + @as(i64, d);
        }
        return .{ .start = start, .end = end, .value = if (neg) -v else v };
    }

    /// The first number at or after `pos` (vim Ctrl+a semantics): the digit
    /// run under the cursor, else the next digit run (optionally '-' signed)
    /// scanning forward. Returns null when no number exists at/after `pos`.
    fn numberAtOrAfter(self: *App, pos: u32) ?Number {
        const pt = &self.cur().pt;
        const len = pt.len();
        if (pos >= len) return null;
        if (isDigitByte(pt.byteAt(pos))) return self.numberAtDigit(pos);
        var i = pos;
        while (i < len) : (i += 1) {
            const b = pt.byteAt(i);
            if (isDigitByte(b)) return self.numberAtDigit(i);
            if (b == '-' and i + 1 < len and isDigitByte(pt.byteAt(i + 1))) {
                return self.numberAtDigit(i + 1);
            }
        }
        return null;
    }

    /// The first number in [ls, le) (column-increment target), if any.
    fn firstNumberInLine(self: *App, ls: u32, le: u32) ?Number {
        var p = ls;
        while (p < le) {
            const b = self.cur().pt.byteAt(p);
            if (isDigitByte(b)) return self.numberAtDigit(p);
            if (b == '-' and p + 1 < le and isDigitByte(self.cur().pt.byteAt(p + 1))) {
                return self.numberAtDigit(p + 1);
            }
            p += 1;
        }
        return null;
    }

    /// Replace one number with value+delta; returns the byte end of the new
    /// text (the number may have grown or shrunk).
    fn replaceNumber(self: *App, n: Number, delta: i64) !u32 {
        const new = try std.fmt.allocPrint(self.alloc, "{d}", .{n.value + delta});
        defer self.alloc.free(new);
        try self.cur().history.record(&self.cur().pt, n.start, n.end - n.start, new);
        return n.start + @as(u32, @intCast(new.len));
    }

    /// Normal-mode Ctrl+a/x: increment the number at/after the cursor and
    /// place the cursor just after it (vim). One undo step.
    fn execNumberDeltaAtCursor(self: *App, delta: i64) !void {
        const n = self.numberAtOrAfter(self.cur().cursor) orelse return;
        self.cur().history.beginGroup();
        const new_end = try self.replaceNumber(n, delta);
        self.cur().history.endGroup();
        self.cur().cursor = new_end;
        self.markDirty();
    }

    /// Visual-mode Ctrl+a/x: increment every number in every line covered by
    /// the selection. One undo group; edits are applied right-to-left so the
    /// earlier offsets stay valid.
    fn execSelectionNumberDelta(self: *App, delta: i64) !void {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.cur().cursor);
        const e = @max(anchor, self.cur().cursor);
        const pt = &self.cur().pt;
        const start_line = pt.lineOf(s);
        const end_line = pt.lineOf(e);
        self.cur().history.beginGroup();
        var numbers = std.ArrayList(Number).empty;
        defer numbers.deinit(self.alloc);
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const ls = pt.lineStart(line);
            const le = ls + pt.lineLen(line);
            var p = ls;
            while (p < le) {
                const b = pt.byteAt(p);
                if (isDigitByte(b)) {
                    const n = self.numberAtDigit(p) orelse {
                        p += 1;
                        continue;
                    };
                    try numbers.append(self.alloc, n);
                    p = n.end;
                } else if (b == '-' and p + 1 < le and isDigitByte(pt.byteAt(p + 1))) {
                    const n = self.numberAtDigit(p + 1) orelse {
                        p += 1;
                        continue;
                    };
                    try numbers.append(self.alloc, n);
                    p = n.end;
                } else {
                    p += 1;
                }
            }
        }
        var i = numbers.items.len;
        while (i > 0) {
            i -= 1;
            _ = try self.replaceNumber(numbers.items[i], delta);
        }
        self.cur().history.endGroup();
        self.markDirty();
    }

    /// Visual-mode g Ctrl+a/x (vim column increment): each selected line's
    /// FIRST number gets ±(count + line offset), the i-th selected line (i
    /// starting at 1) getting ±i with count 1. One undo group; lines are
    /// processed bottom-up so earlier lines keep valid offsets.
    fn execSelectionNumberColumn(self: *App, delta: i64) !void {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.cur().cursor);
        const e = @max(anchor, self.cur().cursor);
        const pt = &self.cur().pt;
        const start_line = pt.lineOf(s);
        const end_line = pt.lineOf(e);
        self.cur().history.beginGroup();
        var line = end_line;
        while (true) {
            const ls = pt.lineStart(line);
            const le = ls + pt.lineLen(line);
            if (self.firstNumberInLine(ls, le)) |n| {
                const offset: i64 = @intCast(line - start_line + 1);
                _ = try self.replaceNumber(n, delta * offset);
            }
            if (line == start_line) break;
            line -= 1;
        }
        self.cur().history.endGroup();
        self.markDirty();
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

    /// Width of the relative-line-number gutter in cells: digits of the
    /// largest possible relative number (≤ the file's line count, since a
    /// relative number is a line offset) + one trailing space, with a
    /// minimum of 3 digits so small files keep a stable gutter.
    fn gutterWidth(self: *const App, line_count: u32) u32 {
        _ = self;
        var digits: u32 = 1;
        var n: u32 = line_count;
        while (n >= 10) : (n /= 10) digits += 1;
        return @max(3, digits) + 1;
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
        // Content area rows: below the tab bar, above the status bar.
        const content_rows = height - status_row_count - tab_bar_rows;

        const cursor_line = self.cur().pt.lineOf(self.cur().cursor);
        const line_count = self.cur().pt.lineCount();
        // relative-number gutter: computed once per frame, reused by the
        // line loop, cursor offset, mc highlight and easymotion labels
        const gutter = self.gutterWidth(line_count);
        const gutter_digits = gutter - 1;

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
            self.vx.screen.cursor_vis = true;
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

        var row: u32 = self.contentTop(); // content starts below the tab bar
        var line = self.cur().view_top;
        // syntax spans covering the visible byte range (empty when inactive)
        const merged = try self.visibleSpans(a, self.cur().view_top, content_rows);
        var span_i: usize = 0;
        while (row < self.contentTop() + content_rows and line < line_count) : ({
            line += 1;
            row += 1;
        }) {
            const rel: u32 = if (line == cursor_line)
                line + 1
            else if (line > cursor_line)
                line - cursor_line
            else
                cursor_line - line;
            // allocPrint's width is comptime-only, so pad by hand: digits
            // right-aligned in the numeric field plus one trailing space
            const num_raw = try std.fmt.allocPrint(a, "{d}", .{rel});
            const num_str = try a.alloc(u8, gutter);
            @memset(num_str[0..gutter], ' ');
            @memcpy(num_str[gutter_digits - num_raw.len .. gutter_digits], num_raw);
            num_str[gutter - 1] = ' ';

            const line_len = self.cur().pt.lineLen(line);
            const line_start = self.cur().pt.lineStart(line);
            var n: u32 = @min(line_len, win.width);
            // don't cut a multibyte char in half at the line end — a lone
            // UTF-8 continuation byte renders as U+FFFD ("box with ?")
            while (n > 0 and n < line_len and (self.cur().pt.byteAt(line_start + n) & 0xC0) == 0x80) {
                n -= 1;
            }
            const text = try a.alloc(u8, n);
            self.cur().pt.copyRange(line_start, text);

            // visual selection bounds as local columns (both = n if absent)
            var sel_s: u32 = n;
            var sel_e: u32 = n;
            if (self.visual_anchor) |anchor| {
                var sel_start = @min(anchor, self.cur().cursor);
                var sel_end = @max(anchor, self.cur().cursor);
                // V (visual_line) selects whole lines: the anchor line starts
                // at its first byte and the cursor line runs to its end —
                // pressing V mid-line must light the whole row, not [cursor..]
                if (self.state.mode == .visual_line) {
                    sel_start = self.cur().pt.lineStart(self.cur().pt.lineOf(sel_start));
                    sel_end = self.cur().pt.lineStart(self.cur().pt.lineOf(sel_end)) + self.cur().pt.lineLen(self.cur().pt.lineOf(sel_end));
                }
                const line_end = line_start + line_len;
                if (sel_start < line_end and sel_end > line_start) {
                    sel_s = @max(sel_start, line_start) - line_start;
                    sel_e = @min(sel_end, line_end) - line_start;
                }
            }

            // split the line into styled runs: syntax fg from the merged
            // spans, cursorline bg on the cursor's row, selection bg wins
            const is_cur_line = line == cursor_line;
            var segs = std.ArrayList(vaxis.Segment).empty;
            try segs.append(a, .{
                .text = num_str,
                .style = if (is_cur_line) .{ .bg = .{ .rgb = .{ 40, 48, 68 } } } else .{},
            });
            var col: u32 = 0;
            while (col < n) {
                while (span_i < merged.len and merged[span_i].end <= line_start + col) span_i += 1;
                var next: u32 = n;
                var fg: ?vaxis.Style = null;
                if (span_i < merged.len) {
                    const sp = merged[span_i];
                    if (sp.start < line_start + n and sp.end > line_start + col) {
                        fg = syntaxStyle(sp.style);
                        const sp_start: u32 = if (sp.start > line_start) sp.start - line_start else 0;
                        const sp_end: u32 = if (sp.end < line_start + n) sp.end - line_start else n;
                        next = if (sp_start > col) sp_start else sp_end;
                    }
                }
                if (sel_s > col and sel_s < next) next = sel_s;
                if (sel_e > col and sel_e < next) next = sel_e;
                const in_sel = col >= sel_s and col < sel_e;
                var style: vaxis.Style = .{};
                if (is_cur_line) style.bg = .{ .rgb = .{ 40, 48, 68 } };
                if (in_sel) style.bg = .{ .rgb = .{ 54, 74, 130 } };
                if (fg) |f| style.fg = f.fg;
                try segs.append(a, .{ .text = text[col..next], .style = style });
                col = next;
            }

            _ = win.print(segs.items, .{
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
            // vim-style scroll window (same semantics as the picker)
            const ft_len = self.filetree_files.items.len;
            const ft_vis = @min(ft_len, @as(usize, content_rows));
            if (ft_len > ft_vis) {
                if (self.filetree_top + ft_vis > ft_len) self.filetree_top = ft_len - ft_vis;
                if (self.filetree_sel < self.filetree_top) self.filetree_top = self.filetree_sel;
                if (self.filetree_sel >= self.filetree_top + ft_vis) self.filetree_top = self.filetree_sel - ft_vis + 1;
            } else self.filetree_top = 0;
            const ft_top = self.filetree_top;
            var k: usize = 0;
            while (k < ft_vis) : (k += 1) {
                const ri = ft_top + k;
                const f = self.filetree_files.items[ri];
                const label = if (f.len > filetree_width) f[f.len - filetree_width ..] else f;
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (ri == self.filetree_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{ .fg = .{ .rgb = .{ 122, 162, 247 } } },
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(1 + k), .col_offset = 0, .wrap = .none });
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
                    if (col >= @as(u32, win.width) - gutter) break;
                    var clen: u32 = 1;
                    while (p + clen < w.end and (self.cur().pt.byteAt(p + clen) & 0xC0) == 0x80) : (clen += 1) {}
                    var char_buf: [4]u8 = undefined;
                    self.cur().pt.copyRange(p, char_buf[0..clen]);
                    const g = try a.dupe(u8, char_buf[0..clen]);
                    win.writeCell(@intCast(self.contentCol() + gutter + col), @intCast(self.contentTop() + wline - self.cur().view_top), .{
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
                win.writeCell(@intCast(self.contentCol() + gutter + col_in_line), @intCast(self.contentTop() + mline - self.cur().view_top), .{
                    .char = .{ .grapheme = label, .width = 1 },
                    .style = .{ .fg = .{ .rgb = .{ 250, 189, 47 } }, .bg = .{ .rgb = .{ 54, 74, 130 } } },
                });
            }
        }

        // fuzzy picker overlay
        if (self.picker_active) {
            const total = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
            const list_rows = @min(@as(usize, 10), total);
            // vim-style scroll window: the selection moves freely inside the
            // window; the window scrolls only when the selection crosses an
            // edge (persisted in picker_top so it doesn't jump around).
            if (total > list_rows) {
                if (self.picker_top + list_rows > total) self.picker_top = total - list_rows;
                if (self.picker_sel < self.picker_top) self.picker_top = self.picker_sel;
                if (self.picker_sel >= self.picker_top + list_rows) self.picker_top = self.picker_sel - list_rows + 1;
            } else self.picker_top = 0;
            const top = self.picker_top;
            const start_row = height - 1 - @as(u32, @intCast(list_rows)) - 1;
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const ri = top + k;
                const label: []const u8 = if (self.picker_mode == .grep) blk: {
                    const r = self.grep_results.items[ri];
                    break :blk std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ r.path, r.line, r.text }) catch "…";
                } else if (self.picker_mode == .buffers) blk: {
                    const bi = self.picker_matches.items[ri];
                    break :blk std.fmt.allocPrint(a, "{d} {s}", .{ bi + 1, self.bufferName(bi) }) catch "…";
                } else if (self.picker_mode == .recent) blk: {
                    const ri2 = self.picker_matches.items[ri];
                    break :blk self.recent_files.items[ri2];
                } else self.picker_files.items[self.picker_matches.items[ri]];
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (ri == self.picker_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{},
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(start_row + k), .wrap = .none });
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
            self.vx.screen.cursor_vis = true;
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
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // insert-mode completion menu (Ctrl+n): a vim-style list directly
        // below the cursor line; the selected row is highlighted like the
        // fuzzy picker's selection. The buffer cursor is left untouched.
        if (self.completion_active) {
            const total = self.completion_words.items.len;
            const list_rows = @min(@as(usize, 8), total);
            var top: usize = 0;
            if (self.completion_sel >= list_rows) top = self.completion_sel - list_rows + 1;
            const c_line = self.cur().pt.lineOf(self.cur().cursor);
            const c_col = self.cur().cursor - self.cur().pt.lineStart(c_line);
            var start_row = c_line - self.cur().view_top + self.contentTop() + 1;
            if (start_row + list_rows > height) {
                // near the bottom: show the menu above the cursor instead
                start_row = c_line - self.cur().view_top + self.contentTop() - list_rows;
            }
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const seg = [_]vaxis.Segment{.{
                    .text = self.completion_words.items[top + k],
                    .style = if (top + k == self.completion_sel)
                        .{ .bg = .{ .rgb = .{ 54, 74, 130 } } }
                    else
                        .{},
                }};
                _ = win.print(&seg, .{
                    .row_offset = @intCast(start_row + k),
                    .col_offset = @intCast(self.contentCol() + gutter + c_col),
                    .wrap = .none,
                });
            }
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

        // cursor position — in the file tree when the tree has focus,
        // otherwise in the buffer
        if (self.filetree_active and self.focus == .filetree) {
            const sel_row: u32 = 1 + @as(u32, @intCast(self.filetree_sel -| self.filetree_top));
            self.vx.screen.cursor = .{
                .row = @intCast(sel_row),
                .col = 0,
            };
        } else {
            const cursor_col = self.cur().cursor - self.cur().pt.lineStart(cursor_line);
            const cursor_row = cursor_line - self.cur().view_top + self.contentTop();
            self.vx.screen.cursor = .{
                .row = @intCast(cursor_row),
                .col = @intCast(self.contentCol() + gutter + cursor_col), // gutter offset
            };
        }
        self.vx.screen.cursor_vis = true;
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
                    if (self.state.mode == .insert) {
                        if (self.mc_active) try self.mcInsertText(text) else try self.insertText(text);
                    }
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

/// Kanagawa-wave-flavored palette for the tree-sitter capture groups
/// (src/syntax.zig Style). Background 41,46,66; fg 192,202,245.
fn syntaxStyle(style: syntax.Style) vaxis.Style {
    return switch (style) {
        .default => .{},
        .comment => .{ .fg = .{ .rgb = .{ 116, 127, 148 } } },
        .keyword => .{ .fg = .{ .rgb = .{ 224, 175, 104 } } }, // gold
        .string => .{ .fg = .{ .rgb = .{ 152, 195, 121 } } }, // green
        .number, .constant, .boolean, .character => .{ .fg = .{ .rgb = .{ 210, 126, 139 } } }, // red
        .function, .tag, .namespace => .{ .fg = .{ .rgb = .{ 122, 162, 247 } } }, // blue
        .type, .constructor, .label => .{ .fg = .{ .rgb = .{ 124, 199, 199 } } }, // cyan
        .operator, .variable, .parameter, .property => .{ .fg = .{ .rgb = .{ 192, 202, 245 } } },
        .attribute, .builtin => .{ .fg = .{ .rgb = .{ 224, 175, 104 } } },
        .punctuation => .{ .fg = .{ .rgb = .{ 122, 124, 135 } } },
    };
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
