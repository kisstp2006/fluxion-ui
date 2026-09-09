// SPDX-License-Identifier: BSD-2-Clause

//! Rectangles, and the numbers that describe where one goes.
//!
//! Everything a layout produces is one of these. `Dimensions` is what an
//! element wants to be, `BoundingBox` is where it ended up, and the rest -
//! `Padding`, `CornerRadius`, `AlignX`, `AlignY` - is what the author asked
//! for in between.
//!
//! The origin is the **top left**, and y grows downwards. That is what every
//! UI has always done, what
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) already settled
//! on for viewports and scissor rectangles, and what a renderer built on
//! either does not have to think about again. OpenGL's bottom-left origin is
//! a backend's problem, and the RHI backend already does that arithmetic.
//!
//! Two width types run through this file, and the split is deliberate rather
//! than sloppy. Positions and sizes are `f32`, because a grow distribution
//! divides and a percentage multiplies. Padding, gaps and border widths are
//! `u16`, because nobody has ever wanted 12.5 pixels of padding and the
//! declaration reads better as `.padding = .all(24)` than as `24.0`.

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");

/// A point or a displacement. [Fluxion Math](https://github.com/kisstp2006/fluxion-math)'s,
/// re-exported because a scroll offset is one and nothing else here needs the
/// rest of that library.
pub const Vec2 = math.Vec2;

/// Where a quad ends up, when something rotated it.
///
/// A **rigid motion** and nothing more: a turn, a mirror, and where the origin
/// lands. Not a general matrix - there is no scale and no shear in it, and two
/// things depend on that. The inverse is the transpose, which is what lets the
/// pointer be moved into a rotated element's own frame without a division. And
/// a distance field measured in the element's own space is still measured in
/// pixels after the motion, so an antialiased edge stays one pixel wide.
///
/// Kept as the two axes rather than as an angle and a pivot because that is
/// what composes: a rotated card holding a rotated icon is one of these, and
/// is not an angle and a pivot without arithmetic nobody wants in a shader.
pub const Transform = extern struct {
    /// Where the x axis points afterwards.
    x_axis: Vec2 = .{ .x = 1, .y = 0 },
    /// Where the y axis points.
    y_axis: Vec2 = .{ .x = 0, .y = 1 },
    /// Where the origin lands, in surface pixels.
    origin: Vec2 = .{ .x = 0, .y = 0 },

    pub const identity: Transform = .{};

    /// Whether this leaves everything where it was, which most elements do -
    /// worth asking before writing six numbers into a vertex buffer.
    pub inline fn isIdentity(self: Transform) bool {
        return self.x_axis.x == 1 and self.x_axis.y == 0 and
            self.y_axis.x == 0 and self.y_axis.y == 1 and
            self.origin.x == 0 and self.origin.y == 0;
    }

    pub inline fn apply(self: Transform, point: Vec2) Vec2 {
        return .{
            .x = self.x_axis.x * point.x + self.y_axis.x * point.y + self.origin.x,
            .y = self.x_axis.y * point.x + self.y_axis.y * point.y + self.origin.y,
        };
    }

    /// Where a point *came from*: the motion undone.
    ///
    /// The transpose and a subtraction, which is only the inverse because
    /// there is no scale in here. What the hit test uses to ask a rotated
    /// button whether the pointer is on it.
    pub fn unapply(self: Transform, point: Vec2) Vec2 {
        const moved: Vec2 = .{ .x = point.x - self.origin.x, .y = point.y - self.origin.y };
        return .{
            .x = self.x_axis.x * moved.x + self.x_axis.y * moved.y,
            .y = self.y_axis.x * moved.x + self.y_axis.y * moved.y,
        };
    }

    /// This one, and then `outer`. The order a nested rotation needs: the
    /// icon turns in the card's frame, and then the card turns.
    pub fn then(self: Transform, outer: Transform) Transform {
        return .{
            .x_axis = .{
                .x = outer.x_axis.x * self.x_axis.x + outer.y_axis.x * self.x_axis.y,
                .y = outer.x_axis.y * self.x_axis.x + outer.y_axis.y * self.x_axis.y,
            },
            .y_axis = .{
                .x = outer.x_axis.x * self.y_axis.x + outer.y_axis.x * self.y_axis.y,
                .y = outer.x_axis.y * self.y_axis.x + outer.y_axis.y * self.y_axis.y,
            },
            .origin = outer.apply(self.origin),
        };
    }

    /// A turn about a point, and a mirror through it, in that order - the
    /// mirror first, as Ply applies its flips before its rotation.
    pub fn about(pivot: Vec2, radians: f32, flip_x: bool, flip_y: bool) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        const sx: f32 = if (flip_x) -1 else 1;
        const sy: f32 = if (flip_y) -1 else 1;

        // The 2x2 is the mirror and then the turn; the origin is whatever
        // keeps the pivot where it is.
        const x_axis: Vec2 = .{ .x = cos * sx, .y = sin * sx };
        const y_axis: Vec2 = .{ .x = -sin * sy, .y = cos * sy };
        return .{
            .x_axis = x_axis,
            .y_axis = y_axis,
            .origin = .{
                .x = pivot.x - (x_axis.x * pivot.x + y_axis.x * pivot.y),
                .y = pivot.y - (x_axis.y * pivot.x + y_axis.y * pivot.y),
            },
        };
    }
};

