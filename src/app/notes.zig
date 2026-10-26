//! Notes + navigator App methods (DESIGN.md §18.3/§18.8, M2b1).
//!
//! The navigator is the existing 30-cell left sidebar with three tabs:
//! `files` (unchanged filetree behavior), `notes` (real markdown buffers
//! stored globally) and `agents` (a view over the session's real AI
//! threads). The pure note/filesystem model lives in `note_store.zig`; the
//! tab model in `navigator.zig`. This file owns the App cache, focus and
//! key routing so no second editor or thread model is introduced.
//!
//! ## Refresh policy (no per-frame scans)
//!
//! `Store.items` is a cache. It is refreshed on Notes tab entry, after
//! creating a note, after `:w` saves a note, and on explicit `r`. Ordinary
//! frames only read the cached list. The notes directory itself is created
//! lazily by the first list/create, never at startup.
//!
//! ## Focus
//!
//! While the navigator owns the keyboard: `Tab`/`Shift-Tab` cycle tabs and
//! `1`/`2`/`3` jump directly; the active tab's own keys are handled exactly
//! as before (`h`/`l` remain filetree fold/parent, never tab switches).
//! `<leader>e` opens the navigator on `files`; `Ctrl-w h/l` enter/leave it
//! like the old tree pane. Notes open as normal buffers (existing
//! `openFile`/`:w` path) and notes live outside the project, so opening one
//! does not re-root the workspace file tree/picker.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const note_store = @import("note_store.zig");
const nav = @import("navigator.zig");

// ---- directory / cache ----

/// Resolved absolute notes directory (cached; resolution performs no
/// filesystem work and creates nothing).
pub fn notesDir(self: *App) ![]const u8 {
    if (self.notes.dir) |d| return d;
    const d = try note_store.resolveDir(self.alloc, self.env_map);
    self.notes.dir = d;
    return d;
}

/// True when `path` lives directly in the notes directory. Used to keep a
/// note from re-rooting the workspace (project-independent data) and to
/// trigger a list refresh after saving one.
pub fn notesIsPath(self: *App, path: []const u8) bool {
    const dir = self.notesDir() catch return false;
    return note_store.isPathInside(dir, path);
}

fn notesSetErrorFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    defer self.alloc.free(text);
    self.notes.setError(self.alloc, text);
}

fn notesMsgFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
    self.setMsg(text) catch self.alloc.free(text);
}

/// Rebuild the cached list from disk. Never fails externally: a missing
/// notes source, an unwritable directory or a scan error becomes a visible
/// `Store.err` in the Notes tab (and an empty list), not a crash.
pub fn refreshNotes(self: *App) void {
    var keep: ?[]u8 = null;
    if (self.notes.selectedPath()) |p| keep = self.alloc.dupe(u8, p) catch null;
    defer if (keep) |k| self.alloc.free(k);

    const fail = struct {
        fn f(app: *App, comptime fmt: []const u8, args: anytype) void {
            app.notes.clearItems(app.alloc);
            app.notes.sel = 0;
            app.notes.top = 0;
            app.notes.loaded = true;
            notesSetErrorFmt(app, fmt, args);
        }
    }.f;

    const dir = self.notesDir() catch |e| {
        const detail = switch (e) {
            error.NotesDirUnavailable => "set OZ_NOTES_DIR, XDG_DATA_HOME or HOME",
            else => @errorName(e),
        };
        fail(self, "notes unavailable: {s}", .{detail});
        return;
    };
    std.Io.Dir.cwd().createDirPath(self.io, dir) catch |e| {
        fail(self, "notes dir {s}: {s}", .{ dir, @errorName(e) });
        return;
    };
    var list = note_store.scanDir(self.io, self.alloc, dir) catch |e| {
        fail(self, "notes dir {s}: {s}", .{ dir, @errorName(e) });
        return;
    };
    defer list.deinit(self.alloc);

    self.notes.clearItems(self.alloc);
    self.notes.items.appendSlice(self.alloc, list.items) catch {
        for (list.items) |*n| n.deinit(self.alloc);
        self.notes.sel = 0;
        self.notes.top = 0;
        self.notes.loaded = true;
        self.notes.setError(self.alloc, "notes: out of memory");
        return;
    };
    self.notes.clearError(self.alloc);
    self.notes.loaded = true;
    self.notes.sel = 0;
    if (keep) |k| self.notes.selectPath(k);
    if (self.notes.sel >= self.notes.items.items.len and self.notes.items.items.len > 0) {
        self.notes.sel = self.notes.items.items.len - 1;
    }
    self.notes.top = 0;
}

