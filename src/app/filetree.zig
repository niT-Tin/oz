//! filetree — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const nav_tabs = @import("navigator.zig");

/// One node of the lazy directory tree (snacks-explorer style). `name`
/// (basename) and `path` (relative, owned; dir paths carry a trailing
/// '/') are owned by the node. Children are populated only when a dir is
/// expanded; collapsed dirs keep their loaded children (cheap re-expand).
pub const TreeNode = struct {
    name: []u8,
    path: []u8,
    is_dir: bool,
    expanded: bool,
    children: std.ArrayList(*TreeNode),
    parent: ?*TreeNode,
};

/// One visible sidebar row: the node plus its DFS depth (for indent).
pub const FiletreeRow = struct { node: *TreeNode, depth: usize };

// ---- file tree (<leader>e / <leader>E) ----

/// Process cwd as an owned absolute path (no trailing slash).
pub fn cwdPath(self: *App) ![]u8 {
    var buf: [4096:0]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return self.alloc.dupe(u8, "/");
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) : (n += 1) {}
    return self.alloc.dupe(u8, buf[0..n]);
}

/// Absolute directory the current workspace operates in (owned, no trailing
/// slash): its project root when one has been set (a file was opened), else
/// the process cwd.
pub fn currentRootDir(self: *App) ![]u8 {
    if (self.project_root) |p| return self.alloc.dupe(u8, p);
    return self.cwdPath();
}

/// True when directory `dir` contains a `.git` entry (a directory in a
/// normal clone, a file in a worktree). Used to find a project's root.
fn dirHasGit(self: *App, dir: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(self.io, dir, .{}) catch return false;
    defer d.close(self.io);
    _ = d.statFile(self.io, ".git", .{}) catch return false;
    return true;
}

/// Absolute project root for an opened file: walk up from its directory to
/// the nearest ancestor with a `.git` entry; with none, the file's own
/// directory is the root. Returns an owned path (no trailing slash).
pub fn detectProjectRoot(self: *App, file_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(file_path) orelse "/";
    var cur = try self.alloc.dupe(u8, dir);
    const fallback = try self.alloc.dupe(u8, dir);
    errdefer self.alloc.free(fallback);
    while (true) {
        if (dirHasGit(self, cur)) {
            self.alloc.free(fallback);
            return cur;
        }
        const parent = std.fs.path.dirname(cur);
        if (parent == null or std.mem.eql(u8, parent.?, cur)) break;
        const next = try self.alloc.dupe(u8, parent.?);
        self.alloc.free(cur);
        cur = next;
    }
    self.alloc.free(cur);
    return fallback;
}

/// Adopt an opened file's project root as the workspace root, invalidating
/// the file tree and the fuzzy-file picker cache when it actually changes.
/// Called by openInBuffer after the path is resolved to absolute form.
pub fn setProjectRoot(self: *App, file_path: []const u8) void {
    const root = self.detectProjectRoot(file_path) catch return;
    defer self.alloc.free(root);
    // Compare against the EFFECTIVE root — project_root, or the process cwd
    // while project_root is unset. Opening a file under the current tree's
    // directory (e.g. the first open in cwd) must NOT invalidate the tree.
    const effective = self.currentRootDir() catch return;
    defer self.alloc.free(effective);
    if (std.mem.eql(u8, root, effective)) return; // no change — keep tree/cache
    if (self.project_root) |p| self.alloc.free(p);
    self.project_root = self.alloc.dupe(u8, root) catch return;
    // The file tree is rooted at the OLD directory: drop it so <leader>e
    // rebuilds at the new root (it is built lazily, per workspace).
    if (self.filetree_root) |old| self.freeFiletreeNode(old);
    self.filetree_root = null;
    self.filetree_rows.clearRetainingCapacity();
    self.filetree_active = false;
    self.navigator_peek = false;
    self.filetree_sel = 0;
    self.filetree_top = 0;
    self.focus = .buffer;
    // The picker cache was walked under the OLD root: drop it so the next
    // <leader>sf re-walks (the cache is global, so it must not leak files
    // from another workspace's project).
    for (self.picker_files.items) |f| self.alloc.free(f);
    self.picker_files.clearRetainingCapacity();
    if (self.picker_root) |p| self.alloc.free(p);
    self.picker_root = null;
}