/// How big something is. Not where it is - that is `BoundingBox`.
pub const Dimensions = extern struct {
    width: f32 = 0,
    height: f32 = 0,

    pub const zero: Dimensions = .{};

    pub inline fn init(width: f32, height: f32) Dimensions {
        return .{ .width = width, .height = height };
    }

    /// The size along one axis. The layout solves each axis with the same
    /// code and a `bool` saying which, so this is called far more often than
    /// it looks like it would be.
    pub inline fn onAxis(self: Dimensions, x_axis: bool) f32 {
        return if (x_axis) self.width else self.height;
    }

    pub fn format(self: Dimensions, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:.1}x{d:.1}", .{ self.width, self.height });
    }
};

/// Where something ended up: a position and a size, in that order.
pub const BoundingBox = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub const zero: BoundingBox = .{};

    pub inline fn init(x: f32, y: f32, width: f32, height: f32) BoundingBox {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    /// A box at a point, of a size. What the layout produces once an
    /// element's size is settled and its place is known.
    pub inline fn at(x: f32, y: f32, dimensions: Dimensions) BoundingBox {
        return .{ .x = x, .y = y, .width = dimensions.width, .height = dimensions.height };
    }

    pub inline fn position(self: BoundingBox) Vec2 {
        return .init(self.x, self.y);
    }

    pub inline fn size(self: BoundingBox) Dimensions {
        return .init(self.width, self.height);
    }

    pub inline fn right(self: BoundingBox) f32 {
        return self.x + self.width;
    }

    pub inline fn bottom(self: BoundingBox) f32 {
        return self.y + self.height;
    }

    pub inline fn center(self: BoundingBox) Vec2 {
        return .init(self.x + self.width / 2, self.y + self.height / 2);
    }

    /// Whether a point is inside. The left and top edges are in, the right
    /// and bottom edges are out - so two boxes that share an edge do not both
    /// claim a pointer sitting exactly on it, and a hit test never answers
    /// twice.
    pub inline fn contains(self: BoundingBox, point: Vec2) bool {
        return point.x >= self.x and point.x < self.right() and
            point.y >= self.y and point.y < self.bottom();
    }

    /// Whether the two overlap at all. Used to drop elements scrolled out of
    /// view before they reach the command list.
    pub inline fn overlaps(self: BoundingBox, other: BoundingBox) bool {
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }

    /// The part of `self` that is also inside `clip`. An empty box - width or
    /// height zero - when they do not meet.
    pub fn intersect(self: BoundingBox, clip: BoundingBox) BoundingBox {
        const x = @max(self.x, clip.x);
        const y = @max(self.y, clip.y);
        return .{
            .x = x,
            .y = y,
            .width = @max(0, @min(self.right(), clip.right()) - x),
            .height = @max(0, @min(self.bottom(), clip.bottom()) - y),
        };
    }

    /// Whether anything would be drawn. A zero-area box is the usual result
    /// of clipping something fully out of view.
    pub inline fn empty(self: BoundingBox) bool {
        return self.width <= 0 or self.height <= 0;
    }

    /// The box shrunk by `by` on every side. What the area inside the padding
    /// is.
    pub fn deflate(self: BoundingBox, by: Padding) BoundingBox {
        return .{
            .x = self.x + @as(f32, @floatFromInt(by.left)),
            .y = self.y + @as(f32, @floatFromInt(by.top)),
            .width = @max(0, self.width - @as(f32, @floatFromInt(by.horizontal()))),
            .height = @max(0, self.height - @as(f32, @floatFromInt(by.vertical()))),
        };
    }

    pub fn format(self: BoundingBox, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d:.1}, {d:.1}) {d:.1}x{d:.1}", .{ self.x, self.y, self.width, self.height });
    }
};