/// Hook for `:w`: a saved note's body/title changed, so refresh the cached
/// list (the notes dir is only touched when the saved path is a note).
pub fn notesDidSave(self: *App, path: []const u8) void {
    if (!self.notesIsPath(path)) return;
    self.refreshNotes();
}

// ---- actions ----

/// Open the selected note exactly like Enter: a normal buffer via the
/// existing `openFile` path, so `:w`, syntax highlighting and the tab title
/// all behave like any other file.
pub fn openNoteAt(self: *App, idx: usize) !void {
    if (idx >= self.notes.items.items.len) return;
    self.notes.sel = idx;
    self.navigator_peek = false; // opening the note returns to the editor
    self.ai.focus = .editor; // a hint action may run while the rail owns keys
    self.focus = .buffer;
    try self.openFile(self.notes.items.items[idx].path);
}

/// `n` on the Notes tab: create a collision-free `note-N.md` with the
/// documented template, refresh the list, select it and open it as a normal
/// buffer. Failures are reported in the navigator + status line, never a
/// crash.
pub fn createNote(self: *App) void {
    const dir = self.notesDir() catch |e| {
        notesSetErrorFmt(self, "notes unavailable: {s}", .{@errorName(e)});
        notesMsgFmt(self, "notes: cannot resolve directory: {s}", .{@errorName(e)});
        return;
    };
    const path = note_store.createNoteFile(self.io, self.alloc, dir) catch |e| {
        notesSetErrorFmt(self, "cannot create note in {s}: {s}", .{ dir, @errorName(e) });
        notesMsgFmt(self, "notes: cannot create note: {s}", .{@errorName(e)});
        return;
    };
    defer self.alloc.free(path);

    // Refresh now (not per frame): the new file must appear in the list and
    // be selected the next time the tab is shown. The editor then shows the
    // buffer, exactly like opening a file from the tree.
    self.notes.loaded = false;
    self.refreshNotes();
    self.notes.selectPath(path);
    self.navigator_peek = false;
    self.ai.focus = .editor;
    self.focus = .buffer;
    self.openFile(path) catch |e| {
        notesMsgFmt(self, "notes: cannot open new note: {s}", .{@errorName(e)});
    };
}

/// True when the terminal is in the compact (<90-col) navigator mode.
pub fn navigatorCompact(self: *App) bool {
    return nav.modeForCols(self.vx.window().width) == .compact;
}

/// Focus the navigator from the keyboard. Full mode just takes focus;
/// compact mode opens the peek so the focused pane has visible content
/// (and closes the AI drawer: the two overlays never stack).
pub fn navigatorEnter(self: *App) void {
    if (self.navigatorCompact()) {
        self.navigator_peek = true;
        if (self.ai.rail_open and self.aiLayout().mode == .drawer) {
            self.ai.rail_open = false;
            self.ai.focus = .editor;
        }
    }
    self.focus = .navigator;
}

/// Close the compact peek overlay (no-op in full mode) and return the
/// keyboard to the editor. The icon rail stays visible.
pub fn navigatorPeekClose(self: *App) void {
    self.navigator_peek = false;
    self.focus = .buffer;
    self.ai.focus = .editor;
}

