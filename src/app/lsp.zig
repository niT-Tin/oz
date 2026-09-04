//! lsp — App method group split out of src/main.zig (physical move).

const std = @import("std");
const buffer = @import("../buffer/root.zig");
const lsp = @import("../lsp/client.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_diag = @import("../lsp/diagnostics.zig");
const json_rpc = @import("../util/json_rpc.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;
const autil = @import("util.zig");

/// Async LSP attach: the server spawn + initialize handshake run on a worker
/// thread so opening a file never blocks the UI (a cold zls boot takes
/// hundreds of ms; a wedged server would otherwise stall first paint for the
/// full 30s handshake cap). The worker fills `client`/`err` BEFORE flipping
/// `done` (release); the main loop consumes with acquire and joins. The
/// handshake is aborted via `cancel` (checked by waitResponse) when the
/// buffer's filetype changes mid-attach.
pub const LspStartJob = struct {
    lang: []u8, // owned (filetype)
    uri: []u8, // owned
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client: ?*lsp.Client = null,
    err: ?[]const u8 = null, // @errorName — static string, not owned
    thread: std.Thread = undefined,
};

// ---- LSP (M2) ----

/// Lazily (re)start the LSP client for the current buffer's filetype.
/// Returns without action when the filetype has no configured server or
/// the spawn/handshake failed — LSP is strictly optional.
pub fn ensureLsp(self: *App) void {
    const ft = autil.filetypeOf(self.cur().path);
    if (self.lsp_client) |c| {
        if (std.mem.eql(u8, c.lang, ft)) {
            // Same filetype but a different document (buffer switch):
            // retarget the client, or every request would carry the
            // stale URI — hover/gd/completion/diagnostics silently die.
            const path = self.cur().path orelse return;
            const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
            defer self.alloc.free(uri);
            if (!std.mem.eql(u8, c.uri, uri)) {
                // The server keeps every opened document, so a switch to a
                // document it already has — and whose content is unchanged
                // since the last didOpen/didChange (lsp_synced_rev) —
                // needs no re-open and no full-text copy: just retarget.
                const buf = &self.buffers.items[self.current];
                if (c.isDocOpen(uri) and buf.lsp_synced_rev == buf.history.revision) {
                    c.retarget(uri) catch {};
                    return;
                }
                const text = self.curText() catch return;
                defer self.alloc.free(text);
                c.switchDocument(uri, text) catch {};
                buf.lsp_synced_rev = buf.history.revision;
            }
            return;
        }
        // filetype changed: close the old server
        c.deinit();
        self.lsp_client = null;
    }
    if (ft.len == 0) return;
    const path = self.cur().path orelse return;
    if (path.len == 0) return;
    const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
    // An attach already in flight for this exact filetype+uri is enough;
    // a mismatched one belongs to a buffer the user already left —
    // cancel it before starting the new one.
    if (self.lsp_starting) |job| {
        if (std.mem.eql(u8, job.lang, ft) and std.mem.eql(u8, job.uri, uri)) {
            self.alloc.free(uri);
            return;
        }
        self.cancelLspStart();
    }
    // Async attach: spawn + handshake run on a worker thread (LspStartJob)
    // so first paint and editing never block on a slow server boot. The
    // job posts a wake event when done; the run loop installs the client
    // (finishLspStart) and only then opens the document with the CURRENT
    // text, so edits during the handshake are not lost.
    const job = self.alloc.create(LspStartJob) catch {
        self.alloc.free(uri);
        return;
    };
    job.* = .{
        .lang = self.alloc.dupe(u8, ft) catch {
            self.alloc.free(uri);
            self.alloc.destroy(job);
            return;
        },
        .uri = uri,
    };
    job.thread = std.Thread.spawn(.{}, lspStartMain, .{ self.alloc, self.io, self.env_map, job, self }) catch {
        self.alloc.free(job.lang);
        self.alloc.free(job.uri);
        self.alloc.destroy(job);
        return;
    };
    self.lsp_starting = job;
}

/// Worker: run the spawn + initialize handshake off the UI thread.
pub fn lspStartMain(alloc: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, job: *LspStartJob, app: *App) void {
    if (lsp.Client.connect(alloc, io, env_map, job.lang, job.uri, &job.cancel)) |client| {
        job.client = client;
    } else |e| {
        job.err = @errorName(e);
    }
    job.done.store(true, .release);
    // wake the main loop so the client is installed without a keypress
    lspWake(app);
}

/// Abort and reap an in-flight attach (buffer switched away / teardown).
/// The join is quick: waitResponse polls `cancel` every 100ms.
pub fn cancelLspStart(self: *App) void {
    const job = self.lsp_starting orelse return;
    job.cancel.store(true, .release);
    job.thread.join();
    if (job.client) |c| c.deinit();
    self.alloc.free(job.lang);
    self.alloc.free(job.uri);
    self.alloc.destroy(job);
    self.lsp_starting = null;
}

/// Consume a finished async attach (run loop, each frame): install the
/// client for the current buffer, or drop it when the user moved on
/// mid-handshake. Returns true when a job was consumed (caller renders).
pub fn finishLspStart(self: *App) bool {
    const job = self.lsp_starting orelse return false;
    if (!job.done.load(.acquire)) return false;
    job.thread.join();
    self.lsp_starting = null;
    defer {
        self.alloc.free(job.lang);
        self.alloc.free(job.uri);
        self.alloc.destroy(job);
    }
    const client = job.client orelse {
        // A cancel is a buffer switch, not an error — stay silent.
        if (job.err) |name| {
            if (!std.mem.eql(u8, name, "Cancelled")) {
                // Tell the user why LSP features are silent: the
                // configured server binary is missing or failed to spawn.
                const msg = std.fmt.allocPrint(self.alloc, "LSP {s}: {s}", .{ job.lang, name }) catch return true;
                self.setMsg(msg) catch {};
            }
        }
        return true;
    };
    // Install only when the current buffer still matches the job.
    const ft = autil.filetypeOf(self.cur().path);
    const cur_uri: ?[]u8 = blk: {
        const path = self.cur().path orelse break :blk null;
        break :blk lsp_types.pathToFileUri(self.alloc, path) catch null;
    };
    defer if (cur_uri) |u| self.alloc.free(u);
    if (cur_uri == null or !std.mem.eql(u8, ft, job.lang) or !std.mem.eql(u8, cur_uri.?, job.uri)) {
        client.deinit(); // user moved on mid-handshake
        self.ensureLsp(); // attach for whatever is current now
        return true;
    }
    // Wire the reader thread's wake callback to our event loop: any
    // incoming LSP message posts an event so the main loop (blocked in
    // pollEvent) wakes up and drains it without waiting for a keypress.
    client.wake_ctx = self;
    client.wake_fn = lspWake;
    self.lsp_client = client;
    // Open with the CURRENT text — edits made during the handshake must
    // not be lost.
    const text = self.curText() catch return true;
    defer self.alloc.free(text);
    client.openDocument(text) catch return true;
    // The didOpen carried the current text: the server's copy of this
    // buffer is now current (same contract as the switchDocument path).
    self.cur().lsp_synced_rev = self.cur().history.revision;
    return true;
}

/// Called from the LSP reader thread when a message arrives: post a
/// (harmless) event so pollEvent wakes up. Only thread-safe state is
/// touched; the event is consumed as `else => {}` by the main loop.
pub fn lspWake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const r = app.loop.tryPostEvent(.focus_in) catch false;
    _ = r;
}

/// Current buffer text (owned copy) — for didOpen/didChange payloads.
pub fn curText(self: *App) ![]u8 {
    const len = self.cur().pt.len();
    const buf = try self.alloc.alloc(u8, len);
    errdefer self.alloc.free(buf);
    self.cur().pt.copyRange(0, buf);
    return buf;
}

/// LSP Position (line + UTF-16 character) of byte offset `byte` in `pt`.
/// LSP counts characters in UTF-16 code units; `utf16Units` converts the
/// byte column without materializing the document.
pub fn lspPositionAt(self: *App, pt: *const buffer.PieceTable, byte: u32) lsp_types.Position {
    const line = pt.lineOf(byte);
    const ls = pt.lineStart(line);
    return .{ .line = line, .character = self.utf16Units(pt, ls, byte) };
}

/// UTF-16 code units in [from, to) of `pt` (BMP chars = 1, astral = 2).
/// Walks the pieces directly — no document copy — carrying a small window
/// across piece boundaries for multi-byte sequences split by an edit.
pub fn utf16Units(self: *App, pt: *const buffer.PieceTable, from: u32, to: u32) u32 {
    _ = self;
    if (to <= from) return 0;
    var units: u32 = 0;
    var carry: [3]u8 = undefined; // lead bytes of a sequence split at a boundary
    var carry_len: usize = 0;
    var doc_off: u32 = 0;
    var first = true;
    for (pt.pieces.items) |p| {
        const piece_end = doc_off + p.len;
        if (piece_end <= from) {
            doc_off = piece_end;
            continue;
        }
        if (doc_off >= to) break;
        const src: []const u8 = if (p.source == .origin) pt.origin else pt.add.items;
        const skip: u32 = if (from > doc_off) from - doc_off else 0;
        const take: u32 = @min(p.len - skip, to - doc_off);
        const bytes = src[@as(usize, p.start) + skip .. @as(usize, p.start) + skip + take];
        var i: usize = 0;
        if (!first and carry_len > 0 and bytes.len > 0 and (bytes[0] & 0xC0) == 0x80) {
            // The previous window ended mid-sequence: complete it with the
            // continuation bytes that start this window.
            const total: usize = std.unicode.utf8ByteSequenceLength(carry[0]) catch 0;
            if (total > carry_len) {
                const need = total - carry_len;
                if (bytes.len >= need) {
                    units += if (total == 4) 2 else 1;
                    i = need;
                } else {
                    // Still split (tiny pieces): carry everything over.
                    @memcpy(carry[carry_len .. carry_len + bytes.len], bytes);
                    carry_len += bytes.len;
                    doc_off = piece_end;
                    first = false;
                    continue;
                }
            }
        }
        carry_len = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b < 0x80) {
                units += 1;
                i += 1;
                continue;
            }
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + seq_len > bytes.len) {
                const left = bytes.len - i;
                @memcpy(carry[0..left], bytes[i..]);
                carry_len = left;
                break;
            }
            units += if (seq_len == 4) 2 else 1;
            i += seq_len;
        }
        doc_off = piece_end;
        first = false;
    }
    return units;
}

