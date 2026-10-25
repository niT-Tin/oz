//! Safe read-only tool executor (M3a).
//!
//! This module is the execution core behind the M3 tool protocol in
//! `ai/tools.zig`. It is deliberately App/UI-independent and can be driven
//! from the future agent loop and from unit tests:
//!
//!   - `read_file(path, start_line?, end_line?)`
//!   - `list_directory(path)`
//!   - `grep(pattern, path?, glob?)` — literal, case-sensitive substring
//!
//! Hidden entries are treated as ordinary workspace files (no `.gitignore`
//! or `.git` exclusion); `grep` skips symlink directory entries during
//! recursion so a link cannot pull an outside tree into a scan.
//!
//! Write tools are never executed. `edit_file` and `apply_patch` return
//! `status = .approval_required`; `terminal` and unknown names return
//! `status = .unsupported`. There is no shell, no network, and no write
//! syscall anywhere in this module.
//!
//! ## Workspace confinement
//!
//! The workspace root is canonicalized once with `realpath` in
//! `Executor.init`. Every requested path is rejected if it is absolute,
//! empty, contains NUL, contains a `..` component, or is longer than
//! `max_path_bytes`. Existing paths are then canonicalized with `realpath`
//! and must be the root itself or begin with `root + separator`; symlinks
//! that resolve outside the root are rejected with
//! `.path_escapes_workspace`. `list_directory`/`grep` never follow symlink
//! entries discovered during recursion, and `grep` only scans regular files.
//!
//! This is a best-effort confinement check: it closes the ordinary
//! `../`, absolute-path and symlink escapes, but does not claim
//! time-of-check-to-time-of-use (TOCTOU) safety against a concurrent process
//! replacing a directory entry between the check and the read.
//!
//! ## Output format
//!
//! Every outcome's `content` is bounded by `max_output_bytes` (including
//! header/text and the `… [truncated]` marker) and is valid UTF-8. The tools
//! use small `key: value` headers followed by `---` and a raw body:
//!
//!   read_file:          "path: <rel>\nlines: <first>-<last>\n---\n<raw text>"
//!   list_directory:     "path: <rel>\n---\n<type>  <name>[  <size>]"
//!   grep:               "path: <rel>\n---\n<rel-path>:<line>:<text>"
//!
//! List entries are directories (`d`, with a trailing `/`) first, then
//! regular files (`f`, byte size after the name), then symlinks (`l`) and
//! other kinds (`o`); each group is sorted by name. `read_file` emits the raw
//! selected text (no injected line numbers) after the header. Grep matches
//! whole lines, one row per matching line, ordered by path then line number.
//!
//! Paths are always workspace-relative (the root is displayed as "."), never
//! absolute host paths. `summary` is a short, bounded, owned one-line
//! description for a future tool card/UI.
//!
//! ## Bounds
//!
//!   read_file: 64 KiB output / 2000 lines, range 1-based inclusive
//!   list:      500 entries, directories first then files/other, name-sorted
//!   grep:      200 matched lines, 1 MiB per file, 8 directory levels,
//!              512-byte displayed line prefix, literal substring matching
//!
//! `grep`'s `glob` is a basename wildcard matcher (`*`, `?`; no character
//! classes or escaping); only the pattern's final path component is used, so
//! `**/*.zig` behaves like `*.zig`.
//!
//! `read_file` streams the file through a fixed stack buffer; `grep` reads at
//! most one file (1 MiB) at a time. There is no unbounded buffering of file
//! contents. A NUL byte in the scanned portion marks a file as binary; a
//! non-UTF-8 text range is also rejected (read_file) or skipped (grep),
//! because tool results must be valid UTF-8.
const std = @import("std");
const tools = @import("tools.zig");

pub const max_output_bytes: usize = 64 * 1024;
pub const max_read_bytes: usize = 64 * 1024;
pub const max_read_lines: usize = 2000;
pub const max_list_entries: usize = 500;
pub const max_grep_matches: usize = 200;
pub const max_grep_file_bytes: usize = 1024 * 1024;
pub const max_grep_depth: usize = 8;
pub const max_grep_line_bytes: usize = 512;
pub const max_path_bytes: usize = 4096;
pub const max_pattern_bytes: usize = 4096;
pub const max_glob_bytes: usize = 512;
pub const max_summary_bytes: usize = 512;

/// Truncation marker appended to bounded content. It starts with a newline so
/// a body cut mid-line is still readable.
const trunc_marker = "\n… [truncated]";

/// Reserved space for path/range headers (display paths are capped at
/// `max_display_path_bytes`; this is deliberately generous).
const header_reserve: usize = 512;
const max_display_path_bytes: usize = 256;
const max_list_name_bytes: usize = 300;
const max_grep_path_bytes: usize = 1024;
const max_tool_name_bytes: usize = 64;

/// Typed terminal status of one tool call. `err` is the keyword-safe spelling
/// of the protocol's "error" status.
pub const Status = enum { ok, err, approval_required, unsupported };

/// Machine-readable failure classification for `status == .err`. The agent
/// loop can log or route on this instead of matching message text.
pub const Failure = enum {
    malformed_arguments,
    missing_argument,
    wrong_argument_type,
    argument_too_long,
    invalid_path,
    invalid_range,
    line_out_of_range,
    invalid_pattern,
    invalid_glob,
    path_escapes_workspace,
    not_found,
    not_a_file,
    not_a_directory,
    unreadable,
    binary_file,
};

/// Result of one execution. `content` and `summary` are owned by the caller;
/// free both with `deinit(alloc)`. `failure` is non-null exactly for
/// `status == .err`.
pub const Outcome = struct {
    status: Status,
    content: []u8,
    summary: ?[]u8 = null,
    failure: ?Failure = null,

    pub fn deinit(self: *Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        if (self.summary) |summary| alloc.free(summary);
        self.* = undefined;
    }
};

/// Errors that are not tool failures: an exhausted allocator, or a workspace
/// root that does not exist / is not a usable directory.
pub const ExecuteError = error{ OutOfMemory, InvalidWorkspaceRoot };

