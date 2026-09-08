// SPDX-License-Identifier: BSD-2-Clause

//! A paragraph measured with a real font, wrapped by the layout, and drawn as
//! characters.
//!
//! ```bash
//! zig build example-prose
//! zig build example-prose -- C:/Windows/Fonts/segoeui.ttf 60
//! ```
//!
//! This is the one example where the whole stack is present at once:
//! [Fluxion Font](https://github.com/kisstp2006/fluxion-font) says how wide
//! each word is, `Ui` decides where the lines break and where every box goes,
//! and the twenty lines at the bottom of this file turn the command list into
//! pixels. There is no GPU, no window, and no PNG - a terminal is a grid of
//! characters and a rasterised glyph is a grid of coverage, so one can be
//! printed against the other.
//!
//! **The adapter is the point.** `Measured` below is fifteen lines, and it is
//! the whole of what connects a font library to a layout engine that has
//! never heard of one. Anything else that can answer "how wide is this run"
//! goes in the same slot - a bitmap font, a table of widths, the monospace
//! measurer the tests use.

const std = @import("std");
const ui = @import("fluxion_ui");
const font = @import("fluxion_font");

const Ui = ui.Ui;

// -------------------------------------------------------------------------
// The adapter
// -------------------------------------------------------------------------

/// A `text.Measurer` backed by a real font.
const Measured = struct {
    face: font.Font,

    fn measure(context: ?*const anyopaque, run: []const u8, style: ui.TextStyle) ui.text.Size {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        const scaled = self.face.at(@floatFromInt(style.font_size));
        return .{
            // A failure here is a font too broken to measure with, and the
            // honest answer is zero: the layout puts a zero-width run where
            // the text should be, which is visible rather than fatal.
            .width = scaled.measure(run) catch 0,
            .height = scaled.lineHeight(),
        };
    }

    fn lineHeight(context: ?*const anyopaque, style: ui.TextStyle) f32 {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        return self.face.at(@floatFromInt(style.font_size)).lineHeight();
    }

    fn measurer(self: *const Measured) ui.Measurer {
        return .{
            .context = self,
            .measureFn = measure,
            .lineHeightFn = lineHeight,
        };
    }
};

// -------------------------------------------------------------------------
// The layout
// -------------------------------------------------------------------------

const body =
    "Ply is an engine for building apps that run on Linux, macOS, Windows, " ++
    "Android, iOS and the web. One codebase, every platform. This paragraph " ++
    "is being measured by Fluxion Font, wrapped by Fluxion UI, and drawn by " ++
    "twenty lines at the bottom of this file.";

fn page(u: *Ui, width: f32) void {
    u.open(.{
        .id = "page",
        .width = .fixed(width),
        .height = .fit,
        .direction = .top_to_bottom,
        .padding = .all(2),
        .gap = 6,
    });
    defer u.close();

    u.text("Fluxion UI", .{ .font_size = 20, .color = .white });
    u.text(body, .{ .font_size = 12, .color = .white });

    // A row of two panes, to show that text and boxes size each other: the
    // label is as wide as it measures, and the bar takes what is left.
    {
        u.open(.{ .id = "row", .width = .grow, .height = .fit, .gap = 8, .align_y = .center });
        defer u.close();

        u.text("shrink me:", .{ .font_size = 12, .color = .white });
        u.empty(.{ .id = "bar", .width = .grow, .height = .fixed(10), .background_color = .white });
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var out_buffer: [1 << 18]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const w = &stdout.interface;

    const arguments = try init.minimal.args.toSlice(gpa);
    const path = if (arguments.len > 1) arguments[1] else defaultFont();
    const columns: f32 = if (arguments.len > 2)
        std.fmt.parseFloat(f32, arguments[2]) catch 150
    else
        150;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(32 << 20));
    var measured: Measured = .{ .face = try .init(bytes) };

    var u: Ui = .init(gpa);
    defer u.deinit();
    u.setMeasurer(measured.measurer());

    u.begin(.init(columns, 400));
    page(&u, columns);
    const drawn = try u.end();

    try w.print("{s}, {d} columns, {d} commands\n\n", .{ path, @as(u32, @intFromFloat(columns)), drawn.len });
    try draw(gpa, w, &measured.face, drawn, @intFromFloat(columns));
    try w.flush();
}

// -------------------------------------------------------------------------
// The renderer
// -------------------------------------------------------------------------

const ramp = " .:-=+*#%@";