/// Free every diagnostic message and empty the list. Messages are dupe'd
/// in parseDiagnostics — a bare clearRetainingCapacity() leaks them.
pub fn clearDiagnostics(self: *App) void {
    for (self.lsp_diagnostics.items) |*d| self.alloc.free(d.message);
    self.lsp_diagnostics.clearRetainingCapacity();
}

/// LSP notification handler (main thread, called from drain each frame).
pub fn lspHandler(self: *App, client: *lsp.Client, msg: *json_rpc.Message) void {
    _ = client;
    const method = msg.method orelse return;
    if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
        if (msg.params) |params| {
            // Parse diagnostics for the CURRENT file into lsp_diagnostics
            // (sorted by line). Diagnostics for other documents are
            // dropped — the editor tracks one buffer at a time.
            self.clearDiagnostics();
            self.diag_dirty = true;
            const path = self.cur().path orelse return;
            const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
            defer self.alloc.free(uri);
            lsp_diag.parseDiagnostics(self.alloc, params, uri, &self.lsp_diagnostics) catch {};
            lsp_diag.sortByLine(self.lsp_diagnostics.items);
        }
    }
}

/// Shared edit bookkeeping (dirty flag, edit_seq, fold reset, inlay
/// invalidation). The LSP sync is left to the caller: markDirty (full
/// text) or markDirtyRange (incremental).
pub fn markDirtyBase(self: *App) void {
    self.cur().dirty = true;
    self.edit_seq += 1;
    // Any edit drops this buffer's fold set (all folds re-open): edit
    // line shifts would otherwise leave the closed-fold start lines
    // pointing at stale text, and shifting ranges per edit is not worth
    // it — re-folding with zM costs one indent scan.
    self.cur().folds.clearRetainingCapacity();
    // The visible text changed: the git gutter marks (buffer-vs-HEAD) are
    // stale until the run loop re-diffs once typing quiesces.
    self.gitMarksStaleNow();
    // Editing normally invalidates inlay hints: their offsets refer to the
    // pre-edit text. During an insert session we skip that and instead
    // shift the hints for the edit (see adjustInlayHintsInsert/Delete) so
    // the screen doesn't flicker on every keystroke; exitInsert forces a
    // fresh request once the session ends. One-shot normal-mode ops
    // (dd, x, o…) still invalidate here and let the auto-refresh re-request.
    if (!self.in_insert) self.invalidateInlayHints();
}

/// Mark the current buffer dirty and push its FULL text to the LSP server
/// (fallback for edits without a tracked byte range: undo/redo,
/// multi-cursor ops, paste, format, …).
pub fn markDirty(self: *App) void {
    self.markDirtyBase();
    self.syncLspFull();
}

/// Mark the current buffer dirty and push an INCREMENTAL didChange to the
/// LSP server: `text` replaced [start, end) of the PRE-EDIT document
/// (`start`/`end` are LSP positions computed before the edit was applied).
/// The per-keystroke path — no full-document copy.
pub fn markDirtyRange(self: *App, start: lsp_types.Position, end: lsp_types.Position, text: []const u8) void {
    self.markDirtyBase();
    if (self.lsp_client) |c| {
        c.didChange(.{ .start = start, .end = end }, text) catch {
            return;
        };
        self.cur().lsp_synced_rev = self.cur().history.revision;
    }
}

/// Full-text didChange for the current buffer (see markDirty).
pub fn syncLspFull(self: *App) void {
    if (self.lsp_client) |c| {
        const text = self.curText() catch return;
        defer self.alloc.free(text);
        c.didChange(null, text) catch {
            return;
        };
        self.cur().lsp_synced_rev = self.cur().history.revision;
    }
}
