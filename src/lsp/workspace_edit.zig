//! Validate LSP edit sets before any document is changed. JSON values borrow
//! the response; prepared replacements and undo groups own all their bytes.
const std = @import("std");
const buffer = @import("../buffer/root.zig");
const history_mod = @import("../buffer/history.zig");
const nav = @import("navigation.zig");

pub const Request = struct {
    path: []u8,
    workspace: usize,
    buffer_index: usize,
    revision: u64,
    edit_seq: u64,

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

pub const Document = struct {
    uri: []const u8,
    edits: std.json.Value,
    version: ?i32 = null,
};

/// Both WorkspaceEdit encodings are supported. Resource operations are
/// rejected as a whole, rather than silently applying the remaining files.
pub fn documents(alloc: std.mem.Allocator, result: std.json.Value, source_uri: []const u8) ![]Document {
    var out: std.ArrayList(Document) = .empty;
    errdefer out.deinit(alloc);
    if (result == .null) return out.toOwnedSlice(alloc);
    if (result == .array) {
        try out.append(alloc, .{ .uri = source_uri, .edits = result });
    } else if (result == .object) {
        const changes = result.object.get("changes");
        const doc_changes = result.object.get("documentChanges");
        if (changes != null and doc_changes != null) return error.AmbiguousWorkspaceEdit;
        if (changes) |map| {
            if (map != .object) return error.InvalidWorkspaceEdit;
            var it = map.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .array) return error.InvalidWorkspaceEdit;
                try out.append(alloc, .{ .uri = entry.key_ptr.*, .edits = entry.value_ptr.* });
            }
        } else if (doc_changes) |list| {
            if (list != .array) return error.InvalidWorkspaceEdit;
            for (list.array.items) |item| {
                if (item != .object) return error.InvalidWorkspaceEdit;
                if (item.object.get("kind") != null) return error.UnsupportedResourceOperation;
                const td = item.object.get("textDocument") orelse return error.InvalidWorkspaceEdit;
                const edits = item.object.get("edits") orelse return error.InvalidWorkspaceEdit;
                if (td != .object or edits != .array) return error.InvalidWorkspaceEdit;
                const uri = td.object.get("uri") orelse return error.InvalidWorkspaceEdit;
                if (uri != .string) return error.InvalidWorkspaceEdit;
                var version: ?i32 = null;
                if (td.object.get("version")) |v| {
                    version = switch (v) {
                        .null => null,
                        .integer => |n| std.math.cast(i32, n) orelse return error.InvalidWorkspaceEdit,
                        .number_string => |s| std.fmt.parseInt(i32, s, 10) catch return error.InvalidWorkspaceEdit,
                        else => return error.InvalidWorkspaceEdit,
                    };
                }
                try out.append(alloc, .{ .uri = uri.string, .edits = edits, .version = version });
            }
        } else return error.InvalidWorkspaceEdit;
    } else return error.InvalidWorkspaceEdit;
    for (out.items, 0..) |doc, i| {
        for (out.items[0..i]) |previous| {
            if (std.mem.eql(u8, doc.uri, previous.uri)) return error.DuplicateDocument;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build a complete replacement from validated, sorted, non-overlapping
/// ranges. Invalid edits reject the entire document, never a subset.
pub fn replacement(alloc: std.mem.Allocator, text: []const u8, value: std.json.Value) ![]u8 {
    if (value != .array) return error.InvalidTextEdit;
    var pt = try buffer.PieceTable.init(alloc, text);
    defer pt.deinit();
    for (value.array.items) |item| {
        if (item != .object) return error.InvalidTextEdit;
        const range = item.object.get("range") orelse return error.InvalidTextEdit;
        if (range != .object) return error.InvalidTextEdit;
    }
    var edits: std.ArrayList(nav.TextEdit) = .empty;
    defer {
        for (edits.items) |e| alloc.free(e.new_text);
        edits.deinit(alloc);
    }
    try nav.parseTextEdits(alloc, value, &pt, &edits);
    if (edits.items.len != value.array.items.len) return error.InvalidTextEdit;
    std.sort.block(nav.TextEdit, edits.items, {}, struct {
        fn less(_: void, a: nav.TextEdit, b: nav.TextEdit) bool {
            return a.start < b.start;
        }
    }.less);
    var previous_end: u32 = 0;
    var new_len: u64 = text.len;
    for (edits.items) |e| {
        if (e.start < previous_end or e.end < e.start or e.end > pt.len()) return error.OverlappingTextEdits;
        previous_end = e.end;
        new_len = new_len - (e.end - e.start) + e.new_text.len;
        if (new_len >= std.math.maxInt(u32)) return error.DocumentTooLarge;
    }
    var i = edits.items.len;
    while (i > 0) {
        i -= 1;
        const e = edits.items[i];
        _ = try pt.replace(e.start, e.end - e.start, e.new_text);
    }
    const result = try alloc.alloc(u8, pt.len());
    pt.copyRange(0, result);
    return result;
}

/// All allocation precedes commit, including the destination history slots.
/// This lets an entire multi-document response install without partial edits
/// on allocation failure, while retaining every document's existing history.
pub const Prepared = struct {
    pt: buffer.PieceTable,
    group: history_mod.Group,

    pub fn init(alloc: std.mem.Allocator, before: []const u8, after: []const u8) !Prepared {
        var pt = try buffer.PieceTable.init(alloc, after);
        errdefer pt.deinit();
        var group: history_mod.Group = .{ .edits = .empty };
        errdefer group.deinit(alloc);
        const old = try alloc.dupe(u8, before);
        errdefer alloc.free(old);
        const new = try alloc.dupe(u8, after);
        errdefer alloc.free(new);
        try group.edits.append(alloc, .{ .pos = 0, .before = old, .after = new });
        return .{ .pt = pt, .group = group };
    }

    pub fn reserve(hist: *buffer.History) !void {
        try hist.undo_stack.ensureUnusedCapacity(hist.allocator, 2);
    }

    pub fn commit(self: *Prepared, pt: *buffer.PieceTable, hist: *buffer.History) void {
        hist.endGroup();
        for (hist.redo_stack.items) |*g| g.deinit(hist.allocator);
        hist.redo_stack.clearRetainingCapacity();
        hist.undo_stack.appendAssumeCapacity(self.group);
        hist.revision += 1;
        hist.last_record = null;
        pt.deinit();
        pt.* = self.pt;
        self.* = undefined;
    }

    pub fn deinit(self: *Prepared, alloc: std.mem.Allocator) void {
        self.pt.deinit();
        self.group.deinit(alloc);
    }
};

test "workspace edit: URI order and documentChanges retain every target" {
    const alloc = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"changes":{"file:///b.zig":[],"file:///a.zig":[]}}
    , .{});
    defer p.deinit();
    const docs = try documents(alloc, p.value, "file:///a.zig");
    defer alloc.free(docs);
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqualStrings("file:///b.zig", docs[0].uri);
    try std.testing.expectEqualStrings("file:///a.zig", docs[1].uri);
    var d = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"documentChanges":[{"textDocument":{"uri":"file:///a.zig","version":3},"edits":[]},{"textDocument":{"uri":"file:///b.zig","version":null},"edits":[]}]}
    , .{});
    defer d.deinit();
    const documents_ = try documents(alloc, d.value, "file:///a.zig");
    defer alloc.free(documents_);
    try std.testing.expectEqual(@as(?i32, 3), documents_[0].version);
    try std.testing.expectEqual(@as(?i32, null), documents_[1].version);
}