/// Reusable executor. Resolving the workspace root once avoids repeating
/// `realpath` for every call in a multi-step agent turn.
pub const Executor = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Canonical absolute workspace root without a trailing separator (except
    /// for "/"). Owned.
    root: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        workspace_root: []const u8,
    ) ExecuteError!Executor {
        if (workspace_root.len == 0) return error.InvalidWorkspaceRoot;

        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, workspace_root, alloc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidWorkspaceRoot,
        };
        errdefer alloc.free(canonical);

        // A real file cannot be a workspace root: the read-only tools need a
        // directory to resolve relative paths against.
        var dir = std.Io.Dir.openDirAbsolute(io, canonical, .{}) catch return error.InvalidWorkspaceRoot;
        dir.close(io);

        var trimmed: []const u8 = canonical;
        while (trimmed.len > 1 and std.fs.path.isSep(trimmed[trimmed.len - 1])) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        const root = try alloc.dupe(u8, trimmed);
        alloc.free(canonical);
        return .{ .alloc = alloc, .io = io, .root = root };
    }

    pub fn deinit(self: *Executor) void {
        self.alloc.free(self.root);
        self.* = undefined;
    }

    /// Execute one read-only tool call. Expected tool failures are returned as
    /// `Outcome` with `status == .err`; only allocation failure and workspace
    /// setup errors are Zig errors.
    pub fn execute(self: *Executor, call: tools.ToolCall) ExecuteError!Outcome {
        const kind = tools.classify(call.name) orelse return self.unknownTool(call.name);
        return switch (kind) {
            .read_file => self.readFile(call.arguments_json),
            .list_directory => self.listDirectory(call.arguments_json),
            .grep => self.grep(call.arguments_json),
            .edit_file, .apply_patch => self.approvalRequired(kind),
            .terminal => self.unsupportedTerminal(),
        };
    }

    // ------------------------------------------------------------------
    // Tool dispatch outcomes for non-read-only tools
    // ------------------------------------------------------------------

    fn approvalRequired(self: *Executor, kind: tools.Kind) ExecuteError!Outcome {
        const content = try std.fmt.allocPrint(
            self.alloc,
            "approval required: {s} was not executed (M3a is read-only)",
            .{@tagName(kind)},
        );
        errdefer self.alloc.free(content);
        const summary = try std.fmt.allocPrint(self.alloc, "approval required: {s}", .{@tagName(kind)});
        return .{ .status = .approval_required, .content = content, .summary = summary };
    }

    fn unsupportedTerminal(self: *Executor) ExecuteError!Outcome {
        const content = try self.alloc.dupe(u8, "unsupported in M3a: terminal execution is not available");
        errdefer self.alloc.free(content);
        const summary = try self.alloc.dupe(u8, "unsupported: terminal execution");
        return .{ .status = .unsupported, .content = content, .summary = summary };
    }

    fn unknownTool(self: *Executor, name: []const u8) ExecuteError!Outcome {
        const shown = try sanitizeBounded(self.alloc, name, max_tool_name_bytes);
        defer self.alloc.free(shown);
        const content = try std.fmt.allocPrint(self.alloc, "error: unsupported tool: {s}", .{shown});
        errdefer self.alloc.free(content);
        const summary = try self.alloc.dupe(u8, "unsupported tool");
        return .{ .status = .unsupported, .content = content, .summary = summary };
    }

    // ------------------------------------------------------------------
    // read_file
    // ------------------------------------------------------------------

    fn readFile(self: *Executor, arguments_json: []const u8) ExecuteError!Outcome {
        var parsed = switch (try self.parseArguments(arguments_json)) {
            .args => |p| p,
            .failure => |out| return out,
        };
        defer parsed.deinit();
        const obj = &parsed.value.object;

        const raw_path = requiredString(obj, "path") catch |e| return try self.stringFieldFailure("path", e);
        const start_arg = optionalPositiveInteger(obj, "start_line") catch |e| return try self.intFieldFailure("start_line", e);
        const end_arg = optionalPositiveInteger(obj, "end_line") catch |e| return try self.intFieldFailure("end_line", e);

        const start_line: usize = if (start_arg) |v| @intCast(v) else 1;
        const end_line: ?usize = if (end_arg) |v| @intCast(v) else null;
        if (end_line) |end| {
            if (end < start_line) {
                return try self.fail(.invalid_range, "end_line must be greater than or equal to start_line", .{});
            }
        }

        const rel = normalizePath(self.alloc, raw_path) catch |e| return try self.pathFailure(raw_path, e);
        defer self.alloc.free(rel);
        const shown = try self.displayPath(rel);
        defer self.alloc.free(shown);

        const canonical = self.resolveExisting(rel) catch |e| return try self.resolveFailure(shown, e);
        defer self.alloc.free(canonical);

        // Stat before opening: opening a FIFO/device can block, and it must
        // be rejected as "not a file" rather than read.
        const stat = self.statPath(canonical) catch |e| return try self.statFailure(shown, e);
        if (stat.kind != .file) return try self.fail(.not_a_file, "not a regular file: {s}", .{shown});

        var file = self.openFileForRead(canonical) catch |e| return try self.openFailure(shown, e);
        defer file.close(self.io);

        // Fixed-size streaming scan. Only the requested range is copied, and
        // only up to the output budget, so a multi-gigabyte file is never
        // loaded into memory.
        const body_budget = @min(max_read_bytes, max_output_bytes -| (header_reserve + trunc_marker.len));
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);

        var line_no: usize = 1;
        var emitting = start_line == 1;
        var emitted_first: usize = 0;
        var emitted_last: usize = 0;
        var lines_emitted: usize = 0;
        var any_bytes = false;
        var limit_hit = false;
        var truncated = false;
        var done = false;

        var reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(self.io, &reader_buffer);
        const reader = &file_reader.interface;
        var chunk: [16 * 1024]u8 = undefined;

        scan: while (!done) {
            const n = reader.readSliceShort(&chunk) catch {
                return try self.fail(.unreadable, "cannot read: {s}", .{shown});
            };
            if (n == 0) break;

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const byte = chunk[i];
                if (limit_hit) {
                    // The line/byte cap was reached, and at least one more
                    // byte exists in the file: the output is truncated.
                    truncated = true;
                    break :scan;
                }
                if (byte == 0) {
                    return try self.fail(.binary_file, "binary file (NUL byte): {s}", .{shown});
                }
                any_bytes = true;

                if (byte == '\n') {
                    if (emitting) {
                        if (body.items.len >= body_budget) {
                            truncated = true;
                            break :scan;
                        }
                        if (emitted_first == 0) emitted_first = line_no;
                        try body.append(self.alloc, byte);
                        emitted_last = line_no;
                        lines_emitted += 1;

                        if (end_line) |end| {
                            if (line_no == end) {
                                done = true;
                                break :scan;
                            }
                        }
                        if (lines_emitted >= max_read_lines) {
                            // Do not mark truncated yet: EOF exactly at the cap
                            // is a complete read. The next byte decides.
                            limit_hit = true;
                            continue;
                        }
                    }
                    line_no += 1;
                    if (!emitting and line_no == start_line) emitting = true;
                } else if (emitting) {
                    if (body.items.len >= body_budget) {
                        truncated = true;
                        break :scan;
                    }
                    if (emitted_first == 0) emitted_first = line_no;
                    try body.append(self.alloc, byte);
                    emitted_last = line_no;
                }
            }
        }

        const empty_file = !any_bytes;
        if (!empty_file and !emitting and emitted_first == 0) {
            return try self.fail(.line_out_of_range, "start_line is beyond the end of the file", .{});
        }
        if (!empty_file and emitting and emitted_first == 0) {
            return try self.fail(.line_out_of_range, "start_line is beyond the end of the file", .{});
        }
        if (empty_file and start_line > 1) {
            return try self.fail(.line_out_of_range, "start_line is beyond the end of the file", .{});
        }

        // A byte-cap cut can land inside a UTF-8 sequence. Back off to the
        // largest valid prefix; invalid UTF-8 anywhere else is a binary file.
        if (body.items.len > 0 and !std.unicode.utf8ValidateSlice(body.items)) {
            if (!truncated) {
                return try self.fail(.binary_file, "binary file (invalid UTF-8): {s}", .{shown});
            }
            var fixed = false;
            var back: usize = 1;
            while (back <= 4 and body.items.len > back) : (back += 1) {
                const candidate_len = body.items.len - back;
                if (std.unicode.utf8ValidateSlice(body.items[0..candidate_len])) {
                    body.shrinkRetainingCapacity(candidate_len);
                    fixed = true;
                    break;
                }
            }
            if (!fixed) {
                return try self.fail(.binary_file, "binary file (invalid UTF-8): {s}", .{shown});
            }
        }

        const header = if (emitted_first == 0)
            try std.fmt.allocPrint(self.alloc, "path: {s}\nlines: none\n---\n", .{shown})
        else
            try std.fmt.allocPrint(
                self.alloc,
                "path: {s}\nlines: {d}-{d}\n---\n",
                .{ shown, emitted_first, emitted_last },
            );
        defer self.alloc.free(header);

        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(self.alloc);
        try content.ensureTotalCapacity(self.alloc, header.len + body.items.len + (if (truncated) trunc_marker.len else 0));
        try content.appendSlice(self.alloc, header);
        try content.appendSlice(self.alloc, body.items);
        if (truncated) try content.appendSlice(self.alloc, trunc_marker);

        const summary = if (emitted_first == 0)
            try std.fmt.allocPrint(self.alloc, "read {s}: empty", .{shown})
        else if (truncated)
            try std.fmt.allocPrint(
                self.alloc,
                "read {s}: lines {d}-{d} (truncated)",
                .{ shown, emitted_first, emitted_last },
            )
        else
            try std.fmt.allocPrint(
                self.alloc,
                "read {s}: lines {d}-{d}",
                .{ shown, emitted_first, emitted_last },
            );

        return .{ .status = .ok, .content = try content.toOwnedSlice(self.alloc), .summary = summary };
    }

    // ------------------------------------------------------------------
    // list_directory
    // ------------------------------------------------------------------

    const ListItem = struct {
        name: []u8,
        kind: std.Io.File.Kind,
    };

    fn listDirectory(self: *Executor, arguments_json: []const u8) ExecuteError!Outcome {
        var parsed = switch (try self.parseArguments(arguments_json)) {
            .args => |p| p,
            .failure => |out| return out,
        };
        defer parsed.deinit();
        const obj = &parsed.value.object;

        const raw_path = requiredString(obj, "path") catch |e| return try self.stringFieldFailure("path", e);
        const rel = normalizePath(self.alloc, raw_path) catch |e| return try self.pathFailure(raw_path, e);
        defer self.alloc.free(rel);
        const requested_shown = try self.displayPath(rel);
        defer self.alloc.free(requested_shown);

        const canonical = self.resolveExisting(rel) catch |e| return try self.resolveFailure(requested_shown, e);
        defer self.alloc.free(canonical);
        const shown = try self.displayPath(relFromCanonical(self.root, canonical));
        defer self.alloc.free(shown);

        var dir = std.Io.Dir.openDirAbsolute(self.io, canonical, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => return try self.fail(.not_found, "not found: {s}", .{requested_shown}),
            error.NotDir => return try self.fail(.not_a_directory, "not a directory: {s}", .{requested_shown}),
            error.AccessDenied, error.PermissionDenied => return try self.fail(.unreadable, "cannot read directory: {s}", .{requested_shown}),
            else => return try self.fail(.unreadable, "cannot read directory: {s}", .{requested_shown}),
        };
        defer dir.close(self.io);

        // Keep only the first `max_list_entries` entries in deterministic
        // (dirs first, then files/other, byte-sorted name) order while
        // counting every entry. Memory stays proportional to the cap.
        var items: std.ArrayList(ListItem) = .empty;
        defer {
            for (items.items) |item| self.alloc.free(item.name);
            items.deinit(self.alloc);
        }

        var total: usize = 0;
        var dirty = false;
        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next(self.io) catch {
                return try self.fail(.unreadable, "cannot read directory: {s}", .{requested_shown});
            };
            const entry = maybe_entry orelse break;
            total += 1;

            const name_copy = try self.alloc.dupe(u8, entry.name);
            const candidate = ListItem{ .name = name_copy, .kind = entry.kind };
            if (items.items.len < max_list_entries) {
                items.append(self.alloc, candidate) catch |e| {
                    self.alloc.free(name_copy);
                    return e;
                };
                dirty = true;
            } else {
                if (dirty) {
                    std.mem.sort(ListItem, items.items, {}, listLessThan);
                    dirty = false;
                }
                if (listLessThan({}, candidate, items.items[items.items.len - 1])) {
                    const removed = items.pop().?;
                    self.alloc.free(removed.name);
                    var index = items.items.len;
                    while (index > 0 and listLessThan({}, candidate, items.items[index - 1])) : (index -= 1) {}
                    items.insert(self.alloc, index, candidate) catch |e| {
                        self.alloc.free(name_copy);
                        return e;
                    };
                } else {
                    self.alloc.free(name_copy);
                }
            }
        }
        if (dirty) std.mem.sort(ListItem, items.items, {}, listLessThan);

        const body_budget = max_output_bytes -| (header_reserve + trunc_marker.len);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        var shown_entries: usize = 0;
        var truncated = total > items.items.len;

        for (items.items) |item| {
            const name = try sanitizeBounded(self.alloc, item.name, max_list_name_bytes);
            defer self.alloc.free(name);

            const line = switch (item.kind) {
                .directory => try std.fmt.allocPrint(self.alloc, "d  {s}/\n", .{name}),
                .file => blk: {
                    const size = self.listFileSize(dir, item.name);
                    if (size) |bytes| {
                        break :blk try std.fmt.allocPrint(self.alloc, "f  {s}  {d}\n", .{ name, bytes });
                    }
                    break :blk try std.fmt.allocPrint(self.alloc, "f  {s}  ?\n", .{name});
                },
                .sym_link => try std.fmt.allocPrint(self.alloc, "l  {s}\n", .{name}),
                else => try std.fmt.allocPrint(self.alloc, "o  {s}\n", .{name}),
            };
            defer self.alloc.free(line);

            if (body.items.len + line.len > body_budget) {
                truncated = true;
                break;
            }
            try body.appendSlice(self.alloc, line);
            shown_entries += 1;
        }

        const header = try std.fmt.allocPrint(self.alloc, "path: {s}\n---\n", .{shown});
        defer self.alloc.free(header);

        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(self.alloc);
        try content.ensureTotalCapacity(self.alloc, header.len + body.items.len + (if (truncated) trunc_marker.len else 0));
        try content.appendSlice(self.alloc, header);
        try content.appendSlice(self.alloc, body.items);
        if (truncated) try content.appendSlice(self.alloc, trunc_marker);

        const summary = if (truncated)
            try std.fmt.allocPrint(
                self.alloc,
                "list {s}: {d} of {d} entries (truncated)",
                .{ shown, shown_entries, total },
            )
        else
            try std.fmt.allocPrint(self.alloc, "list {s}: {d} entries", .{ shown, shown_entries });

        return .{ .status = .ok, .content = try content.toOwnedSlice(self.alloc), .summary = summary };
    }

    fn listFileSize(self: *Executor, dir: std.Io.Dir, name: []const u8) ?u64 {
        const stat = dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch return null;
        if (stat.kind != .file) return null;
        return stat.size;
    }

    // ------------------------------------------------------------------
    // grep
    // ------------------------------------------------------------------

    const Match = struct {
        path: []u8,
        line: usize,
        text: []u8,
    };

    const GrepScan = struct {
        alloc: std.mem.Allocator,
        pattern: []const u8,
        glob: ?[]const u8,
        matches: std.ArrayList(Match) = .empty,
        total: usize = 0,
        files_scanned: usize = 0,
        skipped_binary: usize = 0,
        skipped_large: usize = 0,
        skipped_unreadable: usize = 0,
        skipped_depth: usize = 0,
        skipped_symlink: usize = 0,

        fn deinit(self: *GrepScan) void {
            for (self.matches.items) |match| {
                self.alloc.free(match.path);
                self.alloc.free(match.text);
            }
            self.matches.deinit(self.alloc);
            self.* = undefined;
        }

        fn add(self: *GrepScan, path: []const u8, line_no: usize, line: []const u8) !void {
            self.total += 1;
            if (self.matches.items.len >= max_grep_matches) {
                const worst = self.matches.items[self.matches.items.len - 1];
                if (!matchLessThan(path, line_no, worst.path, worst.line)) return;
            }

            const text = try clipUtf8(self.alloc, line, max_grep_line_bytes);
            errdefer self.alloc.free(text);
            const owned_path = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(owned_path);

            const item = Match{ .path = owned_path, .line = line_no, .text = text };
            var index = self.matches.items.len;
            while (index > 0 and matchLessThan(item.path, item.line, self.matches.items[index - 1].path, self.matches.items[index - 1].line)) : (index -= 1) {}

            if (self.matches.items.len >= max_grep_matches) {
                const removed = self.matches.pop().?;
                self.alloc.free(removed.path);
                self.alloc.free(removed.text);
            }
            try self.matches.insert(self.alloc, index, item);
        }
    };

    fn grep(self: *Executor, arguments_json: []const u8) ExecuteError!Outcome {
        var parsed = switch (try self.parseArguments(arguments_json)) {
            .args => |p| p,
            .failure => |out| return out,
        };
        defer parsed.deinit();
        const obj = &parsed.value.object;

        const pattern = requiredString(obj, "pattern") catch |e| return try self.stringFieldFailure("pattern", e);
        const path_arg = optionalString(obj, "path") catch |e| return try self.stringFieldFailure("path", e);
        const glob_arg = optionalString(obj, "glob") catch |e| return try self.stringFieldFailure("glob", e);

        if (pattern.len == 0) return try self.fail(.invalid_pattern, "pattern must not be empty", .{});
        if (pattern.len > max_pattern_bytes) return try self.fail(.argument_too_long, "pattern is too long", .{});
        if (std.mem.indexOfScalar(u8, pattern, 0) != null) {
            return try self.fail(.invalid_pattern, "pattern must not contain NUL bytes", .{});
        }
        if (std.mem.indexOfAny(u8, pattern, "\r\n") != null) {
            return try self.fail(.invalid_pattern, "pattern must not contain newlines", .{});
        }

        var glob: ?[]const u8 = null;
        if (glob_arg) |g| {
            if (g.len == 0) return try self.fail(.invalid_glob, "glob must not be empty", .{});
            if (g.len > max_glob_bytes) return try self.fail(.argument_too_long, "glob is too long", .{});
            if (std.mem.indexOfScalar(u8, g, 0) != null) {
                return try self.fail(.invalid_glob, "glob must not contain NUL bytes", .{});
            }
            glob = g;
        }

        const raw_path = path_arg orelse ".";
        if (path_arg != null and raw_path.len == 0) {
            return try self.fail(.invalid_path, "path must not be empty", .{});
        }
        const rel = normalizePath(self.alloc, raw_path) catch |e| return try self.pathFailure(raw_path, e);
        defer self.alloc.free(rel);
        const requested_shown = try self.displayPath(rel);
        defer self.alloc.free(requested_shown);

        const canonical = self.resolveExisting(rel) catch |e| return try self.resolveFailure(requested_shown, e);
        defer self.alloc.free(canonical);
        const canonical_rel = relFromCanonical(self.root, canonical);
        const shown = try self.displayPath(canonical_rel);
        defer self.alloc.free(shown);

        var scan = GrepScan{ .alloc = self.alloc, .pattern = pattern, .glob = glob };
        defer scan.deinit();

        const stat = self.statPath(canonical) catch |e| switch (e) {
            error.NotFound => return try self.fail(.not_found, "not found: {s}", .{requested_shown}),
            error.Unreadable => return try self.fail(.unreadable, "cannot read: {s}", .{requested_shown}),
        };
        switch (stat.kind) {
            .directory => {
                // Preflight the explicitly requested directory so an
                // unreadable base is a typed error rather than an empty
                // "everything skipped" success. Nested directories are
                // counted and skipped instead.
                var dir = std.Io.Dir.openDirAbsolute(self.io, canonical, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
                    error.FileNotFound => return try self.fail(.not_found, "not found: {s}", .{requested_shown}),
                    error.NotDir => return try self.fail(.not_a_directory, "not a directory: {s}", .{requested_shown}),
                    error.AccessDenied, error.PermissionDenied => return try self.fail(.unreadable, "cannot read directory: {s}", .{requested_shown}),
                    else => return try self.fail(.unreadable, "cannot read directory: {s}", .{requested_shown}),
                };
                dir.close(self.io);
                try self.grepTree(&scan, canonical, canonical_rel, 0);
            },
            .file => {
                const basename = std.fs.path.basename(canonical);
                if (glob == null or globMatches(glob.?, basename)) {
                    self.grepFile(&scan, canonical, canonical_rel) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Unreadable => return try self.fail(.unreadable, "cannot read: {s}", .{shown}),
                        error.NotAFile => return try self.fail(.not_a_file, "not a regular file: {s}", .{shown}),
                    };
                }
            },
            else => return try self.fail(.not_a_file, "not a regular file: {s}", .{shown}),
        }

        const body_budget = max_output_bytes -| (header_reserve + trunc_marker.len);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        var shown_matches: usize = 0;
        for (scan.matches.items) |match| {
            const path_text = try sanitizeBounded(self.alloc, match.path, max_grep_path_bytes);
            defer self.alloc.free(path_text);
            const row = try std.fmt.allocPrint(self.alloc, "{s}:{d}:{s}\n", .{ path_text, match.line, match.text });
            defer self.alloc.free(row);
            if (body.items.len + row.len > body_budget) break;
            try body.appendSlice(self.alloc, row);
            shown_matches += 1;
        }

        const truncated = shown_matches < scan.total;
        const header = try std.fmt.allocPrint(self.alloc, "path: {s}\n---\n", .{shown});
        defer self.alloc.free(header);

        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(self.alloc);
        try content.ensureTotalCapacity(self.alloc, header.len + body.items.len + (if (truncated) trunc_marker.len else 0));
        try content.appendSlice(self.alloc, header);
        try content.appendSlice(self.alloc, body.items);
        if (truncated) try content.appendSlice(self.alloc, trunc_marker);

        const skipped_files = scan.skipped_binary + scan.skipped_large + scan.skipped_unreadable;
        const summary_base = if (scan.total == 0)
            try std.fmt.allocPrint(self.alloc, "grep: no matching lines", .{})
        else if (truncated)
            try std.fmt.allocPrint(self.alloc, "grep: {d} of {d} matching lines (truncated)", .{ shown_matches, scan.total })
        else
            try std.fmt.allocPrint(self.alloc, "grep: {d} matching lines", .{scan.total});
        defer self.alloc.free(summary_base);
        const summary = if (skipped_files > 0 or scan.skipped_depth > 0 or scan.skipped_symlink > 0)
            try std.fmt.allocPrint(
                self.alloc,
                "{s}; skipped binary={d} large={d} unreadable={d} depth={d} symlinks={d}",
                .{ summary_base, scan.skipped_binary, scan.skipped_large, scan.skipped_unreadable, scan.skipped_depth, scan.skipped_symlink },
            )
        else
            try self.alloc.dupe(u8, summary_base);

        return .{ .status = .ok, .content = try content.toOwnedSlice(self.alloc), .summary = summary };
    }

    const ScanFileError = error{ OutOfMemory, Unreadable, NotAFile };

    fn grepTree(
        self: *Executor,
        scan: *GrepScan,
        abs_dir: []const u8,
        rel_dir: []const u8,
        depth: usize,
    ) ExecuteError!void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, abs_dir, .{ .iterate = true, .follow_symlinks = false }) catch {
            scan.skipped_unreadable += 1;
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next(self.io) catch {
                scan.skipped_unreadable += 1;
                return;
            };
            const entry = maybe_entry orelse return;

            switch (entry.kind) {
                .file => {
                    if (scan.glob) |g| {
                        if (!globMatches(g, entry.name)) continue;
                    }
                    const abs_child = std.fs.path.join(self.alloc, &.{ abs_dir, entry.name }) catch return error.OutOfMemory;
                    defer self.alloc.free(abs_child);
                    const rel_child = childRel(self.alloc, rel_dir, entry.name) catch return error.OutOfMemory;
                    defer self.alloc.free(rel_child);
                    self.grepFile(scan, abs_child, rel_child) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Unreadable => scan.skipped_unreadable += 1,
                        error.NotAFile => {},
                    };
                },
                .directory => {
                    if (depth + 1 > max_grep_depth) {
                        scan.skipped_depth += 1;
                        continue;
                    }
                    const abs_child = std.fs.path.join(self.alloc, &.{ abs_dir, entry.name }) catch return error.OutOfMemory;
                    defer self.alloc.free(abs_child);
                    const rel_child = childRel(self.alloc, rel_dir, entry.name) catch return error.OutOfMemory;
                    defer self.alloc.free(rel_child);
                    try self.grepTree(scan, abs_child, rel_child, depth + 1);
                },
                .sym_link => scan.skipped_symlink += 1,
                else => {},
            }
        }
    }

    fn grepFile(
        self: *Executor,
        scan: *GrepScan,
        abs_path: []const u8,
        rel_path: []const u8,
    ) ScanFileError!void {
        const stat = self.statPath(abs_path) catch |e| switch (e) {
            error.NotFound => return error.Unreadable,
            error.Unreadable => return error.Unreadable,
        };
        if (stat.kind != .file) return error.NotAFile;
        if (stat.size > max_grep_file_bytes) {
            scan.skipped_large += 1;
            return;
        }

        var file = self.openFileForRead(abs_path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IsDir => return error.NotAFile,
            error.NotFound => return error.Unreadable,
            error.Unreadable => return error.Unreadable,
        };
        defer file.close(self.io);

        var reader_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(self.io, &reader_buffer);
        const data = file_reader.interface.allocRemaining(self.alloc, .limited(max_grep_file_bytes + 1)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => {
                scan.skipped_large += 1;
                return;
            },
            else => return error.Unreadable,
        };
        defer self.alloc.free(data);

        scan.files_scanned += 1;
        if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) {
            scan.skipped_binary += 1;
            return;
        }

        var line_no: usize = 1;
        var start: usize = 0;
        while (start < data.len) {
            const end = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
            var line = data[start..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (std.mem.indexOf(u8, line, scan.pattern) != null) {
                try scan.add(rel_path, line_no, line);
            }
            if (end == data.len) break;
            start = end + 1;
            line_no += 1;
        }
    }

    // ------------------------------------------------------------------
    // Argument parsing
    // ------------------------------------------------------------------

    const ParsedArguments = union(enum) {
        args: std.json.Parsed(std.json.Value),
        failure: Outcome,
    };

    fn parseArguments(self: *Executor, arguments_json: []const u8) ExecuteError!ParsedArguments {
        if (arguments_json.len > tools.max_arguments_bytes) {
            return .{ .failure = try self.fail(.argument_too_long, "tool arguments exceed the maximum size", .{}) };
        }
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, arguments_json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = try self.fail(.malformed_arguments, "tool arguments are not valid JSON", .{}) },
        };
        if (parsed.value != .object) {
            parsed.deinit();
            return .{ .failure = try self.fail(.malformed_arguments, "tool arguments must be a JSON object", .{}) };
        }
        return .{ .args = parsed };
    }

    const FieldError = error{ Missing, WrongType };
    const IntegerFieldError = error{ WrongType, InvalidRange };

    fn requiredString(obj: *const std.json.ObjectMap, field: []const u8) FieldError![]const u8 {
        const value = obj.get(field) orelse return error.Missing;
        return switch (value) {
            .string => |text| text,
            else => error.WrongType,
        };
    }

    fn optionalString(obj: *const std.json.ObjectMap, field: []const u8) FieldError!?[]const u8 {
        const value = obj.get(field) orelse return null;
        return switch (value) {
            .null => null,
            .string => |text| text,
            else => error.WrongType,
        };
    }

    fn optionalPositiveInteger(obj: *const std.json.ObjectMap, field: []const u8) IntegerFieldError!?i64 {
        const value = obj.get(field) orelse return null;
        switch (value) {
            .null => return null,
            .integer => |number| {
                if (number <= 0) return error.InvalidRange;
                if (@as(u64, @intCast(number)) > std.math.maxInt(usize)) return error.InvalidRange;
                return number;
            },
            else => return error.WrongType,
        }
    }

    fn stringFieldFailure(self: *Executor, field: []const u8, e: FieldError) ExecuteError!Outcome {
        return switch (e) {
            error.Missing => self.fail(.missing_argument, "missing required argument: {s}", .{field}),
            error.WrongType => self.fail(.wrong_argument_type, "argument {s} must be a string", .{field}),
        };
    }

    fn intFieldFailure(self: *Executor, field: []const u8, e: IntegerFieldError) ExecuteError!Outcome {
        return switch (e) {
            error.WrongType => self.fail(.wrong_argument_type, "argument {s} must be a positive integer", .{field}),
            error.InvalidRange => self.fail(.invalid_range, "argument {s} must be a positive integer", .{field}),
        };
    }

    // ------------------------------------------------------------------
    // Path handling
    // ------------------------------------------------------------------

    const PathError = error{ OutOfMemory, Empty, TooLong, Nul, Absolute, Parent };

    /// Validate a workspace-relative path and normalize redundant separators
    /// and "." components. The result is "." when the path denotes the root.
    /// Any ".." component is rejected even when it would stay inside the root.
    fn normalizePath(alloc: std.mem.Allocator, raw: []const u8) PathError![]u8 {
        if (raw.len == 0) return error.Empty;
        if (raw.len > max_path_bytes) return error.TooLong;
        if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.Nul;
        if (std.fs.path.isAbsolute(raw)) return error.Absolute;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var index: usize = 0;
        var any = false;
        while (index < raw.len) {
            while (index < raw.len and std.fs.path.isSep(raw[index])) index += 1;
            const start = index;
            while (index < raw.len and !std.fs.path.isSep(raw[index])) index += 1;
            const component = raw[start..index];
            if (component.len == 0) continue;
            if (std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) return error.Parent;

            if (any) try out.append(alloc, std.fs.path.sep);
            try out.appendSlice(alloc, component);
            any = true;
        }
        if (!any) return alloc.dupe(u8, ".");
        return out.toOwnedSlice(alloc);
    }

    const ResolveError = error{ OutOfMemory, NotFound, Escapes, Unreadable };

    /// Canonicalize an existing workspace-relative path and verify that it
    /// stays inside the canonical root. Returns an owned absolute path.
    fn resolveExisting(self: *Executor, rel: []const u8) ResolveError![:0]u8 {
        const joined = std.fs.path.join(self.alloc, &.{ self.root, rel }) catch return error.OutOfMemory;
        defer self.alloc.free(joined);

        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, self.alloc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.Unreadable,
            else => return error.Unreadable,
        };
        errdefer self.alloc.free(canonical);

        if (!isWithin(self.root, canonical)) return error.Escapes;
        return canonical;
    }

    const StatPathError = error{ NotFound, Unreadable };

    /// Stat an already-contained path without opening it. Following symlinks
    /// is safe here because the path was canonicalized by `resolveExisting`
    /// (or came from a non-symlink directory entry).
    fn statPath(self: *Executor, canonical: []const u8) StatPathError!std.Io.File.Stat {
        return std.Io.Dir.cwd().statFile(self.io, canonical, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Unreadable,
        };
    }

    const OpenPathError = error{ OutOfMemory, NotFound, IsDir, Unreadable };

    fn openFileForRead(self: *Executor, canonical: []const u8) OpenPathError!std.Io.File {
        return std.Io.Dir.openFileAbsolute(self.io, canonical, .{ .mode = .read_only, .allow_directory = true, .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => error.NotFound,
            error.NotDir => error.NotFound,
            error.IsDir => error.IsDir,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Unreadable,
        };
    }

    fn resolveFailure(self: *Executor, shown: []const u8, e: ResolveError) ExecuteError!Outcome {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotFound => self.fail(.not_found, "not found: {s}", .{shown}),
            error.Escapes => self.fail(.path_escapes_workspace, "path escapes workspace: {s}", .{shown}),
            error.Unreadable => self.fail(.unreadable, "cannot access: {s}", .{shown}),
        };
    }

    fn statFailure(self: *Executor, shown: []const u8, e: StatPathError) ExecuteError!Outcome {
        return switch (e) {
            error.NotFound => self.fail(.not_found, "not found: {s}", .{shown}),
            error.Unreadable => self.fail(.unreadable, "cannot read: {s}", .{shown}),
        };
    }

    fn openFailure(self: *Executor, shown: []const u8, e: OpenPathError) ExecuteError!Outcome {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotFound => self.fail(.not_found, "not found: {s}", .{shown}),
            error.IsDir => self.fail(.not_a_file, "not a regular file: {s}", .{shown}),
            error.Unreadable => self.fail(.unreadable, "cannot read: {s}", .{shown}),
        };
    }

    fn pathFailure(self: *Executor, raw: []const u8, e: PathError) ExecuteError!Outcome {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Empty => self.fail(.invalid_path, "path must not be empty", .{}),
            error.TooLong => self.fail(.argument_too_long, "path is too long", .{}),
            error.Nul => self.fail(.invalid_path, "path must not contain NUL bytes", .{}),
            error.Absolute => self.fail(.path_escapes_workspace, "path escapes workspace: absolute paths are not allowed", .{}),
            error.Parent => blk: {
                const shown = try sanitizeBounded(self.alloc, raw, max_display_path_bytes);
                defer self.alloc.free(shown);
                break :blk self.fail(.path_escapes_workspace, "path escapes workspace: {s}", .{shown});
            },
        };
    }

    fn displayPath(self: *Executor, path: []const u8) ExecuteError![]u8 {
        return sanitizeBounded(self.alloc, path, max_display_path_bytes);
    }

    // ------------------------------------------------------------------
    // Outcome helpers
    // ------------------------------------------------------------------

    fn fail(
        self: *Executor,
        failure: Failure,
        comptime fmt: []const u8,
        args: anytype,
    ) ExecuteError!Outcome {
        const detail = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(detail);
        const content = try std.fmt.allocPrint(self.alloc, "error: {s}", .{detail});
        errdefer self.alloc.free(content);
        const summary = try std.fmt.allocPrint(self.alloc, "error: {s}", .{@tagName(failure)});
        return .{ .status = .err, .content = content, .summary = summary, .failure = failure };
    }
};

