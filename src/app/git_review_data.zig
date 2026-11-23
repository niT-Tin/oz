//! Read-only repository snapshots for Git Review. All repository access and patch
//! indexing run on a worker. Requests own their paths/revisions, and completed
//! results borrow only from the job's arena.
const std = @import("std");
const porcelain = @import("repo_status.zig");
const patch_view = @import("git_review_patch.zig");
const Allocator = std.mem.Allocator;

pub const history_page_size = 256;
const patch_byte_limit = 4 * 1024 * 1024;
const patch_line_limit = 32 * 1024;
const max_files = 100_000;

pub const Group = enum { staged, unstaged, untracked, conflicts, comparison, commit };

pub const File = struct {
    group: Group,
    status: u8,
    path: []const u8,
    root: []const u8 = "",
    old_path: ?[]const u8 = null,
    added: ?u64 = null,
    removed: ?u64 = null,
    binary: bool = false,
    unborn: bool = false,
    base: []const u8 = "",
    target: []const u8 = "",

    pub fn label(self: File) []const u8 {
        return switch (self.group) {
            .staged => if (self.unborn) "empty tree → index" else "HEAD → index",
            .unstaged => "index → worktree",
            .untracked => "empty → untracked file",
            .conflicts => "ours → conflicted worktree",
            .comparison => "merge base → HEAD",
            .commit => "parent → commit",
        };
    }

    fn clone(self: File, a: Allocator) !File {
        var copy = self;
        copy.root = try a.dupe(u8, self.root);
        copy.path = try a.dupe(u8, self.path);
        if (self.old_path) |old| copy.old_path = try a.dupe(u8, old);
        copy.base = try a.dupe(u8, self.base);
        copy.target = try a.dupe(u8, self.target);
        return copy;
    }
};

pub const Commit = struct {
    hash: []const u8,
    short_hash: []const u8,
    parents: []const []const u8,
    author: []const u8,
    date: []const u8,
    labels: []const u8,
    subject: []const u8,
    message: []const u8 = "",
    // First line contains this commit's node, later lines connect it to its parents.
    graph: []const u8 = "",
};

pub const Request = union(enum) {
    changes,
    changes_shared: porcelain.ReviewTarget,
    history,
    history_page: struct { tip: []const u8, offset: usize },
    comparison: []const u8,
    detail: struct { hash: []const u8, parent_index: usize = 0 },
    patch: File,

    fn clone(self: Request, a: Allocator) !Request {
        return switch (self) {
            .changes, .history => self,
            .changes_shared => |target| .{ .changes_shared = .{
                .scope = try a.dupe(u8, target.scope),
                .generation = target.generation,
                .scan = target.scan,
            } },
            .history_page => |p| .{ .history_page = .{ .tip = try a.dupe(u8, p.tip), .offset = p.offset } },
            .comparison => |ref| .{ .comparison = try a.dupe(u8, ref) },
            .detail => |d| .{ .detail = .{ .hash = try a.dupe(u8, d.hash), .parent_index = d.parent_index } },
            .patch => |file| .{ .patch = try file.clone(a) },
        };
    }
};

pub const Result = struct {
    root: []const u8 = "",
    label: []const u8 = "",
    refs: []const []const u8 = &.{},
    files: []const File = &.{},
    commits: []const Commit = &.{},
    commit: ?Commit = null,
    parent_index: usize = 0,
    history_tip: []const u8 = "",
    history_offset: usize = 0,
    history_more: bool = false,
    patch_truncated: bool = false,
    added: u64 = 0,
    removed: u64 = 0,
    patch: []const u8 = "",
    view: patch_view.View = .{},
    problem: ?[]const u8 = null,
};

