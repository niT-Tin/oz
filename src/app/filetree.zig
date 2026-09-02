//! filetree — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;

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

pub fn toggleFiletree(self: *App) !void {
    if (self.filetree_active) {
        self.filetree_active = false;
        return;
    }
    self.filetree_top = 0;
    self.filetree_sel = 0;
    self.focus = .filetree;
    if (self.filetree_root == null) {
        // Build the cwd node; only its first level is scanned — deeper
        // directories are walked lazily when expanded (snacks style).
        const root = try self.alloc.create(TreeNode);
        root.* = .{
            .name = try self.alloc.dupe(u8, ""),
            .path = try self.alloc.dupe(u8, ""),
            .is_dir = true,
            .expanded = true, // the cwd's own children are visible
            .children = .empty,
            .parent = null,
        };
        var dir = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
        defer dir.close(self.io);
        try self.walkTreeLevel(dir, root);
        self.sortTreeChildren(root);
        self.filetree_root = root;
    }
    try self.rebuildFiletreeRows();
    self.filetree_active = true;
}

/// Walk one directory level into `node.children` (lazy expansion).
pub fn walkTreeLevel(self: *App, dir: std.Io.Dir, node: *TreeNode) !void {
    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
        const is_dir = (entry.kind == .directory);
        const child_path = try std.fmt.allocPrint(self.alloc, "{s}{s}{s}", .{ node.path, name, if (is_dir) "/" else "" });
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
    self.focus = .filetree;
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
/// and return the node matching the final component (or null).
pub fn revealPath(self: *App, path: []const u8) !?*TreeNode {
    const root = self.filetree_root orelse return null;
    var cur_node = root;
    var rest = path;
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

/// j/k/Enter/Esc/h/l for the tree; returns true if consumed.
pub fn filetreeKey(self: *App, key: vaxis.Key) !bool {
    switch (key.codepoint) {
        'j', vaxis.Key.down => {
            if (self.filetree_sel + 1 < self.filetree_rows.items.len) self.filetree_sel += 1;
            return true;
        },
        'k', vaxis.Key.up => {
            if (self.filetree_sel > 0) self.filetree_sel -= 1;
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
            const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
            if (node.is_dir) {
                if (node.expanded) {
                    try self.collapseDir(node);
                } else {
                    try self.expandDir(node);
                }
            } else {
                // open the file but keep the tree visible — only
                // <space>e (toggleFiletree) or Esc closes it; focus moves
                // back to the buffer so typing edits, not the tree
                self.focus = .buffer;
                try self.openFile(node.path);
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

/// Free a node and its whole subtree (owned name/path/children).
pub fn freeFiletreeNode(self: *App, node: *TreeNode) void {
    for (node.children.items) |child| self.freeFiletreeNode(child);
    node.children.deinit(self.alloc);
    self.alloc.free(node.name);
    self.alloc.free(node.path);
    self.alloc.destroy(node);
}
