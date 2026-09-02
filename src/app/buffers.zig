//! buffers — App method group split out of src/main.zig (physical move).

const std = @import("std");
const buffer = @import("../buffer/root.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- multi-buffer ----

/// Switch to the buffer at index `i` (clamped, wraps).
pub fn switchTo(self: *App, i: usize) void {
    if (self.buffers.items.len == 0) return;
    self.current = i % self.buffers.items.len;
    // re-home the buffer the focused pane is leaving: if another pane
    // still shows it, its tab moves to THAT pane ("displayed in which
    // pane, the tab belongs to which pane"); hidden from every pane, it
    // keeps this one — the pane that last showed it
    const leaving = self.windows.items[self.current_win].buf;
    if (leaving != self.current) {
        for (self.windows.items, 0..) |w, wi| {
            if (wi != self.current_win and w.buf == leaving) {
                self.buffers.items[leaving].last_win = wi;
                break;
            }
        }
    }
    // the focused window follows the switch; other split windows keep
    // showing whatever buffer they had. This must happen BEFORE
    // ensureLsp: cur() resolves through the window's buf index, so with
    // the old order the server was started/retargeted against the
    // PREVIOUS buffer — files opened via the tree / :e / the picker got
    // no LSP session at all.
    self.windows.items[self.current_win].buf = self.current;
    // the buffer's tab belongs to the pane now showing it
    self.buffers.items[self.current].last_win = self.current_win;
    self.ensureLsp();
    self.state.mode = .normal;
    // leaving the buffer invalidates any visual selection from it
    // (gt / :bn / :e / picker-enter all land here, some without the
    // command-line exitVisual fallback)
    self.visual_anchor = null;
    self.in_insert = false;
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
/// from outside (:e, file tree, pickers, gd/gr into another file) lands
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

/// Load `file` (size bytes) into a PieceTable without copying the file
/// into the heap: a read-only PRIVATE mmap backs the origin piece, so a
/// 50MB file costs one mapping, not a 50MB heap copy (RSS ~1× the file
/// instead of 2×). Falls back to read + copy when the file is empty or
/// the mapping fails (special filesystems, quota, …). The caller keeps
/// `file` open only until this returns — the mapping survives the close.
pub fn loadPieceTable(self: *App, file: std.Io.File, size: u64) !buffer.PieceTable {
    if (size == 0) return buffer.PieceTable.init(self.alloc, "");
    const len: usize = @intCast(size);
    const mapping = std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) catch {
        const bytes = try self.alloc.alloc(u8, len);
        defer self.alloc.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);
        return buffer.PieceTable.init(self.alloc, bytes);
    };
    return buffer.PieceTable.initMapped(self.alloc, mapping);
}

/// Open `path` in a new buffer unless it is already open (then switch).
/// The stored path is ABSOLUTE (like the CLI arg path): LSP uri building,
/// filetype detection and recent-file dedupe all assume absolute paths, so
/// a relative path here (file tree, :e, picker) would silently kill LSP
/// for the opened file.
pub fn openInBuffer(self: *App, path: []const u8) !void {
    const abs = try self.absolutePath(path);
    defer self.alloc.free(abs);
    for (self.buffers.items, 0..) |*buf, i| {
        if (buf.path) |p| {
            if (std.mem.eql(u8, p, abs)) {
                self.targetWindowForOpen(i);
                self.switchTo(i);
                return;
            }
        }
    }
    // load the file
    var file = std.Io.Dir.cwd().openFile(self.io, abs, .{ .mode = .read_only }) catch |e| {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ abs, @errorName(e) }));
        return;
    };
    defer file.close(self.io);
    const size = (try file.stat(self.io)).size;
    // u32-addressed piece table: refuse >= 4 GiB instead of panicking on
    // the @intCast below (see main()'s CLI open for the same guard).
    if (size >= std.math.maxInt(u32)) {
        try self.setMsg(try self.alloc.dupe(u8, "file too large (>4GiB)"));
        return;
    }

    try self.buffers.append(self.alloc, .{
        .pt = try self.loadPieceTable(file, size),
        .history = buffer.History.init(self.alloc),
        .path = try self.alloc.dupe(u8, abs),
    });
    try self.addRecent(abs);
    self.targetWindowForOpen(null);
    self.switchTo(self.buffers.items.len - 1);
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
    // clear every LSP response slot so stale results are not applied
    if (self.nav_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.nav_slot = null;
    if (self.completion_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.completion_slot = null;
    if (self.format_slot) |*v| json_rpc.freeValue(self.alloc, v);
    self.format_slot = null;
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
    if (self.buffers.items.len <= 1) return;
    self.cancelLspStart();
    if (self.lsp_client) |c| {
        c.deinit();
        self.lsp_client = null;
    }
    var buf = self.buffers.orderedRemove(buf_idx);
    buf.history.deinit();
    buf.pt.deinit();
    buf.folds.deinit(self.alloc);
    if (buf.spans_cache.len > 0) self.alloc.free(buf.spans_cache);
    if (buf.hl) |*h| h.deinit();
    if (buf.span_cache) |*sc| self.alloc.free(sc.spans);
    if (buf.path) |p| self.alloc.free(p);
    if (self.current >= self.buffers.items.len) self.current = self.buffers.items.len - 1;
    if (buf_idx < self.current) self.current -= 1;
    // point every window at the surviving buffer, fixing up shifted indices
    for (self.windows.items) |*w| {
        if (w.buf > buf_idx) {
            w.buf -= 1;
        } else if (w.buf == buf_idx) {
            w.buf = self.current;
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
    const buf = self.windows.items[self.current_win].buf;
    self.closeBufferAt(buf);
    self.windows.items[self.current_win].buf = self.current;
    self.windows.items[self.current_win].cursor = @min(self.windows.items[self.current_win].cursor, self.cur().pt.len());
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

/// Called when an insert session begins (all entry paths).
pub fn beginInsertSession(self: *App) void {
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
