// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fluxion-math: `Vec2`, and nothing else yet. A layout is arithmetic, and
    // this is the package whose job that is.
    const math = b.dependency("fluxion_math", .{
        .target = target,
        .optimize = optimize,
    });

    // The importable module. Consumers do:
    //   const ui = @import("fluxion_ui");
    //
    // There is no renderer in here and there will not be. What comes out of a
    // frame is a list of `commands.RenderCommand`, and what draws them is
    // somebody else - see the README.
    const mod = b.addModule("fluxion_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-ui-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-ui",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // Nothing here opens a window, so nothing here is lazy and nothing is
    // skipped when cross-compiling: an example that prints its layout runs
    // wherever the tests do. That changes when the RHI backend arrives, and
    // its example will be gated the way the other packages gate theirs.
    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
    }{
        .{
            .name = "shell",
            .step = "example",
            .about = "An application shell, laid out and printed as draw commands",
        },
    };

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_ui", .module = mod }},
        });

        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-ui-{s}", .{example.name}),
            .root_module = example_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);

        // The examples carry their own tests, and they run with the
        // library's: a layout nobody has checked the numbers of is a guess.
        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-ui-{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