/// One-shot convenience wrapper. Callers doing multiple calls in one turn
/// should construct an `Executor` instead so the root is resolved once.
pub fn execute(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    call: tools.ToolCall,
) ExecuteError!Outcome {
    var executor = try Executor.init(alloc, io, workspace_root);
    defer executor.deinit();
    return executor.execute(call);
}

// ----------------------------------------------------------------------
// Free helper functions
// ----------------------------------------------------------------------

fn isWithin(root: []const u8, canonical: []const u8) bool {
    if (std.mem.eql(u8, root, canonical)) return true;
    if (root.len == 1 and std.fs.path.isSep(root[0])) {
        return canonical.len > 0 and std.fs.path.isSep(canonical[0]);
    }
    return canonical.len > root.len and
        std.mem.startsWith(u8, canonical, root) and
        std.fs.path.isSep(canonical[root.len]);
}

fn relFromCanonical(root: []const u8, canonical: []const u8) []const u8 {
    if (std.mem.eql(u8, root, canonical)) return ".";
    if (root.len == 1 and std.fs.path.isSep(root[0])) return canonical[1..];
    if (canonical.len > root.len and std.fs.path.isSep(canonical[root.len])) {
        return canonical[root.len + 1 ..];
    }
    // Unreachable after resolveExisting containment; never echo host paths.
    return "<outside>";
}

