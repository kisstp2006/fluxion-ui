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
pub const Padding = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub const none: Padding = .{};

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