pub fn toggleFiletree(self: *App) !void {
    self.filetree_pending_g = false;
    if (self.filetree_active) {
        self.filetree_active = false;
        self.navigator_peek = false;
        self.focus = .buffer;
        return;
    }
    self.filetree_top = 0;
    self.filetree_sel = 0;
    // <leader>e is the canonical Files entry; the tab strip can switch to
    // Notes/Agents afterwards (Tab/Shift-Tab or 1/2/3).
    self.navigator_tab = .files;
    self.focus = .navigator;
    // Compact mode has no inline list: the explicit navigator entry opens
    // its peek so the focused pane has visible content. Esc returns to the
    // editor and leaves the icon rail.
    self.navigator_peek = self.navigatorMode() == .compact;
    // A built tree owns its browsing root independently from project/LSP
    // root. Closing and reopening Files must keep a Backspace navigation.
    if (self.filetree_root == null) {
        const root_dir = try self.currentRootDir();
        defer self.alloc.free(root_dir);
        self.filetree_root = try makeFiletreeRoot(self, root_dir);
    }
    try self.rebuildFiletreeRows();
    self.filetree_active = true;
}

/// Build a replacement off to the side: permission/read failures leave the
/// currently displayed tree alive and its node pointers valid.
fn makeFiletreeRoot(self: *App, path: []const u8) !*TreeNode {
    const root = try self.alloc.create(TreeNode);
    errdefer self.alloc.destroy(root);
    const owned_name = try self.alloc.dupe(u8, "");
    errdefer self.alloc.free(owned_name);
    const owned_path = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(owned_path);
    root.* = .{ .name = owned_name, .path = owned_path, .is_dir = true, .expanded = true, .children = .empty, .parent = null };
    errdefer {
        for (root.children.items) |child| self.freeFiletreeNode(child);
        root.children.deinit(self.alloc);
    }
    var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
    defer dir.close(self.io);
    try self.walkTreeLevel(dir, root);
    self.sortTreeChildren(root);
    return root;
}

fn filetreeParent(self: *App) !void {
    const old = self.filetree_root orelse return;
    const path = std.fs.path.dirname(old.path) orelse return;
    if (std.mem.eql(u8, path, old.path)) return;
    const replacement = makeFiletreeRoot(self, path) catch |err| {
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "Files: {s}", .{@errorName(err)}));
        return;
    };
    var selected: usize = 0;
    for (replacement.children.items, 0..) |child, i| {
        if (std.mem.eql(u8, child.path, old.path)) {
            selected = i;
            break;
        }
    }
    self.freeFiletreeNode(old);
    self.filetree_root = replacement;
    self.filetree_sel = selected;
    self.filetree_top = 0;
    try self.rebuildFiletreeRows();
    // project_root, process cwd, picker/LSP/agent root remain unchanged.
}

/// Walk one directory level into `node.children` (lazy expansion). Child
/// paths are ABSOLUTE (node.path + "/" + name, no trailing slash), so a file
/// opens / a dir expands correctly regardless of which directory the tree is
/// rooted at.
pub fn walkTreeLevel(self: *App, dir: std.Io.Dir, node: *TreeNode) !void {
    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
        const is_dir = (entry.kind == .directory);
        const child_path = try std.fs.path.join(self.alloc, &.{ node.path, name });
        errdefer self.alloc.free(child_path);
        const child_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(child_name);
        const child = try self.alloc.create(TreeNode);
        errdefer self.alloc.destroy(child);
        child.* = .{
            .name = child_name,
            .path = child_path,
            .is_dir = is_dir,
            .expanded = false,
            .children = .empty,
            .parent = node,
        };
        try node.children.append(self.alloc, child);
    }
}

