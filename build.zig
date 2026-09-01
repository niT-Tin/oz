const std = @import("std");

// oz build: one source tree (src/) with relative imports only — no nested
// oz-* modules (Zig 0.16 forbids a file belonging to two modules; relative
// imports inside src/ keep every file in exactly one module per binary).
//
//   exe   src/main.zig   vaxis event loop + integration   (zig build / run)
//   test  src/tests.zig  L1 unit + L2 render snapshot      (zig build test)
//   e2e   test/e2e.zig   L3 pty end-to-end                 (zig build e2e)
//
// The test root imports each module file directly so its `test` blocks are
// collected; refAllDecls forces analysis of every public decl.

/// Overwrite a vendored dependency file with the patched copy from
/// patches/ when they differ. zig-pkg/ is a gitignored dependency cache
/// (re-fetched on fresh checkouts), so the vaxis terminal-widget fixes
/// (Zig 0.16 ioctl constants, SIGCHLD map lifecycle, copyTo scrollback
/// bounds, non-blocking event pushes, teardown drain) must be re-applied
/// on every build. Idempotent: an already-patched tree is left alone.
fn applyVaxisPatch(b: *std.Build) void {
    const fixes = [_]struct { target: []const u8, patch: []const u8 }{
        .{
            .target = "zig-pkg/vaxis-0.6.0-BWNV_ALfCQCcOilT8JtOaYa4gzMl_9oApKk0HfxNFo5Z/src/widgets/terminal/Pty.zig",
            .patch = "patches/vaxis-Pty.zig",
        },
        .{
            .target = "zig-pkg/vaxis-0.6.0-BWNV_ALfCQCcOilT8JtOaYa4gzMl_9oApKk0HfxNFo5Z/src/widgets/terminal/Command.zig",
            .patch = "patches/vaxis-Command.zig",
        },
        .{
            .target = "zig-pkg/vaxis-0.6.0-BWNV_ALfCQCcOilT8JtOaYa4gzMl_9oApKk0HfxNFo5Z/src/widgets/terminal/Screen.zig",
            .patch = "patches/vaxis-Screen.zig",
        },
        .{
            .target = "zig-pkg/vaxis-0.6.0-BWNV_ALfCQCcOilT8JtOaYa4gzMl_9oApKk0HfxNFo5Z/src/widgets/terminal/Terminal.zig",
            .patch = "patches/vaxis-Terminal.zig",
        },
    };
    const io = b.graph.io;
    const dir = std.Io.Dir.cwd();
    for (fixes) |fix| {
        const target_path = b.pathFromRoot(fix.target);
        const patch_path = b.pathFromRoot(fix.patch);
        const patched = dir.readFileAlloc(io, patch_path, b.allocator, @enumFromInt(1 << 20)) catch |e| {
            std.debug.print("oz: cannot read patch {s}: {s}\n", .{ fix.patch, @errorName(e) });
            std.process.exit(1);
        };
        defer b.allocator.free(patched);
        const current = dir.readFileAlloc(io, target_path, b.allocator, @enumFromInt(1 << 20)) catch {
            // target missing (dependency not fetched yet — the build will
            // fail later with a clearer error); nothing to patch
            continue;
        };
        defer b.allocator.free(current);
        if (!std.mem.eql(u8, current, patched)) {
            dir.writeFile(io, .{ .sub_path = target_path, .data = patched }) catch |e| {
                std.debug.print("oz: cannot apply {s} to {s}: {s}\n", .{ fix.patch, fix.target, @errorName(e) });
                std.process.exit(1);
            };
            std.debug.print("oz: applied {s} -> {s}\n", .{ fix.patch, fix.target });
        }
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the installed binaries") orelse false;
    // re-apply the vendored vaxis terminal-widget fixes before compiling
    applyVaxisPatch(b);

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
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---- L1 + L2 unit tests ----
    const tests = b.addTest(.{
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
    const test_step = b.step("test", "Run unit tests (L1 logic + L2 render snapshots)");
    test_step.dependOn(&run_tests.step);

    // ---- L3 end-to-end tests (pty) ----
    const e2e = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    const e2e_step = b.step("e2e", "Run end-to-end tests (L3, spawn oz in a pty)");
    e2e_step.dependOn(&run_e2e.step);
    // e2e spawns zig-out/bin/oz (path relative to project root, the run cwd)
    run_e2e.step.dependOn(b.getInstallStep());
}
