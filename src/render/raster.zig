// SPDX-License-Identifier: BSD-2-Clause

//! A renderer on the CPU: `[]const RenderCommand` in, pixels in a buffer out.
//!
//! The same picture `rhi.zig` draws, drawn without a GPU - for the places
//! there is none, or where asking one would be absurd:
//!
//!   * **Shared-memory windows.** A Wayland panel or a menu is a few hundred
//!     thousand pixels in a buffer the compositor reads. Drawing them here
//!     and handing the buffer over needs no EGL, no context, and no driver.
//!   * **Machines with no GPU driver**: a hobby kernel's linear framebuffer,
//!     a virtual machine, a server rendering thumbnails.
//!   * **Tests.** A frame drawn here is the same bytes on every machine, so a
//!     picture can be compared with the last one exactly.
//!
//! ```zig
//! var renderer: Renderer = .init(gpa, &face);
//! defer renderer.deinit();
//!
//! const pixels = try gpa.alloc(u32, 1280 * 720);
//! try renderer.draw(.init(pixels, 1280, 720), try ui.end(), .hex(0x14161A));
//! ```
//!
//! **The pixels are premultiplied, alpha in the top byte**: `0xAARRGGBB` as
//! a `u32`, which little-endian is B, G, R, A in memory. That is Wayland's
//! `argb8888`, a Linux framebuffer's `xrgb8888` and Cairo's and Pixman's
//! format, so the common destinations take the buffer as it is. `toRgba`
//! turns it into straight RGBA bytes for a PNG.
//!
//! What it shares with the GPU renderer is everything that is a decision
//! rather than a way of drawing: the rounded box is the same distance field
//! with the same one-pixel edge, a gradient runs the same way, the animated
//! text is `common.move`, a nine-slice is cut by `common`'s arithmetic. What
//! it does differently, it does because a CPU can:
//!
//!   * **Glyphs land on quarter pixels** and the baseline on a whole one,
//!     rather than being filtered into place - see `Glyphs`.
//!   * **A border has four widths and a position.** The GPU renderer draws
//!     the widest side all round, inside the box; here the left, right, top
//!     and bottom are what was asked for, and `outside` and `middle` are
//!     honoured. A field underlined in its accent colour is a border on its
//!     bottom side only, and it follows the rounded corners up and thins out
//!     the way a stroke on a curve does.
//!   * **Letter spacing is drawn**, as the measurer counted it: once after
//!     every character.
//!   * **A line height centres the text in the line.** A run with a
//!     `line_height` taller than its font puts half the difference above
//!     the text, as CSS does, so a label in a button sits in its middle.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const font = @import("fluxion_font");
const ui = @import("fluxion_ui");

const common = @import("common.zig");
pub const Glyphs = @import("Glyphs.zig");

pub const Error = font.Font.Error;

/// One pixel: premultiplied, alpha in the top byte.
pub const Pixel = u32;

/// Where a frame is drawn: rows of pixels, top first.
pub const Target = struct {
    pixels: []Pixel,
    width: u32,
    height: u32,
    /// Pixels from the start of one row to the start of the next. `width`
    /// for a buffer with nothing between its rows.
    stride: u32,
    /// The only pixels this frame may touch, or null for all of them.
    ///
    /// What a damaged region is: the part of a window that changed. Drawing
    /// the whole list under this clip leaves everything outside it as it
    /// was, so a clock that ticks repaints the clock and not the panel.
    region: ?Clip = null,

    pub fn init(pixels: []Pixel, width: u32, height: u32) Target {
        std.debug.assert(pixels.len >= @as(usize, width) * height);
        return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
    }

    /// The pixel at `x`, `y`, which must be inside.
    pub inline fn at(self: Target, x: i32, y: i32) *Pixel {
        return &self.pixels[@as(usize, @intCast(y)) * self.stride + @as(usize, @intCast(x))];
    }

    /// Every pixel this frame may touch.
    fn bounds(self: Target) Clip {
        const whole: Clip = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
        return if (self.region) |region| whole.intersect(region) else whole;
    }
};

/// A rectangle of whole pixels: from `x0`, `y0` up to but not including
/// `x1`, `y1`.
pub const Clip = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn intersect(self: Clip, other: Clip) Clip {
        return .{
            .x0 = @max(self.x0, other.x0),
            .y0 = @max(self.y0, other.y0),
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
        };
    }

    pub fn isEmpty(self: Clip) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    /// The whole pixels a box touches.
    pub fn around(box: ui.BoundingBox) Clip {
        return .{
            .x0 = toPixel(@floor(box.x)),
            .y0 = toPixel(@floor(box.y)),
            .x1 = toPixel(@ceil(box.right())),
            .y1 = toPixel(@ceil(box.bottom())),
        };
    }
};

