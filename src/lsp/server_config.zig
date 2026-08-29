//! LSP server configuration table (DESIGN.md §9.2) — compile-time constants
//! mapping filetypes to server commands. The client spawns these lazily per
//! filetype; a missing binary simply means no LSP (spawn fails → silent
//! degrade, never an error the user must see).

const std = @import("std");

pub const Server = struct {
    /// Filetypes this server serves (matches `filetypeOf` output).
    filetypes: []const []const u8,
    /// Command line (argv[0] and fixed args).
    command: []const []const u8,
    /// LSP `languageId` override for didOpen. null sends the filetype itself;
    /// set it when the server demands the spec-defined id instead — e.g.
    /// rust-analyzer refuses the bare extension "rs" and wants "rust".
    language_id: ?[]const u8 = null,
};

pub const servers = [_]Server{
    .{ .filetypes = &.{"go"}, .command = &.{"gopls"} },
    .{ .filetypes = &.{"lua"}, .command = &.{"lua-language-server"} },
    .{ .filetypes = &.{ "py", "python" }, .command = &.{"pylsp"} },
    .{
        .filetypes = &.{ "ts", "tsx", "js", "jsx", "mjs", "cjs" },
        .command = &.{ "typescript-language-server", "--stdio" },
    },
    .{
        .filetypes = &.{"json"},
        .command = &.{ "vscode-json-languageserver", "--stdio" },
    },
    .{
        .filetypes = &.{ "c", "h", "cc", "cpp", "hpp", "cxx" },
        .command = &.{"clangd"},
    },
    .{ .filetypes = &.{"zig"}, .command = &.{"zls"} },
    .{ .filetypes = &.{ "rs", "rust" }, .command = &.{"rust-analyzer"}, .language_id = "rust" },
};

/// The server command line for a filetype, or null when no server is
/// configured (the client then skips LSP for that filetype entirely).
pub fn commandFor(ft: []const u8) ?[]const []const u8 {
    for (servers) |s| {
        for (s.filetypes) |f| {
            if (std.mem.eql(u8, f, ft)) return s.command;
        }
    }
    return null;
}

/// The LSP `languageId` for a filetype: the server's declared id when one is
/// configured, otherwise the filetype itself (which is what didOpen sent
/// historically, so non-overridden languages are unaffected).
pub fn languageIdFor(ft: []const u8) []const u8 {
    for (servers) |s| {
        for (s.filetypes) |f| {
            if (std.mem.eql(u8, f, ft)) return s.language_id orelse ft;
        }
    }
    return ft;
}

test "server config: filetype to command mapping" {
    try std.testing.expect(commandFor("zig") != null);
    try std.testing.expect(std.mem.eql(u8, commandFor("zig").?[0], "zls"));
    try std.testing.expect(commandFor("go") != null);
    try std.testing.expect(std.mem.eql(u8, commandFor("rs").?[0], "rust-analyzer"));
    try std.testing.expect(commandFor("ts") != null);
    try std.testing.expect(std.mem.eql(u8, commandFor("ts").?[0], "typescript-language-server"));
    try std.testing.expect(commandFor("c") != null);
    try std.testing.expect(commandFor("md") == null);
    try std.testing.expect(commandFor("txt") == null);
    try std.testing.expect(commandFor("") == null);
}

test "server config: filetype to LSP languageId mapping" {
    try std.testing.expectEqualStrings("rust", languageIdFor("rs"));
    try std.testing.expectEqualStrings("rust", languageIdFor("rust"));
    // No override configured: the filetype itself is the languageId.
    try std.testing.expectEqualStrings("zig", languageIdFor("zig"));
    try std.testing.expectEqualStrings("cpp", languageIdFor("cpp"));
    try std.testing.expectEqualStrings("unknown", languageIdFor("unknown"));
}
