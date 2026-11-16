//! buffers — App method group split out of src/main.zig (physical move).

const std = @import("std");
const buffer = @import("../buffer/root.zig");
const disk_file = @import("../buffer/file.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- multi-buffer ----

/// Switch to the buffer at index `i` (clamped, wraps).
pub fn switchTo(self: *App, i: usize) void {
    if (self.buffers.items.len == 0) return;
    const target = i % self.buffers.items.len;
    const win = &self.windows.items[self.current_win];
    const leaving = win.buf;
    const changed = leaving != target;
    if (changed) {
        // Cursor/viewport belong to the (window, buffer) pair: save the
        // position the focused pane is leaving before it starts showing the
        // new document. Without this the shared window slot carried the old
        // cursor, clamped to the new document length, in both directions.
        self.saveWindowView(win);
        // re-home the buffer the focused pane is leaving: if another pane
        // still shows it, its tab moves to THAT pane ("displayed in which
        // pane, the tab belongs to which pane"); hidden from every pane, it
        // keeps this one — the pane that last showed it
        for (self.windows.items, 0..) |w, wi| {
            if (wi != self.current_win and w.buf == leaving) {
                self.buffers.items[leaving].last_win = wi;
                break;
            }
        }
        // the focused window follows the switch; other split windows keep
        // showing whatever buffer they had. This must happen BEFORE
        // ensureLsp: cur() resolves through the window's buf index, so with
        // the old order the server was started/retargeted against the
        // PREVIOUS buffer — files opened via the tree / :e / the picker got
        // no LSP session at all.
        win.buf = target;
        self.current = target;
        // Restore this pane's last position in the target buffer (validated
        // against the current document), or start at the top if it has
        // never shown it.
        self.restoreWindowView(win);
    } else {
        // Re-selecting the buffer already shown must not reset its position;
        // only keep the cursor inside a document that shrank underneath it.
        self.current = target;
    }
    // the buffer's tab belongs to the pane now showing it
    self.buffers.items[self.current].last_win = self.current_win;
    self.ensureLsp();
    self.state.mode = .normal;
    // leaving the buffer invalidates any visual selection from it
    // (gt / :bn / :e / picker-enter all land here, some without the
    // command-line exitVisual fallback)
    self.visual_anchor = null;
    self.in_insert = false;
    self.insert_goal_col = null;
    self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
    // per-buffer state from the previous buffer must not leak onto the
    // new one: stale inlay hints would render at wrong positions, stale
    // diagnostics would point at wrong files, hover/nav/completion would
    // linger.
    self.invalidateInlayHints();
    self.clearDiagnostics();
    self.clearHover();
    self.nav_list_active = false;
    self.freeGrepPreview();
    self.closeCompletion();
    self.closeGitPreview();
    // git branch + diff marks describe the newly focused buffer; blame
    // stays ON (current_line_blame) — the path check on the cached
    // blame prevents a stale ghost from the previous buffer
    self.scheduleGitStatus();
}

/// Move `delta` buffers (wrapping). gt / gT.
pub fn switchBuffer(self: *App, delta: i32) !void {
    const n = self.buffers.items.len;
    if (n == 0) return;
    var next = @as(i32, @intCast(self.current)) + delta;
    if (next < 0) next += @as(i32, @intCast(n));
    self.switchTo(@intCast(@mod(next, @as(i32, @intCast(n)))));
}

/// <leader>bh/bl workspace model: with a split open, a buffer opened
/// from navigation (file tree, pickers, gd/gr into another file) lands
/// in the LEFT window — the panes then hold distinct buffers by default
/// and bh/bl shuttles them. A buffer already shown in a window is
/// focused THERE instead (never duplicate it into both panes).
/// No-op without a split.
pub fn targetWindowForOpen(self: *App, buf_idx: ?usize) void {
    if (self.windows.items.len <= 1) return;
    if (buf_idx) |b| {
        for (self.windows.items, 0..) |w, wi| {
            if (w.buf == b) {
                self.current_win = wi;
                return;
            }
        }
    }
    const root = self.win_root orelse return;
    self.current_win = self.firstLeaf(root);
}

/// Own a snapshot: external in-place writes/truncation must never mutate
/// the document's origin or SIGBUS a later render/undo/save.
pub fn loadPieceTable(self: *App, file: std.Io.File, size: u64) !buffer.PieceTable {
    const len: usize = @intCast(size);
    const bytes = try self.alloc.alloc(u8, len);
    var owned = true;
    errdefer if (owned) self.alloc.free(bytes);
    if (try file.readPositionalAll(self.io, bytes, 0) != len or (try file.stat(self.io)).size != size)
        return error.FileChanged;
    owned = false;
    return buffer.PieceTable.initOwned(self.alloc, bytes);
}

const OpenTarget = enum { navigation, current_window };

/// Open `path` in a new buffer unless it is already open (then switch).
/// The stored path is ABSOLUTE (like the CLI arg path): LSP uri building,
/// filetype detection and recent-file dedupe all assume absolute paths, so
/// a relative path here (file tree, :e, picker) would silently kill LSP
/// for the opened file.
/// Navigation may re-use an existing pane; Ex commands own their current pane.
pub fn openInBuffer(self: *App, path: []const u8) !void {
    _ = try openInBufferAt(self, path, .navigation);
}

pub fn openInCurrentWindow(self: *App, path: []const u8) !void {
    _ = try openInBufferAt(self, path, .current_window);
}

/// Failed opens must not leave a duplicate pane or steal the original focus.
pub fn splitFileWindow(self: *App, dir: App.SplitDir, path: ?[]const u8) !void {
    const original = self.current_win;
    try self.splitWindow(dir);
    if (path) |p| {
        var opened = false;
        defer if (!opened) {
            self.closeWindow();
            self.switchWindowTo(original);
        };
        opened = try openInBufferAt(self, p, .current_window);
    }
}

fn openInBufferAt(self: *App, path: []const u8, target: OpenTarget) !bool {
    const abs = try self.absolutePath(path);
    defer self.alloc.free(abs);
    for (self.buffers.items, 0..) |*buf, i| {
        if (buf.path) |p| {
            if (std.mem.eql(u8, p, abs)) {
                if (target == .navigation) self.targetWindowForOpen(i);
                self.switchTo(i);
                return true;
            }
        }
    }
    // One document per workspace: Ex routing must not bypass this guard.
    for (self.workspaces.items, 0..) |ws, i| {
        if (i == self.current_ws) continue;
        for (ws.buffers.items) |buf| {
            if (buf.path) |p| {
                if (std.mem.eql(u8, p, abs)) {
                    try self.setMsg(try std.fmt.allocPrint(self.alloc, "已在 workspace '{s}' 中打开", .{ws.name}));
                    return false;
                }
            }
        }
    }
    var file: ?std.Io.File = null;
    if (std.Io.Dir.cwd().openFile(self.io, abs, .{ .mode = .read_only })) |opened| {
        file = opened;
    } else |err| {
        if (!(err == error.FileNotFound and target == .current_window)) {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ abs, @errorName(err) }));
            return false;
        }
    }
    defer if (file) |f| f.close(self.io);
    var size: u64 = 0;
    if (file) |f| {
        const stat = try f.stat(self.io);
        if (stat.kind != .file) {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "E17: {s} is not a regular file", .{abs}));
            return false;
        }
        size = stat.size;
    }
    if (size >= std.math.maxInt(u32)) {
        try self.setMsg(try self.alloc.dupe(u8, "file too large (>4GiB)"));
        return false;
    }
    var loaded = if (file) |f| try self.loadPieceTable(f, size) else try buffer.PieceTable.init(self.alloc, "");
    var own_loaded = true;
    defer if (own_loaded) loaded.deinit();
    const new_path = try self.alloc.dupe(u8, abs);
    defer if (own_loaded) self.alloc.free(new_path);
    var disk = disk_file.Baseline.init(self.alloc, self.io, abs, if (file != null) loaded.origin else null) catch |err| {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ abs, @errorName(err) }));
        return false;
    };
    defer if (own_loaded) disk.deinit(self.alloc);

    const old_index = self.windows.items[self.current_win].buf;
    var reuse_scratch = self.cur().path == null and self.cur().pt.len() == 0 and !self.cur().dirty;
    for (self.windows.items, 0..) |w, wi| {
        if (wi != self.current_win and w.buf == old_index) reuse_scratch = false;
    }
    // Only an unshared pristine startup scratch may be replaced in place.
    // A split's sibling must retain its unnamed document and view.
    var index: usize = undefined;
    if (reuse_scratch) {
        index = old_index;
        const buf = &self.buffers.items[index];
        buf.pt.deinit();
        buf.history.deinit();
        if (buf.disk) |*old_disk| old_disk.deinit(self.alloc);
        self.clearSpanCache(buf);
        buf.views.clear();
        buf.pt = loaded;
        buf.path = new_path;
        buf.disk = disk;
        buf.history = buffer.History.init(self.alloc);
        const w = &self.windows.items[self.current_win];
        w.cursor = 0;
        w.view_top = 0;
        w.view_wrap = 0;
        w.view_pinned = false;
    } else {
        try self.buffers.append(self.alloc, .{
            .pt = loaded,
            .history = buffer.History.init(self.alloc),
            .path = new_path,
            .disk = disk,
        });
        index = self.buffers.items.len - 1;
    }
    own_loaded = false;
    if (!self.notesIsPath(abs)) self.setProjectRoot(abs);
    try self.addRecent(abs);
    if (target == .navigation and !reuse_scratch) self.targetWindowForOpen(null);
    self.switchTo(index);
    return true;
}