/// A picture an image command can name: premultiplied, alpha in the top
/// byte, rows `width` apart.
pub const Image = struct {
    pixels: []const Pixel,
    width: u32,
    height: u32,

    /// Straight RGBA bytes - what a PNG decodes to - turned into an image
    /// this renderer draws. The pixels are the caller's to free.
    pub fn fromRgba(gpa: Allocator, rgba: []const u8, width: u32, height: u32) Allocator.Error!Image {
        const count = @as(usize, width) * height;
        std.debug.assert(rgba.len >= count * 4);
        const pixels = try gpa.alloc(Pixel, count);
        for (pixels, 0..) |*out, i| {
            const px = rgba[i * 4 ..][0..4];
            out.* = Glyphs.premultiply(px[0], px[1], px[2], px[3]);
        }
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// What draws a frame's `custom` commands: the program's own pixels, put
/// down between what came before the command and what comes after it.
pub const CustomDraw = struct {
    context: ?*anyopaque = null,
    draw: *const fn (
        context: ?*anyopaque,
        command: ui.RenderCommand,
        /// What the command is clipped to. Nothing outside it may change.
        clip: Clip,
        target: Target,
    ) anyerror!void,
};

pub const Renderer = struct {
    gpa: Allocator,
    /// What a text command's `font` is an index into, the default first.
    /// The faces are borrowed; the table is this renderer's own.
    faces: std.ArrayList(*const font.Font) = .empty,
    /// The slots in `faces` a run falls back on, in order.
    fallbacks: std.ArrayList(u16) = .empty,
    glyphs: Glyphs,
    /// What an image command's number means. Borrowed.
    images: []const Image = &.{},

    /// What the animated text styles are animated against. See `setTime`.
    time: f64 = 0,
    clocks: common.Clocks = .empty,

    /// The scissor rectangles currently open, innermost last.
    clips: std.ArrayList(Clip) = .empty,

    /// The most faces a run falls back on.
    const max_fallbacks = 7;

    /// A renderer that draws every run in `face`. A program with more than
    /// one font says so afterwards, with `setFaces`.
    pub fn init(gpa: Allocator, face: *const font.Font) Allocator.Error!Renderer {
        var self: Renderer = .{ .gpa = gpa, .glyphs = .init(gpa) };
        try self.faces.append(gpa, face);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.glyphs.deinit();
        self.faces.deinit(self.gpa);
        self.fallbacks.deinit(self.gpa);
        self.clocks.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.* = undefined;
    }

    /// Say which fonts text is drawn in, as `rhi.Renderer.setFaces` does:
    /// the first is the default, an index past the end is drawn in it, and a
    /// slot that holds a different face from last time forgets its glyphs.
    pub fn setFaces(self: *Renderer, faces: []const *const font.Font) Allocator.Error!void {
        try self.faces.ensureTotalCapacity(self.gpa, faces.len);
        for (self.faces.items, 0..) |old, slot| {
            if (slot > std.math.maxInt(u16)) break;
            if (slot >= faces.len or faces[slot] != old) self.glyphs.forget(@intCast(slot));
        }
        self.faces.clearRetainingCapacity();
        self.faces.appendSliceAssumeCapacity(faces);
    }

    /// Which faces a run falls back on, as slots in the `setFaces` table.
    pub fn setFallbacks(self: *Renderer, slots: []const u16) Allocator.Error!void {
        self.fallbacks.clearRetainingCapacity();
        try self.fallbacks.appendSlice(self.gpa, slots);
    }

    /// How colour glyphs are drawn. See `font.ColorOptions`.
    pub fn setColorOptions(self: *Renderer, options: font.ColorOptions) void {
        self.glyphs.color = options;
        self.glyphs.clear();
    }

    /// Forget one face's glyphs, for a font read again in place.
    pub fn forgetFace(self: *Renderer, slot: u16) void {
        self.glyphs.forget(slot);
    }

    /// Say what an image command's `texture` number is. Borrowed, and must
    /// outlive the frames drawn from it. A number with no image behind it
    /// draws the background and nothing else.
    pub fn setImages(self: *Renderer, images: []const Image) void {
        self.images = images;
    }

    /// Say what time it is, in seconds, for the animated markup styles.
    pub fn setTime(self: *Renderer, seconds: f64) void {
        self.time = seconds;
    }

    /// Draw a frame's commands into `target`.
    ///
    /// `clear` fills the target first - only its `region`, if it has one -
    /// or, null, draws on top of what is already there.
    pub fn draw(self: *Renderer, target: Target, commands: []const ui.RenderCommand, clear: ?ui.Color) Error!void {
        self.drawWith(target, commands, clear, null) catch |err| return @errorCast(err);
    }

    /// `draw`, handing each `custom` command to `custom` where it falls in
    /// the frame.
    pub fn drawWith(
        self: *Renderer,
        target: Target,
        commands: []const ui.RenderCommand,
        clear: ?ui.Color,
        custom: ?CustomDraw,
    ) anyerror!void {
        const whole = target.bounds();
        if (clear) |colour| fill(target, whole, pack(colour));

        self.clips.clearRetainingCapacity();
        var clip = whole;

        for (commands) |command| switch (command.config) {
            .scissor_start => {
                try self.clips.append(self.gpa, clip);
                clip = clip.intersect(.around(command.bounding_box));
            },
            .scissor_end => clip = self.clips.pop() orelse whole,
            .none => {},
            else => {
                if (clip.isEmpty()) continue;
                switch (command.config) {
                    .shadow => |shade| drawShadow(target, clip, command, shade),
                    .rectangle => |rect| drawRectangle(target, clip, command, rect),
                    .border => |line| drawBorder(target, clip, command, line),
                    .text => |run| try self.drawText(target, clip, command, run),
                    .image => |picture| self.drawImage(target, clip, command, picture),
                    .custom => if (custom) |drawer| try drawer.draw(drawer.context, command, clip, target),
                    else => unreachable,
                }
            },
        };
    }

    // ---------------------------------------------------------------------
    // Text
    // ---------------------------------------------------------------------

    fn slotFor(self: *Renderer, wanted: u16) ?u16 {
        if (self.faces.items.len == 0) return null;
        return if (wanted < self.faces.items.len) wanted else 0;
    }

    fn drawText(self: *Renderer, target: Target, clip: Clip, command: ui.RenderCommand, run: ui.commands.Text) Error!void {
        const slot = self.slotFor(run.font) orelse return;
        const face = self.faces.items[slot];

        var chain: [1 + max_fallbacks]*const font.Font = undefined;
        var chain_slots: [1 + max_fallbacks]u16 = undefined;
        chain[0] = face;
        chain_slots[0] = slot;
        var links: usize = 1;
        for (self.fallbacks.items) |fallback| {
            if (links == chain.len) break;
            if (fallback == slot or fallback >= self.faces.items.len) continue;
            chain[links] = self.faces.items[fallback];
            chain_slots[links] = fallback;
            links += 1;
        }

        const size = run.font_size;
        const em: f32 = @floatFromInt(size);
        const spacing: f32 = @floatFromInt(run.letter_spacing);
        const turned = !command.transform.isIdentity();

        // A line taller than the font - a 14-pixel body on a 20-pixel line -
        // puts the difference half above and half below, the way CSS's
        // half-leading does, so the text sits in the middle of its line
        // rather than at the top of it.
        const metrics = face.at(em);
        var top = command.bounding_box.y;
        if (run.line_height > 0) {
            const content = metrics.ascent() - metrics.descent();
            top += (@as(f32, @floatFromInt(run.line_height)) - content) / 2;
        }
        // The baseline on a whole pixel, so every horizontal stem in the line
        // is sharp: a stem straddling two rows is two grey ones.
        const baseline = @round(top + metrics.ascent());
        var pen = command.bounding_box.x;
        var previous: ?font.fallback.Placed = null;

        var at: u32 = run.first;
        var cluster: ?u32 = null;

        var glyphs: font.fallback.Glyphs = .init(chain[0..links], run.text);
        while (glyphs.next()) |placed| {
            const glyph_face = chain[placed.face];
            if (previous) |left| {
                if (left.face == placed.face) {
                    pen += @as(f32, @floatFromInt(glyph_face.kern(left.glyph, placed.glyph) catch 0)) * glyph_face.scaleFor(em);
                }
            }
            previous = placed;
            if (cluster) |start| {
                if (start != placed.start) {
                    at += 1;
                    pen += spacing;
                }
            }
            cluster = placed.start;

            const moved: common.Moved = if (run.effects.len == 0)
                .{}
            else
                common.move(self.gpa, &self.clocks, self.time, run.effects, @floatFromInt(at), em);
            if (moved.hidden) {
                pen += (try self.glyphs.glyph(glyph_face, chain_slots[placed.face], placed.glyph, size, 0)).advance;
                continue;
            }

            var colour = run.color;
            if (moved.color) |tint| colour = .{ .r = tint.r, .g = tint.g, .b = tint.b, .a = tint.a * run.color.a };
            colour.a = std.math.clamp(colour.a * moved.opacity, 0, 1);

            const still = run.effects.len == 0 and !turned;

            // Where the pen is, split into the pixel and the quarter within
            // it. A glyph that is going to be turned is drawn at phase zero
            // and sampled where it lands instead.
            const whole = @floor(pen);
            var phase: u8 = if (still) @intFromFloat(@round((pen - whole) * Glyphs.phases)) else 0;
            var column = whole;
            if (phase == Glyphs.phases) {
                phase = 0;
                column += 1;
            }

            const entry = try self.glyphs.glyph(glyph_face, chain_slots[placed.face], placed.glyph, size, phase);
            defer pen += entry.advance;
            if (entry.isBlank() or colour.invisible()) continue;

            const colored = entry.colored and !run.silhouette;

            if (still) {
                const x = toPixel(column) + entry.left;
                const y = toPixel(baseline) - entry.top;
                if (run.outline) |stroke| outlineGlyph(target, clip, entry, x, y, stroke);
                blitGlyph(target, clip, entry, x, y, colour, colored);
                continue;
            }

            // Turned, waved or both: the glyph's own motion, then the
            // element's on top - the same composition the GPU renderer uses.
            const box: [4]f32 = .{
                pen + @as(f32, @floatFromInt(entry.left)),
                baseline - @as(f32, @floatFromInt(entry.top)),
                @floatFromInt(entry.width),
                @floatFromInt(entry.height),
            };
            const motion = common.glyphTransform(box, moved).then(command.transform);
            if (run.outline) |stroke| {
                if (stroke.width > 0 and !stroke.color.invisible()) {
                    const width: f32 = @floatFromInt(stroke.width);
                    for (outline_offsets) |offset| {
                        const shifted: [4]f32 = .{ box[0] + offset[0] * width, box[1] + offset[1] * width, box[2], box[3] };
                        sampleGlyph(target, clip, entry, shifted, motion, stroke.color, false);
                    }
                }
            }
            sampleGlyph(target, clip, entry, box, motion, colour, colored);
        }
    }

    // ---------------------------------------------------------------------
    // Images
    // ---------------------------------------------------------------------

    fn drawImage(self: *Renderer, target: Target, clip: Clip, command: ui.RenderCommand, picture: ui.commands.Image) void {
        const box = command.bounding_box;
        const radii = picture.corner_radius.array();

        if (!picture.background_color.invisible()) {
            fillShape(target, clip, .{ .box = box, .radii = radii }, command.transform, .{ .solid = pack(picture.background_color) });
        }
        if (picture.texture >= self.images.len) return;
        const image = self.images[picture.texture];
        if (image.width == 0 or image.height == 0) return;

        const source = picture.source;
        if (picture.nine_slice) |slice| {
            const x = common.splitAxis(box.x, box.width, slice.border.left, slice.border.right);
            const y = common.splitAxis(box.y, box.height, slice.border.top, slice.border.bottom);
            const u = common.splitSpan(source.x, source.width, source.width * std.math.clamp(slice.source_left, 0, 1), source.width * std.math.clamp(slice.source_right, 0, 1));
            const v = common.splitSpan(source.y, source.height, source.height * std.math.clamp(slice.source_top, 0, 1), source.height * std.math.clamp(slice.source_bottom, 0, 1));
            for (0..3) |row| for (0..3) |col| {
                const part: ui.BoundingBox = .init(x[col], y[row], x[col + 1] - x[col], y[row + 1] - y[row]);
                if (part.width <= 0 or part.height <= 0) continue;
                drawPicture(target, clip, image, part, .init(u[col], v[row], u[col + 1] - u[col], v[row + 1] - v[row]), picture.tint, common.nineSliceRadii(radii, col, row), command.transform);
            };
        } else {
            drawPicture(target, clip, image, box, source, picture.tint, radii, command.transform);
        }
    }
};

// -------------------------------------------------------------------------
// Pixels
// -------------------------------------------------------------------------

/// A colour, premultiplied and packed.
pub fn pack(colour: ui.Color) Pixel {
    const a = std.math.clamp(colour.a, 0, 1);
    const r = std.math.clamp(colour.r, 0, 1) * a;
    const g = std.math.clamp(colour.g, 0, 1) * a;
    const b = std.math.clamp(colour.b, 0, 1) * a;
    return byte(a) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b);
}

inline fn byte(value: f32) u32 {
    return @intFromFloat(@round(value * 255));
}

/// Every channel of `p` multiplied by `a`/255, rounded - two channels at a
/// time, in the two halves of one integer.
pub inline fn scale(p: Pixel, a: u32) Pixel {
    var rb = (p & 0x00FF00FF) * a + 0x00800080;
    rb = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    var ag = ((p >> 8) & 0x00FF00FF) * a + 0x00800080;
    ag = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return rb | ag;
}

/// `src` over `dst`, both premultiplied. Cannot overflow a channel for any
/// premultiplied `src`, which is every pixel `pack` makes.
pub inline fn over(dst: Pixel, src: Pixel) Pixel {
    return src +% scale(dst, 255 - (src >> 24));
}

/// Put `src` down at `coverage` (0 to 255).
inline fn blend(dst: *Pixel, src: Pixel, coverage: u32) void {
    if (coverage == 0) return;
    if (coverage == 255 and src >> 24 == 255) {
        dst.* = src;
    } else {
        dst.* = over(dst.*, if (coverage == 255) src else scale(src, coverage));
    }
}

inline fn coverageByte(value: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

inline fn toPixel(value: f32) i32 {
    // Far enough off the surface is as good as infinitely far, and a box at
    // a billion pixels must not trap the conversion.
    return @intFromFloat(std.math.clamp(value, -1_000_000, 1_000_000));
}

fn fill(target: Target, clip: Clip, colour: Pixel) void {
    if (clip.isEmpty()) return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const row = target.pixels[@as(usize, @intCast(y)) * target.stride ..];
        @memset(row[@intCast(clip.x0)..@intCast(clip.x1)], colour);
    }
}

/// Straight RGBA bytes from premultiplied pixels: what a PNG holds.
pub fn toRgba(pixels: []const Pixel, out: []u8) void {
    std.debug.assert(out.len >= pixels.len * 4);
    for (pixels, 0..) |p, i| {
        const a = p >> 24;
        const px = out[i * 4 ..][0..4];
        if (a == 0) {
            px.* = .{ 0, 0, 0, 0 };
            continue;
        }
        px.* = .{
            @intCast(@min(255, ((p >> 16 & 0xFF) * 255 + a / 2) / a)),
            @intCast(@min(255, ((p >> 8 & 0xFF) * 255 + a / 2) / a)),
            @intCast(@min(255, ((p & 0xFF) * 255 + a / 2) / a)),
            @intCast(a),
        };
    }
}

// -------------------------------------------------------------------------
// Shapes
// -------------------------------------------------------------------------

/// The rounded-box distance field: negative inside, positive outside, in
/// pixels. The shader's, line for line, with the corners in the order
/// `CornerRadius.array` gives them: top left, top right, bottom right,
/// bottom left.
fn roundedBox(px: f32, py: f32, half_w: f32, half_h: f32, r: [4]f32) f32 {
    const radius = if (px > 0) (if (py < 0) r[1] else r[2]) else (if (py < 0) r[0] else r[3]);
    const qx = @abs(px) - half_w + radius;
    const qy = @abs(py) - half_h + radius;
    const outside = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0));
    return @min(@max(qx, qy), 0) + outside - radius;
}

