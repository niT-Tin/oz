//! oz entry point: vaxis event loop + editor integration (DESIGN.md).
//!
//! Loop:
//!   nextEvent → Mode state machine → execute result against PieceTable
//!   → render frame (line numbers + text + status bar) → vaxis diff output.
//!
//! The App state machine lives in app.zig; per-domain method groups
//! live in app/*.zig (physical split — decl aliases in App keep every
//! call site unchanged).

const std = @import("std");
const builtin = @import("builtin");
const buffer = @import("buffer/root.zig");

const app_mod = @import("app.zig");
const autil = @import("app/util.zig");

const App = app_mod.App;

// Silence vaxis's per-frame debug logging (pollutes the tty byte stream and
// interferes with e2e screen reconstruction).
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .err }},
};

pub fn main(init: std.process.Init) !void {
    // Debug builds use the DebugAllocator, which captures a stack trace on
    // EVERY allocation — and MachO/DWARF stack unwinding on macOS is slow
    // enough to make typing visibly laggy once an LSP server is attached
    // (each keystroke parses a large JSON response = thousands of allocs).
    // The libc allocator keeps dev builds responsive; safety checks in the
    // code itself are unaffected. Release builds already use c_allocator.
    var app_init = init;
    if (builtin.mode == .Debug and builtin.link_libc) app_init.gpa = std.heap.c_allocator;
    var app = try App.create(app_init);
    defer app.destroy();

    // args: oz [file[:line]] ...
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    var target_line: u32 = 0;
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        const content = arg[0 .. arg.len - 0];
        if (autil.parseLineArg(content)) |ln| {
            target_line = ln;
        }
        const file_path = if (autil.parseLineArg(content) != null) content[0..std.mem.lastIndexOfScalar(u8, content, ':').?] else content;
        if (file_path.len > 0) {
            var file = std.Io.Dir.cwd().openFile(app.io, file_path, .{ .mode = .read_only }) catch |e| {
                switch (e) {
                    // vim semantics: a path that does not exist yet opens as
                    // an empty buffer with the path set — :w creates the file
                    // (saveFile uses createFile). No status message; this is
                    // the normal "edit a new file" flow, not the dashboard.
                    error.FileNotFound => {
                        app.cur().pt.deinit();
                        app.cur().pt = try buffer.PieceTable.init(app.alloc, "");
                        app.clearSpanCache(app.cur());
                        if (app.cur().path) |p| app.alloc.free(p);
                        app.cur().path = try app.absolutePath(file_path);
                    },
                    // a directory is not a file — refuse it with a message
                    // instead of dying deep in the read path below.
                    error.IsDir => try app.setMsg(try std.fmt.allocPrint(app.alloc, "E17: {s} is a directory", .{file_path})),
                    // exists but unreadable (permissions etc.): say so on the
                    // status bar, don't silently drop into the dashboard.
                    else => try app.setMsg(try std.fmt.allocPrint(app.alloc, "E484: cannot open {s}: {s}", .{ file_path, @errorName(e) })),
                }
                break;
            };
            defer file.close(app.io);
            const size = (try file.stat(app.io)).size;
            // The piece table addresses the document with u32 offsets; a file
            // at/over 4 GiB would overflow (@intCast panics). Refuse it
            // cleanly instead of crashing: syntax highlighting already
            // degrades past SIZE_LIMIT, and editing multi-GiB files with a
            // u32-based buffer is unsupported.
            if (size >= std.math.maxInt(u32)) {
                try app.setMsg(try app.alloc.dupe(u8, "file too large (>4GiB)"));
                continue;
            }
            app.cur().pt.deinit();
            app.cur().pt = try app.loadPieceTable(file, size);
            app.clearSpanCache(app.cur());
            if (app.cur().path) |p| app.alloc.free(p);
            // Store an absolute path so LSP (uri building, server matching)
            // works for relative CLI args like `oz build.zig` — filetypeOf
            // and ensureLsp both consume this.
            app.cur().path = try app.absolutePath(file_path);
            // recent history must hold the same (absolute) form every other
            // entry uses, or the dashboard's relative entries break after a
            // cwd change (and dedupe against absolute entries fails).
            try app.addRecent(app.cur().path.?);
        }
        break; // M0: first file only
    }
    if (target_line > 0) {
        app.curCursor().* = app.cur().pt.lineStart(@min(target_line - 1, app.cur().pt.lineCount() - 1));
    }

    // the CLI arg path edits cur() directly (no openInBuffer/switchTo), so
    // kick the LSP client and the git status refresh for the opened filetype
    // here.
    app.ensureLsp();
    app.scheduleGitStatus();
    try app.loadRecent();
    defer app.saveRecent() catch {};
    try app.run();
}
