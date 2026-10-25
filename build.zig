const std = @import("std");

// oz build: one source tree (src/) with relative imports only — no nested
// oz-* modules (Zig forbids a file belonging to two modules; relative
// imports inside src/ keep every file in exactly one module per binary).
//
//   exe   src/main.zig   vaxis event loop + integration   (zig build / run)
//   test  src/tests.zig  L1 unit + L2 render snapshot      (zig build test)
//   e2e   test/e2e.zig   L3 pty end-to-end                 (zig build e2e)
//
// The test root imports each module file directly so its `test` blocks are
// collected; refAllDecls forces analysis of every public decl.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the installed binaries") orelse false;
    // `-Dtest-filter=NAME` narrows `zig build test` / `zig build e2e` to
    // tests whose name contains NAME (Zig's runner has no runtime filter).
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this string");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    // ---- dependencies ----
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // tree-sitter (C runtime + grammars + treez Zig binding). The treez
    // module links the static library; importers must also link libc.
    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const treez_mod = ts_dep.module("treez");

    // embedded terminal (PTY + VT emulation via vaxis widgets/terminal)
    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/term.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });

    // ---- executable ----
    const exe = b.addExecutable(.{
        .name = "oz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "treez", .module = treez_mod },
                .{ .name = "term", .module = term_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    // ---- mock LSP server (e2e injects it via OZ_LSP_CMD) ----
    const mock = b.addExecutable(.{
        .name = "mock_lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mock_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(mock);

    // ---- run step ----
    const run_step = b.step("run", "Run oz");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // ---- L1 + L2 unit tests ----
    const tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "treez", .module = treez_mod },
                .{ .name = "term", .module = term_mod },
            },
        }),
    });
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    // A test command must execute the test binary, not replay a cached
    // "run" result from an earlier invocation. Without this, `zig build
    // test` can report success without running anything (and
    // `tools/verify.sh` would record no fresh test counts).
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests (L1 logic + L2 render snapshots)");
    test_step.dependOn(&run_tests.step);

    // ---- L3 end-to-end tests (pty) ----
    // The scenario/golden harness imports the pure layout model so tests
    // derive rail geometry from the same source as the renderer instead of
    // duplicating breakpoints.
    const ai_workspace_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/workspace.zig"),
        .target = target,
        .optimize = optimize,
    });
    const e2e = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "ai_workspace", .module = ai_workspace_mod },
            },
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run end-to-end tests (L3, spawn oz in a pty)");
    e2e_step.dependOn(&run_e2e.step);
    // e2e spawns zig-out/bin/oz (path relative to project root, the run cwd)
    run_e2e.step.dependOn(b.getInstallStep());
}