/// A box with rounded corners, in the frame of the command it came from.
const Rounded = struct {
    box: ui.BoundingBox,
    radii: [4]f32,

    /// How much of the pixel centred on `x`, `y` is inside.
    fn coverage(self: Rounded, x: f32, y: f32) f32 {
        const hw = self.box.width / 2;
        const hh = self.box.height / 2;
        return std.math.clamp(0.5 - roundedBox(x - (self.box.x + hw), y - (self.box.y + hh), hw, hh, self.radii), 0, 1);
    }

    /// The columns of row `y` (a pixel centre) that are certainly wholly
    /// inside: past the straight edges by half a pixel and clear of every
    /// corner's square. Conservative on purpose - what it leaves out is
    /// measured pixel by pixel, which is slower and still right.
    fn solidSpan(self: Rounded, y: f32) ?[2]i32 {
        const top = y - self.box.y;
        const bottom = self.box.bottom() - y;
        if (top < 0.5 or bottom < 0.5) return null;

        var left = self.box.x;
        var right = self.box.right();
        if (top < self.radii[0]) left = @max(left, self.box.x + self.radii[0]);
        if (bottom < self.radii[3]) left = @max(left, self.box.x + self.radii[3]);
        if (top < self.radii[1]) right = @min(right, self.box.right() - self.radii[1]);
        if (bottom < self.radii[2]) right = @min(right, self.box.right() - self.radii[2]);

        // Column i is solid when its centre, i + 0.5, is half a pixel in.
        const first = toPixel(@ceil(left));
        const end = toPixel(@floor(right));
        if (end <= first) return null;
        return .{ first, end };
    }
};