/// Space inside an element, before its children start.
/// One whole-pixel number, multiplied by an interface scale.
///
/// Padding, gaps, border widths and font sizes are whole pixels, so scaling
/// one is a multiplication, a rounding, and a clamp - a `u16` that is already
/// large has nowhere to go, and a padding that wrapped round to nothing would
/// be a very strange bug to look for. See `layout.Surface.scale`.
pub inline fn scaleWhole(value: u16, by: f32) u16 {
    const wanted = @round(@as(f32, @floatFromInt(value)) * by);
    return @intFromFloat(std.math.clamp(wanted, 0, std.math.maxInt(u16)));
}

/// One length, multiplied by an interface scale.
///
/// Infinity stays infinity: `Sizing.max` defaults to the largest `f32` there
/// is, and doubling that is not a bigger maximum - it is a maximum that has
/// stopped being a number.
pub inline fn scaleLength(value: f32, by: f32) f32 {
    return if (std.math.isFinite(value)) value * by else value;
}

pub const Padding = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub const none: Padding = .{};

    /// Every side multiplied by an interface scale. See `layout.Surface`.
    pub inline fn scaled(self: Padding, by: f32) Padding {
        return .{
            .left = scaleWhole(self.left, by),
            .right = scaleWhole(self.right, by),
            .top = scaleWhole(self.top, by),
            .bottom = scaleWhole(self.bottom, by),
        };
    }

    /// The same on all four sides, which is what most of them are.
    pub inline fn all(amount: u16) Padding {
        return .{ .left = amount, .right = amount, .top = amount, .bottom = amount };
    }

    /// Horizontal and vertical, as CSS writes a two-value padding.
    pub inline fn xy(horizontal_amount: u16, vertical_amount: u16) Padding {
        return .{
            .left = horizontal_amount,
            .right = horizontal_amount,
            .top = vertical_amount,
            .bottom = vertical_amount,
        };
    }

    /// Top, right, bottom, left - the order CSS writes a four-value padding
    /// in, and the order Ply's `padding((t, r, b, l))` takes.
    pub inline fn trbl(top_amount: u16, right_amount: u16, bottom_amount: u16, left_amount: u16) Padding {
        return .{
            .top = top_amount,
            .right = right_amount,
            .bottom = bottom_amount,
            .left = left_amount,
        };
    }

    pub inline fn horizontal(self: Padding) u16 {
        return self.left + self.right;
    }

    pub inline fn vertical(self: Padding) u16 {
        return self.top + self.bottom;
    }

    /// The total along one axis, already a float - which is how the solver
    /// wants it every single time it asks.
    pub inline fn onAxis(self: Padding, x_axis: bool) f32 {
        return @floatFromInt(if (x_axis) self.horizontal() else self.vertical());
    }
};

/// How round each corner is, in pixels.
pub const CornerRadius = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub const sharp: CornerRadius = .{};

    /// Every corner multiplied by an interface scale. A radius that did not
    /// scale with its box would be a hairline on a card at twice the size.
    pub inline fn scaled(self: CornerRadius, by: f32) CornerRadius {
        return .{
            .top_left = self.top_left * by,
            .top_right = self.top_right * by,
            .bottom_right = self.bottom_right * by,
            .bottom_left = self.bottom_left * by,
        };
    }

    pub inline fn all(radius: f32) CornerRadius {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }

    /// The four, in the order CSS writes them: top-left, top-right,
    /// bottom-right, bottom-left, going clockwise from the top left.
    pub inline fn corners(tl: f32, tr: f32, br: f32, bl: f32) CornerRadius {
        return .{ .top_left = tl, .top_right = tr, .bottom_right = br, .bottom_left = bl };
    }

    pub inline fn isSharp(self: CornerRadius) bool {
        return self.top_left == 0 and self.top_right == 0 and
            self.bottom_right == 0 and self.bottom_left == 0;
    }

    /// Cut every radius down to what the box can actually hold.
    ///
    /// A radius larger than half the shorter side has no meaning - the two
    /// corners it belongs to would overlap - and a renderer handed one draws
    /// either nothing or a shape that turns inside out. Clamping here means
    /// `.corner_radius = .all(9999)` is how you ask for a pill, which is what
    /// people expect it to do.
    pub fn clampTo(self: CornerRadius, width: f32, height: f32) CornerRadius {
        const limit = @min(width, height) / 2;
        return .{
            .top_left = std.math.clamp(self.top_left, 0, limit),
            .top_right = std.math.clamp(self.top_right, 0, limit),
            .bottom_right = std.math.clamp(self.bottom_right, 0, limit),
            .bottom_left = std.math.clamp(self.bottom_left, 0, limit),
        };
    }

    pub inline fn array(self: CornerRadius) [4]f32 {
        return .{ self.top_left, self.top_right, self.bottom_right, self.bottom_left };
    }
};