/// Turn a command list into characters.
///
/// A complete renderer for two of the seven command kinds, which between them
/// are most of any interface: a filled rectangle and a run of text. Anything
/// that draws those and honours the scissor pair shows a recognisable UI.
fn draw(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    face: *const font.Font,
    commands: []const ui.RenderCommand,
    width: u32,
) !void {
    // How tall the page turned out.
    var bottom: f32 = 0;
    for (commands) |command| bottom = @max(bottom, command.bounding_box.bottom());
    const height: u32 = @intFromFloat(@ceil(bottom) + 1);

    const canvas = try gpa.alloc(u8, width * height);
    @memset(canvas, 0);

    var shape: font.Outline = .empty;
    defer shape.deinit(gpa);

    for (commands) |command| switch (command.config) {
        .rectangle => |fill| {
            const box = command.bounding_box;
            const shade: u8 = @intFromFloat(fill.color.a * 160);
            var y: u32 = @intFromFloat(@max(0, box.y));
            while (y < @min(height, @as(u32, @intFromFloat(@ceil(box.bottom()))))) : (y += 1) {
                var x: u32 = @intFromFloat(@max(0, box.x));
                while (x < @min(width, @as(u32, @intFromFloat(@ceil(box.right()))))) : (x += 1) {
                    canvas[y * width + x] = @max(canvas[y * width + x], shade);
                }
            }
        },
        .text => |run| {
            const scale = face.scaleFor(@floatFromInt(run.font_size));
            const ascent = face.at(@floatFromInt(run.font_size)).ascent();

            var pen = command.bounding_box.x;
            var previous: ?u16 = null;

            var letters = (std.unicode.Utf8View.init(run.text) catch continue).iterator();
            while (letters.nextCodepoint()) |codepoint| {
                const glyph = face.glyphFor(codepoint);
                if (previous) |left| {
                    pen += @as(f32, @floatFromInt(face.kern(left, glyph) catch 0)) * scale;
                }
                previous = glyph;

                try face.outlineOf(gpa, glyph, &shape);
                if (!shape.isEmpty()) {
                    const place: font.Placement = .init(shape.bounds(), scale);
                    place.apply(&shape);

                    var bitmap = try font.raster.rasterize(gpa, shape, place.width, place.height);
                    defer bitmap.deinit(gpa);

                    const x0: i32 = @as(i32, @intFromFloat(pen)) + place.left;
                    const y0: i32 = @as(i32, @intFromFloat(command.bounding_box.y + ascent)) - place.top;
                    blit(canvas, width, height, bitmap, x0, y0);
                }

                pen += @as(f32, @floatFromInt(face.advance(glyph) catch 0)) * scale;
            }
        },
        else => {},
    };

    // Two pixel rows to a character row, averaged. A terminal cell is about
    // twice as tall as it is wide, so one character per pixel comes out
    // stretched; this is the trick every terminal image viewer uses, and it
    // is what makes the text below legible rather than merely present.
    var y: usize = 0;
    while (y < height) : (y += 2) {
        for (0..width) |x| {
            const top = canvas[y * width + x];
            const under = if (y + 1 < height) canvas[(y + 1) * width + x] else 0;
            const coverage = (@as(usize, top) + @as(usize, under)) / 2;
            try w.print("{c}", .{ramp[(coverage * (ramp.len - 1)) / 255]});
        }
        try w.print("\n", .{});
    }
}

fn blit(canvas: []u8, width: u32, height: u32, bitmap: font.Bitmap, x0: i32, y0: i32) void {
    for (0..bitmap.height) |row| {
        const y = y0 + @as(i32, @intCast(row));
        if (y < 0 or y >= height) continue;
        for (0..bitmap.width) |column| {
            const x = x0 + @as(i32, @intCast(column));
            if (x < 0 or x >= width) continue;
            const target = &canvas[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
            target.* = @max(target.*, bitmap.at(@intCast(column), @intCast(row)));
        }
    }
}

fn defaultFont() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/segoeui.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
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

test "a real font measures a real paragraph, and the layout wraps it" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var measured: Measured = .{ .face = try .init(bytes) };

    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.setMeasurer(measured.measurer());

    u.begin(.init(400, 400));
    page(&u, 400);
    const drawn = try u.end();

    // The paragraph is far wider than four hundred pixels, so it wrapped -
    // and every line it wrapped into is a command.
    var lines: usize = 0;
    for (drawn) |command| {
        if (command.config == .text) lines += 1;
    }
    try testing.expect(lines > 4);

    // Nothing ran off the right, which is what wrapping to a width means.
    for (drawn) |command| {
        try testing.expect(command.bounding_box.right() <= 400.5);
    }
}

test "a narrower page wraps into more lines and gets taller" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var measured: Measured = .{ .face = try .init(bytes) };

    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.setMeasurer(measured.measurer());

    var heights: [2]f32 = undefined;
    var counts: [2]usize = undefined;

    for ([_]f32{ 600, 260 }, 0..) |width, i| {
        u.begin(.init(width, 800));
        page(&u, width);
        const drawn = try u.end();

        heights[i] = u.boxOf("page").?.height;
        counts[i] = 0;
        for (drawn) |command| {
            if (command.config == .text) counts[i] += 1;
        }
    }

    // The whole point of the wrap pass feeding the vertical one: a narrower
    // column is more lines, and the box round them grew to hold them.
    try testing.expect(counts[1] > counts[0]);
    try testing.expect(heights[1] > heights[0]);
}

test "the label keeps its width and the bar takes the rest" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var measured: Measured = .{ .face = try .init(bytes) };

    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.setMeasurer(measured.measurer());

    u.begin(.init(400, 400));
    page(&u, 400);
    _ = try u.end();

    const row = u.boxOf("row").?;
    const bar = u.boxOf("bar").?;

    // Text sizes a box: the bar is whatever the label and the gap left over.
    try testing.expect(bar.width > 0);
    try testing.expect(bar.width < row.width);
    try testing.expectApproxEqAbs(row.right(), bar.right(), 0.01);
}