/// A filled rounded box, or a border: a rounded box with another cut out.
const Shape = struct {
    box: ui.BoundingBox,
    radii: [4]f32,
    hole: ?Rounded = null,

    fn outer(self: Shape) Rounded {
        return .{ .box = self.box, .radii = self.radii };
    }

    fn coverage(self: Shape, x: f32, y: f32) f32 {
        var a = self.outer().coverage(x, y);
        if (a == 0) return 0;
        if (self.hole) |hole| a *= 1 - hole.coverage(x, y);
        return a;
    }
};

const Paint = union(enum) {
    solid: Pixel,
    /// From one colour to another across the box or down it, straight
    /// colours mixed and then premultiplied - what the GPU's interpolated
    /// vertex colour is.
    gradient: struct { from: ui.Color, to: ui.Color, down: bool },

    /// The colour at a point of the box, as a fraction across and down it.
    inline fn at(self: Paint, across: f32, down: f32) Pixel {
        return switch (self) {
            .solid => |p| p,
            .gradient => |g| blk: {
                const t = std.math.clamp(if (g.down) down else across, 0, 1);
                break :blk pack(.{
                    .r = g.from.r + (g.to.r - g.from.r) * t,
                    .g = g.from.g + (g.to.g - g.from.g) * t,
                    .b = g.from.b + (g.to.b - g.from.b) * t,
                    .a = g.from.a + (g.to.a - g.from.a) * t,
                });
            },
        };
    }
};

/// A soft shadow: the rounded box's distance field through the curve a
/// Gaussian blur gives a straight edge, cut out where the element casting it
/// stands.
///
/// The curve is the logistic one, `1 / (1 + e^(1.702 d / sigma))`, which is
/// within a percent of the Gaussian's own and costs one `exp`. Near a
/// corner it is the corner's distance put through the same curve - not the
/// exact blur of a rounded box, which no interface needs, but rounder
/// rather than squarer than it, which is the side to err on.
fn drawShadow(target: Target, clip: Clip, command: ui.RenderCommand, shade: ui.commands.Shadow) void {
    const box = command.bounding_box;
    if (box.width <= 0 or box.height <= 0) return;

    const sigma = @max(shade.blur / 2, 0.01);
    const reach = sigma * 3;
    const outer: ui.BoundingBox = .init(box.x - reach, box.y - reach, box.width + 2 * reach, box.height + 2 * reach);
    const turned = !command.transform.isIdentity();
    const inverse = if (turned) (Inverse.of(command.transform) orelse return) else undefined;
    const area = clip.intersect(if (turned) turnedArea(outer, command.transform) else .around(outer));
    if (area.isEmpty()) return;

    var radii = shade.corner_radius.array();
    for (&radii) |*r| r.* = @min(r.*, @min(box.width, box.height) / 2);
    const shape: Rounded = .{ .box = box, .radii = radii };
    const caster: ?Rounded = if (shade.caster.width > 0 and shade.caster.height > 0)
        .{ .box = shade.caster, .radii = shade.caster_radius.array() }
    else
        null;

    const ink = pack(shade.color);
    const steep = 1.702 / sigma;
    const hw = box.width / 2;
    const hh = box.height / 2;

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        // Where the caster certainly covers the whole pixel, there is no
        // shadow to draw: skip it.
        const skip: ?[2]i32 = if (caster != null and !turned) caster.?.solidSpan(cy) else null;

        var x = area.x0;
        while (x < area.x1) {
            if (skip) |span| {
                if (x >= span[0] and x < span[1]) {
                    x = span[1];
                    continue;
                }
            }
            var lx = @as(f32, @floatFromInt(x)) + 0.5;
            var ly = cy;
            if (turned) {
                const local = inverse.apply(lx, ly);
                lx = local[0];
                ly = local[1];
            }
            const d = roundedBox(lx - (box.x + hw), ly - (box.y + hh), hw, hh, shape.radii);
            var soft = 1 / (1 + @exp(steep * d));
            if (caster) |c| soft *= 1 - c.coverage(lx, ly);
            blend(target.at(x, y), ink, coverageByte(soft));
            x += 1;
        }
    }
}