/// Directories first, then files; each group sorted by byte order.
pub fn sortTreeChildren(self: *App, node: *TreeNode) void {
    _ = self;
    std.mem.sort(*TreeNode, node.children.items, {}, struct {
        fn lt(_: void, a: *TreeNode, b: *TreeNode) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}

pub fn expandDir(self: *App, node: *TreeNode) !void {
    if (!node.is_dir or node.expanded) return;
    // Children are loaded exactly once, on first expand. A collapsed dir
    // KEEPS its loaded children (collapseDir only flips `expanded`), so a
    // re-expand must not walk the directory again — walkTreeLevel appends
    // to children, and re-walking after every h/l cycle duplicated every
    // entry (the tree grew on each toggle). Only a never-loaded dir
    // (children still empty) hits the filesystem.
    if (node.children.items.len == 0) {
        var dir = try std.Io.Dir.cwd().openDir(self.io, node.path, .{ .iterate = true });
        defer dir.close(self.io);
        try self.walkTreeLevel(dir, node);
        self.sortTreeChildren(node);
    }
    node.expanded = true;
    try self.rebuildFiletreeRows();
}

/// Collapse an expanded dir; its (already loaded) children stay in the
/// tree but become invisible until re-expanded.
pub fn collapseDir(self: *App, node: *TreeNode) !void {
    if (!node.is_dir or !node.expanded) return;
    node.expanded = false;
    try self.rebuildFiletreeRows();
}

/// DFS over the expanded subtree starting at the root's children.
pub fn rebuildFiletreeRows(self: *App) !void {
    self.filetree_rows.clearRetainingCapacity();
    const root = self.filetree_root orelse return;
    try self.appendTreeRows(root, 0, &self.filetree_rows);
}

pub fn appendTreeRows(self: *App, node: *TreeNode, depth: usize, rows: *std.ArrayList(FiletreeRow)) !void {
    for (node.children.items) |child| {
        try rows.append(self.alloc, .{ .node = child, .depth = depth });
        if (child.is_dir and child.expanded) try self.appendTreeRows(child, depth + 1, rows);
    }
}

pub fn filetreeNodeAt(self: *App, idx: usize) ?*TreeNode {
    if (idx < self.filetree_rows.items.len) return self.filetree_rows.items[idx].node;
    return null;
}

/// Row index of `node` in the visible list, or null.
pub fn rowIndexOf(self: *App, node: *TreeNode) ?usize {
    for (self.filetree_rows.items, 0..) |row, i| {
        if (row.node == node) return i;
    }
    return null;
}

pub fn locateInFiletree(self: *App) !void {
    if (self.filetree_root == null) {
        try self.toggleFiletree();
    } else {
        try self.rebuildFiletreeRows();
    }
    self.navigator_tab = .files;
    self.focus = .navigator;
    self.navigator_peek = self.navigatorMode() == .compact;
    if (self.cur().path) |p| {
        // Reveal the file's ancestors (expanding any folded dirs on the
        // way) and select the matching row.
        if (try self.revealPath(p)) |node| {
            if (self.rowIndexOf(node)) |i| {
                self.filetree_sel = i;
                self.filetree_top = 0;
            }
        }
    }
    self.filetree_active = true;
}

/// Walk the tree along `path`'s components, expanding any ancestor dir,
/// and return the node matching the final component (or null). `path` is the
/// buffer's ABSOLUTE path; the tree is rooted at `root.path` (absolute), so
/// the root prefix is stripped before walking. A relative `path` (should not
/// happen from locateInFiletree) is walked from the root's children directly.
pub fn revealPath(self: *App, path: []const u8) !?*TreeNode {
    const root = self.filetree_root orelse return null;
    const prefix = root.path;
    var rest = path;
    if (std.mem.eql(u8, prefix, path)) return null; // path IS the root itself
    if (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/') {
        rest = path[prefix.len + 1 ..];
    }
    var cur_node = root;
    while (rest.len > 0) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const comp = rest[0..slash];
        var found: ?*TreeNode = null;
        for (cur_node.children.items) |child| {
            if (std.mem.eql(u8, child.name, comp)) {
                found = child;
                break;
            }
        }
        const child = found orelse return null;
        if (slash == rest.len) return child;
        if (child.is_dir and !child.expanded) try self.expandDir(child);
        cur_node = child;
        rest = rest[slash + 1 ..];
    }
    return null;
}

/// Activate the selected row exactly like Enter: a directory toggles its
/// expansion (focus stays in the tree); a file opens and focus moves back to
/// the buffer so typing edits text instead of the tree. Shared by
/// `filetreeKey` and the `<leader>j` hint action so the two cannot drift.
pub fn activateFiletreeSelection(self: *App) !void {
    const node = self.filetreeNodeAt(self.filetree_sel) orelse return;
    if (node.is_dir) {
        if (node.expanded) {
            try self.collapseDir(node);
        } else {
            try self.expandDir(node);
        }
    } else {
        // open the file but keep the tree visible — only <space>e
        // (toggleFiletree) or Esc closes it; focus moves back to the buffer
        // so typing edits, not the tree. In compact mode the peek closes:
        // the opened buffer, not the drawer, is the result.
        self.navigator_peek = false;
        self.focus = .buffer;
        try self.openFile(node.path);
    }
}

/// j/k/Enter/Esc/h/l for the tree; returns true if consumed.
/// Move the filetree selection by `delta`, clamped to the visible row list.
/// Shared by j/k and the mouse wheel (one selection policy).
pub fn moveFiletreeCursor(self: *App, delta: i32) void {
    const n = self.filetree_rows.items.len;
    if (n == 0) return;
    var idx: i32 = @intCast(@min(self.filetree_sel, n - 1));
    idx += delta;
    if (idx < 0) idx = 0;
    if (idx >= @as(i32, @intCast(n))) idx = @intCast(n - 1);
    self.filetree_sel = @intCast(idx);
}

pub fn filetreeKey(self: *App, key: vaxis.Key) !bool {
    const was_g = self.filetree_pending_g;
    self.filetree_pending_g = false;
    // Ctrl-w is handled by the shared focus router before reaching Files.
    // Only explicit global surfaces may pass through; editor motions and
    // mutations must never run behind a focused navigator.
    if (key.mods.alt) return !(key.codepoint == 'r' or key.codepoint == 'w' or key.codepoint == 'e');
    if (key.mods.ctrl or key.mods.super or key.mods.hyper or key.mods.meta) return true;
    // Kitty may report base g plus shifted/text G. Interpret the logical
    // character only after command modifiers have been handled above.
    const cp = key.shifted_codepoint orelse blk: {
        if (key.text) |text| {
            if (text.len > 0 and text.len <= 4) break :blk std.unicode.utf8Decode(text) catch key.codepoint;
        }
        break :blk key.codepoint;
    };
    switch (cp) {
        vaxis.Key.backspace => {
            try filetreeParent(self);
            return true;
        },
        'a' => {
            try beginFiletreeCreate(self);
            return true;
        },
        'g' => {
            if (was_g) {
                self.filetree_sel = 0;
                self.filetree_top = 0;
            } else self.filetree_pending_g = true;
            return true;
        },
        'G' => {
            self.filetree_sel = self.filetree_rows.items.len -| 1;
            return true;
        },
        'j', vaxis.Key.down => {
            moveFiletreeCursor(self, 1);
            return true;
        },
        'k', vaxis.Key.up => {
            moveFiletreeCursor(self, -1);
            return true;
        },
        // h: fold the current dir; on an already-folded dir jump to its
        // parent's row. Files swallow h (no-op) so it never reaches the
        // buffer — pane switching is Ctrl-w hjkl.
        'h', vaxis.Key.left => {
            const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
            if (node.is_dir and node.expanded) {
                try self.collapseDir(node);
            } else if (node.is_dir and !node.expanded) {
                if (node.parent) |parent| {
                    if (parent != self.filetree_root) {
                        if (self.rowIndexOf(parent)) |i| self.filetree_sel = i;
                    }
                }
            }
            return true;
        },
        // l: expand the current dir (swallowed on files / open dirs).
        'l', vaxis.Key.right => {
            const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
            if (node.is_dir and !node.expanded) try self.expandDir(node);
            return true;
        },
        vaxis.Key.enter => {
            try self.activateFiletreeSelection();
            return true;
        },
        vaxis.Key.escape => {
            self.closeNavigator();
            return true;
        },
        // Keep command/leader entry and keymap help available; everything
        // else belongs to Files, including unbound editing keys.
        ' ', ':', vaxis.Key.f1 => return false,
        else => return true,
    }
}

/// Free a node and its whole subtree (owned name/path/children).
pub fn freeFiletreeNode(self: *App, node: *TreeNode) void {
    for (node.children.items) |child| self.freeFiletreeNode(child);
    node.children.deinit(self.alloc);
    self.alloc.free(node.name);
    self.alloc.free(node.path);
    self.alloc.destroy(node);
}

// Filename collection uses command-mode input ownership, but has its own
// float and filesystem action; it never enters buffer Insert or executes Ex.
fn beginFiletreeCreate(self: *App) !void {
    const root = self.filetree_root orelse return;
    const node = self.filetreeNodeAt(self.filetree_sel) orelse root;
    const parent = if (node.is_dir) node else node.parent orelse root;
    const captured = try self.alloc.dupe(u8, parent.path);
    if (self.pending_filetree_create) |old| self.alloc.free(old);
    self.pending_filetree_create = captured;
    self.filetree_pending_g = false;
    self.cmdline.clearRetainingCapacity();
    self.clearCmdCompleteNames();
    self.cmd_hist_idx = null;
    self.cmdline_kind = .ex;
    self.state.mode = .command;
}

fn endFiletreeCreate(self: *App) void {
    if (self.pending_filetree_create) |path| self.alloc.free(path);
    self.pending_filetree_create = null;
    self.cmdline.clearRetainingCapacity();
    self.state.mode = .normal;
}

fn nodeWithPath(node: *TreeNode, path: []const u8) ?*TreeNode {
    if (std.mem.eql(u8, node.path, path)) return node;
    for (node.children.items) |child| if (nodeWithPath(child, path)) |found| return found;
    return null;
}

/// Reload only the affected directory, preserving every unrelated subtree.
fn refreshCreatedDirectory(self: *App, path: []const u8, leaf: []const u8) !void {
    const root = self.filetree_root orelse return;
    const node = nodeWithPath(root, path) orelse return;
    var replacement = node.*;
    replacement.children = .empty;
    var transferred = false;
    errdefer if (!transferred) {
        for (replacement.children.items) |child| self.freeFiletreeNode(child);
        replacement.children.deinit(self.alloc);
    };
    var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
    defer dir.close(self.io);
    try self.walkTreeLevel(dir, &replacement);
    self.sortTreeChildren(&replacement);
    for (node.children.items) |child| self.freeFiletreeNode(child);
    node.children.deinit(self.alloc);
    node.children = replacement.children;
    transferred = true;
    node.expanded = true;
    for (node.children.items) |child| child.parent = node;
    try self.rebuildFiletreeRows();
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, leaf)) {
            if (self.rowIndexOf(child)) |index| self.filetree_sel = index;
            break;
        }
    }
}

