//! dashboard — App method group split out of src/main.zig (physical move).

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("../app.zig");
const App = app_mod.App;

// ---- dashboard ----

pub fn isDashboard(self: *App) bool {
    return self.cur().path == null and self.cur().pt.len() == 0 and
        self.state.mode == .normal and !self.picker_active and !self.em_active;
}

/// j/k/Enter for the recent-files list; returns true if consumed.
pub fn dashboardKey(self: *App, key: vaxis.Key) !bool {
    switch (key.codepoint) {
        'j' => {
            if (self.recent_sel + 1 < self.recent_files.items.len) self.recent_sel += 1;
            return true;
        },
        'k' => {
            if (self.recent_sel > 0) self.recent_sel -= 1;
            return true;
        },
        vaxis.Key.enter => {
            if (self.recent_files.items.len > 0) {
                try self.openFile(self.recent_files.items[self.recent_sel]);
                self.recent_sel = 0;
            }
            return true;
        },
        else => return false,
    }
}

pub fn addRecent(self: *App, path: []const u8) !void {
    for (self.recent_files.items, 0..) |f, i| {
        if (std.mem.eql(u8, f, path)) {
            self.alloc.free(self.recent_files.orderedRemove(i));
            break;
        }
    }
    const copy = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(copy);
    try self.recent_files.insert(self.alloc, 0, copy);
    while (self.recent_files.items.len > 10) {
        if (self.recent_files.pop()) |f| self.alloc.free(f);
    }
}
