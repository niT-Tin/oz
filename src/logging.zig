//! Log filtering for the executable.
//!
//! oz owns the terminal screen while it runs, so anything written to stderr
//! lands in the TUI. The vendored vaxis terminal widget logs shell
//! integration traffic at info/warn/err through its own scopes:
//!
//!   .terminal        `unhandled osc: 133;B`, `unhandled OSC 7`, `unhandled CSI`
//!   .vaxis_terminal  `couldn't write uri` / `couldn't write uri_id`
//!   .vaxis_parser    input parser warnings (unhandled SS3 …)
//!
//! Those are diagnostic for vaxis developers, not user-facing: a normal
//! `Alt+r` shell session flooded the editor with thousands of log lines.
//! Suppress those scopes completely (including `.err`: OSC 7 is logged with
//! `log.err` inside vaxis) and leave every other scope on the default
//! stderr path. `main.zig` installs this as `std_options.logFn`; the scope
//! levels there still silence vaxis's per-frame `.vaxis` info logs.
const std = @import("std");

/// True for scopes whose messages must never be written to the pty. Kept
/// comptime so `logFn` compiles the check away per call site.
pub fn quiet(comptime scope: @EnumLiteral()) bool {
    return scope == .terminal or scope == .vaxis_terminal or scope == .vaxis_parser;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime quiet(scope)) return;
    std.log.defaultLog(level, scope, format, args);
}

test "logging: terminal widget scopes are fully quiet, app scopes are not" {
    try std.testing.expect(quiet(.terminal));
    try std.testing.expect(quiet(.vaxis_terminal));
    try std.testing.expect(quiet(.vaxis_parser));
    // vaxis core errors still reach stderr (the global scope level keeps
    // them at .err), and app-scope logs are untouched.
    try std.testing.expect(!quiet(.vaxis));
    try std.testing.expect(!quiet(.default));
    try std.testing.expect(!quiet(.lsp));
}