pub const Job = struct {
    owner: Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    cwd: []const u8,
    request: Request,
    result: Result = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    navigator_snapshot: ?porcelain.Snapshot = null,
    wake_ctx: ?*anyopaque,
    wake_fn: ?*const fn (*anyopaque) void,

    pub fn start(owner: Allocator, io: std.Io, cwd: []const u8, request: Request, wake_ctx: ?*anyopaque, wake_fn: ?*const fn (*anyopaque) void) !*Job {
        const job = try owner.create(Job);
        errdefer owner.destroy(job);
        job.* = .{
            .owner = owner,
            .arena = .init(owner),
            .io = io,
            .cwd = "",
            .request = .changes,
            .wake_ctx = wake_ctx,
            .wake_fn = wake_fn,
        };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.cwd = try a.dupe(u8, cwd);
        job.request = try request.clone(a);
        job.thread = try std.Thread.spawn(.{}, main, .{job});
        return job;
    }

    pub fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        if (self.navigator_snapshot) |*snap| snap.deinit(self.owner);
        self.arena.deinit();
        self.owner.destroy(self);
    }

    fn main(self: *Job) void {
        self.load() catch |err| {
            if (self.result.problem == null) self.result.problem = switch (err) {
                error.StreamTooLong => "Repository metadata exceeds the review size limit",
                error.TooManyChangedFiles => "More than 100,000 changed files",
                error.RepositoryChanged => "Repository changed while loading the patch",
                error.GitPatchUnavailable => "Git could not read this patch",
                else => @errorName(err),
            };
        };
        self.done.store(true, .release);
        if (self.wake_fn) |wake| if (self.wake_ctx) |ctx| wake(ctx);
    }

    fn load(self: *Job) !void {
        self.result.root = chomp(try self.git(&.{ "rev-parse", "--show-toplevel" }));
        self.cwd = self.result.root;
        switch (self.request) {
            .changes, .changes_shared => try self.changes(),
            .history => try self.history(null, 0),
            .history_page => |p| try self.history(p.tip, p.offset),
            .comparison => |ref| try self.comparison(ref),
            .detail => |d| try self.detail(d.hash, d.parent_index),
            .patch => |file| try self.loadPatch(file),
        }
    }

    // Disabling optional locks keeps status from refreshing the on-disk index.
    // Literal pathspecs keep names containing '*', '[', or ':' scoped to one file.
    fn gitArgv(argv: *[48][]const u8, args: []const []const u8) []const []const u8 {
        const flags = [_][]const u8{ "git", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "color.ui=false" };
        std.debug.assert(flags.len + args.len <= argv.len);
        @memcpy(argv[0..flags.len], &flags);
        @memcpy(argv[flags.len..][0..args.len], args);
        return argv[0 .. flags.len + args.len];
    }

    fn run(self: *Job, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.arena.allocator(), self.io, .{
            .argv = argv,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(128 * 1024),
            .cwd = .{ .path = self.cwd },
        });
    }

    fn command(self: *Job, args: []const []const u8) !std.process.RunResult {
        var argv: [48][]const u8 = undefined;
        return self.run(gitArgv(&argv, args));
    }

    fn stream(self: *Job, args: []const []const u8) !std.process.Child {
        var argv: [48][]const u8 = undefined;
        return std.process.spawn(self.io, .{
            .argv = gitArgv(&argv, args),
            .cwd = .{ .path = self.cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
    }

    fn output(self: *Job, result: std.process.RunResult) ![]const u8 {
        if (result.term == .exited and result.term.exited == 0) return result.stdout;
        if (result.stderr.len != 0) self.result.problem = chomp(result.stderr);
        return error.GitCommandFailed;
    }

    fn git(self: *Job, args: []const []const u8) ![]const u8 {
        return self.output(try self.command(args));
    }

    fn head(self: *Job) !?[]const u8 {
        const r = try self.command(&.{ "rev-parse", "--verify", "--quiet", "HEAD^{commit}" });
        if (r.term == .exited and r.term.exited == 1) return null; // unborn branch
        return chomp(try self.output(r));
    }

    fn emptyTree(self: *Job) ![]const u8 {
        // Without -w, hash-object computes the native SHA-1/SHA-256 empty
        // tree ID without adding anything to the object database.
        return chomp(try self.git(&.{ "hash-object", "-t", "tree", "--stdin" }));
    }

    fn readRefs(self: *Job) !void {
        const a = self.arena.allocator();
        const raw = try self.git(&.{ "for-each-ref", "--format=%(refname)", "--sort=refname", "refs/heads/" });
        var refs: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (std.mem.cutPrefix(u8, line, "refs/heads/")) |name| try refs.append(a, name);
        }
        self.result.refs = refs.items;
    }

    fn changes(self: *Job) !void {
        try self.readRefs();
        self.result.label = "Working tree";
        const a = self.arena.allocator();
        const tip = try self.head();
        const base = tip orelse try self.emptyTree();
        const bytes = try self.output(try self.run(&porcelain.status_argv));
        var records = porcelain.Iterator{ .remaining = bytes };
        var files: std.ArrayList(File) = .empty;
        while (try records.next()) |r| {
            if (files.items.len >= max_files) return error.TooManyChangedFiles;
            if (r.conflicted()) {
                try files.append(a, .{ .group = .conflicts, .status = 'U', .path = r.path });
            } else if (r.index == '?') {
                try files.append(a, .{ .group = .untracked, .status = '?', .path = r.path });
            } else {
                if (r.index != ' ') try files.append(a, .{
                    .group = .staged,
                    .status = r.index,
                    .path = r.path,
                    .old_path = if (renamed(r.index)) r.original_path else null,
                    .base = base,
                    .unborn = tip == null,
                });
                if (r.worktree != ' ') try files.append(a, .{
                    .group = .unstaged,
                    .status = r.worktree,
                    .path = r.path,
                    .old_path = if (renamed(r.worktree)) r.original_path else null,
                });
            }
        }
        for (files.items) |*f| f.root = self.result.root;
        std.mem.sort(File, files.items, {}, fileLessThan);
        var begin: usize = 0;
        while (begin < files.items.len) {
            const group = files.items[begin].group;
            var end = begin + 1;
            while (end < files.items.len and files.items[end].group == group) end += 1;
            if (group == .staged or group == .unstaged) {
                const raw = try self.diff(files.items[begin], "--numstat", false);
                try addStats(a, files.items[begin..end], raw);
            }
            begin = end;
        }
        self.result.files = files.items;
        if (self.request == .changes_shared) self.prepareBadges(self.request.changes_shared.scope, bytes) catch {};
    }

    fn prepareBadges(self: *Job, scope: []const u8, bytes: []const u8) !void {
        // Nested and linked worktrees can live inside another worktree. Git
        // must verify the Navigator scope before it can adopt these records.
        var prefix: []const u8 = "\n";
        if (!std.mem.eql(u8, self.result.root, scope)) {
            const root = try self.command(&.{ "-C", scope, "rev-parse", "--show-toplevel" });
            if (root.term != .exited or root.term.exited != 0 or !std.mem.eql(u8, chomp(root.stdout), self.result.root)) return;
            const subdir = try self.command(&.{ "-C", scope, "rev-parse", "--show-prefix" });
            if (subdir.term != .exited or subdir.term.exited != 0) return;
            prefix = subdir.stdout;
        }
        self.navigator_snapshot = try porcelain.Snapshot.copy(self.owner, bytes, prefix);
    }

    const commit_fields = "%H%x00%h%x00%P%x00%an%x00%as%x00%D%x00%s";
    fn history(self: *Job, pinned_tip: ?[]const u8, offset: usize) !void {
        const a = self.arena.allocator();
        const tip = pinned_tip orelse (try self.head()) orelse {
            self.result.label = "No commits yet";
            return;
        };
        if (!validOid(tip)) return error.InvalidCommit;
        self.result.history_tip = tip;
        self.result.history_offset = offset;
        const branch = try self.command(&.{ "symbolic-ref", "-q", "--short", "HEAD" });
        self.result.label = if (pinned_tip != null and !std.mem.eql(u8, tip, (try self.head()) orelse ""))
            try std.fmt.allocPrint(a, "History at {s}", .{abbrev(tip)})
        else if (branch.term == .exited and branch.term.exited == 0) chomp(branch.stdout) else "Detached HEAD";
        // --skip would restart Git's graph at this page with empty lanes.
        // Walk from the pinned tip and discard the prefix as a stream instead.
        const limit = try std.fmt.allocPrint(a, "--max-count={d}", .{offset +| history_page_size +| 1});
        var child = try self.stream(&.{
            "log",                            "--graph", "--topo-order", "--no-color", "--no-show-signature", "--no-notes", "--decorate=short",
            "--format=%x00" ++ commit_fields, limit,     tip,            "--",
        });
        defer child.kill(self.io);
        var buffer: [64 * 1024]u8 = undefined;
        var input = child.stdout.?.readerStreaming(self.io, &buffer);
        try self.readHistory(&input.interface, offset, history_page_size);
        if (!self.result.history_more) {
            const term = try child.wait(self.io);
            if (term != .exited or term.exited != 0) return error.GitHistoryUnavailable;
        }
    }

    fn readHistory(self: *Job, input: *std.Io.Reader, offset: usize, count: usize) !void {
        const a = self.arena.allocator();
        var commits: std.ArrayList(Commit) = .empty;
        var graph: std.ArrayList(u8) = .empty;
        var skip = offset;
        while (true) {
            var oversized = false;
            const line = (input.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => blk: {
                    oversized = true;
                    break :blk input.buffered(); // retain the visible part of an unusually long subject
                },
                else => |e| return e,
            }) orelse break;
            if (std.mem.cutScalar(u8, line, 0)) |parts| {
                if (skip > 0) {
                    skip -= 1;
                } else {
                    if (commits.items.len != 0) commits.items[commits.items.len - 1].graph = try graph.toOwnedSlice(a);
                    if (commits.items.len == count) {
                        self.result.history_more = true;
                        break;
                    }
                    const fields = try a.dupe(u8, parts[1]);
                    var it = std.mem.splitScalar(u8, fields, 0);
                    try commits.append(a, try parseCommit(a, &it));
                    try graph.appendSlice(a, parts[0]);
                }
            } else if (line.len > 0 and commits.items.len > 0 and graph.items.len < 64 * 1024) {
                try graph.append(a, '\n');
                try graph.appendSlice(a, line);
            }
            if (oversized) _ = input.discardDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
        }
        if (graph.items.len != 0) commits.items[commits.items.len - 1].graph = graph.items;
        self.result.commits = commits.items;
    }

    fn comparison(self: *Job, ref: []const u8) !void {
        try self.readRefs();
        const a = self.arena.allocator();
        const ref_spec = try std.fmt.allocPrint(a, "refs/heads/{s}^{{commit}}", .{ref});
        const reference = chomp(try self.git(&.{ "rev-parse", "--verify", ref_spec }));
        const tip = (try self.head()) orelse return error.NoCommitsYet;
        const base = chomp(try self.git(&.{ "merge-base", reference, tip }));
        self.result.label = try std.fmt.allocPrint(a, "{s} (merge base {s}) → HEAD {s}", .{ ref, abbrev(base), abbrev(tip) });
        try self.rangeFiles(.comparison, base, tip);
    }

    fn detail(self: *Job, hash: []const u8, parent_index: usize) !void {
        const a = self.arena.allocator();
        if (!validOid(hash)) return error.InvalidCommit;
        const raw = try self.git(&.{ "show", "-s", "--no-show-signature", "--no-notes", "--decorate=short", "--format=" ++ commit_fields ++ "%x00%aI%x00%B", hash, "--" });
        var fields = std.mem.splitScalar(u8, raw, 0);
        var c = try parseCommit(a, &fields);
        c.date = fields.next() orelse return error.MalformedCommit;
        c.message = std.mem.trimEnd(u8, fields.next() orelse return error.MalformedCommit, "\n");
        self.result.commit = c;
        if (parent_index >= @max(c.parents.len, 1)) return error.InvalidParent;
        const base = if (c.parents.len == 0) try self.emptyTree() else c.parents[parent_index];
        self.result.parent_index = parent_index;
        self.result.label = if (c.parents.len == 0)
            try std.fmt.allocPrint(a, "empty tree → {s}", .{c.short_hash})
        else
            try std.fmt.allocPrint(a, "parent {d}/{d} {s} → {s}", .{ parent_index + 1, c.parents.len, abbrev(base), c.short_hash });
        try self.rangeFiles(.commit, base, c.hash);
        if (self.result.files.len != 0) try self.loadPatch(self.result.files[0]);
    }

    fn rangeFiles(self: *Job, group: Group, base: []const u8, tip: []const u8) !void {
        const a = self.arena.allocator();
        const template: File = .{ .root = self.result.root, .group = group, .status = 0, .path = "", .base = base, .target = tip };
        const raw = try self.diff(template, "--name-status", false);
        var fields = std.mem.splitScalar(u8, raw, 0);
        var files: std.ArrayList(File) = .empty;
        while (fields.next()) |status| {
            if (status.len == 0) break;
            if (files.items.len >= max_files) return error.TooManyChangedFiles;
            var f = template;
            f.status = status[0];
            if (renamed(f.status)) f.old_path = fields.next() orelse return error.MalformedChanges;
            f.path = fields.next() orelse return error.MalformedChanges;
            try files.append(a, f);
        }
        if (files.items.len > 0) try addStats(a, files.items, try self.diff(template, "--numstat", false));
        self.result.files = files.items;
        for (files.items) |file| {
            self.result.added += file.added orelse 0;
            self.result.removed += file.removed orelse 0;
        }
    }

    fn diff(self: *Job, file: File, format: []const u8, one_file: bool) ![]const u8 {
        const a = self.arena.allocator();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--find-renames", format });
        if (!one_file) try args.append(a, "-z");
        switch (file.group) {
            .staged => try args.appendSlice(a, &.{ "--cached", file.base }),
            .unstaged => {},
            .conflicts => try args.append(a, "--ours"),
            .comparison, .commit => try args.appendSlice(a, &.{ file.base, file.target }),
            .untracked => unreachable,
        }
        try args.append(a, "--");
        if (one_file) {
            if (file.old_path) |old| try args.append(a, old);
            try args.append(a, file.path);
        }
        if (one_file) return self.streamPatch(args.items, false);
        return self.git(args.items);
    }

    fn streamPatch(self: *Job, args: []const []const u8, no_index: bool) ![]const u8 {
        var child = try self.stream(args);
        defer child.kill(self.io);
        var buf: [16384]u8 = undefined;
        const a = self.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        var lines: usize = 0;
        while (true) {
            const n = child.stdout.?.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (n == 0) break;
            const len = @min(n, patch_byte_limit - out.items.len);
            var keep = len;
            for (buf[0..len], 0..) |byte, i| {
                if (byte == '\n') {
                    lines += 1;
                    if (lines > patch_line_limit) {
                        keep = i;
                        break;
                    }
                }
            }
            try out.appendSlice(a, buf[0..keep]);
            if (keep < n) {
                self.result.patch_truncated = true;
                try out.appendSlice(a, "\n[Patch preview limited to 4 MiB or 32,768 lines]\n");
                return out.items;
            }
        }
        const term = try child.wait(self.io);
        if (term != .exited or !(term.exited == 0 or (no_index and term.exited == 1))) return error.GitPatchUnavailable;
        return out.items;
    }

    fn loadPatch(self: *Job, file: File) !void {
        if (!std.mem.eql(u8, file.root, self.result.root)) return error.RepositoryChanged;
        const raw = switch (file.group) {
            .untracked => blk: {
                // An untracked embedded repository appears as a directory.
                if (std.mem.endsWith(u8, file.path, "/")) break :blk "Untracked directory (no text patch)";
                const path = try std.fmt.allocPrint(self.arena.allocator(), "./{s}", .{file.path});
                break :blk try self.streamPatch(&.{ "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", path }, true);
            },
            else => try self.diff(file, "--patch", true),
        };
        self.result.patch = if (raw.len > 0) raw else switch (file.group) {
            .conflicts => "Unresolved conflict (no text patch against ours)",
            .untracked => "Empty untracked file",
            else => "No textual changes",
        };
        self.result.view = try patch_view.parse(self.arena.allocator(), self.result.patch);
    }
};

