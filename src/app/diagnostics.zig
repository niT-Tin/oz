//! diagnostics — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");
const lsp_diag = @import("../lsp/diagnostics.zig");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- M2 diagnostics UI ----

/// ]d / [d: jump to the next/previous diagnostic line (current file).
pub fn gotoDiagnostic(self: *App, next: bool) void {
    if (self.lsp_diagnostics.items.len == 0) return;
    const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
    const idx: ?usize = if (next)
        lsp_diag.nextAtOrAfter(self.lsp_diagnostics.items, cursor_line + 1)
    else
        lsp_diag.prevAtOrBefore(self.lsp_diagnostics.items, cursor_line -| 1);
    const i = idx orelse return;
    const target_line = self.lsp_diagnostics.items[i].range.start.line;
    self.curCursor().* = self.cur().pt.lineStart(@min(target_line, self.cur().pt.lineCount() - 1));
}

/// gl: show the cursor line's diagnostics in the status bar.
pub fn showLineDiagnostics(self: *App) void {
    const line = self.cur().pt.lineOf(self.curCursor().*);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(self.alloc);
    for (self.lsp_diagnostics.items) |d| {
        if (d.range.start.line != line) continue;
        if (buf.items.len > 0) buf.append(self.alloc, ';') catch return;
        buf.appendSlice(self.alloc, d.message) catch return;
    }
    if (buf.items.len == 0) {
        const m = self.alloc.dupe(u8, "no diagnostics on this line") catch return;
        self.setMsg(m) catch return;
        return;
    }
    const m = buf.toOwnedSlice(self.alloc) catch return;
    self.setMsg(m) catch return;
}

/// <leader>sd: toggle the diagnostics list overlay.
pub fn toggleDiagnosticsList(self: *App) void {
    if (self.diag_list_active) {
        self.diag_list_active = false;
        return;
    }
    if (self.lsp_diagnostics.items.len == 0) {
        const m = self.alloc.dupe(u8, "no diagnostics") catch return;
        self.setMsg(m) catch return;
        return;
    }
    self.diag_list_active = true;
    self.diag_list_sel = 0;
    self.diag_list_top = 0;
}

/// j/k/Enter/Esc while the diagnostics list is open; returns true if
/// consumed.
pub fn diagnosticsListKey(self: *App, key: vaxis.Key) bool {
    switch (key.codepoint) {
        vaxis.Key.escape => {
            self.diag_list_active = false;
            return true;
        },
        'j', vaxis.Key.down => {
            if (self.diag_list_sel + 1 < self.lsp_diagnostics.items.len) self.diag_list_sel += 1;
            return true;
        },
        'k', vaxis.Key.up => {
            if (self.diag_list_sel > 0) self.diag_list_sel -= 1;
            return true;
        },
        vaxis.Key.enter => {
            if (self.diag_list_sel < self.lsp_diagnostics.items.len) {
                const line = self.lsp_diagnostics.items[self.diag_list_sel].range.start.line;
                self.curCursor().* = self.cur().pt.lineStart(@min(line, self.cur().pt.lineCount() - 1));
                self.diag_list_active = false;
            }
            return true;
        },
        else => return false,
    }
}