fn childRel(alloc: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, base, ".")) return alloc.dupe(u8, name);
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ base, std.fs.path.sep_str, name });
}

fn listGroup(kind: std.Io.File.Kind) u8 {
    return switch (kind) {
        .directory => 0,
        .file => 1,
        else => 2,
    };
}

fn listLessThan(_: void, a: Executor.ListItem, b: Executor.ListItem) bool {
    const a_group = listGroup(a.kind);
    const b_group = listGroup(b.kind);
    if (a_group != b_group) return a_group < b_group;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn matchLessThan(a_path: []const u8, a_line: usize, b_path: []const u8, b_line: usize) bool {
    const order = std.mem.order(u8, a_path, b_path);
    if (order != .eq) return order == .lt;
    return a_line < b_line;
}

/// Simple basename glob: `*` matches any run of bytes, `?` one byte, no
/// character classes or escaping. Only the final path component of the
/// pattern is used, so "**/*.zig" behaves like "*.zig" for this M3a tool.
fn globMatches(pattern: []const u8, name: []const u8) bool {
    var basename = pattern;
    if (std.mem.lastIndexOfAny(u8, basename, "/\\")) |slash| basename = basename[slash + 1 ..];
    if (basename.len == 0) return false;
    if (std.mem.eql(u8, basename, "*")) return true;

    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_index: ?usize = null;
    var star_name_index: usize = 0;

    while (name_index < name.len) {
        if (pattern_index < basename.len and
            (basename[pattern_index] == '?' or basename[pattern_index] == name[name_index]))
        {
            pattern_index += 1;
            name_index += 1;
        } else if (pattern_index < basename.len and basename[pattern_index] == '*') {
            star_index = pattern_index;
            star_name_index = name_index;
            pattern_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_name_index += 1;
            name_index = star_name_index;
        } else {
            return false;
        }
    }
    while (pattern_index < basename.len and basename[pattern_index] == '*') pattern_index += 1;
    return pattern_index == basename.len;
}

/// Copy `input` into a display-safe, bounded, valid-UTF-8 string. Control
/// bytes and invalid UTF-8 are replaced with '?'; a clipped result gets a
/// trailing ellipsis.
fn sanitizeBounded(alloc: std.mem.Allocator, input: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var index: usize = 0;
    var clipped = false;
    while (index < input.len) {
        const byte = input[index];
        if (byte < 0x20 or byte == 0x7f) {
            if (out.items.len >= limit) {
                clipped = true;
                break;
            }
            try out.append(alloc, '?');
            index += 1;
            continue;
        }
        if (byte < 0x80) {
            if (out.items.len >= limit) {
                clipped = true;
                break;
            }
            try out.append(alloc, byte);
            index += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            if (out.items.len >= limit) {
                clipped = true;
                break;
            }
            try out.append(alloc, '?');
            index += 1;
            continue;
        };
        const len: usize = seq_len;
        if (index + len > input.len or !std.unicode.utf8ValidateSlice(input[index .. index + len])) {
            if (out.items.len >= limit) {
                clipped = true;
                break;
            }
            try out.append(alloc, '?');
            index += 1;
            continue;
        }
        if (out.items.len + len > limit) {
            clipped = true;
            break;
        }
        try out.appendSlice(alloc, input[index .. index + len]);
        index += len;
    }
    if (index < input.len) clipped = true;
    if (clipped) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

/// Largest valid-UTF-8 prefix of `input` no longer than `max` bytes.
fn utf8PrefixLen(input: []const u8, max: usize) usize {
    const len = @min(input.len, max);
    if (std.unicode.utf8ValidateSlice(input[0..len])) return len;
    var back: usize = 1;
    while (back <= 4 and len >= back) : (back += 1) {
        if (std.unicode.utf8ValidateSlice(input[0 .. len - back])) return len - back;
    }
    return 0;
}

fn clipUtf8(alloc: std.mem.Allocator, input: []const u8, max: usize) ![]u8 {
    const len = utf8PrefixLen(input, max);
    const clipped = len < input.len;
    if (!clipped) return alloc.dupe(u8, input[0..len]);
    const out = try alloc.alloc(u8, len + 3);
    @memcpy(out[0..len], input[0..len]);
    @memcpy(out[len..][0..3], "…");
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeCall(name: []const u8, arguments_json: []const u8) tools.ToolCall {
    return .{
        .id = @constCast("call_test"),
        .name = @constCast(name),
        .arguments_json = @constCast(arguments_json),
    };
}

const Fixture = struct {
    alloc: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    base: []u8,
    ws: []u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "ws");
        try tmp.dir.createDirPath(testing.io, "outside");

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buffer);
        const base = try alloc.dupe(u8, buffer[0..len]);
        errdefer alloc.free(base);
        const ws = try std.fs.path.join(alloc, &.{ base, "ws" });
        return .{ .alloc = alloc, .tmp = tmp, .base = base, .ws = ws };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.alloc.free(self.base);
        self.alloc.free(self.ws);
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }
};