fn chomp(s: []const u8) []const u8 {
    return std.mem.cutSuffix(u8, s, "\n") orelse s;
}

fn validOid(hash: []const u8) bool {
    if (hash.len != 40 and hash.len != 64) return false;
    for (hash) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn abbrev(hash: []const u8) []const u8 {
    return hash[0..@min(8, hash.len)];
}

fn renamed(status: u8) bool {
    return status == 'R' or status == 'C';
}

fn fileLessThan(_: void, left: File, right: File) bool {
    if (left.group != right.group) return @backingInt(left.group) < @backingInt(right.group);
    return std.mem.lessThan(u8, left.path, right.path);
}

fn parseCommit(a: Allocator, it: *std.mem.SplitIterator(u8, .scalar)) !Commit {
    const hash = it.next() orelse return error.MalformedCommit;
    const short_hash = it.next() orelse return error.MalformedCommit;
    var parents: std.ArrayList([]const u8) = .empty;
    var parent_ids = std.mem.tokenizeScalar(u8, it.next() orelse return error.MalformedCommit, ' ');
    while (parent_ids.next()) |p| try parents.append(a, p);
    return .{
        .hash = hash,
        .short_hash = short_hash,
        .parents = parents.items,
        .author = it.next() orelse return error.MalformedCommit,
        .date = it.next() orelse return error.MalformedCommit,
        .labels = it.next() orelse return error.MalformedCommit,
        .subject = it.next() orelse return error.MalformedCommit,
    };
}

fn addStats(a: Allocator, files: []File, raw: []const u8) !void {
    var by_path: std.StringHashMapUnmanaged(*File) = .empty;
    for (files) |*file| try by_path.put(a, file.path, file);
    var fields = std.mem.splitScalar(u8, raw, 0);
    while (fields.next()) |field| {
        if (field.len == 0) break;
        const plus = std.mem.cutScalar(u8, field, '\t') orelse return error.MalformedNumstat;
        const minus = std.mem.cutScalar(u8, plus[1], '\t') orelse return error.MalformedNumstat;
        const path = if (minus[1].len > 0) minus[1] else path: {
            _ = fields.next() orelse return error.MalformedNumstat; // rename source
            break :path fields.next() orelse return error.MalformedNumstat;
        };
        const f = by_path.get(path) orelse continue;
        if (std.mem.eql(u8, plus[0], "-")) {
            f.binary = true;
        } else {
            f.added = try std.fmt.parseInt(u64, plus[0], 10);
            f.removed = try std.fmt.parseInt(u64, minus[0], 10);
        }
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    cwd: [:0]u8,

    fn init() !Fixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        errdefer a.free(cwd);
        var repo: Fixture = .{ .tmp = tmp, .cwd = cwd };
        try repo.git(&.{ "init", "-q", "-b", "main" });
        try repo.git(&.{ "config", "user.name", "Reviewer" });
        try repo.git(&.{ "config", "user.email", "test@localhost" });
        try repo.git(&.{ "config", "commit.gpgSign", "false" });
        try repo.git(&.{ "config", "core.hooksPath", "/dev/null" });
        return repo;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        std.testing.allocator.free(self.cwd);
    }

    fn gitExit(self: *Fixture, args: []const []const u8, expected: u8) !void {
        const a = std.testing.allocator;
        const argv = try std.mem.concat(a, []const u8, &.{ &.{"git"}, args });
        defer a.free(argv);
        const r = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = .{ .path = self.cwd } });
        defer a.free(r.stderr);
        defer a.free(r.stdout);
        if (r.term != .exited or r.term.exited != expected) {
            std.debug.print("git {s}: {s}\n", .{ args[0], r.stderr });
            return error.GitFixtureFailed;
        }
    }

    fn git(self: *Fixture, args: []const []const u8) !void {
        try self.gitExit(args, 0);
    }

    fn write(self: *Fixture, path: []const u8, content: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
    }

    fn review(self: *Fixture, request: Request) !*Job {
        const j = try Job.start(std.testing.allocator, std.testing.io, self.cwd, request, null, null);
        errdefer j.deinit();
        j.thread.?.join();
        j.thread = null;
        try std.testing.expect(j.done.load(.acquire));
        if (j.result.problem) |problem| {
            std.debug.print("review {s}: {s}\n", .{ @tagName(request), problem });
            return error.GitReviewFailed;
        }
        try std.testing.expectEqualStrings(self.cwd, j.result.root);
        return j;
    }
};