/// Close the navigator. In compact mode Esc closes only the peek overlay and
/// keeps the icon rail; full mode hides the panel (the existing behavior).
pub fn closeNavigator(self: *App) void {
    if (self.navigatorCompact() and self.navigator_peek) {
        self.navigatorPeekClose();
        return;
    }
    self.navigator_peek = false;
    self.filetree_active = false;
    self.focus = .buffer;
}

/// Switch navigator tab. Entry side effects are the only "scan/load" points:
/// Notes refreshes its cached list, Agents ensures the real thread model is
/// initialized (thread 1 is a real thread, same as the rail's) and loads the
/// provider config for the model label. In compact mode the same call opens
/// (or, for the already-open tab, closes) the peek.
pub fn navigatorSetTab(self: *App, tab: nav.Tab) !void {
    const was_active = self.filetree_active;
    if (!was_active) try self.toggleFiletree();

    if (self.navigatorCompact()) {
        // Selecting the already-open tab toggles the peek closed (the demo's
        // icon behavior); any other selection opens/switches it. A first
        // entry through `toggleFiletree` already opened the requested tab.
        if (was_active and self.navigator_peek and
            nav.peekAfterSelect(true, self.navigator_tab, tab) == null)
        {
            self.navigatorPeekClose();
            return;
        }
        self.navigator_peek = true;
        // Compact peek and the drawer rail share the overlay slot.
        if (self.ai.rail_open and self.aiLayout().mode == .drawer) {
            self.ai.rail_open = false;
            self.ai.focus = .editor;
        }
    } else {
        self.navigator_peek = false;
    }

    self.navigator_tab = tab;
    self.ai.focus = .editor; // navigator owns keys; the rail may stay visible
    self.focus = .navigator;
    switch (tab) {
        .files => {},
        .notes => self.refreshNotes(),
        .agents => {
            try self.ensureAi();
            if (self.ai.threads.items.items.len > 0) {
                self.ai.thread_cursor = @min(self.ai.thread_cursor, self.ai.threads.items.items.len - 1);
            }
            self.aiLoadConfig() catch {};
        },
    }
}

pub fn navigatorCycleTab(self: *App, delta: i32) !void {
    try self.navigatorSetTab(nav.next(self.navigator_tab, delta));
}

// ---- keys ----

fn moveNoteCursor(self: *App, delta: i32) void {
    const n = self.notes.items.items.len;
    if (n == 0) return;
    var idx: i32 = @intCast(@min(self.notes.sel, n - 1));
    idx += delta;
    if (idx < 0) idx = 0;
    if (idx >= @as(i32, @intCast(n))) idx = @intCast(n - 1);
    self.notes.sel = @intCast(idx);
}

fn notesKey(self: *App, key: vaxis.Key) !bool {
    switch (key.codepoint) {
        'j', vaxis.Key.down => {
            moveNoteCursor(self, 1);
            return true;
        },
        'k', vaxis.Key.up => {
            moveNoteCursor(self, -1);
            return true;
        },
        vaxis.Key.enter => {
            try self.openNoteAt(self.notes.sel);
            return true;
        },
        'n' => {
            self.createNote();
            return true;
        },
        'r' => {
            self.refreshNotes();
            return true;
        },
        vaxis.Key.escape => {
            closeNavigator(self);
            return true;
        },
        else => return false,
    }
}

fn moveThreadCursor(self: *App, delta: i32) void {
    const n = self.ai.threads.items.items.len;
    if (n == 0) return;
    var idx: i32 = @intCast(@min(self.ai.thread_cursor, n - 1));
    idx += delta;
    if (idx < 0) idx = 0;
    if (idx >= @as(i32, @intCast(n))) idx = @intCast(n - 1);
    self.ai.thread_cursor = @intCast(idx);
}