fn expectStatus(out: *const Outcome, status: Status) !void {
    try testing.expectEqual(status, out.status);
    try testing.expect(std.unicode.utf8ValidateSlice(out.content));
    try testing.expect(out.content.len <= max_output_bytes);
    if (out.summary) |summary| {
        try testing.expect(summary.len <= max_summary_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(summary));
    }
    switch (status) {
        .err => try testing.expect(out.failure != null),
        else => try testing.expect(out.failure == null),
    }
}

fn run(alloc: std.mem.Allocator, ws: []const u8, name: []const u8, arguments_json: []const u8) !Outcome {
    return execute(alloc, testing.io, ws, makeCall(name, arguments_json));
}

test "tool_exec: read_file full file and inclusive line ranges" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/hello.txt", "hello\nworld\n中🙂\n");

    var full = try run(alloc, fixture.ws, "read_file", "{\"path\":\"hello.txt\"}");
    defer full.deinit(alloc);
    try expectStatus(&full, .ok);
    try testing.expectEqualStrings(
        "path: hello.txt\nlines: 1-3\n---\nhello\nworld\n中🙂\n",
        full.content,
    );
    try testing.expect(std.mem.indexOf(u8, full.summary.?, "lines 1-3") != null);

    var range = try run(alloc, fixture.ws, "read_file", "{\"path\":\"hello.txt\",\"start_line\":2,\"end_line\":2}");
    defer range.deinit(alloc);
    try expectStatus(&range, .ok);
    try testing.expectEqualStrings("path: hello.txt\nlines: 2-2\n---\nworld\n", range.content);

    var from_line = try run(alloc, fixture.ws, "read_file", "{\"path\":\"hello.txt\",\"start_line\":2}");
    defer from_line.deinit(alloc);
    try expectStatus(&from_line, .ok);
    try testing.expectEqualStrings("path: hello.txt\nlines: 2-3\n---\nworld\n中🙂\n", from_line.content);

    // End line beyond EOF is clamped by EOF, not an error.
    var tail = try run(alloc, fixture.ws, "read_file", "{\"path\":\"hello.txt\",\"start_line\":3,\"end_line\":99}");
    defer tail.deinit(alloc);
    try expectStatus(&tail, .ok);
    try testing.expectEqualStrings("path: hello.txt\nlines: 3-3\n---\n中🙂\n", tail.content);

    // Unknown fields are ignored.
    var unknown = try run(alloc, fixture.ws, "read_file", "{\"path\":\"hello.txt\",\"future\":{\"x\":1}}");
    defer unknown.deinit(alloc);
    try expectStatus(&unknown, .ok);
    try testing.expect(std.mem.indexOf(u8, unknown.content, "hello\nworld") != null);
}