pub fn filetreeCreatePaste(self: *App, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text) or self.cmdline.items.len + text.len > 4096) {
        try self.setMsg(try self.alloc.dupe(u8, "InvalidName"));
        return;
    }
    for (text) |b| if (b < 0x20 or b == 0x7f) {
        try self.setMsg(try self.alloc.dupe(u8, "InvalidName"));
        return;
    };
    try self.cmdline.appendSlice(self.alloc, text);
}

pub fn filetreeCreateKey(self: *App, key: vaxis.Key) !void {
    if (self.msg) |message| self.alloc.free(message);
    self.msg = null;
    if (key.codepoint == vaxis.Key.escape or (key.mods.ctrl and key.codepoint == 'c')) {
        endFiletreeCreate(self);
        return;
    }
    if (key.mods.ctrl and key.codepoint == 'u') {
        self.cmdline.clearRetainingCapacity();
        return;
    }
    if (key.codepoint == vaxis.Key.enter) {
        if (self.cmdline.items.len == 0) {
            endFiletreeCreate(self);
            return;
        }
        const policy = @import("filetree_create.zig");
        const path = self.pending_filetree_create orelse return;
        policy.create(self.io, path, self.cmdline.items) catch |err| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "{s} · enter one name, / for directory", .{@errorName(err)}));
            return;
        };
        const name = try policy.parseName(self.cmdline.items);
        refreshCreatedDirectory(self, path, name.leaf) catch |err| {
            endFiletreeCreate(self);
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "Created; Files refresh: {s}", .{@errorName(err)}));
            return;
        };
        endFiletreeCreate(self);
        return;
    }
    if (key.codepoint == vaxis.Key.backspace) {
        if (self.cmdline.items.len > 0) {
            var last = self.cmdline.items.len - 1;
            while (last > 0 and (self.cmdline.items[last] & 0xC0) == 0x80) last -= 1;
            self.cmdline.shrinkRetainingCapacity(last);
        }
        return;
    }
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.text) |text| try filetreeCreatePaste(self, text);
}