/// Enter on the Agents tab: attach to the selected real thread and land on
/// its prompt in the rail/workbox (opening the rail if it was closed). This
/// is `aiSelectThread` — the same method the rail's Enter and the hint action
/// use — so the navigator cannot diverge from the thread model.
pub fn navigatorAttachSelectedThread(self: *App) !void {
    try self.ensureAi();
    const n = self.ai.threads.items.items.len;
    if (n == 0) return;
    self.navigator_peek = false;
    self.ai.rail_open = true;
    self.ai.rail_pending_leader = false;
    self.aiSelectThread(@min(self.ai.thread_cursor, n - 1));
    self.aiLoadConfig() catch {};
}

/// `n` on the Agents tab: same new-thread path as the rail (`aiNewThread`).
pub fn navigatorNewThread(self: *App) !void {
    try self.ensureAi();
    self.navigator_peek = false;
    self.ai.rail_open = true;
    self.ai.rail_pending_leader = false;
    try self.aiNewThread();
}

fn agentsKey(self: *App, key: vaxis.Key) !bool {
    switch (key.codepoint) {
        'j', vaxis.Key.down => {
            moveThreadCursor(self, 1);
            return true;
        },
        'k', vaxis.Key.up => {
            moveThreadCursor(self, -1);
            return true;
        },
        vaxis.Key.enter => {
            try self.navigatorAttachSelectedThread();
            return true;
        },
        'n' => {
            try self.navigatorNewThread();
            return true;
        },
        vaxis.Key.escape => {
            closeNavigator(self);
            return true;
        },
        else => return false,
    }
}

/// Wheel over the navigator list: move the active tab's selection (clamped)
/// through the same helpers the keyboard uses. Wheel never changes tab or
/// focus; it only scrolls the list under the pointer.
pub fn navigatorScrollBy(self: *App, delta: i32) void {
    switch (self.navigator_tab) {
        .files => self.moveFiletreeCursor(delta),
        .notes => moveNoteCursor(self, delta),
        .agents => moveThreadCursor(self, delta),
    }
}

/// Navigator key routing, called only while the navigator owns the keyboard.
/// Tab switching is consumed first (so `h`/`l` remain fold/parent on Files);
/// every other key goes to the active tab's existing handler. Returns false
/// for unhandled keys so editor commands (e.g. `:`) still work.
pub fn navigatorKey(self: *App, key: vaxis.Key) !bool {
    if (key.codepoint == vaxis.Key.tab and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        try self.navigatorCycleTab(if (key.mods.shift) -1 else 1);
        return true;
    }
    const plain = !key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.shift;
    if (plain) {
        if (nav.fromDigit(key.codepoint)) |tab| {
            try self.navigatorSetTab(tab);
            return true;
        }
    }
    return switch (self.navigator_tab) {
        .files => try self.filetreeKey(key),
        .notes => try notesKey(self, key),
        .agents => try agentsKey(self, key),
    };
}

/// Screen row of the navigator's block cursor (status cursor is not test
/// observability; this keeps it aligned with the selected row as before).
pub fn navigatorCursorRow(self: *App, a: std.mem.Allocator) u32 {
    const top = self.contentTop(a);
    if (self.navigatorCompact() and !self.navigator_peek) return top;
    const body = top + nav.full_header_rows;
    return switch (self.navigator_tab) {
        .files => blk: {
            const n = self.filetree_rows.items.len;
            const sel = if (n == 0) 0 else @min(self.filetree_sel, n - 1);
            break :blk body + @as(u32, @intCast(sel -| self.filetree_top));
        },
        .notes => blk: {
            const n = self.notes.items.items.len;
            const sel = if (n == 0) 0 else @min(self.notes.sel, n - 1);
            break :blk body + 2 * @as(u32, @intCast(sel -| self.notes.top));
        },
        .agents => blk: {
            const n = self.ai.threads.items.items.len;
            const sel = if (n == 0) 0 else @min(self.ai.thread_cursor, n - 1);
            break :blk body + 1 + @as(u32, @intCast(sel -| self.ai.thread_top));
        },
    };
}