test "tool_exec: read_file empty, hidden and out-of-range handling" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/empty.txt", "");
    try fixture.write("ws/.hidden", "secret inside workspace\n");

    var empty = try run(alloc, fixture.ws, "read_file", "{\"path\":\"empty.txt\"}");
    defer empty.deinit(alloc);
    try expectStatus(&empty, .ok);
    try testing.expectEqualStrings("path: empty.txt\nlines: none\n---\n", empty.content);

    var hidden = try run(alloc, fixture.ws, "read_file", "{\"path\":\".hidden\"}");
    defer hidden.deinit(alloc);
    try expectStatus(&hidden, .ok);
    try testing.expectEqualStrings("secret inside workspace\n", hidden.content[std.mem.indexOf(u8, hidden.content, "---\n").? + 4 ..]);

    var missing = try run(alloc, fixture.ws, "read_file", "{\"path\":\"missing.txt\"}");
    defer missing.deinit(alloc);
    try expectStatus(&missing, .err);
    try testing.expectEqual(Failure.not_found, missing.failure.?);

    var directory = try run(alloc, fixture.ws, "read_file", "{\"path\":\".\"}");
    defer directory.deinit(alloc);
    try expectStatus(&directory, .err);
    try testing.expectEqual(Failure.not_a_file, directory.failure.?);

    var beyond = try run(alloc, fixture.ws, "read_file", "{\"path\":\"empty.txt\",\"start_line\":2}");
    defer beyond.deinit(alloc);
    try expectStatus(&beyond, .err);
    try testing.expectEqual(Failure.line_out_of_range, beyond.failure.?);

    var bad_range = try run(alloc, fixture.ws, "read_file", "{\"path\":\"empty.txt\",\"start_line\":0}");
    defer bad_range.deinit(alloc);
    try expectStatus(&bad_range, .err);
    try testing.expectEqual(Failure.invalid_range, bad_range.failure.?);

    var reversed = try run(alloc, fixture.ws, "read_file", "{\"path\":\"empty.txt\",\"start_line\":3,\"end_line\":2}");
    defer reversed.deinit(alloc);
    try expectStatus(&reversed, .err);
    try testing.expectEqual(Failure.invalid_range, reversed.failure.?);
}

test "tool_exec: read_file rejects NUL bytes and non-UTF-8" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/binary.dat", "abc\x00def\n");
    try fixture.write("ws/invalid.txt", "ok\xffbad\n");

    var binary = try run(alloc, fixture.ws, "read_file", "{\"path\":\"binary.dat\"}");
    defer binary.deinit(alloc);
    try expectStatus(&binary, .err);
    try testing.expectEqual(Failure.binary_file, binary.failure.?);

    var invalid = try run(alloc, fixture.ws, "read_file", "{\"path\":\"invalid.txt\"}");
    defer invalid.deinit(alloc);
    try expectStatus(&invalid, .err);
    try testing.expectEqual(Failure.binary_file, invalid.failure.?);
}

test "tool_exec: read_file line and byte truncation are bounded and UTF-8 safe" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();

    var many_lines: std.ArrayList(u8) = .empty;
    defer many_lines.deinit(alloc);
    var i: usize = 0;
    while (i < 3000) : (i += 1) try many_lines.appendSlice(alloc, "x\n");
    try fixture.write("ws/many.txt", many_lines.items);

    var many = try run(alloc, fixture.ws, "read_file", "{\"path\":\"many.txt\"}");
    defer many.deinit(alloc);
    try expectStatus(&many, .ok);
    try testing.expect(many.content.len <= max_output_bytes);
    try testing.expect(std.mem.endsWith(u8, many.content, "… [truncated]"));
    try testing.expectEqual(@as(usize, 3 + max_read_lines + 1), std.mem.count(u8, many.content, "\n"));

    // Exactly at the line cap, EOF means a complete (untruncated) read.
    var exact_lines: std.ArrayList(u8) = .empty;
    defer exact_lines.deinit(alloc);
    i = 0;
    while (i < max_read_lines) : (i += 1) try exact_lines.appendSlice(alloc, "y\n");
    try fixture.write("ws/exact.txt", exact_lines.items);

    var exact = try run(alloc, fixture.ws, "read_file", "{\"path\":\"exact.txt\"}");
    defer exact.deinit(alloc);
    try expectStatus(&exact, .ok);
    try testing.expect(std.mem.indexOf(u8, exact.content, "[truncated]") == null);
    try testing.expectEqual(@as(usize, 3 + max_read_lines), std.mem.count(u8, exact.content, "\n"));

    // A single huge line is cut at the byte budget.
    const huge = try alloc.alloc(u8, 100_000);
    defer alloc.free(huge);
    @memset(huge, 'a');
    try fixture.write("ws/huge.txt", huge);

    var cut = try run(alloc, fixture.ws, "read_file", "{\"path\":\"huge.txt\"}");
    defer cut.deinit(alloc);
    try expectStatus(&cut, .ok);
    try testing.expect(cut.content.len <= max_output_bytes);
    try testing.expect(std.mem.endsWith(u8, cut.content, "… [truncated]"));

    // A multi-byte character cut by the byte budget is removed whole.
    const wide = try alloc.alloc(u8, 30_000 * "🙂".len);
    defer alloc.free(wide);
    i = 0;
    while (i < 30_000) : (i += 1) @memcpy(wide[i * 4 ..][0..4], "🙂");
    try fixture.write("ws/wide.txt", wide);

    var wide_out = try run(alloc, fixture.ws, "read_file", "{\"path\":\"wide.txt\"}");
    defer wide_out.deinit(alloc);
    try expectStatus(&wide_out, .ok);
    try testing.expect(wide_out.content.len <= max_output_bytes);
    try testing.expect(std.mem.endsWith(u8, wide_out.content, "… [truncated]"));
    try testing.expect(std.unicode.utf8ValidateSlice(wide_out.content));
    try testing.expect(std.mem.indexOf(u8, wide_out.content, "\u{FFFD}") == null);
}

test "tool_exec: confinement rejects traversal, absolute paths and symlink escapes" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/ok.txt", "inside\n");
    try fixture.write("outside/secret.txt", "outside secret\n");
    try fixture.tmp.dir.symLink(testing.io, "../outside/secret.txt", "ws/link_out", .{});
    try fixture.tmp.dir.symLink(testing.io, "../outside", "ws/link_dir", .{});
    try fixture.tmp.dir.symLink(testing.io, "ok.txt", "ws/link_in", .{});
    const absolute = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}/ok.txt\"}}", .{fixture.ws});
    defer alloc.free(absolute);

    const cases = [_]struct { name: []const u8, args: []const u8, failure: Failure }{
        .{ .name = "read_file", .args = "{\"path\":\"../outside/secret.txt\"}", .failure = .path_escapes_workspace },
        .{ .name = "read_file", .args = "{\"path\":\"a/../../outside/secret.txt\"}", .failure = .path_escapes_workspace },
        .{ .name = "read_file", .args = absolute, .failure = .path_escapes_workspace },
        .{ .name = "read_file", .args = "{\"path\":\"link_out\"}", .failure = .path_escapes_workspace },
        .{ .name = "list_directory", .args = "{\"path\":\"../outside\"}", .failure = .path_escapes_workspace },
        .{ .name = "list_directory", .args = "{\"path\":\"link_dir\"}", .failure = .path_escapes_workspace },
        .{ .name = "grep", .args = "{\"pattern\":\"outside\",\"path\":\"../outside\"}", .failure = .path_escapes_workspace },
        .{ .name = "grep", .args = "{\"pattern\":\"outside\",\"path\":\"link_out\"}", .failure = .path_escapes_workspace },
    };
    for (cases) |case| {
        var out = try run(alloc, fixture.ws, case.name, case.args);
        defer out.deinit(alloc);
        try expectStatus(&out, .err);
        try testing.expectEqual(case.failure, out.failure.?);
        try testing.expect(std.mem.indexOf(u8, out.content, "escapes workspace") != null);
        try testing.expect(std.mem.indexOf(u8, out.content, fixture.base) == null);
    }

    // Inside-root symlinks and hidden files remain usable.
    var inside_link = try run(alloc, fixture.ws, "read_file", "{\"path\":\"link_in\"}");
    defer inside_link.deinit(alloc);
    try expectStatus(&inside_link, .ok);
    try testing.expect(std.mem.indexOf(u8, inside_link.content, "inside\n") != null);

    var hidden = try run(alloc, fixture.ws, "read_file", "{\"path\":\".hidden\"}");
    defer hidden.deinit(alloc);
    // The file does not exist in this fixture; this must be a clean error.
    try expectStatus(&hidden, .err);
    try testing.expectEqual(Failure.not_found, hidden.failure.?);

    var nul_path = try run(alloc, fixture.ws, "read_file", "{\"path\":\"a\\u0000b\"}");
    defer nul_path.deinit(alloc);
    try expectStatus(&nul_path, .err);
    try testing.expectEqual(Failure.invalid_path, nul_path.failure.?);
}

