//! input — App method group split out of src/main.zig (physical move).

const vaxis = @import("vaxis");
const buffer = @import("../buffer/root.zig");
const editor = @import("../editor/root.zig");
const term = @import("../term.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const foldNextLine = App.foldNextLine;
const foldPrevLine = App.foldPrevLine;
const foldSnapPos = App.foldSnapPos;
const isWordByte = App.isWordByte;

// ---- input ----

pub fn handleKey(self: *App, key: vaxis.Key) !void {
    // Terminal focus first: every key belongs to the child (Esc /
    // Alt+r/w/e are intercepted inside handleTerminalKey).
    if (term.supported) {
        if (self.term_pane) |*tp| {
            if (tp.focused) {
                try self.handleTerminalKey(key);
                return;
            }
        }
    }
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

    // Diagnostics list overlay (<leader>sd)
    if (self.diag_list_active) {
        if (self.diagnosticsListKey(key)) return;
    }
    // Navigation location list overlay (gr / gI)
    if (self.nav_list_active) {
        if (self.navListKey(key)) return;
    }
    // Hunk preview float (<leader>hp): Esc/Enter/q close, j/k scroll
    if (self.git_preview != null) {
        if (self.gitPreviewKey(key)) return;
    }

    // A status message (e.g. "no candidates") lives until the next
    // keystroke, like vim's message line.
    if (self.msg) |m| {
        self.alloc.free(m);
        self.msg = null;
    }

    // Ctrl-w window commands: switch keyboard focus between split windows
    // (vim Ctrl-w hjkl geometric navigation) and the file-tree sidebar.
    // Not in insert mode — there Ctrl+w still deletes the word before it.
    if (key.codepoint == 'w' and key.mods.ctrl and self.state.mode != .insert) {
        self.pending_window = true;
        return;
    }
    if (self.pending_window) {
        self.pending_window = false;
        if (key.codepoint == vaxis.Key.escape) return;
        switch (key.codepoint) {
            // Vim Ctrl-w hjkl geometric navigation. The file-tree
            // sidebar is a full-height pane at column 0, so h from the
            // leftmost buffer window (or from the tree: nothing further
            // left) reaches it, l from the tree re-enters the buffer,
            // and j/k always move between buffer windows (the tree spans
            // every row; from it j/k enter the buffer). Previously h/l
            // only toggled tree ↔ current window, stranding the other
            // split windows unreachable.
            'h' => {
                if (self.filetree_active and self.focus == .buffer) {
                    const before = self.current_win;
                    self.navigateWindow(.left);
                    if (self.current_win == before) self.focus = .filetree;
                } else if (!self.filetree_active) {
                    self.navigateWindow(.left);
                }
                // from the tree (tree open, focus == .filetree) there is
                // nothing further left
            },
            'l' => {
                if (self.filetree_active and self.focus == .filetree) {
                    self.focus = .buffer;
                } else {
                    self.navigateWindow(.right);
                }
            },
            'j' => {
                if (self.filetree_active and self.focus == .filetree) {
                    self.focus = .buffer;
                } else {
                    self.navigateWindow(.down);
                }
            },
            'k' => {
                if (self.filetree_active and self.focus == .filetree) {
                    self.focus = .buffer;
                } else {
                    self.navigateWindow(.up);
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

    // r{char}: replace the character under the cursor. The first 'r'
    // (execAction .replace_char) sets pending_replace; the NEXT plain
    // key is the replacement character (normal mode only — in insert
    // mode 'r' is just a typed character).
    if (self.pending_replace) |pr| {
        if (self.state.mode != .insert and key.text != null and key.text.?.len > 0 and
            !key.mods.ctrl and !key.mods.alt and !key.mods.super and
            key.codepoint != vaxis.Key.escape)
        {
            const ch = key.text.?[0];
            self.pending_replace = null;
            try self.replaceCharsAtCursor(ch, pr.count);
            return;
        }
        // Esc / anything else cancels the pending replace
        self.pending_replace = null;
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
            // LSP sync (same rule as every other edit): the server's
            // copy must follow the deletion.
            self.markDirty();
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
        // ---- insert-mode completion (Ctrl+n and auto-suggest) ----
        // Esc while the menu is open only dismisses it (stays in insert);
        // a second Esc exits the insert session as usual.
        if (self.completion_active and key.codepoint == vaxis.Key.escape) {
            self.closeCompletion();
            return;
        }
        // Ctrl+e: hide the menu (blink.cmp mapping), stay in insert.
        if (self.completion_active and key.codepoint == 'e' and key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            self.closeCompletion();
            return;
        }
        // Ctrl+n: next candidate when the menu is open; otherwise collect
        // candidates and open the menu — but only when the cursor is
        // inside a word. Without a word prefix the key is swallowed.
        // (Insert-mode completion only; in normal mode the keymap routes
        // Ctrl+n to multi-cursor .mc_add instead.)
        if (self.state.mode == .insert and key.codepoint == 'n' and key.mods.ctrl and !key.mods.alt and !key.mods.super) {
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
            // Enter accepts the selected word (replaces the typed prefix).
            // Matches the user's nvim: Enter is the only accept key; Tab
            // always inserts literal spaces.
            if (key.codepoint == vaxis.Key.enter) {
                try self.acceptCompletion();
                return;
            }
            // Word-char or trigger-char input keeps the menu open — the
            // prefix grows / the trigger context changes and
            // maybeAutoComplete below re-requests. Anything else (space,
            // backspace, Ctrl+w, j/k, Ctrl+c…) dismisses the menu, then
            // falls through to the normal insert handling so jk exit,
            // Esc exit and text entry behave as usual.
            const is_comp_input = key.text != null and key.text.?.len > 0 and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super and
                (isWordByte(key.text.?[0]) or self.isCompletionTriggerText(key.text.?));
            if (!is_comp_input) self.closeCompletion();
        }
        // Arrow keys move the cursor without leaving insert mode (up/down
        // with the completion menu open select candidates, handled above).
        // prev_insert_key is left untouched so a jk exit still works after
        // arrow movement.
        if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.right or
            key.codepoint == vaxis.Key.up or key.codepoint == vaxis.Key.down)
        {
            var c = self.curCursor().*;
            editor.Motion.apply(&self.cur().pt, switch (key.codepoint) {
                vaxis.Key.left => .left,
                vaxis.Key.right => .right,
                vaxis.Key.up => .up,
                else => .down,
            }, .{}, &c, 1);
            self.curCursor().* = c;
            self.clearHover();
            return;
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
                if (self.curCursor().* > 0 and self.cur().pt.byteAt(self.curCursor().* - 1) == 'j') {
                    const pos = self.curCursor().* - 1;
                    // LSP range in the PRE-EDIT document: [pos, pos+1).
                    const start_pos = self.lspPositionAt(&self.cur().pt, pos);
                    const end_pos = self.lspPositionAt(&self.cur().pt, pos + 1);
                    try self.cur().history.record(&self.cur().pt, pos, 1, "");
                    self.curCursor().* = pos;
                    // The 'j' was shift-adjusted INTO the hints when it
                    // was inserted (adjustInlayHintsInsert +1); removing
                    // it must shift them back, or every jk exit leaves the
                    // hints one column too far right (accumulating).
                    const line = self.cur().pt.lineOf(pos);
                    const col = pos - self.cur().pt.lineStart(line);
                    self.adjustInlayHintsDelete(line, col, "j");
                    // markDirty: the 'j' insertion already sent a
                    // didChange, so the LSP server's copy still contains
                    // the phantom 'j'. Re-sync the removal or the server
                    // keeps analyzing text that never existed — stale
                    // diagnostics ("expected ',' after field" at col 0)
                    // and inlay hints computed against the wrong
                    // document. Also bumps edit_seq so any in-flight
                    // response is discarded as stale. (Runs before
                    // exitInsert, so in_insert is still true and the
                    // freshly shifted-back hints are NOT invalidated.)
                    self.markDirtyRange(start_pos, end_pos, "");
                }
                self.exitInsert();
                return;
            }
        }
        if (key.codepoint == vaxis.Key.enter) {
            // A manual Ctrl+n asked the server for candidates but the
            // response hasn't arrived (zls on build.zig can take many
            // seconds). A blind Enter here would insert a newline and the
            // completion would look ignored — the cursor ends up on the
            // wrong line. Wait instead: tell the user, and let the next
            // Enter accept once the menu opens.
            if (self.completion_waiting_enter and !self.completion_active) {
                try self.setMsg(try self.alloc.dupe(u8, "completion pending…"));
                return;
            }
            try self.insertNewline();
            return;
        }
        if (key.codepoint == 'k' and key.mods.ctrl) {
            try self.deleteToEol();
            return;
        }
        if (key.codepoint == vaxis.Key.backspace) {
            // between an empty auto-pair, backspace deletes both sides
            if (!try self.autoPairBackspace()) try self.deleteBeforeCursor();
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
                self.curCursor().* = buffer.ops.wordStartBefore(&self.cur().pt, self.curCursor().*);
                return;
            }
            if (key.codepoint == 'f') {
                var c = self.curCursor().*;
                editor.Motion.apply(&self.cur().pt, .word_next_end, .{}, &c, 1);
                self.curCursor().* = c;
                return;
            }
        }
        self.prev_insert_key = key;
        if (key.text) |text| {
            // auto-pairs: openers/quotes close themselves (cursor lands
            // between), closers skip over an identical closer. The
            // signature-help / auto-suggest triggers below still apply.
            const paired = try self.autoPairInsert(text);
            if (!paired) try self.insertText(text);
            // Signature help: typing '(' asks the language server for
            // the callee's signature and shows it in the floating window
            // (LSP signatureHelp; the response arrives via the wake
            // mechanism and renders without a keypress).
            if (key.codepoint == '(' and !key.mods.ctrl and !key.mods.alt) {
                try self.requestNav("textDocument/signatureHelp", .signature);
            }
            // Auto-suggest: typing a word character asks the LSP for
            // candidates, and typing a trigger character (".", "::", …)
            // asks it to resolve the context ("b." member access). The
            // menu appears when the response lands. 'j' is excluded:
            // jk is the insert-exit shortcut, and asking the server on
            // the 'j' alone makes the menu flash between 'j' and 'k'.
            if (!key.mods.ctrl and !key.mods.alt and !key.mods.super and
                key.codepoint != 'j' and
                (isWordByte(text[0]) or self.isCompletionTriggerText(text)))
            {
                try self.maybeAutoComplete(text);
            }
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
            var new_cursor = self.curCursor().*;
            if (self.viewMotionTargetLine(m.motion)) |line| {
                // H/M/L: target line resolved from the focused window's
                // viewport; keep the column, clamp to the line end (j/k
                // semantics).
                new_cursor = editor.Motion.toLineKeepCol(&self.cur().pt, new_cursor, line);
            } else if (m.motion == .down or m.motion == .up) {
                // j/k: a closed fold counts as ONE line — walk visible
                // lines instead of document lines (foldNext/foldPrev
                // skip hidden bodies).
                const buf = self.cur();
                const line_count = buf.pt.lineCount();
                var line = buf.pt.lineOf(new_cursor);
                var i: u32 = 0;
                while (i < m.count) : (i += 1) {
                    if (m.motion == .down) {
                        if (line + 1 >= line_count) break;
                        line = @min(foldNextLine(buf, line), line_count - 1);
                    } else {
                        if (line == 0) break;
                        line = foldPrevLine(buf, line);
                    }
                }
                new_cursor = editor.Motion.toLineKeepCol(&buf.pt, new_cursor, line);
            } else {
                editor.Motion.apply(&self.cur().pt, m.motion, m.args, &new_cursor, m.count);
                // any other motion landing inside a closed fold snaps to
                // its header line — the cursor never rests on hidden text
                new_cursor = foldSnapPos(self.cur(), new_cursor);
            }
            if (new_cursor != self.curCursor().*) {
                // The cursor moved: nvim-style hover windows vanish once
                // the cursor leaves the annotated token.
                self.clearHover();
            }
            self.curCursor().* = new_cursor;
        },
        .op_motion => |m| try self.execOpMotion(m),
        .surround => |s| try self.execSurround(s),
        .align_lines => |a| try self.execAlign(a),
        .command_mode => {
            // ':' pressed: open the command line (Mode already set .command)
            self.cmdline.clearRetainingCapacity();
            self.cmd_hist_idx = null;
            self.cmd_complete_idx = 0;
            self.clearCmdCompleteNames();
            self.cmdline_kind = .ex;
            try self.setMsg(try self.alloc.dupe(u8, ""));
            // From visual mode vim auto-types :'<,'>; :s then applies to
            // the selection (the anchor survives until Enter).
            if (self.visual_anchor != null) {
                try self.cmdline.appendSlice(self.alloc, "'<,'>");
            }
        },
        .search_mode => |dir| {
            // '/' or '?' pressed: the command line collects the search
            // query (Mode already set .command)
            self.cmdline.clearRetainingCapacity();
            self.cmd_hist_idx = null;
            self.cmd_complete_idx = 0;
            self.clearCmdCompleteNames();
            self.cmdline_kind = if (dir == .forward) .search_fwd else .search_bwd;
            try self.setMsg(try self.alloc.dupe(u8, ""));
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

pub fn exitInsert(self: *App) void {
    self.state.mode = .normal;
    self.cur().history.endGroup();
    self.in_insert = false;
    self.prev_insert_key = null;
    self.closeCompletion();
    self.endInsertSession();
    // The old code forced a full reparse here (syntax_revision = maxInt)
    // to avoid the "chars turn comment-gray after jk" drift. That guard
    // was belt-and-suspenders: the drift comes from multi-edit structural
    // ops (o/O insert a newline AND indentation as two records in one
    // frame), and THOSE sites already force a full reparse themselves.
    // A plain typing session (including jk's trailing 'j' deletion) is a
    // sequence of single-record edits — the incremental path is exact for
    // them, and forcing a full reparse on every insert exit made large
    // files visibly flash/stutter the frame after jk. Leave the revision
    // alone; visibleSpansFor takes the incremental path when it can.
    // The session's in-place shifts kept the hint DATA current (adjust
    // on every edit), so hints stay rendered across the exit — no
    // clear + async re-request, which was the "hints vanish then
    // reappear" flash after jk. But code WRITTEN during the session has
    // no hints at all until the server is asked again, so reset the
    // request bookkeeping (NOT the displayed hints): the run loop
    // re-requests the visible range in the background and processInlay
    // swaps the fresh hints in atomically — no flash, and new code
    // gets its hints.
    self.inlay_view_top = null;
}
