// SPDX-License-Identifier: BSD-2-Clause

//! An application shell - title bar, sidebar, content, status bar - laid out
//! and printed as the list of things a renderer would draw.
//!
//! There is no window and no GPU here, and that is the point being made: a
//! layout is arithmetic, and the list it produces is the whole of what a
//! renderer needs. The same declaration below, handed to the RHI backend,
//! draws the same boxes on a real surface.
//!
//! It is also how the layout is checked without a display. The test at the
//! bottom builds this exact shell and asserts where the panes ended up, which
//! is a thing that runs on a build server.

const std = @import("std");
const ui_lib = @import("fluxion_ui");

const Ui = ui_lib.Ui;

/// A dark theme, in the hex a designer would hand over.
const theme = struct {
    const window: ui_lib.Color = .hex(0x14161A);
    const bar: ui_lib.Color = .hex(0x1D2026);
    const sidebar: ui_lib.Color = .hex(0x191C21);
    const content: ui_lib.Color = .hex(0x101216);
    const card: ui_lib.Color = .hex(0x232830);
    const accent: ui_lib.Color = .oklch(0.7, 0.14, 250);
    const line: ui_lib.Color = .hex(0x2E343D);
};

/// Declare the shell. Separated from `main` so the test below can build the
/// same tree without printing anything.
fn shell(ui: *Ui, cards: usize) void {
    ui.open(.{
        .id = "window",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = theme.window,
    });
    defer ui.close();

    // The title bar: a fixed height across the whole width.
    {
        ui.open(.{
            .id = "titlebar",
            .width = .grow,
            .height = .fixed(40),
            .padding = .xy(12, 0),
            .gap = 8,
            .align_y = .center,
            .background_color = theme.bar,
            .border = .all(theme.line, 1),
        });
        defer ui.close();

        // Three round dots, as every title bar has.
        for (0..3) |_| {
            ui.empty(.{
                .width = .fixed(12),
                .height = .fixed(12),
                .corner_radius = .all(9999), // clamped to a circle
                .background_color = theme.accent,
            });
        }
    }

    // The body: a fixed sidebar and everything else.
    {
        ui.open(.{ .id = "body", .width = .grow, .height = .grow });
        defer ui.close();

        ui.open(.{
            .id = "sidebar",
            .width = .fixed(220),
            .height = .grow,
            .padding = .all(12),
            .gap = 6,
            .direction = .top_to_bottom,
            .background_color = theme.sidebar,
        });
        {
            defer ui.close();
            for (0..4) |_| {
                ui.empty(.{
                    .width = .grow,
                    .height = .fixed(32),
                    .corner_radius = .all(6),
                    .background_color = theme.card,
                });
            }
        }

        // The content, with a row of cards that share the width unevenly.
        ui.open(.{
            .id = "content",
            .width = .grow,
            .height = .grow,
            .padding = .all(20),
            .gap = 16,
            .background_color = theme.content,
        });
        {
            defer ui.close();
            for (0..cards) |i| {
                ui.empty(.{
                    // The first card is twice the share of the others, which
                    // is what grow weights are for: no arithmetic here knows
                    // how wide the content pane is.
                    .width = if (i == 0) .growWeighted(2) else .grow,
                    .height = .grow,
                    .corner_radius = .all(10),
                    .background_color = theme.card,
                    .border = .all(theme.line, 1),
                });
            }
        }
    }

    // The status bar.
    ui.empty(.{
        .id = "statusbar",
        .width = .grow,
        .height = .fixed(24),
        .background_color = theme.bar,
    });
}

pub fn main(init: std.process.Init) !void {
    var ui: Ui = .init(init.arena.allocator());
    defer ui.deinit();

    var out_buffer: [8192]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const w = &stdout.interface;

    ui.begin(.init(1280, 720));
    shell(&ui, 3);
    const drawn = try ui.end();

    try w.print("1280x720, {d} commands\n\n", .{drawn.len});
    for (drawn) |command| try w.print("  {f}\n", .{command});

    try w.print("\nthe panes:\n", .{});
    for ([_][]const u8{ "titlebar", "sidebar", "content", "statusbar" }) |name| {
        try w.print("  {s:<10} {f}\n", .{ name, ui.boxOf(name).? });
    }
    try w.flush();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the shell adds up: the panes tile the window with no gaps or overlaps" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1280, 720));
    shell(&ui, 3);
    _ = try ui.end();

    const titlebar = ui.boxOf("titlebar").?;
    const body = ui.boxOf("body").?;
    const status = ui.boxOf("statusbar").?;

    // Full width each, stacked with nothing between them and nothing left
    // over - which is the arithmetic a hand-written layout gets wrong first.
    try testing.expectEqual(@as(f32, 1280), titlebar.width);
    try testing.expectEqual(@as(f32, 40), titlebar.height);
    try testing.expectEqual(titlebar.bottom(), body.y);
    try testing.expectEqual(body.bottom(), status.y);
    try testing.expectEqual(@as(f32, 720), status.bottom());
    try testing.expectEqual(@as(f32, 720 - 40 - 24), body.height);
}

test "the sidebar keeps its width and the content takes the rest" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1280, 720));
    shell(&ui, 3);
    _ = try ui.end();

    const sidebar = ui.boxOf("sidebar").?;
    const content = ui.boxOf("content").?;

    try testing.expectEqual(@as(f32, 220), sidebar.width);
    try testing.expectEqual(@as(f32, 1280 - 220), content.width);
    try testing.expectEqual(sidebar.right(), content.x);
}

test "the first card is twice the share of the others" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1280, 720));
    shell(&ui, 3);
    const drawn = try ui.end();

    // The cards are the anonymous children of the content pane, so find them
    // by shape rather than by name: full-height boxes inside it.
    const content = ui.boxOf("content").?;
    var widths: [8]f32 = undefined;
    var found: usize = 0;
    for (drawn) |command| {
        if (command.config != .rectangle) continue;
        const b = command.bounding_box;
        if (b.x < content.x or b.right() > content.right() + 0.01) continue;
        if (b.y < content.y + 19 or b.height < content.height - 41) continue;
        if (found < widths.len) {
            widths[found] = b.width;
            found += 1;
        }
    }

    try testing.expectEqual(3, found);
    // Weighted two to one to one, so the first is twice either of the others.
    try testing.expectApproxEqAbs(widths[0], widths[1] * 2, 0.5);
    try testing.expectApproxEqAbs(widths[1], widths[2], 0.5);
}

test "the window resizing moves everything and breaks nothing" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    for ([_]ui_lib.Dimensions{ .init(1280, 720), .init(640, 480), .init(3840, 2160) }) |size| {
        ui.begin(.{ .size = size });
        shell(&ui, 3);
        _ = try ui.end();

        const status = ui.boxOf("statusbar").?;
        try testing.expectEqual(size.width, status.width);
        try testing.expectEqual(size.height, status.bottom());

        // The sidebar is fixed, so it does not move with the window.
        try testing.expectEqual(@as(f32, 220), ui.boxOf("sidebar").?.width);
    }
}

test "a card count of zero is a layout, not a crash" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1280, 720));
    shell(&ui, 0);
    _ = try ui.end();

    // The content pane is still there and still the right size; there is
    // simply nothing in it.
    try testing.expectEqual(@as(f32, 1060), ui.boxOf("content").?.width);
}