fn drawRectangle(target: Target, clip: Clip, command: ui.RenderCommand, rect: ui.commands.Rectangle) void {
    const paint: Paint = if (rect.gradient) |g|
        .{ .gradient = .{ .from = rect.color, .to = g.to, .down = g.toward == .down } }
    else
        .{ .solid = pack(rect.color) };
    fillShape(target, clip, .{ .box = command.bounding_box, .radii = rect.corner_radius.array() }, command.transform, paint);
}

fn drawBorder(target: Target, clip: Clip, command: ui.RenderCommand, line: ui.commands.Border) void {
    const w = line.width;
    const left: f32 = @floatFromInt(w.left);
    const right: f32 = @floatFromInt(w.right);
    const top: f32 = @floatFromInt(w.top);
    const bottom: f32 = @floatFromInt(w.bottom);

    // How far the line reaches past the box on each side.
    const reach: f32 = switch (line.position) {
        .inside => 0,
        .middle => 0.5,
        .outside => 1,
    };
    const box = command.bounding_box;
    const outer_box: ui.BoundingBox = .init(
        box.x - left * reach,
        box.y - top * reach,
        box.width + (left + right) * reach,
        box.height + (top + bottom) * reach,
    );
    const grow = @max(@max(left, right), @max(top, bottom)) * reach;
    var radii = line.corner_radius.array();
    if (grow > 0) {
        for (&radii) |*r| r.* = if (r.* > 0) r.* + grow else 0;
    }

    // The hole is the outer box less each side's width, its corners as much
    // smaller as the wider of the two sides that meet there.
    const hole_box: ui.BoundingBox = .init(
        outer_box.x + left,
        outer_box.y + top,
        @max(0, outer_box.width - left - right),
        @max(0, outer_box.height - top - bottom),
    );
    const hole_radii: [4]f32 = .{
        @max(0, radii[0] - @max(left, top)),
        @max(0, radii[1] - @max(right, top)),
        @max(0, radii[2] - @max(right, bottom)),
        @max(0, radii[3] - @max(left, bottom)),
    };

    fillShape(target, clip, .{
        .box = outer_box,
        .radii = radii,
        .hole = .{ .box = hole_box, .radii = hole_radii },
    }, command.transform, .{ .solid = pack(line.color) });
}

fn fillShape(target: Target, clip: Clip, shape: Shape, transform: ui.geometry.Transform, paint: Paint) void {
    if (shape.box.width <= 0 or shape.box.height <= 0) return;
    if (!transform.isIdentity()) return fillTurned(target, clip, shape, transform, paint);

    const area = clip.intersect(.around(shape.box));
    if (area.isEmpty()) return;
    const inv_w = 1 / shape.box.width;
    const inv_h = 1 / shape.box.height;

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const down = (cy - shape.box.y) * inv_h;

        // What this row can skip or fill without asking: inside the hole of
        // a border nothing is drawn; inside a filled box everything is.
        var skip: ?[2]i32 = null;
        var solid: ?[2]i32 = null;
        if (shape.hole) |hole| {
            skip = hole.solidSpan(cy);
        } else if (paint == .solid) {
            solid = shape.outer().solidSpan(cy);
        }

        var x = area.x0;
        while (x < area.x1) {
            if (skip) |span| {
                if (x >= span[0] and x < span[1]) {
                    x = span[1];
                    continue;
                }
            }
            if (solid) |span| {
                if (x >= span[0] and x < span[1]) {
                    const end = @min(span[1], area.x1);
                    const colour = paint.solid;
                    const row = target.pixels[@as(usize, @intCast(y)) * target.stride ..];
                    if (colour >> 24 == 255) {
                        @memset(row[@intCast(x)..@intCast(end)], colour);
                    } else {
                        for (row[@intCast(x)..@intCast(end)]) |*p| p.* = over(p.*, colour);
                    }
                    x = end;
                    continue;
                }
            }

            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            const cover = coverageByte(shape.coverage(cx, cy));
            if (cover > 0) {
                const across = (cx - shape.box.x) * inv_w;
                blend(target.at(x, y), paint.at(across, down), cover);
            }
            x += 1;
        }
    }
}

/// The inverse of a transform: from where a pixel is on the surface to where
/// it was in the command's own frame. A general 2x2 inverse rather than
/// `Transform.unapply`, because a glyph's motion can stretch one axis more
/// than the other.
const Inverse = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    ox: f32,
    oy: f32,

    fn of(t: ui.geometry.Transform) ?Inverse {
        const det = t.x_axis.x * t.y_axis.y - t.y_axis.x * t.x_axis.y;
        if (@abs(det) < 1e-12) return null;
        return .{
            .a = t.y_axis.y / det,
            .b = -t.y_axis.x / det,
            .c = -t.x_axis.y / det,
            .d = t.x_axis.x / det,
            .ox = t.origin.x,
            .oy = t.origin.y,
        };
    }

    inline fn apply(self: Inverse, x: f32, y: f32) [2]f32 {
        const mx = x - self.ox;
        const my = y - self.oy;
        return .{ self.a * mx + self.b * my, self.c * mx + self.d * my };
    }
};

/// The pixels a box covers once `transform` has moved it.
fn turnedArea(box: ui.BoundingBox, transform: ui.geometry.Transform) Clip {
    const corners = [_]ui.geometry.Vec2{
        .{ .x = box.x, .y = box.y },
        .{ .x = box.right(), .y = box.y },
        .{ .x = box.x, .y = box.bottom() },
        .{ .x = box.right(), .y = box.bottom() },
    };
    var lo_x = std.math.inf(f32);
    var lo_y = std.math.inf(f32);
    var hi_x = -std.math.inf(f32);
    var hi_y = -std.math.inf(f32);
    for (corners) |corner| {
        const p = transform.apply(corner);
        lo_x = @min(lo_x, p.x);
        lo_y = @min(lo_y, p.y);
        hi_x = @max(hi_x, p.x);
        hi_y = @max(hi_y, p.y);
    }
    // A pixel either side, for the antialiased edge.
    return .{
        .x0 = toPixel(@floor(lo_x) - 1),
        .y0 = toPixel(@floor(lo_y) - 1),
        .x1 = toPixel(@ceil(hi_x) + 1),
        .y1 = toPixel(@ceil(hi_y) + 1),
    };
}

