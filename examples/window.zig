// SPDX-License-Identifier: BSD-2-Clause

//! The whole stack, on a real GPU: a window, a device, and an interface drawn
//! into it every frame.
//!
//! ```bash
//! zig build example-window
//! zig build example-window -- --frames 120
//! ```
//!
//! Everything above this file has been checked without a graphics card - the
//! layout against a monospace measurer, the renderer against the `none`
//! backend that validates every call and draws none of them. This is where
//! that stops being enough: a shader that does not compile, an attribute at
//! the wrong offset and a matrix the wrong way up all pass every test in the
//! library and produce a blank window.
//!
//! So the test at the bottom opens a hidden window, renders one frame into a
//! texture, reads it back, and looks at the pixels. On a machine with no
//! display it skips.

const std = @import("std");
const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");
const font = @import("fluxion_font");
const ui = @import("fluxion_ui");
const render = @import("fluxion_ui_rhi");

const Ui = ui.Ui;

// -------------------------------------------------------------------------
// The interface
// -------------------------------------------------------------------------

const theme = struct {
    const window: ui.Color = .hex(0x14161A);
    const bar: ui.Color = .hex(0x1D2026);
    const sidebar: ui.Color = .hex(0x191C21);
    const card: ui.Color = .hex(0x232830);
    const line: ui.Color = .hex(0x2E343D);
    const hover: ui.Color = .hex(0x2E343D);
    const ink: ui.Color = .hex(0xE8E8EA);
    const accent: ui.Color = .oklch(0.7, 0.14, 250);
};

const body =
    "One instanced draw for the whole frame. Every rectangle, every border " ++
    "and every glyph is the same unit quad under a different set of numbers, " ++
    "and the fragment shader decides what it is looking at. The list on the " ++
    "left scrolls with the wheel, and is clipped by a scissor rectangle that " ++
    "breaks the batch in two.";

fn shell(u: *Ui, size: ui.Dimensions) void {
    u.open(.{
        .id = "window",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = theme.window,
    });
    defer u.close();
    _ = size;

    // Title bar.
    {
        u.open(.{
            .id = "titlebar",
            .width = .grow,
            .height = .fixed(38),
            .padding = .xy(12, 0),
            .gap = 8,
            .align_y = .center,
            .background_color = theme.bar,
            .border = .all(theme.line, 1),
        });
        defer u.close();

        for (0..3) |_| {
            u.empty(.{
                .width = .fixed(11),
                .height = .fixed(11),
                .corner_radius = .all(9999),
                .background_color = theme.accent,
            });
        }
        u.text("Fluxion UI", .{ .font_size = 15, .color = theme.ink });
    }

    // Body.
    {
        u.open(.{ .id = "body", .width = .grow, .height = .grow });
        defer u.close();

        u.open(.{
            .id = "sidebar",
            .width = .fixed(190),
            .height = .grow,
            .padding = .all(10),
            .gap = 6,
            .direction = .top_to_bottom,
            .background_color = theme.sidebar,
        });
        {
            defer u.close();

            // Thirty rows in a box that holds a handful: the whole point of a
            // clip. Without one the rows would be squeezed until they all
            // fitted, and there would be nothing to scroll.
            u.open(.{
                .id = "list",
                .width = .grow,
                .height = .grow,
                .gap = 6,
                .direction = .top_to_bottom,
                .clip = .scrollY,
            });
            defer u.close();

            for (0..30) |i| {
                var label: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&label, "Item {d}", .{i + 1}) catch "Item";

                var name: [24]u8 = undefined;
                const id = std.fmt.bufPrint(&name, "item{d}", .{i}) catch "item";

                // Asked before the element is opened, because the answer is
                // about where it was last frame - which is what an
                // immediate-mode interface always has to work from.
                const lit = u.isPointerOver(id);
                const down = u.isElementPressed(id);

                u.open(.{
                    .id = id,
                    .width = .grow,
                    .height = .fixed(28),
                    .padding = .xy(10, 0),
                    .align_y = .center,
                    .corner_radius = .all(6),
                    .background_color = if (down)
                        theme.accent
                    else if (lit)
                        theme.hover
                    else
                        theme.card,
                });
                defer u.close();
                u.text(text, .{ .font_size = 13, .color = theme.ink });
            }
        }

        u.open(.{
            .id = "content",
            .width = .grow,
            .height = .grow,
            .padding = .all(20),
            .gap = 14,
            .direction = .top_to_bottom,
        });
        {
            defer u.close();

            u.text("One draw call", .{ .font_size = 22, .color = theme.ink });
            u.text(body, .{ .font_size = 13, .color = theme.ink });

            u.open(.{
                .id = "panel",
                .width = .grow,
                .height = .grow,
                .padding = .all(14),
                .corner_radius = .all(10),
                .background_color = theme.card,
                .border = .all(theme.line, 1),
            });
            defer u.close();
            u.text("Rounded corners and this border are the same shader.", .{
                .font_size = 12,
                .color = theme.ink,
            });
        }
    }
}

