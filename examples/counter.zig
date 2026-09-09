// SPDX-License-Identifier: BSD-2-Clause

//! A number and two buttons, in a window, clicked with the mouse.
//!
//! ```bash
//! zig build example-counter
//! zig build example-counter -- --frames 120
//! ```
//!
//! Escape closes it. The interface is the two functions at the top. What is
//! added below them is the plumbing every windowed program has: a
//! window from fluxion-platform, a device from fluxion-rhi, a font from
//! fluxion-font and the ready-made renderer in `fluxion_ui_rhi`, and a loop
//! that feeds the mouse in and the command list out, once a frame.

const std = @import("std");
const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");
const font = @import("fluxion_font");
const ui_lib = @import("fluxion_ui");
const render = @import("fluxion_ui_rhi");

const Ui = ui_lib.Ui;

// -------------------------------------------------------------------------
// The interface
// -------------------------------------------------------------------------

const theme = struct {
    const window: ui_lib.Color = .hex(0x14161A);
    const card: ui_lib.Color = .hex(0x232830);
    const button: ui_lib.Color = .hex(0x2E343D);
    const hover: ui_lib.Color = .hex(0x3A4250);
    const pressed: ui_lib.Color = .oklch(0.7, 0.14, 250);
    const ink: ui_lib.Color = .hex(0xE8E8EA);
};

/// A button with a label. True on the frame the mouse is released on it.
fn button(ui: *Ui, id: []const u8, label: []const u8) bool {
    // Asked before `open`: the colour goes into the declaration, and it comes
    // from where the boxes were last frame.
    const lit = ui.isPointerOver(id);
    const down = ui.isElementPressed(id);

    ui.open(.{
        .id = id,
        .width = .fixed(44),
        .height = .fixed(44),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(8),
        .background_color = if (down) theme.pressed else if (lit) theme.hover else theme.button,
    });
    defer ui.close();

    ui.text(label, .{ .font_size = 20, .color = theme.ink });
    return ui.justReleased();
}

/// The whole interface. Returns how much the count should change by.
fn counter(ui: *Ui, count: i32) i32 {
    var delta: i32 = 0;

    ui.open(.{
        .width = .grow,
        .height = .grow,
        .align_x = .center,
        .align_y = .center,
        .background_color = theme.window,
    });
    defer ui.close();

    ui.open(.{
        .width = .fit,
        .height = .fit,
        .padding = .all(24),
        .gap = 16,
        .direction = .top_to_bottom,
        .align_x = .center,
        .corner_radius = .all(12),
        .background_color = theme.card,
    });
    defer ui.close();

    ui.text("Counter", .{ .font_size = 14, .color = theme.ink });

    var digits: [16]u8 = undefined;
    ui.text(std.fmt.bufPrint(&digits, "{d}", .{count}) catch "?", .{ .font_size = 48, .color = theme.ink });

    ui.open(.{ .width = .fit, .height = .fit, .gap = 12 });
    defer ui.close();
    if (button(ui, "minus", "-")) delta -= 1;
    if (button(ui, "plus", "+")) delta += 1;

    return delta;
}

// -------------------------------------------------------------------------
// The plumbing
// -------------------------------------------------------------------------

/// How the layout asks the font how wide a run of text is.
const Measured = struct {
    face: font.Font,

    fn measure(context: ?*const anyopaque, run: []const u8, style: ui_lib.TextStyle) ui_lib.text.Size {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        const scaled = self.face.at(@floatFromInt(style.font_size));
        return .{ .width = scaled.measure(run) catch 0, .height = scaled.lineHeight() };
    }

    fn lineHeight(context: ?*const anyopaque, style: ui_lib.TextStyle) f32 {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        return self.face.at(@floatFromInt(style.font_size)).lineHeight();
    }
};

/// What the OpenGL backend needs from the window: three callbacks onto it.
fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.types.GlProc {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    return win.getProcAddress(name);
}

fn swapBuffers(context: *anyopaque) void {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    win.swapBuffers() catch {};
}

fn framebufferSize(context: *anyopaque) [2]u32 {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    return win.framebufferSize();
}

const font_path = switch (@import("builtin").os.tag) {
    .windows => "C:/Windows/Fonts/segoeui.ttf",
    .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
    else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    // `--frames N` stops after N frames, so the build can run it unattended.
    const arguments = try init.minimal.args.toSlice(gpa);
    var frames: ?u32 = null;
    for (arguments[1..], 1..) |argument, i| {
        if (std.mem.eql(u8, argument, "--frames") and i + 1 < arguments.len) {
            frames = std.fmt.parseInt(u32, arguments[i + 1], 10) catch null;
        }
    }

    // The window, with an OpenGL context.
    var ctx = try platform.Context.init(std.heap.smp_allocator, .{});
    defer ctx.deinit();
    var win = try ctx.createWindow(.{
        .title = "Fluxion UI - counter",
        .width = 480,
        .height = 320,
        .gl = .{ .major = 3, .minor = 3, .profile = .core },
    });
    defer win.destroy();
    try win.makeContextCurrent();
    win.setSwapInterval(.vsync) catch {};

    // The device on it, and the surface it presents to.
    var device: rhi.Device = try .init(gpa, .{ .backend = .gl, .gl = .{
        .context = &win,
        .get_proc_address = getProcAddress,
        .swap_buffers = swapBuffers,
        .framebuffer_size = framebufferSize,
    } });
    defer device.deinit();
    const fb = win.framebufferSize();
    const surface = try device.createSurface(.{ .native_window = win.native(), .width = fb[0], .height = fb[1] });
    defer device.destroySurface(surface);

    // The font, the renderer that draws with it, and the layout that measures with it.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, font_path, gpa, .limited(32 << 20));
    var measured: Measured = .{ .face = try .init(bytes) };
    var renderer: render.Renderer = try .init(gpa, &device, &measured.face);
    defer renderer.deinit();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.{ .context = &measured, .measureFn = Measured.measure, .lineHeightFn = Measured.lineHeight });

    var count: i32 = 0;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down = false;
    var drawn: u32 = 0;

    while (!win.shouldClose()) {
        // Events in.
        try ctx.pump();
        while (ctx.poll()) |event| switch (event) {
            .close => win.setShouldClose(true),
            .key => |k| if (k.key == .escape and k.action == .press) win.setShouldClose(true),
            .cursor => |m| {
                mouse_x = @floatCast(m.x);
                mouse_y = @floatCast(m.y);
            },
            .mouse_button => |b| if (b.button == .left) {
                mouse_down = b.action == .press;
            },
            else => {},
        };

        // One frame: the mouse goes in before `begin`, the commands come out of `end`.
        const size_fb = win.framebufferSize();
        const size: ui_lib.Dimensions = .init(@floatFromInt(size_fb[0]), @floatFromInt(size_fb[1]));
        ui.setPointer(mouse_x, mouse_y, mouse_down);
        ui.tick(1.0 / 60.0);
        ui.begin(size);
        count += counter(&ui, count);
        const commands = try ui.end();

        // Pixels out.
        try renderer.draw(.{ .surface = surface }, size, commands, theme.window);
        try device.present(surface);

        drawn += 1;
        if (frames) |limit| if (drawn >= limit) break;
    }
}