test "workspace edit: unsupported or duplicate documents reject the whole set" {
    const alloc = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"documentChanges":[{"textDocument":{"uri":"file:///a","version":null},"edits":[]},{"kind":"delete","uri":"file:///b"}]}
    , .{});
    defer p.deinit();
    try std.testing.expectError(error.UnsupportedResourceOperation, documents(alloc, p.value, "file:///a"));
    var d = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"documentChanges":[{"textDocument":{"uri":"file:///a"},"edits":[]},{"textDocument":{"uri":"file:///a"},"edits":[]}]}
    , .{});
    defer d.deinit();
    try std.testing.expectError(error.DuplicateDocument, documents(alloc, d.value, "file:///a"));
}

test "workspace edit: unsorted UTF-16 edits produce one undoable replacement" {
    const alloc = std.testing.allocator;
    const before = "a你😀z\n";
    var p = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":5}},"newText":"Z"},{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"newText":"好"}]
    , .{});
    defer p.deinit();
    const after = try replacement(alloc, before, p.value);
    defer alloc.free(after);
    try std.testing.expectEqualStrings("a好😀Z\n", after);
    var pt = try buffer.PieceTable.init(alloc, before);
    defer pt.deinit();
    var hist = buffer.History.init(alloc);
    defer hist.deinit();
    var prepared = try Prepared.init(alloc, before, after);
    try Prepared.reserve(&hist);
    prepared.commit(&pt, &hist);
    try std.testing.expect(hist.undo(&pt));
    const undone = try alloc.alloc(u8, pt.len());
    defer alloc.free(undone);
    pt.copyRange(0, undone);
    try std.testing.expectEqualStrings(before, undone);
    try std.testing.expect(hist.redo(&pt));
}

test "workspace edit: one invalid or overlapping edit rejects every edit" {
    const alloc = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}},"newText":"x"},{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"newText":"y"}]
    , .{});
    defer p.deinit();
    try std.testing.expectError(error.OverlappingTextEdits, replacement(alloc, "abcd", p.value));
    var bad = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"range\":7}]", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidTextEdit, replacement(alloc, "abcd", bad.value));
}