/// Where children sit along the horizontal axis when there is room to spare.
///
/// Spelled the American way, as `center`, because Ply spells it that way and
/// an API that is ninety per cent the same is worth more than a consistent
/// dictionary. The prose in this library still says centre; the identifiers
/// say what a reader coming from Ply will type.
pub const AlignX = enum { left, center, right };

/// Where children sit along the vertical axis when there is room to spare.
pub const AlignY = enum { top, center, bottom };

/// The share of the space left over that goes *before* the content.
///
/// The rule is the same on both axes - the leading edge takes none of it, the
/// centre takes half, the trailing edge takes all - and these two are how the
/// solver says so without a `switch` at each of the several places it aligns
/// something. Two functions rather than one generic over the enum, because
/// the two enums are different types and that is the point of them: `.left`
/// cannot be handed to the vertical case.
pub inline fn leadingSpaceX(extra: f32, alignment: AlignX) f32 {
    return switch (alignment) {
        .left => 0,
        .center => extra / 2,
        .right => extra,
    };
}

pub inline fn leadingSpaceY(extra: f32, alignment: AlignY) f32 {
    return switch (alignment) {
        .top => 0,
        .center => extra / 2,
        .bottom => extra,
    };
}

test "a bounding box knows its own edges" {
    const box: BoundingBox = .init(10, 20, 100, 50);
    try testing.expectEqual(@as(f32, 110), box.right());
    try testing.expectEqual(@as(f32, 70), box.bottom());
    try testing.expectEqual(@as(f32, 60), box.center().x);
    try testing.expectEqual(@as(f32, 45), box.center().y);
}

test "the left and top edges are inside, the right and bottom are not" {
    // Two boxes sharing an edge must not both claim a pointer on it, or a
    // hit test answers twice and the wrong one wins.
    const left: BoundingBox = .init(0, 0, 100, 100);
    const right: BoundingBox = .init(100, 0, 100, 100);

    const on_the_seam: Vec2 = .init(100, 50);
    try testing.expect(!left.contains(on_the_seam));
    try testing.expect(right.contains(on_the_seam));

    try testing.expect(left.contains(.init(0, 0)));
    try testing.expect(!left.contains(.init(-1, 50)));
}

test "intersection is the visible part, and empty when there is none" {
    const box: BoundingBox = .init(0, 0, 100, 100);
    const clip: BoundingBox = .init(50, 50, 100, 100);

    const visible = box.intersect(clip);
    try testing.expectEqual(BoundingBox.init(50, 50, 50, 50), visible);
    try testing.expect(!visible.empty());

    const apart = box.intersect(.init(500, 500, 10, 10));
    try testing.expect(apart.empty());
    try testing.expect(!box.overlaps(.init(500, 500, 10, 10)));
    try testing.expect(box.overlaps(clip));
}

test "deflating by padding leaves the content area" {
    const box: BoundingBox = .init(0, 0, 100, 100);
    const inner = box.deflate(.all(10));
    try testing.expectEqual(BoundingBox.init(10, 10, 80, 80), inner);

    // Padding bigger than the box leaves nothing rather than going negative.
    const crushed = box.deflate(.all(200));
    try testing.expect(crushed.empty());
    try testing.expectEqual(@as(f32, 0), crushed.width);
}

test "padding totals, on either axis" {
    const p: Padding = .xy(24, 12);
    try testing.expectEqual(48, p.horizontal());
    try testing.expectEqual(24, p.vertical());
    try testing.expectEqual(@as(f32, 48), p.onAxis(true));
    try testing.expectEqual(@as(f32, 24), p.onAxis(false));
    try testing.expectEqual(@as(f32, 0), Padding.none.onAxis(true));
}