fn findFile(files: []const File, group: Group, path: []const u8) !File {
    for (files) |f| if (f.group == group and std.mem.eql(u8, f.path, path)) return f;
    return error.MissingFile;
}

fn includes(bytes: []const u8, fragment: []const u8) bool {
    return std.mem.indexOf(u8, bytes, fragment) != null;
}

test "Git Review distinguishes staged, unstaged, renamed, deleted, untracked and binary files" {
    var repo = try Fixture.init();
    defer repo.deinit();
    const odd = "[:x]\tname";
    try repo.write(odd, "original\n");
    try repo.write("old name", "renamed\n");
    try repo.write("removed", "deleted\n");
    try repo.write("binary", "before\x00\n");
    try repo.git(&.{ "add", "." });

    const unborn = try repo.review(.changes);
    defer unborn.deinit();
    const initial_file = try findFile(unborn.result.files, .staged, odd);
    try std.testing.expectEqualStrings("empty tree → index", initial_file.label());
    const initial = try repo.review(.{ .patch = initial_file });
    defer initial.deinit();
    try std.testing.expect(includes(initial.result.patch, "+original"));

    try repo.git(&.{ "commit", "-qm", "root" });
    try repo.git(&.{ "mv", "old name", "new name" });
    try repo.write(odd, "index\nextra\n");
    try repo.write("binary", "after\x00\n");
    try repo.git(&.{ "add", "-u" });
    try repo.tmp.dir.deleteFile(std.testing.io, "removed");
    try repo.write(odd, "worktree\nextra\n");
    try repo.write("new\nfile", "untracked\n");
    const index_before = try repo.tmp.dir.readFileAlloc(std.testing.io, ".git/index", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(index_before);
    const j = try repo.review(.changes);
    defer j.deinit();
    try std.testing.expectEqual(6, j.result.files.len);
    const staged = try findFile(j.result.files, .staged, odd);
    const unstaged = try findFile(j.result.files, .unstaged, odd);
    try std.testing.expectEqual(2, staged.added.?);
    try std.testing.expectEqual(1, unstaged.added.?);
    const rename = try findFile(j.result.files, .staged, "new name");
    try std.testing.expectEqualStrings("old name", rename.old_path.?);
    try std.testing.expectEqual(0, rename.removed.?);
    const renamed_patch = try repo.review(.{ .patch = rename });
    defer renamed_patch.deinit();
    try std.testing.expect(includes(renamed_patch.result.patch, "rename from old name"));
    const binary = try findFile(j.result.files, .staged, "binary");
    try std.testing.expect(binary.binary);
    try std.testing.expectEqual(null, binary.added);
    const binary_patch = try repo.review(.{ .patch = binary });
    defer binary_patch.deinit();
    try std.testing.expect(includes(binary_patch.result.patch, "Binary files"));
    try std.testing.expectEqual('D', (try findFile(j.result.files, .unstaged, "removed")).status);
    const index = try repo.review(.{ .patch = staged });
    defer index.deinit();
    try std.testing.expect(includes(index.result.patch, "-original\n+index") and !includes(index.result.patch, "worktree"));
    const work = try repo.review(.{ .patch = unstaged });
    defer work.deinit();
    try std.testing.expect(includes(work.result.patch, "-index\n+worktree") and !includes(work.result.patch, "original"));
    const new = try repo.review(.{ .patch = try findFile(j.result.files, .untracked, "new\nfile") });
    defer new.deinit();
    try std.testing.expect(includes(new.result.patch, "+untracked"));
    const index_after = try repo.tmp.dir.readFileAlloc(std.testing.io, ".git/index", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(index_after);
    try std.testing.expectEqualSlices(u8, index_before, index_after);
}

test "Git Review pins branch endpoints and exact historical commit, parent and root patches" {
    var repo = try Fixture.init();
    defer repo.deinit();
    try repo.write("a", "root\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-qm", "root" });
    try repo.git(&.{ "branch", "topic" });
    try repo.write("a", "old commit\n");
    try repo.write("b", "second file\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-qm", "earlier", "-m", "Full message body" });
    try repo.git(&.{ "tag", "selected" });
    try repo.write("a", "newer\n");
    try repo.git(&.{ "commit", "-qam", "newer" });
    try repo.git(&.{ "switch", "-q", "topic" });
    try repo.write("side", "topic\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-qm", "side" });
    try repo.git(&.{ "switch", "-q", "main" });
    try repo.write("a", "local\n");

    const branch = try repo.review(.{ .comparison = "topic" });
    defer branch.deinit();
    try std.testing.expectEqual(2, branch.result.files.len);
    try std.testing.expectEqual(2, branch.result.refs.len);
    try std.testing.expect(includes(branch.result.label, "topic (merge base"));
    const compared = try findFile(branch.result.files, .comparison, "a");
    try repo.git(&.{ "merge", "--no-ff", "-qm", "merge", "topic" });
    const range_patch = try repo.review(.{ .patch = compared });
    defer range_patch.deinit();
    try std.testing.expect(includes(range_patch.result.patch, "-root\n+newer") and !includes(range_patch.result.patch, "local"));

    const h = try repo.review(.history);
    defer h.deinit();
    const commits = h.result.commits;
    try std.testing.expectEqual(5, commits.len);
    try std.testing.expectEqual(2, commits[0].parents.len);
    try std.testing.expect(includes(commits[0].graph, "\n|\\"));
    // Page 2 starts inside the merge. A fresh --graph --skip would erase
    // the active side lane here. Moving HEAD must also leave this page intact.
    try repo.git(&.{ "commit", "-q", "--allow-empty", "-m", "after snapshot" });
    const page = try repo.review(.{ .history_page = .{ .tip = h.result.history_tip, .offset = 1 } });
    defer page.deinit();
    try std.testing.expectEqualStrings(commits[1].hash, page.result.commits[0].hash);
    try std.testing.expectEqualStrings(commits[1].graph, page.result.commits[0].graph);
    try std.testing.expectEqualStrings(h.result.history_tip, page.result.history_tip);
    try std.testing.expectEqual(commits.len - 1, page.result.commits.len);
    try std.testing.expect(includes(page.result.label, "History at "));
    const selected = for (commits) |c| {
        if (std.mem.eql(u8, c.subject, "earlier")) break c;
    } else return error.MissingCommit;
    try std.testing.expect(includes(selected.labels, "selected"));
    const older = try repo.review(.{ .detail = .{ .hash = selected.hash } });
    defer older.deinit();
    const result = older.result;
    try std.testing.expectEqualStrings(selected.hash, result.commit.?.hash);
    try std.testing.expectEqualStrings("Reviewer", result.commit.?.author);
    try std.testing.expectEqualStrings("earlier\n\nFull message body", result.commit.?.message);
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqual(2, result.added);
    try std.testing.expectEqual(1, result.removed);
    try std.testing.expect(includes(result.patch, "-root\n+old commit") and !includes(result.patch, "local"));
    try std.testing.expectEqual(1, result.view.hunks.len);
    const second = try repo.review(.{ .patch = result.files[1] });
    defer second.deinit();
    try std.testing.expect(includes(second.result.patch, "+second file"));

    const merge1 = try repo.review(.{ .detail = .{ .hash = commits[0].hash } });
    defer merge1.deinit();
    try std.testing.expectEqualStrings("side", merge1.result.files[0].path);
    try std.testing.expectEqualStrings(commits[0].parents[0], merge1.result.files[0].base);
    const merge2 = try repo.review(.{ .detail = .{ .hash = commits[0].hash, .parent_index = 1 } });
    defer merge2.deinit();
    try std.testing.expectEqual(2, merge2.result.files.len);
    try std.testing.expect(includes(merge2.result.label, "parent 2/2"));
    try std.testing.expectEqualStrings(commits[0].parents[1], merge2.result.files[0].base);
    const root = try repo.review(.{ .detail = .{ .hash = commits[commits.len - 1].hash } });
    defer root.deinit();
    try std.testing.expectEqual(0, root.result.commit.?.parents.len);
    try std.testing.expect(includes(root.result.patch, "+root"));
    try std.testing.expect(includes(root.result.label, "empty tree"));
}

