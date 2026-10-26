//! Staged `apply_patch` support (M3b2): pure unified-diff parsing for one or
//! more modified files, exact application to each old full text, and a bounded
//! review preview.
//!
//! Deliberately App/vaxis/filesystem-independent: `src/app/agent_edit_ui.zig`
//! resolves every patch path inside the captured workspace root, reads the
//! target texts (open buffer first, disk second), validates the whole set
//! here, and stages one multi-file review. The executor is never asked to
//! write, and nothing here touches a buffer or a file.
//!
//! Scope and invariants (this slice):
//!   - one file per `diff --git`/`---` section; sections are accepted
//!     back-to-back in patch order (1..`max_files`, multi-file is 2+);
//!     duplicate normalized paths are rejected;
//!   - add/delete (`/dev/null`), binary, rename/copy and mode changes are
//!     rejected with typed errors; there is never a partial apply;
//!   - at least one `@@` hunk per file; hunk counts may be omitted (default 1);
//!   - context/removal lines must match the old text byte-for-byte, hunks
//!     must be in order and inside the file, and the new-file line numbers
//!     must agree with the applied result (drift from earlier hunks);
//!   - `\ No newline at end of file` is honored and validated against the
//!     old text and the reconstructed new text;
//!   - patch bytes, file count, total/per-file hunk counts, hunk-body lines,
//!     the old texts and the reconstructed texts are all bounded so one tool
//!     call cannot stage an unbounded change;
//!   - `validateSet` applies every file before anything is staged or written
//!     and returns a per-file reason list when any file fails.
const std = @import("std");
const inline_model = @import("inline.zig");
const tool_exec = @import("../ai/tool_exec.zig");

/// Maximum patch text accepted for one call.
pub const max_patch_bytes: usize = 256 * 1024;

/// Maximum staged old/result text per file. Shared with
/// `agent_edit.max_stage_bytes`.
pub const max_stage_bytes: usize = 256 * 1024;

/// Maximum total staged old+result bytes for one multi-file set.
pub const max_total_stage_bytes: usize = 2 * 1024 * 1024;

/// Maximum number of modified files in one patch.
pub const max_files: usize = 8;

/// Maximum number of hunks in one patch (all files together).
pub const max_hunks: usize = 256;

/// Maximum number of hunks in one file.
pub const max_hunks_per_file: usize = 128;

/// Maximum total hunk-body lines (context/removal/addition) in one patch.
pub const max_hunk_lines: usize = 16 * 1024;

/// Maximum hunk-body lines in one file.
pub const max_hunk_lines_per_file: usize = 8 * 1024;

/// Upper bound on previewed lines (all shown hunks together).
pub const max_preview_lines: u32 = 240;

/// Upper bound on previewed hunks. Further hunks are summarized truthfully.
pub const max_preview_hunks: usize = 16;

pub const ArgError = error{
    OutOfMemory,
    MalformedArguments,
    MissingPatch,
    PatchNotString,
    EmptyPatch,
};

pub const PatchArgs = struct {
    patch: []u8,

    pub fn deinit(self: *PatchArgs, alloc: std.mem.Allocator) void {
        alloc.free(self.patch);
        self.* = undefined;
    }
};

/// Parse the advertised `apply_patch` arguments (`{"patch": "..."}`). Unknown
/// fields are ignored; wrong types/missing/empty text are typed errors (the
/// UI maps them to a real card error and never stages).
pub fn parseArgs(alloc: std.mem.Allocator, arguments_json: []const u8) ArgError!PatchArgs {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedArguments;
    const obj = &parsed.value.object;
    const value = obj.get("patch") orelse return error.MissingPatch;
    const patch = switch (value) {
        .string => |s| s,
        else => return error.PatchNotString,
    };
    if (patch.len == 0) return error.EmptyPatch;
    return .{ .patch = try alloc.dupe(u8, patch) };
}

pub const ParseError = error{
    OutOfMemory,
    EmptyPatch,
    PatchTooLarge,
    NulByte,
    NotUtf8,
    MissingPath,
    /// Single-file `parse` only: the input contained more than one section.
    MultiFile,
    TooManyFiles,
    DuplicatePath,
    AddDeleteFile,
    BinaryPatch,
    RenameOrCopy,
    ModeChange,
    MalformedHeader,
    MalformedHunk,
    MalformedCounts,
    NoHunks,
    TooManyHunks,
    TooManyLines,
    PathEmpty,
    PathTooLong,
    PathNul,
    PathAbsolute,
    PathParent,
    PathMismatch,
};

pub const LineKind = enum { context, remove, add };

pub const HunkLine = struct {
    kind: LineKind,
    /// Line text without the diff prefix (and without its trailing newline).
    text: []u8,
    /// Set by a preceding `\ No newline at end of file` marker.
    no_newline: bool = false,
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []HunkLine,

    pub fn deinit(self: *Hunk, alloc: std.mem.Allocator) void {
        for (self.lines) |*line| alloc.free(line.text);
        alloc.free(self.lines);
        self.* = undefined;
    }

    /// 1-based last old line touched by this hunk (a pure insertion reports
    /// the line it follows; 0 stays 0 before clamping by the caller).
    pub fn oldEndLine(self: *const Hunk) u32 {
        if (self.old_count == 0) return self.old_start;
        return self.old_start + self.old_count - 1;
    }
};

pub const Stats = struct { removed: u32, added: u32 };

pub const Patch = struct {
    /// Normalized workspace-relative path (not canonicalized against a root;
    /// the UI resolves that through `tool_exec` confinement before staging).
    path: []u8,
    hunks: []Hunk,

    pub fn deinit(self: *Patch, alloc: std.mem.Allocator) void {
        if (self.path.len > 0) alloc.free(self.path);
        for (self.hunks) |*hunk| hunk.deinit(alloc);
        if (self.hunks.len > 0) alloc.free(self.hunks);
        self.* = undefined;
    }

    /// Full removed/added line counts from the parsed hunks. Unlike the
    /// bounded preview's stats this never undercounts: the caller may show
    /// only a prefix of the diff but the counts still describe the whole file.
    pub fn stats(self: *const Patch) Stats {
        var removed: u32 = 0;
        var added: u32 = 0;
        for (self.hunks) |*hunk| {
            for (hunk.lines) |line| switch (line.kind) {
                .remove => removed += 1,
                .add => added += 1,
                .context => {},
            };
        }
        return .{ .removed = removed, .added = added };
    }
};

