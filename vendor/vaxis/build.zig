const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend for compile steps") orelse true;
    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    });
    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
            "is_emoji_vs_base",
            "is_emoji_modifier_base",
            "case_folding_simple",
            "simple_uppercase_mapping",
            "simple_lowercase_mapping",
            "is_lowercase",
            "changes_when_casefolded",
            "changes_when_lowercased",
        }),
    });

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    vaxis_mod.addImport("uucode", uucode_dep.module("uucode"));

    // Examples
    const Example = enum {
        cli,
        counter,
        fuzzy,
        image,
        main,
        scroll,
        split_view,
        table,
        text_input,
        text_view,
        list_view,
        vaxis,
        view,
        vt,
    };
    var examples: std.EnumMap(Example, *std.Build.Module) = .init(.{});
    inline for (@typeInfo(Example).@"enum".field_values) |value| {
        const example: Example = @enumFromInt(value);
        examples.put(
            example,
            b.createModule(.{
                .root_source_file = b.path(
                    b.fmt("examples/{t}.zig", .{example}),
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "vaxis", .module = vaxis_mod },
                },
            }),
        );
    }
    const example_option = b.option(Example, "example", "Example to run (default: text_input)") orelse .text_input;
    const example_step = b.step("example", "Run example");
    const example = b.addExecutable(.{
        .name = b.fmt("example-{t}", .{example_option}),
        .root_module = examples.get(example_option) orelse unreachable,
        .use_llvm = use_llvm,
    });

    b.getInstallStep().dependOn(&example.step);

    const example_run = b.addRunArtifact(example);
    example_step.dependOn(&example_run.step);

    // Benchmarks
    const bench_step = b.step("bench", "Run benchmarks");
    const bench = b.addExecutable(.{
        .name = "bench",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    bench_step.dependOn(&bench_run.step);

    // Tests
    const tests_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
                .{ .name = "uucode", .module = uucode_dep.module("uucode") },
            },
        }),
    });

    // Let's make sure that all of the examples compile and can run any tests
    // that they may have defined.
    var it = examples.iterator();
    while (it.next()) |v| {
        const e = b.addTest(.{
            .use_llvm = use_llvm,
            .root_module = v.value.*,
        });
        const r = b.addRunArtifact(e);
        tests_step.dependOn(&r.step);
    }

    const tests_run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    tests_step.dependOn(&tests_run.step);

    // Docs
    const docs_step = b.step("docs", "Build the vaxis library docs");
    const docs_obj = b.addObject(.{
        .name = "vaxis",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