test "Git Review lists an unresolved merge once and shows the ours-to-worktree patch" {
    var repo = try Fixture.init();
    defer repo.deinit();
    try repo.write("conflict", "root\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-qm", "root" });
    try repo.git(&.{ "switch", "-qc", "topic" });
    try repo.write("conflict", "theirs\n");
    try repo.git(&.{ "commit", "-qam", "topic" });
    try repo.git(&.{ "switch", "-q", "main" });
    try repo.write("conflict", "ours\n");
    try repo.git(&.{ "commit", "-qam", "main" });
    try repo.gitExit(&.{ "merge", "-q", "topic" }, 1);
    const status = try repo.review(.changes);
    defer status.deinit();
    try std.testing.expectEqual(1, status.result.files.len);
    const file = status.result.files[0];
    try std.testing.expectEqual(Group.conflicts, file.group);
    const patch = try repo.review(.{ .patch = file });
    defer patch.deinit();
    try std.testing.expect(includes(patch.result.patch, "theirs"));
}

test "Git Review limits patch bytes and rows without losing commit metadata or other files" {
    var repo = try Fixture.init();
    defer repo.deinit();
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, patch_byte_limit + 1024);
    defer a.free(bytes);
    @memset(bytes, 'x');
    try repo.write("a", bytes);
    try repo.write("b", "small patch\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-qm", "large root" });
    const h = try repo.review(.history);
    defer h.deinit();
    const detail = try repo.review(.{ .detail = .{ .hash = h.result.history_tip } });
    defer detail.deinit();
    try std.testing.expectEqual(2, detail.result.files.len);
    try std.testing.expect(detail.result.patch_truncated);
    try std.testing.expect(detail.result.patch.len < patch_byte_limit + 128);
    const small = try repo.review(.{ .patch = detail.result.files[1] });
    defer small.deinit();
    try std.testing.expect(!small.result.patch_truncated);
    try std.testing.expect(includes(small.result.patch, "+small patch"));

    const many_lines = bytes[0 .. (patch_line_limit + 1) * 2];
    for (0..many_lines.len / 2) |i| @memcpy(many_lines[2 * i ..][0..2], "x\n");
    try repo.write("many", many_lines);
    const status = try repo.review(.changes);
    defer status.deinit();
    const untracked = try findFile(status.result.files, .untracked, "many");
    const patch = try repo.review(.{ .patch = untracked });
    defer patch.deinit();
    try std.testing.expect(patch.result.patch_truncated);
    try std.testing.expect(patch.result.view.rows.len <= patch_line_limit + 2);
    var other = try Fixture.init();
    defer other.deinit();
    const stale = try Job.start(a, std.testing.io, other.cwd, .{ .patch = untracked }, null, null);
    defer stale.deinit();
    stale.thread.?.join();
    stale.thread = null;
    try std.testing.expectEqualStrings("Repository changed while loading the patch", stale.result.problem.?);
}