test "tool_exec: list_directory sorts dirs first, reports types/sizes and includes hidden" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "ws/zdir");
    try fixture.tmp.dir.createDirPath(testing.io, "ws/adir");
    try fixture.write("ws/b.txt", "hello");
    try fixture.write("ws/a.txt", "abc");
    try fixture.write("ws/.hidden", "x");
    try fixture.tmp.dir.symLink(testing.io, "a.txt", "ws/link", .{});

    var root = try run(alloc, fixture.ws, "list_directory", "{\"path\":\".\"}");
    defer root.deinit(alloc);
    try expectStatus(&root, .ok);
    try testing.expectEqualStrings(
        "path: .\n---\n" ++
            "d  adir/\n" ++
            "d  zdir/\n" ++
            "f  .hidden  1\n" ++
            "f  a.txt  3\n" ++
            "f  b.txt  5\n" ++
            "l  link\n",
        root.content,
    );

    var sub = try run(alloc, fixture.ws, "list_directory", "{\"path\":\"adir\"}");
    defer sub.deinit(alloc);
    try expectStatus(&sub, .ok);
    try testing.expectEqualStrings("path: adir\n---\n", sub.content);

    var file_as_dir = try run(alloc, fixture.ws, "list_directory", "{\"path\":\"a.txt\"}");
    defer file_as_dir.deinit(alloc);
    try expectStatus(&file_as_dir, .err);
    try testing.expectEqual(Failure.not_a_directory, file_as_dir.failure.?);

    var missing = try run(alloc, fixture.ws, "list_directory", "{\"path\":\"nope\"}");
    defer missing.deinit(alloc);
    try expectStatus(&missing, .err);
    try testing.expectEqual(Failure.not_found, missing.failure.?);
}

test "tool_exec: list_directory caps at 500 entries deterministically" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "ws/many");

    var i: usize = 0;
    while (i < 510) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "ws/many/f{d:0>3}", .{i});
        defer alloc.free(name);
        try fixture.write(name, "x");
    }

    var out = try run(alloc, fixture.ws, "list_directory", "{\"path\":\"many\"}");
    defer out.deinit(alloc);
    try expectStatus(&out, .ok);
    try testing.expect(out.content.len <= max_output_bytes);
    try testing.expect(std.mem.indexOf(u8, out.content, "f499") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "f500") == null);
    try testing.expect(std.mem.endsWith(u8, out.content, "… [truncated]"));
    try testing.expectEqual(@as(usize, 2 + max_list_entries + 1), std.mem.count(u8, out.content, "\n"));
    try testing.expect(std.mem.indexOf(u8, out.summary.?, "500 of 510") != null);
}

test "tool_exec: grep literal substring, glob filtering and deterministic row order" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "ws/src");
    try fixture.write("ws/README.md", "TODO readme\n");
    try fixture.write("ws/src/main.zig", "const x = 1;\n// TODO fix\n");
    try fixture.write("ws/src/other.txt", "TODO other\nTODO second\n");
    try fixture.write("ws/meta.txt", "a.b\naxb\n");

    var all = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\"}");
    defer all.deinit(alloc);
    try expectStatus(&all, .ok);
    try testing.expectEqualStrings(
        "path: .\n---\n" ++
            "README.md:1:TODO readme\n" ++
            "src/main.zig:2:// TODO fix\n" ++
            "src/other.txt:1:TODO other\n" ++
            "src/other.txt:2:TODO second\n",
        all.content,
    );

    var zig_only = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"glob\":\"*.zig\"}");
    defer zig_only.deinit(alloc);
    try expectStatus(&zig_only, .ok);
    try testing.expectEqualStrings("path: .\n---\nsrc/main.zig:2:// TODO fix\n", zig_only.content);

    var recursive_glob = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"glob\":\"**/*.zig\"}");
    defer recursive_glob.deinit(alloc);
    try expectStatus(&recursive_glob, .ok);
    try testing.expectEqualStrings("path: .\n---\nsrc/main.zig:2:// TODO fix\n", recursive_glob.content);

    // '.' is a literal byte, not a regex wildcard.
    var literal = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"a.b\",\"path\":\"meta.txt\"}");
    defer literal.deinit(alloc);
    try expectStatus(&literal, .ok);
    try testing.expectEqualStrings("path: meta.txt\n---\nmeta.txt:1:a.b\n", literal.content);

    // Explicit file as the search path, plus a case-sensitive miss.
    var file_target = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"path\":\"README.md\"}");
    defer file_target.deinit(alloc);
    try expectStatus(&file_target, .ok);
    try testing.expectEqualStrings("path: README.md\n---\nREADME.md:1:TODO readme\n", file_target.content);

    var miss = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"todo\"}");
    defer miss.deinit(alloc);
    try expectStatus(&miss, .ok);
    try testing.expectEqualStrings("path: .\n---\n", miss.content);
    try testing.expectEqualStrings("grep: no matching lines", miss.summary.?);
}

test "tool_exec: grep skips binary, large, symlinked and unreadable files" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/binary.dat", "TODO\x00inside\n");
    try fixture.write("ws/invalid.dat", "TODO\xff\n");
    try fixture.write("ws/text.txt", "TODO visible\n");
    try fixture.write("outside/secret.txt", "TODO outside\n");
    try fixture.tmp.dir.symLink(testing.io, "../outside/secret.txt", "ws/link_out", .{});

    const large_bytes = try alloc.alloc(u8, max_grep_file_bytes + 1);
    defer alloc.free(large_bytes);
    @memset(large_bytes, 'a');
    @memcpy(large_bytes[0..4], "TODO");
    try fixture.write("ws/large.txt", large_bytes);

    var out = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\"}");
    defer out.deinit(alloc);
    try expectStatus(&out, .ok);
    try testing.expectEqualStrings("path: .\n---\ntext.txt:1:TODO visible\n", out.content);
    try testing.expect(std.mem.indexOf(u8, out.summary.?, "binary=2") != null);
    try testing.expect(std.mem.indexOf(u8, out.summary.?, "large=1") != null);
    try testing.expect(std.mem.indexOf(u8, out.summary.?, "symlinks=1") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "outside") == null);

    // Explicitly asking for the escaping symlink is still rejected.
    var escape = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"path\":\"link_out\"}");
    defer escape.deinit(alloc);
    try expectStatus(&escape, .err);
    try testing.expectEqual(Failure.path_escapes_workspace, escape.failure.?);
}

test "tool_exec: grep caps matches at 200 sorted by path and line" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();

    var hits: std.ArrayList(u8) = .empty;
    defer hits.deinit(alloc);
    var i: usize = 0;
    while (i < 250) : (i += 1) try hits.appendSlice(alloc, "hit\n");
    try fixture.write("ws/hits.txt", hits.items);

    var out = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"hit\",\"path\":\"hits.txt\"}");
    defer out.deinit(alloc);
    try expectStatus(&out, .ok);
    try testing.expect(out.content.len <= max_output_bytes);
    try testing.expect(std.mem.indexOf(u8, out.content, "hits.txt:1:hit") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "hits.txt:200:hit") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "hits.txt:201:hit") == null);
    try testing.expect(std.mem.endsWith(u8, out.content, "… [truncated]"));
    try testing.expect(std.mem.indexOf(u8, out.summary.?, "200 of 250") != null);
}

test "tool_exec: grep max depth and missing or unreadable paths" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();

    const deep8 = "ws/deep/d1/d2/d3/d4/d5/d6/d7";
    try fixture.tmp.dir.createDirPath(testing.io, deep8);
    try fixture.write(deep8 ++ "/inside.txt", "DEEPMATCH\n");
    const deep9 = "ws/deep/d1/d2/d3/d4/d5/d6/d7/d8";
    try fixture.tmp.dir.createDirPath(testing.io, deep9);
    try fixture.write(deep9 ++ "/outside-depth.txt", "DEEPMATCH\n");

    var deep = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"DEEPMATCH\"}");
    defer deep.deinit(alloc);
    try expectStatus(&deep, .ok);
    try testing.expect(std.mem.indexOf(u8, deep.content, "level") == null);
    try testing.expect(std.mem.indexOf(u8, deep.content, "inside.txt:1:DEEPMATCH") != null);
    try testing.expect(std.mem.indexOf(u8, deep.content, "outside-depth.txt") == null);
    try testing.expect(std.mem.indexOf(u8, deep.summary.?, "depth=1") != null);
    var missing = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"x\",\"path\":\"missing\"}");
    defer missing.deinit(alloc);
    try expectStatus(&missing, .err);
    try testing.expectEqual(Failure.not_found, missing.failure.?);

    // Permission-denied paths are only testable when not running as root.
    if (std.c.geteuid() != 0) {
        fixture.write("ws/unreadable.txt", "TODO blocked\n") catch return error.TestUnexpectedResult;
        var file = try fixture.tmp.dir.openFile(testing.io, "ws/unreadable.txt", .{ .mode = .read_write });
        try file.setPermissions(testing.io, std.Io.File.Permissions.fromMode(0));
        file.close(testing.io);

        var skipped = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\"}");
        defer skipped.deinit(alloc);
        try expectStatus(&skipped, .ok);
        try testing.expect(std.mem.indexOf(u8, skipped.content, "unreadable.txt") == null);
        try testing.expect(std.mem.indexOf(u8, skipped.summary.?, "unreadable=1") != null);

        var direct = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"path\":\"unreadable.txt\"}");
        defer direct.deinit(alloc);
        try expectStatus(&direct, .err);
        try testing.expectEqual(Failure.unreadable, direct.failure.?);

        try fixture.tmp.dir.createDirPath(testing.io, "ws/noread");
        try fixture.tmp.dir.setFilePermissions(testing.io, "ws/noread", std.Io.File.Permissions.fromMode(0), .{});

        var blocked = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"TODO\",\"path\":\"noread\"}");
        defer blocked.deinit(alloc);
        try expectStatus(&blocked, .err);
        try testing.expectEqual(Failure.unreadable, blocked.failure.?);
    }
}