// -------------------------------------------------------------------------
// A measurer over the font
// -------------------------------------------------------------------------

const Measured = struct {
    face: font.Font,

    fn measure(context: ?*const anyopaque, run: []const u8, style: ui.TextStyle) ui.text.Size {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        const scaled = self.face.at(@floatFromInt(style.font_size));
        return .{ .width = scaled.measure(run) catch 0, .height = scaled.lineHeight() };
    }

    fn lineHeight(context: ?*const anyopaque, style: ui.TextStyle) f32 {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        return self.face.at(@floatFromInt(style.font_size)).lineHeight();
    }

    fn measurer(self: *const Measured) ui.Measurer {
        return .{ .context = self, .measureFn = measure, .lineHeightFn = lineHeight };
    }
};

fn defaultFont() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/segoeui.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
}

// -------------------------------------------------------------------------
// The window
// -------------------------------------------------------------------------

/// A window with an OpenGL context, and the two seams a device wants from
/// one.
///
/// None of this is part of the library. It is `fluxion-platform` doing the
/// work, and what is left here is the shape an example wants: open it, ask it
/// for hooks, pump it until somebody closes it.
const Window = struct {
    /// Boxed, because the hooks below hand a pointer to it across to the
    /// device and it has to stay where it is.
    inner: *Inner,
    /// How far the wheel has turned since this was last asked.
    wheel: f32 = 0,
    /// Where the cursor is, and whether the left button is down.
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    down: bool = false,

    const Inner = struct {
        ctx: platform.Context,
        win: platform.Window,
    };

    fn open(width: u32, height: u32, visible: bool) !Window {
        const gpa = std.heap.smp_allocator;

        const inner = try gpa.create(Inner);
        errdefer gpa.destroy(inner);

        inner.ctx = try platform.Context.init(gpa, .{});
        errdefer inner.ctx.deinit();

        inner.win = try inner.ctx.createWindow(.{
            .title = "Fluxion UI",
            .width = width,
            .height = height,
            .visible = visible,
            .gl = .{ .major = 3, .minor = 3, .profile = .core },
        });
        errdefer inner.win.destroy();

        try inner.win.makeContextCurrent();
        inner.win.setSwapInterval(.vsync) catch {};

        return .{ .inner = inner };
    }

    /// Whether this error is the machine having no display rather than the
    /// program being wrong. A build server gets the first and should skip.
    fn isAbsent(err: anyerror) bool {
        return switch (err) {
            error.Unsupported,
            error.NoDisplay,
            error.ConnectionFailed,
            error.WindowCreationFailed,
            error.Unavailable,
            => true,
            else => false,
        };
    }

    fn close(self: *Window) void {
        self.inner.win.destroy();
        self.inner.ctx.deinit();
        std.heap.smp_allocator.destroy(self.inner);
        self.* = undefined;
    }

    fn size(self: Window) ui.Dimensions {
        const fb = self.inner.win.framebufferSize();
        return .init(@floatFromInt(fb[0]), @floatFromInt(fb[1]));
    }

    /// Drain the events and say whether the window is still there.
    fn pump(self: *Window) bool {
        self.inner.ctx.pump() catch return false;
        while (self.inner.ctx.poll()) |event| switch (event) {
            .close => self.inner.win.setShouldClose(true),
            .key => |k| if (k.key == .escape and k.action == .press) {
                self.inner.win.setShouldClose(true);
            },
            // One notch is one line of a list, near enough. Turning a wheel
            // event into pixels is the program's business, not the layout's.
            .scroll => |w| self.wheel -= @as(f32, @floatCast(w.y)) * 40,
            .cursor => |m| {
                self.pointer_x = @floatCast(m.x);
                self.pointer_y = @floatCast(m.y);
            },
            .mouse_button => |b| if (b.button == .left) {
                self.down = b.action == .press;
            },
            else => {},
        };
        return !self.inner.win.shouldClose();
    }

    fn takeWheel(self: *Window) f32 {
        defer self.wheel = 0;
        return self.wheel;
    }

    fn cursor(self: Window) struct { x: f32, y: f32 } {
        return .{ .x = self.pointer_x, .y = self.pointer_y };
    }

    fn buttonDown(self: Window) bool {
        return self.down;
    }

    /// What the OpenGL backend needs from whoever made the context, which is
    /// never the renderer: four callbacks onto this window.
    fn hooks(self: Window) rhi.GlHooks {
        return .{
            .context = self.inner,
            .get_proc_address = getProcAddress,
            .swap_buffers = swapBuffers,
            .framebuffer_size = framebufferSize,
        };
    }

    fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.types.GlProc {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.getProcAddress(name);
    }

    fn swapBuffers(context: *anyopaque) void {
        const inner: *Inner = @ptrCast(@alignCast(context));
        inner.win.swapBuffers() catch {};
    }

    fn framebufferSize(context: *anyopaque) [2]u32 {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.framebufferSize();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    const arguments = try init.minimal.args.toSlice(gpa);
    var frames: ?u32 = null;
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        if (std.mem.eql(u8, arguments[i], "--frames") and i + 1 < arguments.len) {
            i += 1;
            frames = std.fmt.parseInt(u32, arguments[i], 10) catch null;
        }
    }

    var out_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const w = &stdout.interface;

    var window = Window.open(1100, 680, true) catch |err| {
        try w.print("no window: {s}\n", .{@errorName(err)});
        try w.flush();
        return;
    };
    defer window.close();

    var device: rhi.Device = try .init(gpa, .{ .gl = window.hooks() });
    defer device.deinit();
    try w.print("{f}\n", .{device.info()});
    try w.flush();

    const surface = try device.createSurface(.{});
    defer device.destroySurface(surface);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, defaultFont(), gpa, .limited(32 << 20));
    var measured: Measured = .{ .face = try .init(bytes) };

    var renderer: render.Renderer = try .init(gpa, &device, &measured.face);
    defer renderer.deinit();

    var layout: Ui = .init(gpa);
    defer layout.deinit();
    layout.setMeasurer(measured.measurer());

    var drawn: u32 = 0;
    while (window.pump()) {
        const size = window.size();

        // The wheel moves the list, and the layout clamps it at either end
        // when the frame finishes. A program with a pointer under the cursor
        // would ask which container is under it; this one has only the one.
        const wheel = window.takeWheel();
        if (wheel != 0) layout.scrollBy("list", 0, wheel);

        // Before `begin`, once a frame. It advances the button through its
        // four states and works out what is under the cursor from where
        // things were when the last frame finished.
        const cursor = window.cursor();
        layout.setPointer(cursor.x, cursor.y, window.buttonDown());

        layout.begin(size);
        shell(&layout, size);
        const commands = try layout.end();

        try renderer.draw(.{ .surface = surface }, size, commands, theme.window);
        try device.present(surface);

        // Say once what there is to scroll through, so a run with `--frames`
        // leaves something behind to read.
        if (drawn == 0) {
            if (layout.scrollOf("list")) |scroll| {
                try w.print("list: {d:.0} of {d:.0} pixels visible\n", .{
                    scroll.viewport.height,
                    scroll.content.height,
                });
                try w.flush();
            }
        }

        drawn += 1;
        if (frames) |limit| {
            if (drawn >= limit) break;
        }
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn systemFont(gpa: std.mem.Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/consola.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch continue;
    }
    return null;
}