test "Git Review streams a full history page and follows its final parent onto the next page" {
    var repo = try Fixture.init();
    defer repo.deinit();
    var fixture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer fixture.deinit();
    for (0..history_page_size + 3) |i| {
        try fixture.writer.print("commit refs/heads/main\ncommitter Test <test@localhost> {d} +0000\ndata 1\nx\n\n", .{i + 1});
    }
    try repo.write(".git/fixture", fixture.written());
    const io = std.testing.io;
    const input = try repo.tmp.dir.openFile(io, ".git/fixture", .{});
    defer input.close(io);
    var import = try std.process.spawn(io, .{
        .argv = &.{ "git", "fast-import", "--quiet" },
        .cwd = .{ .path = repo.cwd },
        .stdin = .{ .file = input },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer import.kill(io);
    const end = try import.wait(io);
    try std.testing.expect(end == .exited and end.exited == 0);
    const first = try repo.review(.history);
    defer first.deinit();
    try std.testing.expectEqual(history_page_size, first.result.commits.len);
    try std.testing.expect(first.result.history_more);
    const second = try repo.review(.{ .history_page = .{ .tip = first.result.history_tip, .offset = history_page_size } });
    defer second.deinit();
    try std.testing.expectEqual(3, second.result.commits.len);
    try std.testing.expect(!second.result.history_more);
    try std.testing.expectEqualStrings(first.result.commits[history_page_size - 1].parents[0], second.result.commits[0].hash);
}

test "Git Review publishes fresh, independently owned badge data for the same repository" {
    var repo = try Fixture.init();
    defer repo.deinit();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try repo.tmp.dir.createDir(io, "sub", .default_dir);
    try repo.write("sub/file", "staged immediately before opening Review\n");
    try repo.write("elsewhere", "not in the Navigator subtree\n");
    try repo.git(&.{ "add", "sub/file" });
    const scope = try repo.tmp.dir.realPathFileAlloc(io, "sub", a);
    defer a.free(scope);
    const job = try repo.review(.{ .changes_shared = .{ .scope = scope, .generation = 2, .scan = 4 } });
    var snap = job.navigator_snapshot.?;
    defer snap.deinit(a);
    job.navigator_snapshot = null;
    job.deinit();
    try std.testing.expectEqualStrings("A.", &snap.paths.get("file").?.text);
    try std.testing.expectEqual(null, snap.paths.get("elsewhere"));
    var other = try Fixture.init();
    defer other.deinit();
    const unrelated = try repo.review(.{ .changes_shared = .{ .scope = other.cwd, .generation = 2, .scan = 4 } });
    defer unrelated.deinit();
    try std.testing.expectEqual(null, unrelated.navigator_snapshot);
    try std.testing.expectEqual(2, unrelated.result.files.len);
}