test "tool_exec: malformed arguments are typed errors, unknown fields ignored" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/hello.txt", "hello\n");

    const malformed = [_][]const u8{ "", "{", "{not json", "[]", "null", "\"path\"" };
    for (malformed) |args| {
        var out = try run(alloc, fixture.ws, "read_file", args);
        defer out.deinit(alloc);
        try expectStatus(&out, .err);
        try testing.expectEqual(Failure.malformed_arguments, out.failure.?);
    }

    const missing_path = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "read_file", .args = "{}" },
        .{ .name = "list_directory", .args = "{}" },
        .{ .name = "grep", .args = "{}" },
    };
    for (missing_path) |case| {
        var out = try run(alloc, fixture.ws, case.name, case.args);
        defer out.deinit(alloc);
        try expectStatus(&out, .err);
        try testing.expectEqual(Failure.missing_argument, out.failure.?);
    }

    const wrong_types = [_][]const u8{
        "{\"path\":3}",
        "{\"path\":null}",
        "{\"path\":\"hello.txt\",\"start_line\":\"1\"}",
        "{\"path\":\"hello.txt\",\"end_line\":true}",
    };
    for (wrong_types) |args| {
        var out = try run(alloc, fixture.ws, "read_file", args);
        defer out.deinit(alloc);
        try expectStatus(&out, .err);
        try testing.expectEqual(Failure.wrong_argument_type, out.failure.?);
    }

    const bad_grep = [_]struct { args: []const u8, failure: Failure }{
        .{ .args = "{\"pattern\":3}", .failure = .wrong_argument_type },
        .{ .args = "{\"pattern\":\"\"}", .failure = .invalid_pattern },
        .{ .args = "{\"pattern\":\"a\\nb\"}", .failure = .invalid_pattern },
        .{ .args = "{\"pattern\":\"x\",\"glob\":3}", .failure = .wrong_argument_type },
        .{ .args = "{\"pattern\":\"x\",\"glob\":\"\"}", .failure = .invalid_glob },
        .{ .args = "{\"pattern\":\"x\",\"path\":3}", .failure = .wrong_argument_type },
    };
    for (bad_grep) |case| {
        var out = try run(alloc, fixture.ws, "grep", case.args);
        defer out.deinit(alloc);
        try expectStatus(&out, .err);
        try testing.expectEqual(case.failure, out.failure.?);
    }

    const oversized = try alloc.alloc(u8, max_path_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    const too_long = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{oversized});
    defer alloc.free(too_long);
    var long_out = try run(alloc, fixture.ws, "read_file", too_long);
    defer long_out.deinit(alloc);
    try expectStatus(&long_out, .err);
    try testing.expectEqual(Failure.argument_too_long, long_out.failure.?);
}

test "tool_exec: write and terminal tools never execute" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/editable.txt", "original\n");

    var edit = try run(
        alloc,
        fixture.ws,
        "edit_file",
        "{\"path\":\"editable.txt\",\"old_string\":\"original\",\"new_string\":\"changed\"}",
    );
    defer edit.deinit(alloc);
    try expectStatus(&edit, .approval_required);
    try testing.expect(std.mem.indexOf(u8, edit.content, "not executed") != null);

    var patch = try run(
        alloc,
        fixture.ws,
        "apply_patch",
        "{\"patch\":\"--- a/editable.txt\\n+++ b/editable.txt\\n@@ -1 +1 @@\\n-original\\n+changed\\n\"}",
    );
    defer patch.deinit(alloc);
    try expectStatus(&patch, .approval_required);

    var terminal = try run(alloc, fixture.ws, "terminal", "{\"command\":\"rm -rf /\"}");
    defer terminal.deinit(alloc);
    try expectStatus(&terminal, .unsupported);

    var unknown = try run(alloc, fixture.ws, "shell", "{}");
    defer unknown.deinit(alloc);
    try expectStatus(&unknown, .unsupported);
    try testing.expect(std.mem.indexOf(u8, unknown.content, "shell") != null);

    var new_edit = try run(
        alloc,
        fixture.ws,
        "edit_file",
        "{\"path\":\"created.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}",
    );
    defer new_edit.deinit(alloc);
    try expectStatus(&new_edit, .approval_required);

    const original = try fixture.tmp.dir.readFileAlloc(testing.io, "ws/editable.txt", alloc, .limited(128));
    defer alloc.free(original);
    try testing.expectEqualStrings("original\n", original);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(testing.io, "ws/created.txt", .{}));
}

test "tool_exec: executor root validation and reuse" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/hello.txt", "hello\n");

    try testing.expectError(
        error.InvalidWorkspaceRoot,
        execute(alloc, testing.io, "", makeCall("read_file", "{\"path\":\"hello.txt\"}")),
    );
    try testing.expectError(
        error.InvalidWorkspaceRoot,
        execute(alloc, testing.io, "/definitely/not/a/oz/tool-exec/workspace", makeCall("read_file", "{\"path\":\"x\"}")),
    );
    const file_root = try std.fmt.allocPrint(alloc, "{s}/hello.txt", .{fixture.ws});
    defer alloc.free(file_root);
    try testing.expectError(
        error.InvalidWorkspaceRoot,
        execute(alloc, testing.io, file_root, makeCall("read_file", "{\"path\":\"x\"}")),
    );

    var executor = try Executor.init(alloc, testing.io, fixture.ws);
    defer executor.deinit();
    var first = try executor.execute(makeCall("read_file", "{\"path\":\"hello.txt\"}"));
    defer first.deinit(alloc);
    var second = try executor.execute(makeCall("list_directory", "{\"path\":\".\"}"));
    defer second.deinit(alloc);
    try expectStatus(&first, .ok);
    try expectStatus(&second, .ok);
    try testing.expect(std.mem.indexOf(u8, second.content, "f  hello.txt  6\n") != null);
}

test "tool_exec: every tool's content and summary stay within bounds" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/a.txt", "alpha\nbeta\n");

    const calls = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "read_file", .args = "{\"path\":\"a.txt\"}" },
        .{ .name = "read_file", .args = "{\"path\":\"a.txt\",\"start_line\":1,\"end_line\":1}" },
        .{ .name = "list_directory", .args = "{\"path\":\".\"}" },
        .{ .name = "grep", .args = "{\"pattern\":\"alpha\"}" },
        .{ .name = "grep", .args = "{\"pattern\":\"missing\"}" },
        .{ .name = "read_file", .args = "{\"path\":\"../escape\"}" },
        .{ .name = "edit_file", .args = "{}" },
        .{ .name = "terminal", .args = "{}" },
    };
    for (calls) |call| {
        var out = try run(alloc, fixture.ws, call.name, call.args);
        defer out.deinit(alloc);
        try testing.expect(out.content.len <= max_output_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out.content));
        if (out.summary) |summary| {
            try testing.expect(summary.len <= max_summary_bytes);
            try testing.expect(std.unicode.utf8ValidateSlice(summary));
        }
    }
}

test "tool_exec: oversized arguments and long listing rows stay bounded" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/hello.txt", "hello\n");
    try fixture.tmp.dir.createDirPath(testing.io, "ws/long");

    // Arguments larger than the protocol accumulator cap are rejected before
    // JSON parsing allocates proportionally to the input.
    const huge_path = try alloc.alloc(u8, tools.max_arguments_bytes + 1024);
    defer alloc.free(huge_path);
    @memset(huge_path, 'a');
    const huge_args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{huge_path});
    defer alloc.free(huge_args);
    var huge = try run(alloc, fixture.ws, "read_file", huge_args);
    defer huge.deinit(alloc);
    try expectStatus(&huge, .err);
    try testing.expectEqual(Failure.argument_too_long, huge.failure.?);

    // 500 long names exceed the byte budget: rows are cut at a line boundary
    // and the header/summary still describe a partial 500-entry listing.
    const long_name = try alloc.alloc(u8, 240);
    defer alloc.free(long_name);
    @memset(long_name, 'n');
    var i: usize = 0;
    while (i < max_list_entries) : (i += 1) {
        const path = try std.fmt.allocPrint(alloc, "ws/long/f{d:0>3}-{s}", .{ i, long_name });
        defer alloc.free(path);
        try fixture.write(path, "x");
    }

    var listed = try run(alloc, fixture.ws, "list_directory", "{\"path\":\"long\"}");
    defer listed.deinit(alloc);
    try expectStatus(&listed, .ok);
    try testing.expect(listed.content.len <= max_output_bytes);
    try testing.expect(std.mem.endsWith(u8, listed.content, "… [truncated]"));
    try testing.expect(std.mem.indexOf(u8, listed.summary.?, "of 500") != null);
    try testing.expect(std.mem.indexOf(u8, listed.summary.?, "(truncated)") != null);
}

test "tool_exec: grep scans hidden text files but skips hiding symlinks" {
    const alloc = testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit();
    try fixture.write("ws/.hidden.txt", "HIDDENNEEDLE\n");
    try fixture.write("outside/secret.txt", "HIDDENNEEDLE outside\n");
    try fixture.tmp.dir.symLink(testing.io, "../outside/secret.txt", "ws/.hidden-link", .{});

    var out = try run(alloc, fixture.ws, "grep", "{\"pattern\":\"HIDDENNEEDLE\"}");
    defer out.deinit(alloc);
    try expectStatus(&out, .ok);
    try testing.expectEqualStrings("path: .\n---\n.hidden.txt:1:HIDDENNEEDLE\n", out.content);
    try testing.expect(std.mem.indexOf(u8, out.content, "outside") == null);
}