fn fillTurned(target: Target, clip: Clip, shape: Shape, transform: ui.geometry.Transform, paint: Paint) void {
    const inverse = Inverse.of(transform) orelse return;
    const area = clip.intersect(turnedArea(shape.box, transform));
    if (area.isEmpty()) return;

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        var x = area.x0;
        while (x < area.x1) : (x += 1) {
            const local = inverse.apply(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            const cover = coverageByte(shape.coverage(local[0], local[1]));
            if (cover == 0) continue;
            const across = (local[0] - shape.box.x) / shape.box.width;
            const down = (local[1] - shape.box.y) / shape.box.height;
            blend(target.at(x, y), paint.at(across, down), cover);
        }
    }
}

// -------------------------------------------------------------------------
// Glyphs
// -------------------------------------------------------------------------

/// The eight places a glyph is drawn again, in the outline's colour, to make
/// the outline - the GPU renderer's, so the two agree.
const outline_offsets = [_][2]f32{
    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
    .{ -1, 0 },  .{ 1, 0 },  .{ -1, 1 },
    .{ 0, 1 },   .{ 1, 1 },
};

fn outlineGlyph(target: Target, clip: Clip, entry: Glyphs.Entry, x: i32, y: i32, stroke: ui.TextOutline) void {
    if (stroke.width == 0 or stroke.color.invisible()) return;
    const width: i32 = stroke.width;
    for (outline_offsets) |offset| {
        const dx: i32 = @intFromFloat(offset[0]);
        const dy: i32 = @intFromFloat(offset[1]);
        blitGlyph(target, clip, entry, x + dx * width, y + dy * width, stroke.color, false);
    }
}

/// A glyph put down on whole pixels, as it was rasterised.
fn blitGlyph(target: Target, clip: Clip, entry: Glyphs.Entry, x: i32, y: i32, colour: ui.Color, colored: bool) void {
    const w: i32 = @intCast(entry.width);
    const h: i32 = @intCast(entry.height);
    const area = clip.intersect(.{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h });
    if (area.isEmpty()) return;

    const ink = pack(colour);
    const alpha = coverageByte(colour.a);

    var row = area.y0;
    while (row < area.y1) : (row += 1) {
        const sy: usize = @intCast(row - y);
        var col = area.x0;
        while (col < area.x1) : (col += 1) {
            const sx: usize = @intCast(col - x);
            const i = sy * entry.width + sx;
            if (entry.colored) {
                const p = entry.pixels[i];
                if (colored) {
                    if (p >> 24 != 0) blend(target.at(col, row), p, alpha);
                } else {
                    blend(target.at(col, row), ink, p >> 24);
                }
            } else {
                blend(target.at(col, row), ink, entry.coverage[i]);
            }
        }
    }
}

/// A glyph put down wherever `motion` takes it, sampled between texels.
fn sampleGlyph(target: Target, clip: Clip, entry: Glyphs.Entry, box: [4]f32, motion: ui.geometry.Transform, colour: ui.Color, colored: bool) void {
    const inverse = Inverse.of(motion) orelse return;
    const rect: ui.BoundingBox = .init(box[0], box[1], box[2], box[3]);
    const area = clip.intersect(turnedArea(rect, motion));
    if (area.isEmpty()) return;

    const ink = pack(colour);
    const alpha = coverageByte(colour.a);

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        var x = area.x0;
        while (x < area.x1) : (x += 1) {
            const local = inverse.apply(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            // Texel coordinates, centres on the halves.
            const u = local[0] - box[0] - 0.5;
            const v = local[1] - box[1] - 0.5;
            if (u < -1 or v < -1 or u > box[2] or v > box[3]) continue;
            if (entry.colored) {
                const p = bilinear(entry.pixels, entry.width, entry.height, u, v);
                if (colored) {
                    blend(target.at(x, y), p, alpha);
                } else {
                    blend(target.at(x, y), ink, p >> 24);
                }
            } else {
                blend(target.at(x, y), ink, bilinearCoverage(entry.coverage, entry.width, entry.height, u, v));
            }
        }
    }
}

// -------------------------------------------------------------------------
// Pictures
// -------------------------------------------------------------------------

/// One rectangle of an image into one box: scaled to fit it, tinted, and
/// cut to the box's rounded corners.
fn drawPicture(
    target: Target,
    clip: Clip,
    image: Image,
    box: ui.BoundingBox,
    source: ui.BoundingBox,
    tint: ui.Color,
    radii: [4]f32,
    transform: ui.geometry.Transform,
) void {
    if (box.width <= 0 or box.height <= 0) return;
    const turned = !transform.isIdentity();
    const inverse = if (turned) (Inverse.of(transform) orelse return) else undefined;
    const area = clip.intersect(if (turned) turnedArea(box, transform) else .around(box));
    if (area.isEmpty()) return;

    const mask: Rounded = .{ .box = box, .radii = radii };
    // Texels per pixel of the box, on each axis.
    const fw: f32 = @floatFromInt(image.width);
    const fh: f32 = @floatFromInt(image.height);
    const step_u = source.width * fw / box.width;
    const step_v = source.height * fh / box.height;
    const start_u = source.x * fw;
    const start_v = source.y * fh;

    const tinted = tint.r != 1 or tint.g != 1 or tint.b != 1 or tint.a != 1;
    const tint_a = std.math.clamp(tint.a, 0, 1);
    const tint_scale = [3]f32{
        std.math.clamp(tint.r, 0, 1) * tint_a,
        std.math.clamp(tint.g, 0, 1) * tint_a,
        std.math.clamp(tint.b, 0, 1) * tint_a,
    };

    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        var x = area.x0;
        while (x < area.x1) : (x += 1) {
            var lx = @as(f32, @floatFromInt(x)) + 0.5;
            var ly = @as(f32, @floatFromInt(y)) + 0.5;
            if (turned) {
                const local = inverse.apply(lx, ly);
                lx = local[0];
                ly = local[1];
            }
            const cover = coverageByte(mask.coverage(lx, ly));
            if (cover == 0) continue;

            const u = start_u + (lx - box.x) * step_u - 0.5;
            const v = start_v + (ly - box.y) * step_v - 0.5;
            var texel = bilinear(image.pixels, image.width, image.height, u, v);
            if (tinted) texel = tintPixel(texel, tint_scale, tint_a);
            blend(target.at(x, y), texel, cover);
        }
    }
}