/// Drop the LSP client and all LSP-derived state. `died` reports whether
/// the server exited on its own (reader EOF) — then the user is told,
/// because pending requests will never resolve.
pub fn teardownLsp(self: *App, died: bool) void {
    self.cancelLspStart();
    if (self.lsp_client) |c| {
        c.deinit();
        self.lsp_client = null;
    }
    // No inlay request can complete anymore — clear the in-flight flag or
    // the run loop would never auto-refresh hints for the next server.
    self.inlay_inflight = false;
    // clear every LSP response slot so stale results are not applied
    if (self.nav_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.nav_slot = null;
    if (self.completion_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.completion_slot = null;
    if (self.format_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.format_slot = null;
    if (self.format_request) |*request| request.deinit(self.alloc);
    self.format_request = null;
    if (self.inlay_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.inlay_slot = null;
    if (self.outline_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.outline_slot = null;
    self.invalidateInlayHints();
    self.clearDiagnostics();
    self.clearHover();
    self.closeCompletion();
    if (died) {
        const msg = self.alloc.dupe(u8, "LSP server exited") catch return;
        self.setMsg(msg) catch {};
    }
}

/// Close the buffer at `buf_idx`; every window showing it points at the
/// next buffer. The last buffer stays. Used by :bd and the single-window
/// :q path.
pub fn closeBufferAt(self: *App, buf_idx: usize) void {
    closeBufferAtForce(self, buf_idx, false);
}

pub fn closeBufferAtForce(self: *App, buf_idx: usize, force: bool) void {
    if (buf_idx >= self.buffers.items.len) return;
    if (self.buffers.items.len <= 1) return;
    if (!force and self.buffers.items[buf_idx].dirty) {
        const msg = self.alloc.dupe(u8, "E37: No write since last change (add ! to override)") catch return;
        self.setMsg(msg) catch self.alloc.free(msg);
        return;
    }
    self.cancelLspStart();
    if (self.lsp_client) |c| {
        c.deinit();
        self.lsp_client = null;
    }
    self.inlay_inflight = false;
    var buf = self.buffers.orderedRemove(buf_idx);
    self.deinitBuffer(&buf);
    if (self.current >= self.buffers.items.len) self.current = self.buffers.items.len - 1;
    if (buf_idx < self.current) self.current -= 1;
    // point every window at the surviving buffer, fixing up shifted indices
    for (self.windows.items) |*w| {
        if (w.buf > buf_idx) {
            w.buf -= 1;
            w.cursor = @min(w.cursor, self.buffers.items[w.buf].pt.len());
        } else if (w.buf == buf_idx) {
            w.buf = self.current;
            // the pane did not choose this buffer: install its own saved
            // position there (or the top), not the closed buffer's cursor
            self.restoreWindowView(w);
        }
    }
    self.winTreeSanity();
    // tab ownership: a displayed buffer owns its displaying pane
    for (self.windows.items, 0..) |w, wi| {
        self.buffers.items[w.buf].last_win = wi;
    }
    self.state.mode = .normal;
    // closing the buffer also discards a visual selection anchored in it
    self.visual_anchor = null;
    self.in_insert = false;
    // the surviving buffer may need its own server (or a retarget)
    self.invalidateInlayHints();
    self.clearDiagnostics();
    self.ensureLsp();
}

/// :bd — close the focused window's buffer; the window shows the next one.
pub fn closeCurrentBuffer(self: *App) void {
    closeCurrentBufferForce(self, false);
}

pub fn closeCurrentBufferForce(self: *App, force: bool) void {
    const buf = self.windows.items[self.current_win].buf;
    closeBufferAtForce(self, buf, force);
    self.windows.items[self.current_win].buf = self.current;
    self.windows.items[self.current_win].cursor = @min(self.windows.items[self.current_win].cursor, self.cur().pt.len());
}

/// Every exit destroys every workspace, including hidden buffers. Keep the
/// check at the exit boundary so dashboard/window shortcuts share it.
pub fn requestQuit(self: *App, force: bool) void {
    if (!force) {
        var dirty: usize = 0;
        for (self.buffers.items) |buf| {
            if (buf.dirty) dirty += 1;
        }
        for (self.workspaces.items) |workspace| {
            for (workspace.buffers.items) |buf| {
                if (buf.dirty) dirty += 1;
            }
        }
        if (dirty > 0) {
            const msg = std.fmt.allocPrint(self.alloc, "E37: {d} unsaved buffer(s) (add ! to override)", .{dirty}) catch return;
            self.setMsg(msg) catch self.alloc.free(msg);
            return;
        }
    }
    self.quit = true;
}

/// FNV-1a hash of the current buffer content (for dirty detection).
pub fn contentHash(self: *App) u64 {
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

/// Called when an insert session begins (all entry paths). A fresh
/// session must never inherit the previous one's completion menu or its
/// pending-request bookkeeping (a stale `completion_waiting_enter` made
/// the first Enter on the new line show "completion pending…" instead of
/// inserting a newline).
pub fn beginInsertSession(self: *App) void {
    self.insert_session +%= 1;
    self.invalidatePassiveHints();
    self.closeCompletion();
    self.insert_base_hash = self.contentHash();
    self.insert_was_dirty = self.cur().dirty;
}

/// Called when an insert session ends (exitInsert / exitMcInsert): a
/// session with zero net change clears the dirty flag.
pub fn endInsertSession(self: *App) void {
    const now = self.contentHash();
    if (!self.insert_was_dirty and now == self.insert_base_hash) {
        self.cur().dirty = false;
    }
}
