//! The Git worker checks directory metadata for the open part of the tree.
//! Only a changed directory needs a new listing. No node pointers cross threads.
const std = @import("std");
const App = @import("../app.zig").App;
const Allocator = std.mem.Allocator;

pub const Stamp = struct {
    inode: std.Io.File.INode,
    mtime: std.Io.Timestamp,

    pub fn of(stat: std.Io.File.Stat) Stamp {
        return .{ .inode = stat.inode, .mtime = stat.mtime };
    }
};
const Target = struct { path: []const u8, stamp: ?Stamp };

pub const Targets = struct {
    arena: std.heap.ArenaAllocator,
    dirs: std.ArrayList(Target) = .empty,

    pub fn capture(app: *App) !Targets {
        var result = Targets{ .arena = .init(app.alloc) };
        errdefer result.arena.deinit();
        if (app.filetree_root) |root| {
            try result.add(root);
            for (app.filetree_rows.items) |row| {
                if (row.node.expanded) try result.add(row.node);
            }
        }
        return result;
    }

    fn add(self: *Targets, node: *App.TreeNode) !void {
        const a = self.arena.allocator();
        try self.dirs.append(a, .{ .path = try a.dupe(u8, node.path), .stamp = node.stamp });
    }

    pub fn scan(self: *const Targets, alloc: Allocator, io: std.Io) !Changes {
        var result = Changes{ .arena = .init(alloc) };
        errdefer result.arena.deinit();
        next_dir: for (self.dirs.items) |target| {
            const stat = std.Io.Dir.cwd().statFile(io, target.path, .{}) catch continue;
            if (std.meta.eql(target.stamp, @as(?Stamp, .of(stat)))) continue;
            var dir = std.Io.Dir.cwd().openDir(io, target.path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            const a = result.arena.allocator();
            var entries: std.ArrayList(Entry) = .empty;
            var it = dir.iterate();
            while (it.next(io) catch continue :next_dir) |entry| {
                try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .is_dir = entry.kind == .directory });
            }
            try result.dirs.append(a, .{ .path = try a.dupe(u8, target.path), .before = target.stamp, .after = .of(stat), .entries = entries.items });
        }
        return result;
    }
};

pub const Entry = struct { name: []const u8, is_dir: bool };
pub const Listing = struct { path: []const u8, before: ?Stamp, after: Stamp, entries: []const Entry };
pub const Changes = struct { arena: std.heap.ArenaAllocator, dirs: std.ArrayList(Listing) = .empty };