fn tintPixel(p: Pixel, rgb: [3]f32, a: f32) Pixel {
    const r: f32 = @floatFromInt(p >> 16 & 0xFF);
    const g: f32 = @floatFromInt(p >> 8 & 0xFF);
    const b: f32 = @floatFromInt(p & 0xFF);
    const alpha: f32 = @floatFromInt(p >> 24);
    return @as(u32, @intFromFloat(@round(alpha * a))) << 24 |
        @as(u32, @intFromFloat(@round(r * rgb[0]))) << 16 |
        @as(u32, @intFromFloat(@round(g * rgb[1]))) << 8 |
        @as(u32, @intFromFloat(@round(b * rgb[2])));
}

/// A premultiplied pixel between four texels, the edges clamped.
fn bilinear(pixels: []const Pixel, width: u32, height: u32, u: f32, v: f32) Pixel {
    const max_x: f32 = @floatFromInt(width - 1);
    const max_y: f32 = @floatFromInt(height - 1);
    const cu = std.math.clamp(u, 0, max_x);
    const cv = std.math.clamp(v, 0, max_y);
    const x0: u32 = @intFromFloat(@floor(cu));
    const y0: u32 = @intFromFloat(@floor(cv));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const fx = cu - @as(f32, @floatFromInt(x0));
    const fy = cv - @as(f32, @floatFromInt(y0));

    // Weights out of 256 so the mix is integer arithmetic.
    const wx: u32 = @intFromFloat(@round(fx * 256));
    const wy: u32 = @intFromFloat(@round(fy * 256));
    if (wx == 0 and wy == 0) return pixels[y0 * width + x0];

    const top = lerp(pixels[y0 * width + x0], pixels[y0 * width + x1], wx);
    const bottom = lerp(pixels[y1 * width + x0], pixels[y1 * width + x1], wx);
    return lerp(top, bottom, wy);
}

/// From `a` to `b` by `t`/256, channel by channel.
inline fn lerp(a: Pixel, b: Pixel, t: u32) Pixel {
    if (t == 0) return a;
    if (t >= 256) return b;
    const s = 256 - t;
    const rb = (((a & 0x00FF00FF) * s + (b & 0x00FF00FF) * t) >> 8) & 0x00FF00FF;
    const ag = (((a >> 8) & 0x00FF00FF) * s + ((b >> 8) & 0x00FF00FF) * t) & 0xFF00FF00;
    return rb | ag;
}

/// Coverage between four texels: zero outside the bitmap, so a turned
/// glyph's edge fades rather than smearing its last column outwards.
fn bilinearCoverage(coverage: []const u8, width: u32, height: u32, u: f32, v: f32) u32 {
    const x0f = @floor(u);
    const y0f = @floor(v);
    const fx = u - x0f;
    const fy = v - y0f;
    const x0: i64 = @intFromFloat(x0f);
    const y0: i64 = @intFromFloat(y0f);

    const sample = struct {
        fn at(cov: []const u8, w: u32, h: u32, x: i64, y: i64) f32 {
            if (x < 0 or y < 0 or x >= w or y >= h) return 0;
            return @floatFromInt(cov[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))]);
        }
    }.at;

    const top = sample(coverage, width, height, x0, y0) * (1 - fx) + sample(coverage, width, height, x0 + 1, y0) * fx;
    const bottom = sample(coverage, width, height, x0, y0 + 1) * (1 - fx) + sample(coverage, width, height, x0 + 1, y0 + 1) * fx;
    return @intFromFloat(@round(std.math.clamp(top * (1 - fy) + bottom * fy, 0, 255)));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test {
    _ = common;
    _ = Glyphs;
}

/// A target of `w` by `h` pixels, cleared to black.
fn canvas(w: u32, h: u32) !Target {
    const pixels = try testing.allocator.alloc(Pixel, @as(usize, w) * h);
    @memset(pixels, 0xFF000000);
    return .init(pixels, w, h);
}

fn filled(box: ui.BoundingBox, colour: ui.Color, radius: f32) ui.RenderCommand {
    return .{ .bounding_box = box, .config = .{ .rectangle = .{
        .color = colour,
        .corner_radius = .all(radius),
    } } };
}

test "scaling and compositing are exact at the ends" {
    try testing.expectEqual(@as(Pixel, 0x80402010), scale(0xFF804020, 128));
    try testing.expectEqual(@as(Pixel, 0), scale(0xFFFFFFFF, 0));
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), scale(0xFFFFFFFF, 255));
    // Half white over black is mid grey, opaque.
    try testing.expectEqual(@as(Pixel, 0xFF808080), over(0xFF000000, 0x80808080));
}

test "a square fills exactly its pixels" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(8, 8);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{filled(.init(2, 2, 4, 4), .hex(0xFF8000), 0)};
    try renderer.draw(target, &commands, null);

    // Orange rather than white, so a channel order that is wrong cannot pass.
    try testing.expectEqual(@as(Pixel, 0xFFFF8000), target.at(2, 2).*);
    try testing.expectEqual(@as(Pixel, 0xFFFF8000), target.at(5, 5).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(1, 2).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(6, 6).*);
}

test "an edge between pixels is shared between them" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(4, 1);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{filled(.init(0.5, 0, 2, 1), .white, 0)};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFF808080), target.at(0, 0).*);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(1, 0).*);
    try testing.expectEqual(@as(Pixel, 0xFF808080), target.at(2, 0).*);
}

test "a rounded corner is cut and its middle is not" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(20, 20);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{filled(.init(0, 0, 20, 20), .white, 8)};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(0, 0).*);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(10, 10).*);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(10, 0).*);
    // On the curve: partly covered.
    const edge = target.at(2, 2).* & 0xFF;
    try testing.expect(edge > 0 and edge < 255);
}

test "the solid span agrees with the pixel-by-pixel answer" {
    // Two renderers' worth of the same box, one through the fast path and
    // one forced through coverage: they must be the same picture.
    const shape: Rounded = .{ .box = .init(1.3, 0.7, 30.4, 17.9), .radii = .{ 6, 0, 3, 9 } };
    var y: f32 = 0.5;
    while (y < 20) : (y += 1) {
        const span = shape.solidSpan(y) orelse continue;
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            try testing.expectEqual(@as(f32, 1), shape.coverage(@as(f32, @floatFromInt(x)) + 0.5, y));
        }
    }
}