test "the shaders compile and the frame reaches the pixels" {
    // The one test in the ecosystem that needs a graphics driver. A shader
    // that does not compile, an attribute at the wrong offset and a viewport
    // the wrong way up all pass every other test and produce a blank window;
    // this is what catches them.
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var window = Window.open(64, 64, false) catch |err|
        if (Window.isAbsent(err)) return error.SkipZigTest else return err;
    defer window.close();

    var device: rhi.Device = rhi.Device.init(testing.allocator, .{ .gl = window.hooks() }) catch
        return error.SkipZigTest;
    defer device.deinit();

    // Into a texture rather than the window, so the pixels can be read back.
    const target = try device.createTexture(.{
        .width = 128,
        .height = 128,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer device.destroyTexture(target);

    var measured: Measured = .{ .face = try .init(bytes) };
    var renderer: render.Renderer = try .init(testing.allocator, &device, &measured.face);
    defer renderer.deinit();

    const size: ui.Dimensions = .init(128, 128);

    var layout: Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(measured.measurer());

    layout.begin(size);
    {
        layout.open(.{ .width = .grow, .height = .grow, .padding = .all(24) });
        defer layout.close();
        // One white square in the middle of a black frame.
        layout.empty(.{ .width = .grow, .height = .grow, .background_color = .white });
    }
    const commands = try layout.end();

    try renderer.draw(.{ .texture = target }, size, commands, .black);

    const pixels = try device.readTexture(target, testing.allocator);
    defer testing.allocator.free(pixels);
    try testing.expectEqual(128 * 128 * 4, pixels.len);

    const at = struct {
        fn red(data: []const u8, x: usize, y: usize) u8 {
            return data[(y * 128 + x) * 4];
        }
    }.red;

    // The middle is the white square and the corner is the clear colour.
    // Both wrong means the shader did not run; one wrong means it ran upside
    // down or at the wrong scale.
    try testing.expect(at(pixels, 64, 64) > 200);
    try testing.expect(at(pixels, 2, 2) < 50);
    try testing.expect(at(pixels, 126, 126) < 50);

    // And the edge of the square is where the padding put it.
    try testing.expect(at(pixels, 30, 64) > 200);
    try testing.expect(at(pixels, 10, 64) < 50);
}

test "text reaches the pixels too" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var window = Window.open(64, 64, false) catch |err|
        if (Window.isAbsent(err)) return error.SkipZigTest else return err;
    defer window.close();

    var device: rhi.Device = rhi.Device.init(testing.allocator, .{ .gl = window.hooks() }) catch
        return error.SkipZigTest;
    defer device.deinit();

    const target = try device.createTexture(.{
        .width = 256,
        .height = 64,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer device.destroyTexture(target);

    var measured: Measured = .{ .face = try .init(bytes) };
    var renderer: render.Renderer = try .init(testing.allocator, &device, &measured.face);
    defer renderer.deinit();

    const size: ui.Dimensions = .init(256, 64);

    var layout: Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(measured.measurer());

    layout.begin(size);
    {
        layout.open(.{ .width = .grow, .height = .grow, .padding = .all(8) });
        defer layout.close();
        layout.text("HHHHHHHH", .{ .font_size = 32, .color = .white });
    }
    const commands = try layout.end();

    try renderer.draw(.{ .texture = target }, size, commands, .black);

    const pixels = try device.readTexture(target, testing.allocator);
    defer testing.allocator.free(pixels);

    // Some of it is ink and most of it is not, which is what a line of text
    // looks like. A glyph atlas bound wrong gives either nothing or a solid
    // block, and both are caught here.
    var lit: usize = 0;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (pixels[i] > 128) lit += 1;
    }
    try testing.expect(lit > 200);
    try testing.expect(lit < 256 * 64 / 2);
}
