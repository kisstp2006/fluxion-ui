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

    // -------------------------------------------------------------------
    // The optional renderer
    // -------------------------------------------------------------------

    // A second module, and not part of the first. The library's output is a
    // command list and something else draws it; this is that something else
    // for programs that want one ready-made. Consumers do:
    //   const render = @import("fluxion_ui_rhi");
    //
    // Both its dependencies are lazy, so a program that only lays out - or
    // that brings its own renderer - fetches neither.
    const rhi_dep = b.lazyDependency("fluxion_rhi", .{ .target = target, .optimize = optimize });
    const font_for_render = b.lazyDependency("fluxion_font", .{ .target = target, .optimize = optimize });

    const render_mod: ?*std.Build.Module = if (rhi_dep != null and font_for_render != null)
        b.addModule("fluxion_ui_rhi", .{
            .root_source_file = b.path("src/render/rhi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_ui", .module = mod },
                .{ .name = "fluxion_rhi", .module = rhi_dep.?.module("fluxion_rhi") },
                .{ .name = "fluxion_font", .module = font_for_render.?.module("fluxion_font") },
            },
        })
    else
        null;

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-ui-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // The renderer carries its own, and they run against the `none` backend -
    // which accepts every call and draws nothing, so the instances and the
    // scissor batches can be checked on a machine with no GPU.
    if (render_mod) |render| {
        const render_tests = b.addTest(.{
            .name = "fluxion-ui-rhi-tests",
            .root_module = render,
        });
        test_step.dependOn(&b.addRunArtifact(render_tests).step);
    }

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
        /// Whether it measures text with a real font, and so needs
        /// fluxion-font fetched.
        needs_font: bool = false,
        /// Whether it opens a window and draws on a real GPU, and so needs
        /// fluxion-platform, fluxion-rhi and the renderer module too.
        needs_window: bool = false,
    }{
        .{
            .name = "counter",
            .step = "example-counter",
            .about = "A number and two buttons, in a window, clicked with the mouse",
            .needs_font = true,
            .needs_window = true,
        },
        .{
            .name = "shell",
            .step = "example",
            .about = "An application shell, laid out and printed as draw commands",
        },
        .{
            .name = "prose",
            .step = "example-prose",
            .about = "A paragraph measured with a real font, wrapped, and drawn as characters",
            .needs_font = true,
        },
        .{
            .name = "window",
            .step = "example-window",
            .about = "The whole stack on a real GPU: a window, a device, and an interface",
            .needs_font = true,
            .needs_window = true,
        },
    };

    // Already asked for above, and null on the first run after a clean
    // checkout while the build runner fetches it.
    const font_dep = font_for_render;

    const platform_dep = b.lazyDependency("fluxion_platform", .{
        .target = target,
        .optimize = optimize,
    });

    for (examples) |example| {
        if (example.needs_font and font_dep == null) continue;
        // An example that draws on a GPU needs three more packages, and a
        // clean checkout has none of them on the first run - the build runner
        // fetches them and starts again.
        if (example.needs_window and (platform_dep == null or rhi_dep == null or render_mod == null)) {
            continue;
        }

        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.append(b.allocator, .{ .name = "fluxion_ui", .module = mod }) catch @panic("OOM");
        if (example.needs_font) {
            imports.append(b.allocator, .{
                .name = "fluxion_font",
                .module = font_dep.?.module("fluxion_font"),
            }) catch @panic("OOM");
        }
        if (example.needs_window) {
            imports.append(b.allocator, .{
                .name = "fluxion_platform",
                .module = platform_dep.?.module("fluxion_platform"),
            }) catch @panic("OOM");
            imports.append(b.allocator, .{
                .name = "fluxion_rhi",
                .module = rhi_dep.?.module("fluxion_rhi"),
            }) catch @panic("OOM");
            imports.append(b.allocator, .{
                .name = "fluxion_ui_rhi",
                .module = render_mod.?,
            }) catch @panic("OOM");
        }

        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
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
