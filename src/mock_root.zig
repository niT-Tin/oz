//! Build root for the mock LSP server executable. The module root must sit
//! in src/ so lsp/mock_lsp.zig's relative imports of util/ stay inside the
//! module path; the actual logic lives in lsp/mock_lsp.zig.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    return @import("lsp/mock_lsp.zig").main(init);
}