test "a scissor keeps everything inside it, and nested ones intersect" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(10, 10);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{
        .{ .bounding_box = .init(0, 0, 6, 10), .config = .scissor_start },
        .{ .bounding_box = .init(3, 0, 7, 10), .config = .scissor_start },
        filled(.init(0, 0, 10, 10), .white, 0),
        .{ .bounding_box = .zero, .config = .scissor_end },
        .{ .bounding_box = .zero, .config = .scissor_end },
        filled(.init(9, 9, 1, 1), .hex(0xFF0000), 0),
    };
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(2, 5).*);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(4, 5).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(7, 5).*);
    // Drawn after both closed: nothing clips it.
    try testing.expectEqual(@as(Pixel, 0xFFFF0000), target.at(9, 9).*);
}

test "a bottom border is drawn on the bottom only" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(10, 10);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(0, 0, 10, 10),
        .config = .{ .border = .{ .color = .white, .width = .{ .bottom = 2 } } },
    }};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(5, 9).*);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(5, 8).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(5, 7).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(0, 5).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(5, 0).*);
}

test "an outside border is drawn outside the box" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(10, 10);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(2, 2, 6, 6),
        .config = .{ .border = .{ .color = .white, .width = .all(1), .position = .outside } },
    }};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(1, 4).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(2, 4).*);
}

test "a gradient runs from its colour to the other" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(100, 1);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(0, 0, 100, 1),
        .config = .{ .rectangle = .{ .color = .black, .gradient = .{ .to = .white } } },
    }};
    try renderer.draw(target, &commands, null);
    try testing.expect(target.at(0, 0).* & 0xFF < 4);
    try testing.expect(target.at(99, 0).* & 0xFF > 251);
    const middle = target.at(50, 0).* & 0xFF;
    try testing.expect(middle > 120 and middle < 135);
}

test "a turned square still covers its middle and not its old corner" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(20, 20);
    defer testing.allocator.free(target.pixels);

    // An eighth of a turn about the middle of a 10x10 square at (5, 5): the
    // middle stays where it was, and the square becomes a diamond.
    const c = @cos(std.math.pi / 4.0);
    const s = @sin(std.math.pi / 4.0);
    var command = filled(.init(5, 5, 10, 10), .white, 0);
    command.transform = .{
        .x_axis = .{ .x = c, .y = s },
        .y_axis = .{ .x = -s, .y = c },
        .origin = .{ .x = 10 - (c * 10 - s * 10), .y = 10 - (s * 10 + c * 10) },
    };
    const commands = [_]ui.RenderCommand{command};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(10, 10).*);
    // Turned by an eighth, the old corner is outside the diamond.
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(5, 5).*);
    // And its tip reaches past where the square's edge was.
    try testing.expect(target.at(10, 3).* & 0xFF > 0);
}

test "a shadow fades out past the edge and is not drawn under its caster" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    var target = try canvas(60, 60);
    defer testing.allocator.free(target.pixels);
    @memset(target.pixels, 0xFFFFFFFF);

    const caster: ui.BoundingBox = .init(20, 20, 20, 20);
    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(20, 24, 20, 20),
        .config = .{ .shadow = .{ .color = .black, .blur = 8, .caster = caster } },
    }};
    try renderer.draw(target, &commands, null);

    // Under the caster: untouched.
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(30, 30).*);
    // Just below it, where the shadow falls: dark.
    const below = target.at(30, 41).* & 0xFF;
    try testing.expect(below < 128);
    // Further out, lighter; far away, nothing.
    const further = target.at(30, 48).* & 0xFF;
    try testing.expect(further > below);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(2, 2).*);
}

test "an image is drawn at its size, tinted, and the rest of it is left alone" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    const target = try canvas(4, 4);
    defer testing.allocator.free(target.pixels);

    const texels = [_]Pixel{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0x00000000 };
    const images = [_]Image{.{ .pixels = &texels, .width = 2, .height = 2 }};
    renderer.setImages(&images);

    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(1, 1, 2, 2),
        .config = .{ .image = .{ .texture = 0 } },
    }};
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(@as(Pixel, 0xFFFF0000), target.at(1, 1).*);
    try testing.expectEqual(@as(Pixel, 0xFF00FF00), target.at(2, 1).*);
    try testing.expectEqual(@as(Pixel, 0xFF0000FF), target.at(1, 2).*);
    // A transparent texel shows what was there.
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(2, 2).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(0, 0).*);
}

test "a region keeps the frame to the pixels that changed" {
    var renderer = Renderer{ .gpa = testing.allocator, .glyphs = .init(testing.allocator) };
    defer renderer.deinit();
    var target = try canvas(10, 10);
    defer testing.allocator.free(target.pixels);
    target.region = .{ .x0 = 0, .y0 = 0, .x1 = 5, .y1 = 10 };

    const commands = [_]ui.RenderCommand{filled(.init(0, 0, 10, 10), .white, 0)};
    try renderer.draw(target, &commands, .hex(0x202020));
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), target.at(4, 4).*);
    try testing.expectEqual(@as(Pixel, 0xFF000000), target.at(5, 4).*);
}

test "straight RGBA comes back from premultiplied pixels" {
    var out: [8]u8 = undefined;
    toRgba(&.{ 0x80804020, 0 }, &out);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 64, 128, 0, 0, 0, 0 }, &out);
}

/// A font from the system, for the tests that need text: Inter where Fedora
/// puts it, DejaVu where Debian does. Null on a machine with neither.
fn systemFont() !?[]u8 {
    const candidates = [_][]const u8{
        "/usr/share/fonts/rsms-inter-fonts/Inter-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(32 << 20)) catch continue;
    }
    return null;
}

test "text is drawn where the layout put it, on a whole-pixel baseline" {
    const bytes = try systemFont() orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    var face: font.Font = try .init(bytes);

    var renderer: Renderer = try .init(testing.allocator, &face);
    defer renderer.deinit();
    const target = try canvas(120, 40);
    defer testing.allocator.free(target.pixels);

    const commands = [_]ui.RenderCommand{.{
        .bounding_box = .init(10.3, 5, 100, 24),
        .config = .{ .text = .{ .text = "Hellö", .color = .white, .font_size = 20 } },
    }};
    try renderer.draw(target, &commands, null);

    // Ink inside the line's box, and none left of it or below it.
    var inked: usize = 0;
    var stray: usize = 0;
    for (0..40) |y| for (0..120) |x| {
        const lit = target.at(@intCast(x), @intCast(y)).* & 0xFF > 0;
        const inside = x >= 10 and y >= 5 and y < 30;
        if (lit and inside) inked += 1;
        if (lit and !inside) stray += 1;
    };
    try testing.expect(inked > 100);
    try testing.expectEqual(@as(usize, 0), stray);

    // Drawing it again reuses every glyph.
    const cached = renderer.glyphs.entries.count();
    try renderer.draw(target, &commands, null);
    try testing.expectEqual(cached, renderer.glyphs.entries.count());
}
