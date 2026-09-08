//! workspace — App method group: Doom-Emacs-style workspaces
//! (swap-on-switch data model, docs/workspace-plan.md §2).
//!
//! The App's `buffers`/`windows`/`win_root`/`current`/`current_win` fields
//! ARE the current workspace's live state. The slot at
//! `workspaces.items[current_ws]` is that workspace's moved-from shell
//! (owned `name` only); every OTHER slot holds a complete workspace state.
//!
//! Zig's `std.ArrayList` assignment is a bitwise copy, NOT a real move:
//! after storing the App fields into a slot, the slot and the App point at
//! the same heap. Two rules follow, and every function here obeys them:
//!   • a LOAD must explicitly reset the source slot's containers to
//!     `.empty` / `win_root` to `null` (else deinit/wsDelete double-free);
//!   • after a STORE, the App's containers must be rebuilt from `.empty`
//!     before any append (else the append writes into the list that was
//!     just stashed into the slot, corrupting the stored workspace).

const std = @import("std");
const buffer = @import("../buffer/root.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

const Buffer = App.Buffer;
const Window = App.Window;
const WinNode = App.WinNode;
const Workspace = App.Workspace;

// ---- per-buffer teardown ----

/// Free every allocation owned by one buffer (`history`, `pt`, `folds`,
/// spans/decors caches, highlighter, span cache, path). Shared by
/// closeBufferAt (buffers.zig) and deinit (app.zig), and by workspace
/// teardown — deleting a workspace / clearing the session deinits each
/// stored buffer exactly once through this single path.
pub fn deinitBuffer(self: *App, buf: *Buffer) void {
    buf.history.deinit();
    buf.pt.deinit();
    buf.folds.deinit(self.alloc);
    if (buf.spans_cache.len > 0) self.alloc.free(buf.spans_cache);
    if (buf.decors_cache.len > 0) self.alloc.free(buf.decors_cache);
    if (buf.hl) |*h| h.deinit();
    if (buf.span_cache) |*sc| self.alloc.free(sc.spans);
    if (buf.path) |p| self.alloc.free(p);
}

// ---- workspace switching ----

/// Close every transient UI whose state indexes into the CURRENT
/// workspace's buffers/windows (picker/completion/hover/nav+diag lists,
/// easymotion, multi-cursor, grep/git previews). Their indices/cursors
/// point at the outgoing workspace's buffers, so this must run BEFORE any
/// workspace swap or teardown.
fn closeTransientUi(self: *App) void {
    self.closePicker();
    self.closeCompletion();
    self.clearHover();
    self.nav_list_active = false;
    self.diag_list_active = false;
    self.endEasyMotion();
    self.mc_active = false; // multi-cursor positions are old-buffer bytes
    self.freeGrepPreview();
    self.closeGitPreview();
}

/// Global cleanup once a (possibly fresh) workspace is current: the single
/// LSP client is bound to the previous workspace's buffer, so tear it down
/// and re-attach to the new current buffer (plan §2.1); per-buffer visual
/// state from the old workspace must not leak onto the new one. Mirrors
/// switchTo's cleanup (buffers.zig) plus teardownLsp and the scope
/// animation/cache reset.
fn afterWsActivate(self: *App) void {
    self.teardownLsp(false);
    self.ensureLsp();
    self.visual_anchor = null;
    self.in_insert = false;
    self.state.mode = .normal;
    self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
    self.invalidateInlayHints();
    self.clearDiagnostics();
    self.scope_anim = null;
    self.scope_cache = null;
    self.scheduleGitStatus();
}

/// Switch to the workspace at slot `idx` (no-op for out-of-range / the
/// current one): store the current App fields back into slot[cur]
/// (overwriting its moved-from shell — no leak), then load slot[idx] into
/// the App fields and reduce slot[idx] to a shell. The file tree travels
/// with the swap exactly like buffers/windows (per-workspace tree, §2.1).
pub fn wsSwitchTo(self: *App, idx: usize) void {
    if (idx >= self.workspaces.items.len or idx == self.current_ws) return;
    // 1. transient UI first — their indices point into the outgoing
    //    workspace's buffer list
    closeTransientUi(self);
    // 2. store the current state back into its slot (was a shell)
    const cur = self.current_ws;
    self.workspaces.items[cur].buffers = self.buffers;
    self.workspaces.items[cur].windows = self.windows;
    self.workspaces.items[cur].win_root = self.win_root;
    self.workspaces.items[cur].current = self.current;
    self.workspaces.items[cur].current_win = self.current_win;
    storeFiletree(self, &self.workspaces.items[cur]);
    // 3. load the target slot into the App fields…
    self.buffers = self.workspaces.items[idx].buffers;
    self.windows = self.workspaces.items[idx].windows;
    self.win_root = self.workspaces.items[idx].win_root;
    self.current = self.workspaces.items[idx].current;
    self.current_win = self.workspaces.items[idx].current_win;
    loadFiletree(self, &self.workspaces.items[idx]);
    // 4. …and reduce slot[idx] to a shell (bitwise copy ≠ move: without
    //    this both the App and the slot would own the same memory)
    self.workspaces.items[idx].buffers = .empty;
    self.workspaces.items[idx].windows = .empty;
    self.workspaces.items[idx].win_root = null;
    self.current_ws = idx;
    // 5. global cleanup for the newly active workspace
    afterWsActivate(self);
}

/// Store the App's live file-tree state into slot `ws` (overwriting its
/// moved-from shell — the shell's root is null and its rows are empty, so
/// nothing leaks). The tree is per workspace: each workspace keeps its own
/// root/rows/selection/scroll, swapped exactly like buffers/windows.
fn storeFiletree(self: *App, ws: *Workspace) void {
    ws.filetree_root = self.filetree_root;
    ws.filetree_rows = self.filetree_rows;
    ws.filetree_active = self.filetree_active;
    ws.filetree_sel = self.filetree_sel;
    ws.filetree_top = self.filetree_top;
    ws.focus = self.focus;
    ws.project_root = self.project_root;
}

/// Load slot `ws`'s file-tree state into the App fields and reduce the
/// slot's to a moved-from shell (root null, rows empty) so deinit/wsDelete
/// never double-frees. Called by every swap path after the buffers/windows
/// load, before the slot's other fields are reset.
fn loadFiletree(self: *App, ws: *Workspace) void {
    self.filetree_root = ws.filetree_root;
    self.filetree_rows = ws.filetree_rows;
    self.filetree_active = ws.filetree_active;
    self.filetree_sel = ws.filetree_sel;
    self.filetree_top = ws.filetree_top;
    self.focus = ws.focus;
    self.project_root = ws.project_root;
    ws.filetree_root = null;
    ws.filetree_rows = .empty;
    ws.filetree_active = false;
    ws.filetree_sel = 0;
    ws.filetree_top = 0;
    ws.focus = .buffer;
    ws.project_root = null;
}

/// Move `delta` workspaces (wrapping): `[`/`]`.
pub fn wsSwitchDelta(self: *App, delta: i32) void {
    const n = self.workspaces.items.len;
    if (n <= 1) return;
    const next = @mod(@as(i32, @intCast(self.current_ws)) + delta, @as(i32, @intCast(n)));
    self.wsSwitchTo(@intCast(next));
}

/// Create a fresh workspace (one empty buffer + one window + a leaf root,
/// exactly like startup — its empty buffer hits the dashboard logic, which
/// is expected) named with the first free "ws{N}" (N from 2; "main" is the
/// startup slot), then switch to it.
pub fn wsNew(self: *App) !void {
    closeTransientUi(self);
    // pick the first name "ws{N}" not taken by any slot
    var n: usize = 2;
    const name = blk: {
        while (true) : (n += 1) {
            const cand = try std.fmt.allocPrint(self.alloc, "ws{d}", .{n});
            var taken = false;
            for (self.workspaces.items) |ws| {
                if (std.mem.eql(u8, ws.name, cand)) {
                    taken = true;
                    break;
                }
            }
            if (!taken) break :blk cand;
            self.alloc.free(cand); // colliding candidate — discard it
        }
    };
    // Function-scope errdefer: frees `name` if ANY staging step below
    // fails. Once the slot append succeeds the slot owns `name` — and
    // nothing fallible runs after that point (the commit is plain
    // assignments and afterWsActivate is void), so this can never
    // double-free.
    errdefer self.alloc.free(name);
    // Stage the fresh workspace's state BEFORE touching the current one, so
    // an allocation failure leaves the current workspace fully intact.
    var fresh_bufs: std.ArrayList(Buffer) = .empty;
    var fresh_wins: std.ArrayList(Window) = .empty;
    var fresh_root: ?*WinNode = null;
    errdefer {
        if (fresh_root) |r| self.alloc.destroy(r);
        fresh_wins.deinit(self.alloc);
        for (fresh_bufs.items) |*b| self.deinitBuffer(b);
        fresh_bufs.deinit(self.alloc);
    }
    try fresh_bufs.append(self.alloc, .{
        .pt = try buffer.PieceTable.init(self.alloc, ""),
        .history = buffer.History.init(self.alloc),
    });
    try fresh_wins.append(self.alloc, .{ .buf = 0 });
    const leaf = try self.alloc.create(WinNode);
    leaf.* = .{ .leaf = 0 };
    fresh_root = leaf;
    // register the new slot (moved-from shell + duped name) — the slot now
    // owns `name`, and the function-scope errdefer above is inert from here
    // on (nothing fallible follows)
    try self.workspaces.append(self.alloc, .{
        .name = name,
        .buffers = .empty,
        .windows = .empty,
        .win_root = null,
        .current = 0,
        .current_win = 0,
    });
    // …then commit (nothing below can fail): stash the current state into
    // its slot and install the fresh workspace into the App fields.
    const new_idx = self.workspaces.items.len - 1;
    const old = self.current_ws;
    self.workspaces.items[old].buffers = self.buffers;
    self.workspaces.items[old].windows = self.windows;
    self.workspaces.items[old].win_root = self.win_root;
    self.workspaces.items[old].current = self.current;
    self.workspaces.items[old].current_win = self.current_win;
    storeFiletree(self, &self.workspaces.items[old]);
    self.buffers = fresh_bufs;
    self.windows = fresh_wins;
    self.win_root = fresh_root;
    self.current = 0;
    self.current_win = 0;
    // the fresh workspace starts with NO file tree: a clean root (built
    // lazily on the first <leader>e), its own selection/scroll — not a
    // share of the outgoing workspace's tree (the tree is per workspace).
    self.filetree_root = null;
    self.filetree_rows = .empty;
    self.filetree_active = false;
    self.filetree_sel = 0;
    self.filetree_top = 0;
    self.focus = .buffer;
    self.project_root = null;
    self.current_ws = new_idx;
    afterWsActivate(self);
}

/// Rename the current workspace: open the cmdline prefilled with the
/// current name; Enter renames via execWsRename. Mirrors requestRename's
/// cmdline handling (src/app/lsp_edit.zig).
pub fn wsRenameStart(self: *App) !void {
    self.cmdline.clearRetainingCapacity();
    try self.cmdline.appendSlice(self.alloc, self.curWsName());
    self.cmd_hist_idx = null;
    self.cmd_complete_idx = 0;
    self.clearCmdCompleteNames();
    try self.setMsg(try self.alloc.dupe(u8, ""));
    self.state.mode = .command;
    self.pending_ws_rename = true;
}

/// Enter in a pending workspace rename: adopt the cmdline's text as the
/// current workspace's name (an owned dupe replaces the old name). Empty
/// text keeps the old name.
pub fn execWsRename(self: *App) !void {
    self.pending_ws_rename = false;
    const new_name = self.cmdline.items;
    if (new_name.len == 0) return;
    const duped = try self.alloc.dupe(u8, new_name);
    const ws = &self.workspaces.items[self.current_ws];
    self.alloc.free(ws.name);
    ws.name = duped;
}

/// Delete the CURRENT workspace — its buffers, window tree and slot die;
/// the adjacent workspace (idx-1, or the first when the deleted one was
/// slot 0) becomes current. Refuses when it is the last workspace or any
/// buffer of the current workspace is dirty (the buffers die here, so a
/// dirty one means data loss — vim E37 style).
pub fn wsDelete(self: *App) void {
    if (self.workspaces.items.len <= 1) {
        const m = self.alloc.dupe(u8, "cannot delete the last workspace") catch return;
        self.setMsg(m) catch {};
        return;
    }
    var ndirty: usize = 0;
    for (self.buffers.items) |b| {
        if (b.dirty) ndirty += 1;
    }
    if (ndirty > 0) {
        const m = std.fmt.allocPrint(self.alloc, "E37: {d} unsaved buffer(s) in workspace '{s}'", .{ ndirty, self.curWsName() }) catch return;
        self.setMsg(m) catch {};
        return;
    }
    closeTransientUi(self);
    // the LSP client is bound to a buffer of the dying workspace
    self.teardownLsp(false);
    // free the current workspace's state (the App fields)…
    for (self.buffers.items) |*b| self.deinitBuffer(b);
    self.buffers.deinit(self.alloc);
    if (self.win_root) |root| self.freeWinTree(root);
    self.windows.deinit(self.alloc);
    self.buffers = .empty;
    self.windows = .empty;
    self.win_root = null;
    // …and its file tree (per workspace: the dying workspace's own root
    // and rows die with it)
    if (self.filetree_root) |root| self.freeFiletreeNode(root);
    self.filetree_rows.deinit(self.alloc);
    self.filetree_root = null;
    self.filetree_rows = .empty;
    self.filetree_active = false;
    self.filetree_sel = 0;
    self.filetree_top = 0;
    self.focus = .buffer;
    if (self.project_root) |p| self.alloc.free(p);
    self.project_root = null;
    // …drop its slot (name included)…
    const removed = self.current_ws;
    self.alloc.free(self.workspaces.items[removed].name);
    _ = self.workspaces.orderedRemove(removed);
    // …and load the adjacent slot (indices above `removed` have shifted
    // down, but `removed-1` / 0 still name the neighbor holding full state)
    const adj = if (removed > 0) removed - 1 else 0;
    self.buffers = self.workspaces.items[adj].buffers;
    self.windows = self.workspaces.items[adj].windows;
    self.win_root = self.workspaces.items[adj].win_root;
    self.current = self.workspaces.items[adj].current;
    self.current_win = self.workspaces.items[adj].current_win;
    loadFiletree(self, &self.workspaces.items[adj]);
    self.workspaces.items[adj].buffers = .empty;
    self.workspaces.items[adj].windows = .empty;
    self.workspaces.items[adj].win_root = null;
    self.current_ws = adj;
    afterWsActivate(self);
}

/// Clear the whole session: every workspace's buffers/windows/trees, every
/// slot name and the LSP client are freed and a single fresh empty "main"
/// workspace remains (like startup). Refuses while ANY buffer — current or
/// stored in any slot — is dirty, reporting the count.
pub fn wsKillSession(self: *App) !void {
    var ndirty: usize = 0;
    for (self.buffers.items) |b| {
        if (b.dirty) ndirty += 1;
    }
    // every stored slot is counted too: the current slot is a shell (no
    // buffers), the rest hold full states, so this covers each workspace
    // exactly once
    for (self.workspaces.items) |ws| {
        for (ws.buffers.items) |b| {
            if (b.dirty) ndirty += 1;
        }
    }
    if (ndirty > 0) {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "E37: {d} unsaved buffer(s) — save before clearing the session", .{ndirty}));
        return;
    }
    // Stage the replacement — a fresh empty "main" workspace — BEFORE
    // tearing the session down, so an allocation failure leaves the current
    // session fully intact. All fallible work happens here; everything
    // after the teardown below is plain, non-failing assignments.
    var fresh_bufs: std.ArrayList(Buffer) = .empty;
    var fresh_wins: std.ArrayList(Window) = .empty;
    var fresh_root: ?*WinNode = null;
    var fresh_workspaces: std.ArrayList(Workspace) = .empty;
    var main_name: ?[]u8 = null;
    errdefer {
        if (fresh_root) |r| self.alloc.destroy(r);
        fresh_wins.deinit(self.alloc);
        for (fresh_bufs.items) |*b| self.deinitBuffer(b);
        fresh_bufs.deinit(self.alloc);
        for (fresh_workspaces.items) |*ws| self.alloc.free(ws.name);
        fresh_workspaces.deinit(self.alloc);
        if (main_name) |n| self.alloc.free(n);
    }
    try fresh_bufs.append(self.alloc, .{
        .pt = try buffer.PieceTable.init(self.alloc, ""),
        .history = buffer.History.init(self.alloc),
    });
    try fresh_wins.append(self.alloc, .{ .buf = 0 });
    const leaf = try self.alloc.create(WinNode);
    leaf.* = .{ .leaf = 0 };
    fresh_root = leaf;
    try fresh_workspaces.ensureTotalCapacity(self.alloc, 1);
    main_name = try self.alloc.dupe(u8, "main");
    // ---- teardown the current session (nothing below fails) ----
    closeTransientUi(self);
    self.teardownLsp(false);
    // free the current workspace's state (App fields)
    for (self.buffers.items) |*b| self.deinitBuffer(b);
    self.buffers.deinit(self.alloc);
    if (self.win_root) |root| self.freeWinTree(root);
    self.windows.deinit(self.alloc);
    // the current workspace's file tree (per workspace)
    if (self.filetree_root) |root| self.freeFiletreeNode(root);
    self.filetree_rows.deinit(self.alloc);
    if (self.project_root) |p| self.alloc.free(p);
    // free every stored slot (current = shell, others = full states)
    for (self.workspaces.items) |*ws| {
        for (ws.buffers.items) |*b| self.deinitBuffer(b);
        ws.buffers.deinit(self.alloc);
        if (ws.win_root) |root| self.freeWinTree(root);
        ws.windows.deinit(self.alloc);
        // each stored slot's own file tree
        if (ws.filetree_root) |root| self.freeFiletreeNode(root);
        ws.filetree_rows.deinit(self.alloc);
        if (ws.project_root) |p| self.alloc.free(p);
        self.alloc.free(ws.name);
    }
    self.workspaces.deinit(self.alloc);
    // ---- commit: install the staged "main" workspace (no failures) ----
    self.buffers = fresh_bufs;
    self.windows = fresh_wins;
    self.win_root = fresh_root;
    self.current = 0;
    self.current_win = 0;
    // the fresh main starts with a clean file tree (per workspace)
    self.filetree_root = null;
    self.filetree_rows = .empty;
    self.filetree_active = false;
    self.filetree_sel = 0;
    self.filetree_top = 0;
    self.focus = .buffer;
    self.project_root = null;
    fresh_workspaces.appendAssumeCapacity(.{
        .name = main_name.?,
        .buffers = .empty,
        .windows = .empty,
        .win_root = null,
        .current = 0,
        .current_win = 0,
    });
    self.workspaces = fresh_workspaces;
    self.current_ws = 0;
    // Disarm the staging errdefer: the staged memory is now owned by the
    // App fields (bitwise copies), so a failure in the tail (the setMsg
    // below) must not free it a second time.
    fresh_bufs = .empty;
    fresh_wins = .empty;
    fresh_root = null;
    fresh_workspaces = .empty;
    main_name = null;
    afterWsActivate(self);
    try self.setMsg(try self.alloc.dupe(u8, "session cleared"));
}

/// The current workspace's name (owned by its slot).
pub fn curWsName(self: *const App) []const u8 {
    return self.workspaces.items[self.current_ws].name;
}