pub fn drawFiletreeCreate(self: *App, a: std.mem.Allocator, win: vaxis.Window) !void {
    const path = self.pending_filetree_create orelse return;
    const width: u16 = @min(win.width -| 2, 64);
    const height: u16 = 5;
    if (width < 6 or win.height < height) return;
    const x = (win.width - width) / 2;
    const y = (win.height - height) / 2;
    const inner = width - 4;
    const bg: vaxis.Color = .{ .rgb = self.theme.bg_float };
    const outer = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = width, .height = height });
    outer.fill(.{ .style = .{ .bg = bg } });
    const border = @import("chrome.zig").panelBorderStyle(self.theme, true, bg);
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        outer.writeCell(col, 0, .{ .char = .{ .grapheme = if (col == 0) "╭" else if (col == width - 1) "╮" else "─", .width = 1 }, .style = border });
        outer.writeCell(col, height - 1, .{ .char = .{ .grapheme = if (col == 0) "╰" else if (col == width - 1) "╯" else "─", .width = 1 }, .style = border });
    }
    var row: u16 = 1;
    while (row + 1 < height) : (row += 1) {
        outer.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
        outer.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
    }
    const autil = @import("util.zig");
    const title = autil.cellFitPrefix(win, " New file / directory ", width - 2).slice;
    _ = outer.print(&.{.{ .text = title, .style = border }}, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    const context = try std.fmt.allocPrint(a, "In: {s}", .{path});
    _ = outer.print(&.{.{ .text = autil.cellFitPrefix(win, context, inner).slice, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = bg } }}, .{ .row_offset = 1, .col_offset = 2, .wrap = .none });
    var start: usize = 0;
    while (start < self.cmdline.items.len and self.textWidth(win, self.cmdline.items[start..]) >= inner) {
        start += std.unicode.utf8ByteSequenceLength(self.cmdline.items[start]) catch 1;
    }
    const input = self.cmdline.items[start..];
    _ = outer.print(&.{.{ .text = input, .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = bg } }}, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });
    const hint = self.msg orelse "Enter create · / directory · Esc cancel";
    _ = outer.print(&.{.{ .text = autil.cellFitPrefix(win, hint, inner).slice, .style = .{ .fg = .{ .rgb = if (self.msg != null) self.theme.diag_error else self.theme.fg_dim }, .bg = bg } }}, .{ .row_offset = 3, .col_offset = 2, .wrap = .none });
    self.vx.screen.cursor = .{ .row = y + 2, .col = @intCast(x + 2 + self.textWidth(win, input)) };
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_shape = .beam;
}
