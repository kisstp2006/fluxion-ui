// SPDX-License-Identifier: BSD-2-Clause

//! What every renderer in this package agrees on.
//!
//! There are two: `rhi.zig`, which draws on a GPU, and `raster.zig`, which
//! draws on the CPU into a buffer of pixels. Both turn the same
//! `RenderCommand`s into the same picture, and the parts of that which are
//! arithmetic rather than drawing - where a waving letter goes, how a
//! nine-slice image is cut up - are here, written once. Two copies of a
//! wave would be two waves the first time somebody tuned one of them.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ui = @import("fluxion_ui");

/// When each named reveal started, by the hash of its name.
///
/// A `type` or `fade` runs from the first frame it is seen on, so it has to
/// be remembered somewhere - and two runs sharing an `id` share a start,
/// which is what the name is for. Never swept: the names are written in the
/// program's own strings, so there is a fixed number of them however long it
/// runs.
pub const Clocks = std.AutoHashMapUnmanaged(u32, f64);

// -------------------------------------------------------------------------
// Animated text
// -------------------------------------------------------------------------

/// What the effects do to one glyph.
pub const Moved = struct {
    /// Added to where the glyph would have been, in pixels.
    offset: ui.geometry.Vec2 = .{ .x = 0, .y = 0 },
    scale: ui.geometry.Vec2 = .{ .x = 1, .y = 1 },
    /// In radians, about the middle of the glyph.
    rotate: f32 = 0,
    /// Multiplied into the alpha.
    opacity: f32 = 1,
    color: ?ui.Color = null,
    hidden: bool = false,
};

/// Work out what one glyph of one frame looks like.
///
/// Ply's arithmetic, effect by effect, with its defaults. `index` is how
/// many characters into the whole run this glyph is, which is what makes
/// a wave travel along a word instead of every letter moving together.
pub fn move(
    gpa: Allocator,
    /// When each named reveal started. Written the first time one is seen.
    clocks: *Clocks,
    /// The renderer's clock, in seconds. See `Renderer.setTime`.
    time: f64,
    effects: []const ui.markup.Effect,
    index: f32,
    em: f32,
) Moved {
    var moved: Moved = .{};

    for (effects) |effect| switch (effect) {
        .wave => |wave| {
            // A displacement along a direction, which is straight down
            // until `r` says otherwise.
            const distance = wave.cycle.at(time, index) * wave.cycle.amplitude * em;
            const along = wave.direction * std.math.pi / 180.0;
            moved.offset.x += -distance * @sin(along);
            moved.offset.y += distance * @cos(along);
        },
        .pulse => |cycle| {
            const size = 1 + cycle.at(time, index) * cycle.amplitude;
            moved.scale.x *= size;
            moved.scale.y *= size;
        },
        .swing => |cycle| {
            // Ply's amplitude here is in degrees, and its wave is a sine
            // rather than a cosine - a swing starts upright.
            const width = if (cycle.width == 0) 1 else cycle.width;
            const turns = cycle.frequency * @as(f32, @floatCast(time)) +
                index / width + cycle.phase;
            moved.rotate += @sin(2 * std.math.pi * turns) *
                cycle.amplitude * std.math.pi / 180.0;
        },
        .jitter => |jitter| {
            // Twenty steps a second, so it shakes rather than shimmers,
            // and the same nonsense-from-a-sine Ply uses for the numbers.
            const seed = @floor(@as(f32, @floatCast(time)) * 20) + index * 13.37;
            const x = fract(@sin(seed) * 43758.5453);
            const y = fract(@cos(seed + 7.1) * 23421.632);
            const shake_x = (x - 0.5) * 2 * jitter.radius.x * em;
            const shake_y = (y - 0.5) * 2 * jitter.radius.y * em;
            const along = jitter.rotation * std.math.pi / 180.0;
            moved.offset.x += shake_x * @cos(along) - shake_y * @sin(along);
            moved.offset.y += shake_x * @sin(along) + shake_y * @cos(along);
        },
        .transform => |fixed| {
            moved.offset.x += fixed.translate.x * em;
            moved.offset.y += fixed.translate.y * em;
            moved.scale.x *= fixed.scale.x;
            moved.scale.y *= fixed.scale.y;
            moved.rotate += fixed.rotate * std.math.pi / 180.0;
        },
        .gradient => |gradient| {
            moved.color = gradient.sample(index - @as(f32, @floatCast(time)) * gradient.speed);
        },
        .reveal => |reveal| {
            const started = clocks.get(reveal.clock) orelse blk: {
                clocks.put(gpa, reveal.clock, time) catch {};
                break :blk time;
            };
            const elapsed = @max(0, @as(f32, @floatCast(time - started)) - reveal.delay);
            const reached = elapsed * reveal.speed;

            switch (reveal.kind) {
                // No edge: a letter is either there or it is not.
                .type => {
                    const arrived = index < reached;
                    if (arrived == reveal.out) moved.hidden = true;
                },
                .fade, .scale => {
                    const trail = if (reveal.trail == 0) 1 else reveal.trail;
                    const progress = std.math.clamp((reached - index) / trail, 0, 1);
                    const amount = if (reveal.out) 1 - progress else progress;
                    if (reveal.kind == .fade) {
                        moved.opacity *= amount;
                    } else {
                        moved.scale.x *= amount;
                        moved.scale.y *= amount;
                    }
                },
            }
        },
    };

    return moved;
}