test "a radius larger than the box becomes a pill, not a mistake" {
    // `.all(9999)` is how people ask for fully rounded ends, and it has to
    // mean that rather than drawing an inside-out shape.
    const pill = CornerRadius.all(9999).clampTo(200, 40);
    try testing.expectEqual(@as(f32, 20), pill.top_left);
    try testing.expectEqual(@as(f32, 20), pill.bottom_right);

    // A radius that already fits is left alone.
    const gentle = CornerRadius.all(8).clampTo(200, 40);
    try testing.expectEqual(@as(f32, 8), gentle.top_left);

    try testing.expect(CornerRadius.sharp.isSharp());
    try testing.expect(!gentle.isSharp());
}

test "corners are written in CSS order" {
    const r: CornerRadius = .corners(1, 2, 3, 4);
    try testing.expectEqual(@as(f32, 1), r.top_left);
    try testing.expectEqual(@as(f32, 2), r.top_right);
    try testing.expectEqual(@as(f32, 3), r.bottom_right);
    try testing.expectEqual(@as(f32, 4), r.bottom_left);
    try testing.expectEqual([4]f32{ 1, 2, 3, 4 }, r.array());
}

test "dimensions answer for whichever axis is being solved" {
    const size: Dimensions = .init(320, 240);
    try testing.expectEqual(@as(f32, 320), size.onAxis(true));
    try testing.expectEqual(@as(f32, 240), size.onAxis(false));
}

test "boxes and sizes print the way they are read out loud" {
    var text: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);

    try w.print("{f}", .{BoundingBox.init(10, 20, 100.5, 50)});
    try testing.expectEqualStrings("(10.0, 20.0) 100.5x50.0", w.buffered());

    w = .fixed(&text);
    try w.print("{f}", .{Dimensions.init(320, 240)});
    try testing.expectEqualStrings("320.0x240.0", w.buffered());
}

test "alignment gives the leading edge its share and no more" {
    // Left and top take nothing, so content starts where the padding ends.
    try testing.expectEqual(@as(f32, 0), leadingSpaceX(100, .left));
    try testing.expectEqual(@as(f32, 0), leadingSpaceY(100, .top));

    // Centre splits it, which is the only one that divides.
    try testing.expectEqual(@as(f32, 50), leadingSpaceX(100, .center));
    try testing.expectEqual(@as(f32, 50), leadingSpaceY(100, .center));

    // Right and bottom push the content the whole way across.
    try testing.expectEqual(@as(f32, 100), leadingSpaceX(100, .right));
    try testing.expectEqual(@as(f32, 100), leadingSpaceY(100, .bottom));
}

test "a transform leaves the pivot alone and moves the rest round it" {
    const quarter: Transform = .about(.{ .x = 10, .y = 10 }, std.math.pi / 2.0, false, false);

    const pivot = quarter.apply(.{ .x = 10, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 10), pivot.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), pivot.y, 0.001);

    // A quarter turn clockwise on screen, where y points down: the point to
    // the right of the pivot ends up below it.
    const right = quarter.apply(.{ .x = 20, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 10), right.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), right.y, 0.001);
}

test "undoing a transform is the transform undone" {
    for ([_]f32{ 0.3, 1.0, -2.2 }) |angle| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |flips| {
            const motion: Transform = .about(.{ .x = 7, .y = -3 }, angle, flips[0], flips[1]);
            const there = motion.apply(.{ .x = 21, .y = 5 });
            const back = motion.unapply(there);
            try testing.expectApproxEqAbs(@as(f32, 21), back.x, 0.001);
            try testing.expectApproxEqAbs(@as(f32, 5), back.y, 0.001);
        }
    }
}

test "two turns about two pivots compose into one motion" {
    // The reason this is two axes and an origin rather than an angle and a
    // pivot: a rotated card holding a rotated icon has to be one of these.
    const inner: Transform = .about(.{ .x = 0, .y = 0 }, 0.4, false, false);
    const outer: Transform = .about(.{ .x = 50, .y = 20 }, -1.1, false, true);
    const both = inner.then(outer);

    const point: Vec2 = .{ .x = 13, .y = 29 };
    const step_by_step = outer.apply(inner.apply(point));
    const at_once = both.apply(point);
    try testing.expectApproxEqAbs(step_by_step.x, at_once.x, 0.001);
    try testing.expectApproxEqAbs(step_by_step.y, at_once.y, 0.001);
}

test "the identity is the identity, and says so" {
    try testing.expect(Transform.identity.isIdentity());
    try testing.expect(!Transform.about(.{ .x = 1, .y = 1 }, 0.5, false, false).isIdentity());
    // A turn of nothing about anywhere still leaves everything where it was.
    try testing.expect(Transform.about(.{ .x = 40, .y = 40 }, 0, false, false).isIdentity());
}