/// One parsed patch: ordered file sections, exactly as they appeared. The
/// order is deterministic (patch order) and is the order the review UI and
/// the write transaction use.
pub const PatchSet = struct {
    files: []Patch,

    pub fn deinit(self: *PatchSet, alloc: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(alloc);
        if (self.files.len > 0) alloc.free(self.files);
        self.* = undefined;
    }

    /// Move one file out of the set. The caller then owns (and must deinit)
    /// the returned Patch; `self` keeps a deinitializable empty slot.
    pub fn takeFile(self: *PatchSet, index: usize) Patch {
        const file = self.files[index];
        self.files[index] = .{ .path = &.{}, .hunks = &.{} };
        return file;
    }

    pub fn totals(self: *const PatchSet) Stats {
        var removed: u32 = 0;
        var added: u32 = 0;
        for (self.files) |*file| {
            const s = file.stats();
            removed +|= s.removed;
            added +|= s.added;
        }
        return .{ .removed = removed, .added = added };
    }
};

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```");
}

/// Split on LF; a trailing newline does not create a phantom line. No slices
/// are copied. The returned slice is mutable so a CRLF patch can be
/// normalized in place.
fn splitPatchLines(alloc: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    if (input.len == 0) return out.toOwnedSlice(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '\n') continue;
        try out.append(alloc, input[start..i]);
        start = i + 1;
    }
    if (start < input.len) try out.append(alloc, input[start..]);
    return out.toOwnedSlice(alloc);
}

fn parseQuotedToken(alloc: std.mem.Allocator, s: []const u8, index: *usize) ParseError![]u8 {
    if (index.* >= s.len or s[index.*] != '"') return error.MalformedHeader;
    index.* += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (index.* < s.len) {
        const c = s[index.*];
        index.* += 1;
        switch (c) {
            '"' => return out.toOwnedSlice(alloc),
            '\\' => {
                if (index.* >= s.len) return error.MalformedHeader;
                const escaped = s[index.*];
                index.* += 1;
                const decoded: u8 = switch (escaped) {
                    '"' => '"',
                    '\\' => '\\',
                    't' => '\t',
                    'n' => '\n',
                    'r' => '\r',
                    else => return error.MalformedHeader,
                };
                try out.append(alloc, decoded);
            },
            else => try out.append(alloc, c),
        }
    }
    return error.MalformedHeader;
}

/// Parse one `diff --git` path token. Git quotes paths containing spaces or
/// special bytes; unquoted tokens end at the first space.
fn parsePathToken(alloc: std.mem.Allocator, s: []const u8, index: *usize) ParseError![]u8 {
    if (index.* >= s.len) return error.MalformedHeader;
    if (s[index.*] == '"') return parseQuotedToken(alloc, s, index);
    const start = index.*;
    while (index.* < s.len and s[index.*] != ' ') index.* += 1;
    if (index.* == start) return error.MalformedHeader;
    return alloc.dupe(u8, s[start..index.*]);
}

fn parseGitHeader(alloc: std.mem.Allocator, rest: []const u8) ParseError!struct { old: []u8, new: []u8 } {
    var index: usize = 0;
    const old = try parsePathToken(alloc, rest, &index);
    errdefer alloc.free(old);
    if (index >= rest.len or rest[index] != ' ') return error.MalformedHeader;
    index += 1;
    const new = try parsePathToken(alloc, rest, &index);
    errdefer alloc.free(new);
    while (index < rest.len and rest[index] == ' ') index += 1;
    if (index != rest.len) return error.MalformedHeader;
    return .{ .old = old, .new = new };
}

/// Parse a `---`/`+++` path. Git appends a tab-separated timestamp; a quoted
/// path may contain spaces. The timestamp is not part of the path.
fn parseHeaderPath(alloc: std.mem.Allocator, rest: []const u8) ParseError![]u8 {
    if (rest.len == 0) return error.MalformedHeader;
    if (rest[0] == '"') {
        var index: usize = 0;
        return parseQuotedToken(alloc, rest, &index);
    }
    const end = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
    if (end == 0) return error.MalformedHeader;
    return alloc.dupe(u8, rest[0..end]);
}

fn parseU32(s: []const u8, index: *usize) ?u32 {
    const start = index.*;
    var value: u64 = 0;
    while (index.* < s.len and std.ascii.isDigit(s[index.*])) : (index.* += 1) {
        value = value * 10 + (s[index.*] - '0');
        if (value > std.math.maxInt(u32)) return null;
    }
    if (index.* == start) return null;
    return @intCast(value);
}

/// Parse `@@ -old[,count] +new[,count] @@ [section]`. Omitted counts default
/// to 1; a zero count is legal (pure insertion/deletion) but a 0 start with a
/// positive count is not.
fn parseHunkHeader(line: []const u8) ParseError!HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.MalformedHunk;
    var i: usize = 4;
    const old_start = parseU32(line, &i) orelse return error.MalformedCounts;
    var old_count: u32 = 1;
    if (i < line.len and line[i] == ',') {
        i += 1;
        old_count = parseU32(line, &i) orelse return error.MalformedCounts;
    }
    if (i + 1 >= line.len or line[i] != ' ' or line[i + 1] != '+') return error.MalformedCounts;
    i += 2;
    const new_start = parseU32(line, &i) orelse return error.MalformedCounts;
    var new_count: u32 = 1;
    if (i < line.len and line[i] == ',') {
        i += 1;
        new_count = parseU32(line, &i) orelse return error.MalformedCounts;
    }
    if (i + 2 >= line.len or line[i] != ' ' or line[i + 1] != '@' or line[i + 2] != '@') {
        return error.MalformedCounts;
    }
    if (old_count == 0 and new_count == 0) return error.MalformedHunk;
    if (old_count > 0 and old_start == 0) return error.MalformedCounts;
    if (new_count > 0 and new_start == 0) return error.MalformedCounts;
    return .{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
    };
}

fn bumpHunkLineCount(total: *usize) ParseError!void {
    if (total.* >= max_hunk_lines) return error.TooManyLines;
    total.* += 1;
}

fn appendHunkLine(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(HunkLine),
    kind: LineKind,
    text: []const u8,
) ParseError!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NulByte;
    try list.append(alloc, .{ .kind = kind, .text = try alloc.dupe(u8, text) });
}

fn parseHunkBody(
    alloc: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    header: HunkHeader,
    total_lines: *usize,
) ParseError!Hunk {
    var list: std.ArrayList(HunkLine) = .empty;
    errdefer {
        for (list.items) |*line| alloc.free(line.text);
        list.deinit(alloc);
    }

    var used_old: u32 = 0;
    var used_new: u32 = 0;
    while (used_old < header.old_count or used_new < header.new_count) {
        if (index.* >= lines.len) return error.MalformedCounts;
        const line = lines[index.*];
        if (line.len == 0) {
            // Tolerate a stripped trailing space on an empty context line.
            if (used_old >= header.old_count or used_new >= header.new_count) return error.MalformedCounts;
            try appendHunkLine(alloc, &list, .context, "");
            used_old += 1;
            used_new += 1;
            try bumpHunkLineCount(total_lines);
            index.* += 1;
            continue;
        }
        switch (line[0]) {
            ' ' => {
                if (used_old >= header.old_count or used_new >= header.new_count) return error.MalformedCounts;
                try appendHunkLine(alloc, &list, .context, line[1..]);
                used_old += 1;
                used_new += 1;
            },
            '-' => {
                if (used_old >= header.old_count) return error.MalformedCounts;
                try appendHunkLine(alloc, &list, .remove, line[1..]);
                used_old += 1;
            },
            '+' => {
                if (used_new >= header.new_count) return error.MalformedCounts;
                try appendHunkLine(alloc, &list, .add, line[1..]);
                used_new += 1;
            },
            '\\' => {
                // A marker follows the line on the side that lacks a trailing
                // newline. It may sit mid-hunk (replace the final line), so
                // it is not a hunk terminator.
                if (!isNoNewlineMarker(line)) return error.MalformedHunk;
                if (list.items.len == 0) return error.MalformedHunk;
                if (list.items[list.items.len - 1].no_newline) return error.MalformedHunk;
                list.items[list.items.len - 1].no_newline = true;
                index.* += 1;
                continue;
            },
            else => return error.MalformedHunk,
        }
        try bumpHunkLineCount(total_lines);
        index.* += 1;
    }

    // A marker may trail the final counted line.
    if (index.* < lines.len and lines[index.*].len > 0 and lines[index.*][0] == '\\') {
        if (!isNoNewlineMarker(lines[index.*])) return error.MalformedHunk;
        if (list.items.len == 0) return error.MalformedHunk;
        if (list.items[list.items.len - 1].no_newline) return error.MalformedHunk;
        list.items[list.items.len - 1].no_newline = true;
        index.* += 1;
    }
    if (used_old != header.old_count or used_new != header.new_count) return error.MalformedCounts;
    return .{
        .old_start = header.old_start,
        .old_count = header.old_count,
        .new_start = header.new_start,
        .new_count = header.new_count,
        .lines = try list.toOwnedSlice(alloc),
    };
}

fn isNoNewlineMarker(line: []const u8) bool {
    return std.mem.eql(u8, line, "\\ No newline at end of file");
}

fn isDevNull(path: []const u8) bool {
    return std.mem.eql(u8, path, "/dev/null");
}

fn stripDiffPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "a/")) return path[2..];
    if (std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

const FilePair = struct {
    old: []const u8,
    new: []const u8,
    /// Whether the old/new header paths carry their respective git prefixes.
    old_strip: bool,
    new_strip: bool,
};

/// Decide once whether old/new path spellings use git's `a/`+`b/` prefixes.
/// Identical spellings stay untouched, so a real file named `a/notes.txt`
/// survives a `--no-prefix` diff; only differing `a/`+`b/` (or same-side)
/// spellings are stripped. Mixed/renamed spellings are rejected.
fn splitFilePair(old_raw: []const u8, new_raw: []const u8) ParseError!FilePair {
    if (std.mem.eql(u8, old_raw, new_raw)) {
        return .{ .old = old_raw, .new = new_raw, .old_strip = false, .new_strip = false };
    }
    const old_a = std.mem.startsWith(u8, old_raw, "a/");
    const old_b = std.mem.startsWith(u8, old_raw, "b/");
    const new_a = std.mem.startsWith(u8, new_raw, "a/");
    const new_b = std.mem.startsWith(u8, new_raw, "b/");
    if ((old_a and new_b) or (old_a and new_a) or (old_b and new_b)) {
        const old = old_raw[2..];
        const new = new_raw[2..];
        if (std.mem.eql(u8, old, new)) {
            return .{ .old = old, .new = new, .old_strip = true, .new_strip = true };
        }
    }
    return error.RenameOrCopy;
}

fn mapPathError(e: tool_exec.WorkspacePathError) ParseError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Empty => error.PathEmpty,
        error.TooLong => error.PathTooLong,
        error.Nul => error.PathNul,
        error.Absolute => error.PathAbsolute,
        error.Parent => error.PathParent,
    };
}

fn isAddDeleteLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "new file mode ") or
        std.mem.startsWith(u8, line, "deleted file mode ");
}

fn isModeLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "old mode ") or
        std.mem.startsWith(u8, line, "new mode ");
}

fn isRenameCopyLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "rename from ") or
        std.mem.startsWith(u8, line, "rename to ") or
        std.mem.startsWith(u8, line, "copy from ") or
        std.mem.startsWith(u8, line, "copy to ") or
        std.mem.startsWith(u8, line, "similarity index ") or
        std.mem.startsWith(u8, line, "dissimilarity index ");
}

fn isBinaryLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "Binary files ") or
        std.mem.startsWith(u8, line, "GIT binary patch");
}

const Section = struct {
    git_old: ?[]u8 = null,
    git_new: ?[]u8 = null,
    hdr_old: ?[]u8 = null,
    hdr_new: ?[]u8 = null,
    hunks: std.ArrayList(Hunk) = .empty,

    fn deinit(self: *Section, alloc: std.mem.Allocator) void {
        if (self.git_old) |p| alloc.free(p);
        if (self.git_new) |p| alloc.free(p);
        if (self.hdr_old) |p| alloc.free(p);
        if (self.hdr_new) |p| alloc.free(p);
        for (self.hunks.items) |*hunk| hunk.deinit(alloc);
        self.hunks.deinit(alloc);
        self.* = .{};
    }

    fn hasPaths(self: *const Section) bool {
        return self.git_old != null or self.git_new != null or
            self.hdr_old != null or self.hdr_new != null;
    }
};

/// Resolve one section's path source and append the finished `Patch` to the
/// set. Consumes `section` (including on failure): callers can reset it to a
/// fresh value and their own `deinit` stays a no-op.
fn finalizeSection(
    alloc: std.mem.Allocator,
    section: *Section,
    files: *std.ArrayList(Patch),
    seen: *std.StringHashMap(void),
) ParseError!void {
    defer section.deinit(alloc);
    if (files.items.len >= max_files) return error.TooManyFiles;
    if (section.hunks.items.len == 0) return error.NoHunks;
    var file_lines: usize = 0;
    for (section.hunks.items) |hunk| file_lines += hunk.lines.len;
    if (file_lines > max_hunk_lines_per_file) return error.TooManyLines;

    var source: []const u8 = undefined;
    if (section.git_old) |go| {
        const gn = section.git_new orelse return error.MalformedHeader;
        if (isDevNull(go) or isDevNull(gn)) return error.AddDeleteFile;
        const pair = try splitFilePair(go, gn);
        if (section.hdr_old) |ho| {
            const hn = section.hdr_new orelse return error.MalformedHeader;
            if (isDevNull(ho) or isDevNull(hn)) return error.AddDeleteFile;
            const h_old = if (pair.old_strip) stripDiffPrefix(ho) else ho;
            const h_new = if (pair.new_strip) stripDiffPrefix(hn) else hn;
            if (!std.mem.eql(u8, h_old, pair.old) or !std.mem.eql(u8, h_new, pair.new)) {
                return error.PathMismatch;
            }
        } else if (section.hdr_new != null) {
            return error.MalformedHeader;
        }
        source = pair.old;
    } else {
        const ho = section.hdr_old orelse return error.MissingPath;
        const hn = section.hdr_new orelse return error.MalformedHeader;
        if (isDevNull(ho) or isDevNull(hn)) return error.AddDeleteFile;
        const pair = try splitFilePair(ho, hn);
        source = pair.old;
    }

    const normalized = tool_exec.normalizeWorkspacePath(alloc, source) catch |e| return mapPathError(e);
    defer alloc.free(normalized);
    if (std.mem.eql(u8, normalized, ".")) return error.PathEmpty;
    // Duplicate detection uses the normalized spelling, so `a/x`, `x`, and a
    // second `diff --git` section naming the same file are all one file.
    if (seen.contains(normalized)) return error.DuplicatePath;

    const owned_path = try alloc.dupe(u8, normalized);
    errdefer alloc.free(owned_path);
    const owned_hunks = try section.hunks.toOwnedSlice(alloc);
    errdefer {
        for (owned_hunks) |*hunk| hunk.deinit(alloc);
        alloc.free(owned_hunks);
    }
    // The map borrows `owned_path`; it is deinit'd (without freeing keys)
    // before parseSet returns, so ownership can move into the Patch.
    try seen.put(owned_path, {});
    try files.append(alloc, .{ .path = owned_path, .hunks = owned_hunks });
}

/// Parse a bounded unified diff with 1..`max_files` modified-file sections.
/// Sections may be separated by `diff --git` and/or back-to-back `---`/`+++`
/// headers. The returned set preserves patch order; every file owns its path
/// and hunk text.
pub fn parseSet(alloc: std.mem.Allocator, input: []const u8) ParseError!PatchSet {
    if (input.len == 0) return error.EmptyPatch;
    if (input.len > max_patch_bytes) return error.PatchTooLarge;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return error.NulByte;
    if (!std.unicode.utf8ValidateSlice(input)) return error.NotUtf8;

    const raw_lines = try splitPatchLines(alloc, input);
    defer alloc.free(raw_lines);
    // A CRLF-transported patch is normalized before parsing; hunk content is
    // then compared byte-for-byte against the LF text the editor loaded.
    if (raw_lines.len > 0 and raw_lines[0].len > 0 and raw_lines[0][raw_lines[0].len - 1] == '\r') {
        for (raw_lines) |*line| {
            if (line.*.len > 0 and line.*[line.*.len - 1] == '\r') {
                line.* = line.*[0 .. line.*.len - 1];
            }
        }
    }

    // Optional leading/trailing Markdown fence (models often wrap diffs).
    var begin: usize = 0;
    while (begin < raw_lines.len and raw_lines[begin].len == 0) begin += 1;
    if (begin < raw_lines.len and isFence(raw_lines[begin])) begin += 1;
    var stop: usize = raw_lines.len;
    while (stop > begin and raw_lines[stop - 1].len == 0) stop -= 1;
    if (stop > begin and isFence(raw_lines[stop - 1])) stop -= 1;
    while (stop > begin and raw_lines[stop - 1].len == 0) stop -= 1;
    if (begin >= stop) return error.EmptyPatch;
    const lines = raw_lines[begin..stop];

    var files: std.ArrayList(Patch) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(alloc);
        files.deinit(alloc);
    }
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var section = Section{};
    errdefer section.deinit(alloc);
    var total_hunks: usize = 0;
    var total_hunk_lines: usize = 0;
    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        if (line.len == 0) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (section.hunks.items.len > 0) {
                try finalizeSection(alloc, &section, &files, &seen);
            } else if (section.hasPaths()) {
                // A new file section before the previous one had a hunk is
                // malformed; never silently drop the empty section.
                return error.NoHunks;
            }
            const parsed = try parseGitHeader(alloc, line["diff --git ".len..]);
            section.git_old = parsed.old;
            section.git_new = parsed.new;
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "index ")) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "--- ")) {
            if (section.hdr_old != null or section.hdr_new != null) {
                if (section.hunks.items.len == 0) return error.MalformedHeader;
                try finalizeSection(alloc, &section, &files, &seen);
            } else if (section.hunks.items.len > 0) {
                try finalizeSection(alloc, &section, &files, &seen);
            }
            section.hdr_old = try parseHeaderPath(alloc, line[4..]);
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (section.hdr_new != null or section.hunks.items.len > 0) return error.MalformedHeader;
            if (section.hdr_old == null) return error.MalformedHeader;
            section.hdr_new = try parseHeaderPath(alloc, line[4..]);
            index += 1;
            continue;
        }
        if (isAddDeleteLine(line)) return error.AddDeleteFile;
        if (isModeLine(line)) return error.ModeChange;
        if (isRenameCopyLine(line)) return error.RenameOrCopy;
        if (isBinaryLine(line)) return error.BinaryPatch;
        if (std.mem.startsWith(u8, line, "@@")) {
            const header = try parseHunkHeader(line);
            index += 1;
            var hunk = try parseHunkBody(alloc, lines, &index, header, &total_hunk_lines);
            if (section.hunks.items.len >= max_hunks_per_file) {
                hunk.deinit(alloc);
                return error.TooManyHunks;
            }
            section.hunks.append(alloc, hunk) catch |e| {
                hunk.deinit(alloc);
                return e;
            };
            total_hunks += 1;
            if (total_hunks > max_hunks) return error.TooManyHunks;
            continue;
        }
        if (std.mem.startsWith(u8, line, "diff ")) return error.MalformedHeader;
        return error.MalformedHunk;
    }

    if (section.hunks.items.len > 0) {
        try finalizeSection(alloc, &section, &files, &seen);
    } else if (section.hasPaths()) {
        return error.NoHunks;
    }
    if (files.items.len == 0) return error.NoHunks;
    return .{ .files = try files.toOwnedSlice(alloc) };
}

/// Single-file compatibility wrapper used by the existing callers/tests.
/// Multi-file input is rejected with `error.MultiFile`; use `parseSet` for
/// the staged multi-file path.
pub fn parse(alloc: std.mem.Allocator, input: []const u8) ParseError!Patch {
    var set = try parseSet(alloc, input);
    defer set.deinit(alloc);
    if (set.files.len != 1) return error.MultiFile;
    return set.takeFile(0);
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

pub const ApplyError = error{
    OutOfMemory,
    NulByte,
    ContextMismatch,
    NoNewlineMismatch,
    OutOfRange,
    MalformedHunk,
    TooLarge,
    NoChanges,
};

const OldLine = struct { text: []const u8, has_nl: bool };
const NewLine = struct { text: []const u8, has_nl: bool };

fn splitOldLines(alloc: std.mem.Allocator, text: []const u8) ![]OldLine {
    var out: std.ArrayList(OldLine) = .empty;
    errdefer out.deinit(alloc);
    if (text.len == 0) return out.toOwnedSlice(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        try out.append(alloc, .{ .text = text[start..i], .has_nl = true });
        start = i + 1;
    }
    if (start < text.len) try out.append(alloc, .{ .text = text[start..], .has_nl = false });
    return out.toOwnedSlice(alloc);
}

fn joinNewLines(alloc: std.mem.Allocator, lines: []const NewLine) ApplyError![]u8 {
    var total: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx + 1 < lines.len and !line.has_nl) return error.NoNewlineMismatch;
        total = std.math.add(usize, total, line.text.len) catch return error.TooLarge;
        if (line.has_nl) {
            total = std.math.add(usize, total, 1) catch return error.TooLarge;
        }
        if (total > max_stage_bytes) return error.TooLarge;
    }
    const out = try alloc.alloc(u8, total);
    errdefer alloc.free(out);
    var pos: usize = 0;
    for (lines) |line| {
        @memcpy(out[pos..][0..line.text.len], line.text);
        pos += line.text.len;
        if (line.has_nl) {
            out[pos] = '\n';
            pos += 1;
        }
    }
    return out;
}

/// Apply every hunk in order to `old_text` and return the full new text.
/// Refuses anything that does not match exactly; never applies partially.
pub fn apply(alloc: std.mem.Allocator, patch: *const Patch, old_text: []const u8) ApplyError![]u8 {
    if (old_text.len > max_stage_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, old_text, 0) != null) return error.NulByte;

    const old_lines = try splitOldLines(alloc, old_text);
    defer alloc.free(old_lines);

    var out: std.ArrayList(NewLine) = .empty;
    defer out.deinit(alloc);

    var cursor: usize = 0;
    for (patch.hunks) |*hunk| {
        const start_idx: usize = if (hunk.old_count == 0)
            hunk.old_start
        else
            @as(usize, hunk.old_start - 1);
        if (start_idx < cursor) return error.OutOfRange;
        if (start_idx > old_lines.len) return error.OutOfRange;
        if (hunk.old_count > 0 and start_idx + hunk.old_count > old_lines.len) {
            return error.OutOfRange;
        }
        while (cursor < start_idx) : (cursor += 1) {
            try out.append(alloc, .{
                .text = old_lines[cursor].text,
                .has_nl = old_lines[cursor].has_nl,
            });
        }

        // New-file coordinates are checked against the applied result (after
        // the unchanged gap), which proves that line-number drift from
        // earlier hunks was handled.
        if (hunk.new_count > 0) {
            if (hunk.new_start != out.items.len + 1) return error.MalformedHunk;
        } else {
            if (hunk.new_start != out.items.len) return error.MalformedHunk;
        }

        var old_i = start_idx;
        var used_old: u32 = 0;
        var used_new: u32 = 0;
        for (hunk.lines) |line| {
            switch (line.kind) {
                .context => {
                    if (used_old >= hunk.old_count or used_new >= hunk.new_count) return error.MalformedHunk;
                    if (old_i >= old_lines.len) return error.OutOfRange;
                    const old_line = old_lines[old_i];
                    if (!std.mem.eql(u8, old_line.text, line.text)) return error.ContextMismatch;
                    if (line.no_newline != !old_line.has_nl) return error.NoNewlineMismatch;
                    try out.append(alloc, .{ .text = old_line.text, .has_nl = old_line.has_nl });
                    old_i += 1;
                    used_old += 1;
                    used_new += 1;
                },
                .remove => {
                    if (used_old >= hunk.old_count) return error.MalformedHunk;
                    if (old_i >= old_lines.len) return error.OutOfRange;
                    const old_line = old_lines[old_i];
                    if (!std.mem.eql(u8, old_line.text, line.text)) return error.ContextMismatch;
                    if (line.no_newline != !old_line.has_nl) return error.NoNewlineMismatch;
                    old_i += 1;
                    used_old += 1;
                },
                .add => {
                    if (used_new >= hunk.new_count) return error.MalformedHunk;
                    try out.append(alloc, .{ .text = line.text, .has_nl = !line.no_newline });
                    used_new += 1;
                },
            }
        }
        if (used_old != hunk.old_count or used_new != hunk.new_count) return error.MalformedHunk;
        cursor = start_idx + hunk.old_count;
    }
    while (cursor < old_lines.len) : (cursor += 1) {
        try out.append(alloc, .{
            .text = old_lines[cursor].text,
            .has_nl = old_lines[cursor].has_nl,
        });
    }

    const new_text = try joinNewLines(alloc, out.items);
    errdefer alloc.free(new_text);
    if (std.mem.eql(u8, new_text, old_text)) return error.NoChanges;
    return new_text;
}

// ---------------------------------------------------------------------------
// Bounded review preview
// ---------------------------------------------------------------------------

pub const Preview = struct {
    lines: []inline_model.DiffLine,
    removed: u32 = 0,
    added: u32 = 0,
    first_line: u32 = 1,
    last_line: u32 = 1,
    partial: bool = false,
};

fn appendNote(alloc: std.mem.Allocator, list: *std.ArrayList(inline_model.DiffLine), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    errdefer alloc.free(text);
    try list.append(alloc, .{ .kind = .context, .text = text });
}

/// Build the review diff directly from the parsed hunks: a patch already is a
/// line diff, so re-running an LCS would only risk disagreeing with it. The
/// shown hunks are bounded; omitted hunks/lines are summarized truthfully and
/// the `-N +M` stats count only what is displayed.
pub fn buildPreview(alloc: std.mem.Allocator, patch: *const Patch) error{OutOfMemory}!Preview {
    return buildPreviewWithLimits(alloc, patch, max_preview_lines, max_preview_hunks);
}

/// Preview with explicit limits. Multi-file staging passes the global patch
/// budgets so every file's diff is complete and the card/Changes stats are
/// exact; the single-file path keeps the historical bounded preview.
pub fn buildPreviewWithLimits(
    alloc: std.mem.Allocator,
    patch: *const Patch,
    line_limit: u32,
    hunk_limit: usize,
) error{OutOfMemory}!Preview {
    var out: std.ArrayList(inline_model.DiffLine) = .empty;
    errdefer {
        for (out.items) |line| alloc.free(line.text);
        out.deinit(alloc);
    }

    var preview = Preview{ .lines = &.{} };
    var shown_lines: u32 = 0;
    var shown_hunks: usize = 0;
    var prev_end: ?u32 = null;
    var omitted_hunks: usize = 0;

    outer: for (patch.hunks, 0..) |*hunk, hi| {
        if (shown_hunks >= hunk_limit) {
            preview.partial = true;
            omitted_hunks = patch.hunks.len - hi;
            break;
        }
        const first_line: u32 = if (hunk.old_count == 0) @max(hunk.old_start, 1) else hunk.old_start;
        const last_line: u32 = @max(hunk.oldEndLine(), first_line);
        if (prev_end) |end_line| {
            if (first_line > end_line + 1) try appendNote(alloc, &out, "…", .{});
        }
        if (shown_hunks == 0) preview.first_line = first_line;
        preview.last_line = last_line;
        shown_hunks += 1;

        for (hunk.lines) |line| {
            if (shown_lines >= line_limit) {
                preview.partial = true;
                break :outer;
            }
            const kind: inline_model.DiffKind = switch (line.kind) {
                .context => .context,
                .remove => .removed,
                .add => .added,
            };
            try out.append(alloc, .{
                .kind = kind,
                .text = try inline_model.dupeDisplayLine(alloc, line.text),
            });
            switch (line.kind) {
                .remove => preview.removed += 1,
                .add => preview.added += 1,
                .context => {},
            }
            shown_lines += 1;
        }
        prev_end = last_line;
    }

    if (preview.partial) {
        if (omitted_hunks > 0) {
            try appendNote(alloc, &out, "… {d} more hunk(s) not shown", .{omitted_hunks});
        } else {
            try appendNote(alloc, &out, "… preview truncated", .{});
        }
    }
    preview.lines = try out.toOwnedSlice(alloc);
    return preview;
}

// ---------------------------------------------------------------------------
// Whole-set validation
// ---------------------------------------------------------------------------

pub const ValidationIssue = struct {
    /// Index in `PatchSet.files` / the caller's old-text array.
    index: usize,
    /// Path borrowed from the parsed set; valid until the set is freed.
    path: []const u8,
    err: ApplyError,
};

pub const Validation = union(enum) {
    /// One owned new full text per file, in patch order.
    ok: [][]u8,
    /// At least one file failed; no new text is returned and nothing may be
    /// staged or written.
    rejected: []ValidationIssue,

    pub fn deinit(self: *Validation, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |texts| {
                for (texts) |text| alloc.free(text);
                alloc.free(texts);
            },
            .rejected => |issues| alloc.free(issues),
        }
        self.* = undefined;
    }
};

/// Apply every file's hunks to its old full text before anything is staged or
/// written. Collects every failure (not just the first) so the caller can
/// show a clear per-file reason list. When any file fails, all successfully
/// reconstructed texts are freed and the set must be rejected as a whole.
pub fn validateSet(
    alloc: std.mem.Allocator,
    set: *const PatchSet,
    old_texts: []const []const u8,
) error{OutOfMemory}!Validation {
    std.debug.assert(old_texts.len == set.files.len);
    var applied: std.ArrayList([]u8) = .empty;
    errdefer {
        for (applied.items) |text| alloc.free(text);
        applied.deinit(alloc);
    }
    var issues: std.ArrayList(ValidationIssue) = .empty;
    errdefer issues.deinit(alloc);

    var total_old: usize = 0;
    var total_new: usize = 0;
    for (set.files, 0..) |*file, i| {
        const old_text = old_texts[i];
        total_old = std.math.add(usize, total_old, old_text.len) catch max_total_stage_bytes + 1;
        const result = apply(alloc, file, old_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try issues.append(alloc, .{ .index = i, .path = file.path, .err = e });
                continue;
            },
        };
        total_new = std.math.add(usize, total_new, result.len) catch max_total_stage_bytes + 1;
        const total_combined = std.math.add(usize, total_old, total_new) catch max_total_stage_bytes + 1;
        if (old_text.len > max_stage_bytes or result.len > max_stage_bytes or
            total_old > max_total_stage_bytes or total_new > max_total_stage_bytes or
            total_combined > max_total_stage_bytes)
        {
            alloc.free(result);
            try issues.append(alloc, .{ .index = i, .path = file.path, .err = error.TooLarge });
            continue;
        }
        applied.append(alloc, result) catch |e| {
            alloc.free(result);
            return e;
        };
    }

    if (issues.items.len > 0) {
        for (applied.items) |text| alloc.free(text);
        applied.deinit(alloc);
        return .{ .rejected = try issues.toOwnedSlice(alloc) };
    }
    return .{ .ok = try applied.toOwnedSlice(alloc) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectParseError(expected: ParseError, patch_text: []const u8) !void {
    const alloc = testing.allocator;
    if (parse(alloc, patch_text)) |*parsed| {
        var p = parsed.*;
        p.deinit(alloc);
        return error.TestUnexpectedResult;
    } else |e| {
        try testing.expectEqual(expected, e);
    }
}

fn applyText(alloc: std.mem.Allocator, patch_text: []const u8, old_text: []const u8) ![]u8 {
    var patch = try parse(alloc, patch_text);
    defer patch.deinit(alloc);
    return apply(alloc, &patch, old_text);
}

test "agent_patch: parses and applies a simple single hunk" {
    const alloc = testing.allocator;
    const patch_text =
        \\diff --git a/notes.txt b/notes.txt
        \\index 1234567..89abcde 100644
        \\--- a/notes.txt
        \\+++ b/notes.txt
        \\@@ -1,3 +1,3 @@
        \\ alpha
        \\-beta
        \\+BETA
        \\ gamma
        \\
    ;
    var patch = try parse(alloc, patch_text);
    defer patch.deinit(alloc);
    try testing.expectEqualStrings("notes.txt", patch.path);
    try testing.expectEqual(@as(usize, 1), patch.hunks.len);
    try testing.expectEqual(@as(u32, 1), patch.hunks[0].old_start);
    try testing.expectEqual(@as(u32, 3), patch.hunks[0].old_count);
    try testing.expectEqual(@as(u32, 3), patch.hunks[0].new_count);

    const new_text = try apply(alloc, &patch, "alpha\nbeta\ngamma\n");
    defer alloc.free(new_text);
    try testing.expectEqualStrings("alpha\nBETA\ngamma\n", new_text);
}

test "agent_patch: multiple hunks in one file apply in order with drift" {
    const alloc = testing.allocator;
    const patch_text =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
        \\@@ -4,2 +4,3 @@
        \\ four
        \\-five
        \\+FIVE
        \\+five and a half
        \\
    ;
    const old_text = "one\ntwo\nthree\nfour\nfive\n";
    const new_text = try applyText(alloc, patch_text, old_text);
    defer alloc.free(new_text);
    try testing.expectEqualStrings("one\nTWO\nthree\nfour\nFIVE\nfive and a half\n", new_text);
}

test "agent_patch: omitted counts default to one and zero counts insert/delete" {
    const alloc = testing.allocator;
    const patch_text =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1,2 @@
        \\-one
        \\+ONE
        \\+extra
        \\@@ -3,0 +5,1 @@
        \\+inserted
        \\
    ;
    // Line 3 is "three"; the zero-count hunk inserts after it.
    const new_text = try applyText(alloc, patch_text, "one\ntwo\nthree\n");
    defer alloc.free(new_text);
    try testing.expectEqualStrings("ONE\nextra\ntwo\nthree\ninserted\n", new_text);

    const delete_patch =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -2,2 +1,0 @@
        \\-two
        \\-three
        \\
    ;
    const deleted = try applyText(alloc, delete_patch, "one\ntwo\nthree\nfour\n");
    defer alloc.free(deleted);
    try testing.expectEqualStrings("one\nfour\n", deleted);
}

test "agent_patch: no-newline marker is honored on both sides" {
    const alloc = testing.allocator;
    const patch_text =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\\ No newline at end of file
        \\+TWO
        \\\ No newline at end of file
        \\
    ;
    const new_text = try applyText(alloc, patch_text, "one\ntwo");
    defer alloc.free(new_text);
    try testing.expectEqualStrings("one\nTWO", new_text);

    const add_trailing_newline =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -2 +2 @@
        \\-two
        \\\ No newline at end of file
        \\+two
        \\
    ;
    const with_nl = try applyText(alloc, add_trailing_newline, "one\ntwo");
    defer alloc.free(with_nl);
    try testing.expectEqualStrings("one\ntwo\n", with_nl);
}

test "agent_patch: malformed headers, counts and hunks are typed errors" {
    try expectParseError(error.MalformedCounts,
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -x +1 @@
        \\-a
        \\+b
        \\
    );
    try expectParseError(error.MalformedCounts,
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\-a
        \\+b
        \\
    );
    try expectParseError(error.MalformedHunk,
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\?a
        \\+b
        \\
    );
    try expectParseError(error.MalformedHunk,
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,0 +1,0 @@
        \\
    );
    try expectParseError(error.NoHunks,
        \\--- a/f.txt
        \\+++ b/f.txt
        \\
    );
}

test "agent_patch: context and removal mismatches are refused" {
    const alloc = testing.allocator;
    const wrong_context =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ alpha
        \\-WRONG
        \\+beta
        \\
    ;
    var patch = try parse(alloc, wrong_context);
    defer patch.deinit(alloc);
    try testing.expectError(error.ContextMismatch, apply(alloc, &patch, "alpha\nbeta\n"));

    const no_newline_mismatch =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-beta
        \\+BETA
        \\
    ;
    var patch2 = try parse(alloc, no_newline_mismatch);
    defer patch2.deinit(alloc);
    // The old file has no trailing newline but the patch does not say so.
    try testing.expectError(error.NoNewlineMismatch, apply(alloc, &patch2, "beta"));
}

test "agent_patch: out-of-range and overlapping hunks are refused" {
    const alloc = testing.allocator;
    const beyond_eof =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -9,1 +9,1 @@
        \\-nine
        \\+NINE
        \\
    ;
    var patch = try parse(alloc, beyond_eof);
    defer patch.deinit(alloc);
    try testing.expectError(error.OutOfRange, apply(alloc, &patch, "one\n"));

    const wrong_new_start =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,1 +7,1 @@
        \\-one
        \\+ONE
        \\
    ;
    var patch2 = try parse(alloc, wrong_new_start);
    defer patch2.deinit(alloc);
    try testing.expectError(error.MalformedHunk, apply(alloc, &patch2, "one\n"));
}

test "agent_patch: multi-file, add/delete, binary, rename and mode patches are refused" {
    try expectParseError(error.MultiFile,
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+A
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1 +1 @@
        \\-b
        \\+B
        \\
    );
    try expectParseError(error.AddDeleteFile,
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+created
        \\
    );
    try expectParseError(error.AddDeleteFile,
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-gone
        \\
    );
    try expectParseError(error.BinaryPatch,
        \\diff --git a/img.bin b/img.bin
        \\index 1111111..2222222 100644
        \\Binary files a/img.bin and b/img.bin differ
        \\
    );
    try expectParseError(error.RenameOrCopy,
        \\diff --git a/old.txt b/new.txt
        \\similarity index 100%
        \\rename from old.txt
        \\rename to new.txt
        \\
    );
    try expectParseError(error.ModeChange,
        \\diff --git a/run.sh b/run.sh
        \\old mode 100644
        \\new mode 100755
        \\
    );
}

test "agent_patch: unsafe paths are refused" {
    try expectParseError(error.PathAbsolute,
        \\--- /etc/passwd
        \\+++ /etc/passwd
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    );
    try expectParseError(error.PathParent,
        \\--- a/../escape.txt
        \\+++ b/../escape.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    );
    try expectParseError(error.NulByte, "--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-a\u{0}\n+b\n");
    try expectParseError(error.PathMismatch,
        \\diff --git a/one.txt b/one.txt
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    );
}

test "agent_patch: patch, hunk and line caps are enforced" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_patch_bytes + 1);
    defer alloc.free(big);
    @memset(big, ' ');
    try testing.expectError(error.PatchTooLarge, parse(alloc, big));
    try testing.expectError(error.EmptyPatch, parse(alloc, ""));

    var many_hunks: std.ArrayList(u8) = .empty;
    defer many_hunks.deinit(alloc);
    try many_hunks.appendSlice(alloc, "--- a/f.txt\n+++ b/f.txt\n");
    var h: usize = 0;
    while (h <= max_hunks) : (h += 1) {
        const line = try std.fmt.allocPrint(alloc, "@@ -{d},1 +{d},1 @@\n x\n", .{ h + 1, h + 1 });
        defer alloc.free(line);
        try many_hunks.appendSlice(alloc, line);
    }
    try testing.expectError(error.TooManyHunks, parse(alloc, many_hunks.items));

    var many_lines: std.ArrayList(u8) = .empty;
    defer many_lines.deinit(alloc);
    try many_lines.appendSlice(alloc, "--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,20000 @@\n");
    var l: usize = 0;
    while (l <= max_hunk_lines) : (l += 1) try many_lines.appendSlice(alloc, "+x\n");
    try testing.expectError(error.TooManyLines, parse(alloc, many_lines.items));
}

test "agent_patch: oversized old text and no-op patches are refused" {
    const alloc = testing.allocator;
    const patch_text =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    ;
    const big = try alloc.alloc(u8, max_stage_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    try testing.expectError(error.TooLarge, applyText(alloc, patch_text, big));

    const noop =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-same
        \\+same
        \\
    ;
    try testing.expectError(error.NoChanges, applyText(alloc, noop, "same\n"));
}

test "agent_patch: preview is bounded and truthful, stats cover shown lines" {
    const alloc = testing.allocator;
    var patch_text: std.ArrayList(u8) = .empty;
    defer patch_text.deinit(alloc);
    try patch_text.appendSlice(alloc, "--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-old\n+NEW\n");
    var h: usize = 0;
    while (h < 40) : (h += 1) {
        const line = try std.fmt.allocPrint(
            alloc,
            "@@ -{d},1 +{d},1 @@\n-line {d}\n+LINE {d}\n",
            .{ (h + 1) * 4, (h + 1) * 4, h, h },
        );
        defer alloc.free(line);
        try patch_text.appendSlice(alloc, line);
    }
    var patch = try parse(alloc, patch_text.items);
    defer patch.deinit(alloc);
    const preview = try buildPreview(alloc, &patch);
    defer {
        for (preview.lines) |line| alloc.free(line.text);
        alloc.free(preview.lines);
    }
    try testing.expect(preview.partial);
    try testing.expect(preview.removed <= max_preview_lines);
    try testing.expect(preview.added <= max_preview_lines);
    try testing.expect(preview.lines.len <= max_preview_lines + 1);
    var note_found = false;
    for (preview.lines) |line| {
        if (std.mem.indexOf(u8, line.text, "not shown") != null) note_found = true;
    }
    try testing.expect(note_found);
}

test "agent_patch: apply_patch arguments are validated" {
    const alloc = testing.allocator;
    var args = try parseArgs(alloc, "{\"patch\":\"--- a/f\\n+++ b/f\\n@@ -1 +1 @@\\n-a\\n+b\\n\"}");
    defer args.deinit(alloc);
    try testing.expect(std.mem.indexOf(u8, args.patch, "@@ -1 +1 @@") != null);
    try testing.expectError(error.MissingPatch, parseArgs(alloc, "{}"));
    try testing.expectError(error.PatchNotString, parseArgs(alloc, "{\"patch\":1}"));
    try testing.expectError(error.EmptyPatch, parseArgs(alloc, "{\"patch\":\"\"}"));
    try testing.expectError(error.MalformedArguments, parseArgs(alloc, "not json"));
}

test "agent_patch: paths beginning with a/ or b/ are not mis-stripped" {
    const alloc = testing.allocator;
    // Plain diff of a file literally named "a/notes.txt": identical spellings
    // mean no prefix stripping.
    const plain =
        \\--- a/notes.txt
        \\+++ a/notes.txt
        \\@@ -1 +1 @@
        \\-before
        \\+after
        \\
    ;
    var patch = try parse(alloc, plain);
    defer patch.deinit(alloc);
    try testing.expectEqualStrings("a/notes.txt", patch.path);

    // git --no-prefix output for the same file.
    const no_prefix =
        \\diff --git a/notes.txt a/notes.txt
        \\--- a/notes.txt
        \\+++ a/notes.txt
        \\@@ -1 +1 @@
        \\-before
        \\+after
        \\
    ;
    var patch2 = try parse(alloc, no_prefix);
    defer patch2.deinit(alloc);
    try testing.expectEqualStrings("a/notes.txt", patch2.path);

    // Normal git prefixes for a file whose real path is "a/notes.txt".
    const prefixed =
        \\diff --git a/a/notes.txt b/a/notes.txt
        \\--- a/a/notes.txt
        \\+++ b/a/notes.txt
        \\@@ -1 +1 @@
        \\-before
        \\+after
        \\
    ;
    var patch3 = try parse(alloc, prefixed);
    defer patch3.deinit(alloc);
    try testing.expectEqualStrings("a/notes.txt", patch3.path);
}

test "agent_patch: fenced and no-prefix single-file patches parse" {
    const alloc = testing.allocator;
    const fenced =
        \\```diff
        \\--- old.txt
        \\+++ old.txt
        \\@@ -1 +1 @@
        \\-before
        \\+after
        \\```
    ;
    const new_text = try applyText(alloc, fenced, "before\n");
    defer alloc.free(new_text);
    try testing.expectEqualStrings("after\n", new_text);

    const git_only =
        \\diff --git a/g.txt b/g.txt
        \\index 1111111..2222222 100644
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\
    ;
    const from_git = try applyText(alloc, git_only, "x\n");
    defer alloc.free(from_git);
    try testing.expectEqualStrings("y\n", from_git);
}

test "agent_patch: parses multiple files in order with mixed hunk counts" {
    const alloc = testing.allocator;
    const patch_text =
        \\diff --git a/one.txt b/one.txt
        \\index 1111111..2222222 100644
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-old one
        \\+new one
        \\@@ -3 +3 @@
        \\-old one extra
        \\+new one extra
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1 +1,2 @@
        \\-old two
        \\+new two
        \\+extra two
        \\diff --git a/three.txt b/three.txt
        \\--- a/three.txt
        \\+++ b/three.txt
        \\@@ -2,2 +2,2 @@
        \\ keep three
        \\-old three
        \\+new three
        \\
    ;
    var set = try parseSet(alloc, patch_text);
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), set.files.len);
    try testing.expectEqualStrings("one.txt", set.files[0].path);
    try testing.expectEqualStrings("two.txt", set.files[1].path);
    try testing.expectEqualStrings("three.txt", set.files[2].path);
    try testing.expectEqual(@as(usize, 2), set.files[0].hunks.len);
    try testing.expectEqual(@as(usize, 1), set.files[1].hunks.len);
    try testing.expectEqual(@as(usize, 1), set.files[2].hunks.len);
    const totals = set.totals();
    try testing.expectEqual(@as(u32, 4), totals.removed);
    try testing.expectEqual(@as(u32, 5), totals.added);

    const old_texts = [_][]const u8{ "one\nold one\nold one extra\n", "old two\n", "zero\nkeep three\nold three\n" };
    var validation = try validateSet(alloc, &set, &old_texts);
    defer validation.deinit(alloc);
    switch (validation) {
        .ok => |texts| {
            try testing.expectEqual(@as(usize, 3), texts.len);
            try testing.expectEqualStrings("one\nnew one\nnew one extra\n", texts[0]);
            try testing.expectEqualStrings("new two\nextra two\n", texts[1]);
            try testing.expectEqualStrings("zero\nkeep three\nnew three\n", texts[2]);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    // Each file exposes its own complete preview (multi staging passes the
    // global budgets instead of the single-file display cap).
    const preview = try buildPreviewWithLimits(alloc, &set.files[1], 1000, 100);
    defer {
        for (preview.lines) |line| alloc.free(line.text);
        alloc.free(preview.lines);
    }
    try testing.expectEqual(@as(u32, 1), preview.removed);
    try testing.expectEqual(@as(u32, 2), preview.added);
    try testing.expect(!preview.partial);
}

test "agent_patch: duplicate, unsafe and oversized file sets are rejected" {
    const alloc = testing.allocator;

    // Same normalized path twice (`a/dup.txt`, then `dup.txt`).
    try expectParseError(error.DuplicatePath,
        \\--- a/dup.txt
        \\+++ b/dup.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- dup.txt
        \\+++ dup.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    );
    // A second section with an absolute path rejects the whole set.
    try expectParseError(error.PathAbsolute,
        \\--- a/ok.txt
        \\+++ b/ok.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- /etc/passwd
        \\+++ /etc/passwd
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    );
    // A `..` section also rejects before any file is returned.
    try expectParseError(error.PathParent,
        \\--- a/ok.txt
        \\+++ b/ok.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- a/../escape.txt
        \\+++ b/../escape.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i <= max_files) : (i += 1) {
        const section = try std.fmt.allocPrint(
            alloc,
            "--- a/f{d}.txt\n+++ b/f{d}.txt\n@@ -1 +1 @@\n-a\n+b\n",
            .{ i, i },
        );
        defer alloc.free(section);
        try buf.appendSlice(alloc, section);
    }
    try expectParseError(error.TooManyFiles, buf.items);
}

test "agent_patch: one malformed section rejects the entire set" {
    try expectParseError(error.MalformedCounts,
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1,2 +1,2 @@
        \\-only one line
        \\+nope
        \\
    );
    try expectParseError(error.NoHunks,
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- a/empty.txt
        \\+++ b/empty.txt
        \\
    );
    try expectParseError(error.BinaryPatch,
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/img.bin b/img.bin
        \\Binary files a/img.bin and b/img.bin differ
        \\
    );
}

test "agent_patch: per-file hunk budget and total validation errors" {
    const alloc = testing.allocator;
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(alloc);
    try many.appendSlice(alloc, "--- a/f.txt\n+++ b/f.txt\n");
    var h: usize = 0;
    while (h <= max_hunks_per_file) : (h += 1) {
        const line = try std.fmt.allocPrint(alloc, "@@ -{d},1 +{d},1 @@\n x\n", .{ h + 1, h + 1 });
        defer alloc.free(line);
        try many.appendSlice(alloc, line);
    }
    try expectParseError(error.TooManyHunks, many.items);

    // Validation collects every failing file instead of stopping at the
    // first; the caller can show a real per-file list and write nothing.
    var set = try parseSet(alloc,
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1 +1 @@
        \\-old b
        \\+new b
        \\
    );
    defer set.deinit(alloc);
    const stale = [_][]const u8{ "wrong a\n", "old b\n" };
    var rejected = try validateSet(alloc, &set, &stale);
    defer rejected.deinit(alloc);
    switch (rejected) {
        .ok => return error.TestUnexpectedResult,
        .rejected => |issues| {
            try testing.expectEqual(@as(usize, 1), issues.len);
            try testing.expectEqual(@as(usize, 0), issues[0].index);
            try testing.expectEqualStrings("a.txt", issues[0].path);
            try testing.expectEqual(error.ContextMismatch, issues[0].err);
        },
    }

    const stale_both = [_][]const u8{ "wrong a\n", "wrong b\n" };
    var rejected_both = try validateSet(alloc, &set, &stale_both);
    defer rejected_both.deinit(alloc);
    switch (rejected_both) {
        .ok => return error.TestUnexpectedResult,
        .rejected => |issues| {
            try testing.expectEqual(@as(usize, 2), issues.len);
            try testing.expectEqualStrings("a.txt", issues[0].path);
            try testing.expectEqualStrings("b.txt", issues[1].path);
        },
    }
}

test "agent_patch: single-file wrapper still rejects multi-file input" {
    const alloc = testing.allocator;
    try testing.expectError(error.MultiFile, parse(alloc,
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+A
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1 +1 @@
        \\-b
        \\+B
        \\
    ));
    var set = try parseSet(alloc,
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+A
        \\
    );
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), set.files.len);
}