/// The part after the point, which is what Ply's `fract` is.
fn fract(value: f32) f32 {
    return value - @floor(value);
}

/// Where one glyph ends up once its effects have moved it: turned and grown
/// about its own middle, then shifted.
///
/// `box` is the glyph's rectangle as x, y, width, height. The caller puts the
/// element's own transform on top with `then`, which is how a waving word
/// inside a tilted badge stays in the badge. This one is not a rigid motion,
/// because a pulse scales it; nothing ever asks for it back, which is the
/// only thing rigidity buys.
pub fn glyphTransform(box: [4]f32, moved: Moved) ui.geometry.Transform {
    const middle_x = box[0] + box[2] / 2;
    const middle_y = box[1] + box[3] / 2;
    const cos = @cos(moved.rotate);
    const sin = @sin(moved.rotate);
    const m00 = cos * moved.scale.x;
    const m10 = sin * moved.scale.x;
    const m01 = -sin * moved.scale.y;
    const m11 = cos * moved.scale.y;
    return .{
        .x_axis = .{ .x = m00, .y = m10 },
        .y_axis = .{ .x = m01, .y = m11 },
        .origin = .{
            .x = middle_x + moved.offset.x - (m00 * middle_x + m01 * middle_y),
            .y = middle_y + moved.offset.y - (m10 * middle_x + m11 * middle_y),
        },
    };
}

// -------------------------------------------------------------------------
// Nine-slice images
// -------------------------------------------------------------------------

pub fn splitAxis(start: f32, length: f32, first: u16, last: u16) [4]f32 {
    return splitSpan(start, length, @floatFromInt(first), @floatFromInt(last));
}

pub fn splitSpan(start: f32, length: f32, first: f32, last: f32) [4]f32 {
    var before = first;
    var after = last;
    const total = before + after;
    if (total > length and total > 0) {
        const scale = length / total;
        before *= scale;
        after *= scale;
    }
    return .{ start, start + before, start + length - after, start + length };
}

pub fn nineSliceRadii(radii: [4]f32, column: usize, row: usize) [4]f32 {
    var out: [4]f32 = @splat(0);
    if (column == 0 and row == 0) out[0] = radii[0];
    if (column == 2 and row == 0) out[1] = radii[1];
    if (column == 2 and row == 2) out[2] = radii[2];
    if (column == 0 and row == 2) out[3] = radii[3];
    return out;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "nine-slice borders meet instead of crossing" {
    try testing.expectEqual([4]f32{ 10, 15, 15, 20 }, splitSpan(10, 10, 8, 8));
}

test "a glyph that nothing moves stays where it is" {
    const box = [4]f32{ 10, 20, 8, 12 };
    const still = glyphTransform(box, .{});
    const corner = still.apply(.{ .x = 10, .y = 20 });
    try testing.expectApproxEqAbs(@as(f32, 10), corner.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), corner.y, 0.0001);
}

test "a reveal starts on the first frame it is seen" {
    var clocks: Clocks = .empty;
    defer clocks.deinit(testing.allocator);
    const effects = [_]ui.markup.Effect{.{ .reveal = .{ .clock = 7, .kind = .type, .speed = 10 } }};

    // At the moment it is first seen, nothing has arrived yet.
    try testing.expect(move(testing.allocator, &clocks, 5, &effects, 0, 16).hidden);
    // A second later, ten characters have.
    try testing.expect(!move(testing.allocator, &clocks, 6, &effects, 3, 16).hidden);
}
