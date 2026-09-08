// SPDX-License-Identifier: BSD-2-Clause

//! What an element asks for: how big, which way round, and where its children
//! sit.
//!
//! This is the vocabulary the API is written in, and it is the part of Ply
//! that survives the port unchanged in meaning. Ply spells these with macros -
//! `grow!()`, `fixed!(100)`, `percent!(0.5)` - because Rust needs one to give
//! a struct literal default arguments. Zig does not: a declaration literal
//! resolves against the type the field already has, so the same thing is
//! written with a dot and no macro anywhere:
//!
//! ```zig
//! ui.open(.{
//!     .width = .grow,             // Sizing.grow
//!     .height = .fixed(40),       // Sizing.fixed(40)
//!     .padding = .all(12),
//!     .gap = 8,
//!     .direction = .left_to_right,
//! });
//! defer ui.close();
//! ```
//!
//! Five ways to be a size, and the order they are resolved in is the whole
//! layout algorithm:
//!
//!   `fixed`    this many pixels, and nothing argues
//!   `percent`  this fraction of what the parent has left
//!   `fit`      as small as the children allow, within min and max
//!   `grow`     as large as the parent allows, sharing what is spare
//!   `ratio`    this multiple of the other axis, once that axis is known
//!
//! `fit` is the default, and it is the one to reach for when unsure: an
//! element that has not been told a size is exactly as big as what is in it.

const std = @import("std");
const testing = std.testing;

const geometry = @import("geometry.zig");

const AlignX = geometry.AlignX;
const AlignY = geometry.AlignY;
const Padding = geometry.Padding;

/// Which way children are stacked.
pub const Direction = enum {
    /// Children in a row. The main axis is x.
    left_to_right,
    /// Children in a column. The main axis is y.
    top_to_bottom,

    /// Whether this direction lays children out along x.
    ///
    /// The solver runs the same code for both axes with a `bool` saying
    /// which, and this is the question it asks to find out whether it is
    /// looking at the main axis or the cross axis - which is where every
    /// layout bug lives.
    pub inline fn isMainAxisX(self: Direction) bool {
        return self == .left_to_right;
    }
};

/// How an element decides its size on one axis.
pub const Sizing = struct {
    kind: Kind = .fit,
    /// Never smaller than this, whatever else is decided.
    min: f32 = 0,
    /// Never larger than this.
    max: f32 = std.math.floatMax(f32),
    /// For `.percent`, the fraction of the parent. For `.ratio`, the multiple
    /// of the other axis. Unused otherwise.
    fraction: f32 = 0,
    /// For `.grow`, this element's share of the spare space relative to its
    /// siblings. Two children at `1` split it evenly; one at `2` beside one
    /// at `1` takes two thirds.
    ///
    /// Ply added this over Clay, and it is worth keeping: without it, the
    /// only way to make one pane twice the width of another is to know the
    /// container's size, which is exactly what `grow` exists to avoid.
    weight: f32 = 1,

    pub const Kind = enum { fit, grow, fixed, percent, ratio };

    /// As small as the children allow. The default, and the right answer far
    /// more often than people expect.
    pub const fit: Sizing = .{ .kind = .fit };

    /// As large as the parent allows, sharing the spare space evenly with
    /// other growing siblings.
    pub const grow: Sizing = .{ .kind = .grow };

    /// Exactly this many pixels.
    pub inline fn fixed(size: f32) Sizing {
        return .{ .kind = .fixed, .min = size, .max = size };
    }

    /// This fraction of the parent's inner size. `0.5` is half.
    pub inline fn percent(of_parent: f32) Sizing {
        return .{ .kind = .percent, .fraction = of_parent };
    }

    /// The bounds and share `fitWith` and `growWith` take. Between them they
    /// are Ply's `fit!(min, max)` and `grow!(min, max, weight)`, with every
    /// argument optional and named rather than positional.
    pub const Bounds = struct {
        min: f32 = 0,
        max: f32 = std.math.floatMax(f32),
        /// Only read by `growWith`.
        weight: f32 = 1,
    };

    /// As small as the children allow, but never outside these bounds.
    /// Ply's `fit!(min, max)`.
    pub inline fn fitWith(bounds: Bounds) Sizing {
        return .{ .kind = .fit, .min = bounds.min, .max = bounds.max };
    }

    /// As small as the children allow, between these two. The shorthand most
    /// callers want.
    pub inline fn fitBetween(min: f32, max: f32) Sizing {
        return fitWith(.{ .min = min, .max = max });
    }

    /// Grow, with bounds and a share. Ply's `grow!(min, max, weight)`.
    ///
    /// Two of Ply's rules live here rather than in the solver, because they
    /// are about what the declaration means rather than about arithmetic:
    ///
    ///   * **A weight of zero is `fit`.** Not "grows by nothing" - an element
    ///     that took no share but still counted as growable would keep the
    ///     spare space away from its siblings, which is the opposite of what
    ///     writing zero asks for.
    ///   * **A negative weight is a mistake**, caught here rather than
    ///     producing a layout that leans. Ply panics; so does this, in a
    ///     build with safety on.
    pub inline fn growWith(bounds: Bounds) Sizing {
        std.debug.assert(bounds.weight >= 0);
        if (bounds.weight == 0) return fitWith(bounds);
        return .{
            .kind = .grow,
            .min = bounds.min,
            .max = bounds.max,
            .weight = bounds.weight,
        };
    }

    /// Grow, but never outside these bounds.
    pub inline fn growBetween(min: f32, max: f32) Sizing {
        return growWith(.{ .min = min, .max = max });
    }

    /// Grow with a share other than one. See `weight`.
    pub inline fn growWeighted(share: f32) Sizing {
        return growWith(.{ .weight = share });
    }

    /// Never smaller than this, whatever else applies.
    pub inline fn atLeast(size: f32) Sizing {
        return fitWith(.{ .min = size });
    }

    /// This multiple of the *other* axis - `.ratio(16.0 / 9.0)` on width
    /// makes a box as wide as sixteen ninths of its height.
    ///
    /// Only one axis may be a ratio. Both would have nothing to resolve
    /// against, and `Ui.end` says so rather than looping.
    pub inline fn ratio(of_other_axis: f32) Sizing {
        return .{ .kind = .ratio, .fraction = of_other_axis };
    }

    /// Whether this size is decided by the parent rather than the children.
    /// `grow` and `percent` both are, and both are skipped by the fit pass.
    pub inline fn dependsOnParent(self: Sizing) bool {
        return self.kind == .grow or self.kind == .percent;
    }

    /// `size`, held inside `min` and `max`.
    pub inline fn clamp(self: Sizing, size: f32) f32 {
        return @min(@max(size, self.min), self.max);
    }
};

/// Both axes at once, which is how an element declares its size.
pub const SizingConfig = struct {
    width: Sizing = .fit,
    height: Sizing = .fit,

    pub inline fn onAxis(self: SizingConfig, x_axis: bool) Sizing {
        return if (x_axis) self.width else self.height;
    }
};

/// Everything about how an element arranges what is inside it.
pub const LayoutConfig = struct {
    sizing: SizingConfig = .{},
    padding: Padding = .none,
    /// Space between one child and the next, along the main axis. Ply's
    /// `layout(|l| l.gap(8))`.
    gap: u16 = 0,
    /// Where the children sit when there is room to spare. Ply writes the
    /// pair as `align(CenterX, CenterY)`; here they are two fields, because
    /// `align` is a keyword in Zig and cannot be the name of one.
    align_x: AlignX = .left,
    align_y: AlignY = .top,
    direction: Direction = .left_to_right,

    pub const default: LayoutConfig = .{};
};

/// What `Ui.open` takes: everything an element is, in one literal.
///
/// Flat rather than nested, because a nested `.layout = .{ .sizing = .{ ... } }`
/// is three lines of punctuation before anything is said. Ply nests it and
/// then provides builder methods to hide the nesting; a Zig struct literal
/// with defaults needs neither.
pub const Declaration = struct {
    /// A name for this element, so that state - hover, focus, scroll - can
    /// follow it between frames. Elements without one get a name from their
    /// position in the tree, which is stable as long as the tree is.
    id: ?[]const u8 = null,

    width: Sizing = .fit,
    height: Sizing = .fit,
    padding: Padding = .none,
    gap: u16 = 0,
    align_x: AlignX = .left,
    align_y: AlignY = .top,
    direction: Direction = .left_to_right,

    /// Shrink the resolved box to this aspect ratio, inside the room the
    /// layout gave it. Ply's `contain(ratio)`, and what a letterboxed image
    /// wants.
    contain: ?f32 = null,
    /// Grow the resolved box to this aspect ratio, past the room the layout
    /// gave it. Ply's `cover(ratio)`, and what a cropped background wants.
    /// Only one of the two applies; `contain` wins if both are given.
    cover: ?f32 = null,

    background_color: Color = .transparent,
    corner_radius: CornerRadius = .sharp,
    border: ?Border = null,

    /// What happens to content larger than this element. See `Clip`.
    clip: Clip = .none,

    /// Whether the pointer stops here rather than reaching what is behind.
    /// Ply's `.capture()`, and what a button inside a draggable panel wants:
    /// dragging the button must not also drag the panel.
    capture: bool = false,
    /// Whether pressing here leaves the keyboard where it is. Ply's
    /// `.preserve_focus()`, for a toolbar control that should not take the
    /// caret out of the field beside it.
    preserve_focus: bool = false,

    /// Drawn above lower numbers, below higher ones. Elements at the same
    /// z-index are drawn in the order they were declared.
    z_index: i16 = 0,

    /// The `LayoutConfig` this declaration is asking for.
    pub fn layout(self: Declaration) LayoutConfig {
        return .{
            .sizing = .{ .width = self.width, .height = self.height },
            .padding = self.padding,
            .gap = self.gap,
            .align_x = self.align_x,
            .align_y = self.align_y,
            .direction = self.direction,
        };
    }

    /// The aspect ratio this element is held to after the layout has run, and
    /// which way it is held. See `SlotFit`.
    pub fn slotFit(self: Declaration) ?SlotFit {
        if (self.contain) |ratio| return .{ .ratio = ratio, .mode = .contain };
        if (self.cover) |ratio| return .{ .ratio = ratio, .mode = .cover };
        return null;
    }
};

const Color = @import("color.zig").Color;
const CornerRadius = geometry.CornerRadius;

/// A line around an element.
pub const Border = struct {
    color: Color = .transparent,
    width: BorderWidth = .none,

    /// Whether the line sits inside the element's box or outside it.
    ///
    /// Inside is CSS's `box-sizing: border-box` and is the default here for
    /// the same reason it is what everybody sets CSS to: a 100-pixel box with
    /// a 2-pixel border is 100 pixels wide, not 104, and a row of them still
    /// adds up.
    position: BorderPosition = .inside,

    pub inline fn all(color: Color, width: u16) Border {
        return .{ .color = color, .width = .all(width) };
    }
};

/// How thick the line is on each side.
pub const BorderWidth = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub const none: BorderWidth = .{};

    pub inline fn all(width: u16) BorderWidth {
        return .{ .left = width, .right = width, .top = width, .bottom = width };
    }

    pub inline fn isNone(self: BorderWidth) bool {
        return self.left == 0 and self.right == 0 and self.top == 0 and self.bottom == 0;
    }
};

/// Where the line sits relative to the box. Ply's three, under Ply's names -
/// which is why the middle one is `middle` rather than `center`.
pub const BorderPosition = enum { outside, middle, inside };

/// What happens to content larger than the element holding it.
///
/// Ply spells this with an `OverflowBuilder` - `clip()`, `scroll_y()`,
/// `no_drag_scroll()` - and the flags underneath are the same four. The
/// declarations below are those builder calls as values.
///
/// **Clipping is what makes scrolling possible**, and the two are separate on
/// purpose: an element may clip without scrolling, which is what a fixed-width
/// chip with a long label wants. Scrolling without clipping is not a thing,
/// so every `scroll` constructor turns the matching clip on too.
///
/// Three things change for an element that clips, and each is a place the
/// layout would otherwise refuse to overflow:
///
///   1. **Its children do not raise its minimum** on the clipped axis. A
///      paragraph inside a scroll container does not make the container
///      un-shrinkable.
///   2. **Its children are not squeezed to fit** along a clipped main axis.
///      They keep their sizes and run off the end, which is the content a
///      scrollbar scrolls through.
///   3. **Its children may be larger than it** across a clipped cross axis.
pub const Clip = struct {
    /// Cut off anything past the left and right edges.
    horizontal: bool = false,
    /// Cut off anything past the top and bottom.
    vertical: bool = false,
    /// Whether the content may be moved sideways. Implies `horizontal`.
    scroll_x: bool = false,
    /// Whether it may be moved up and down. Implies `vertical`.
    scroll_y: bool = false,

    /// How far the content has been scrolled, in pixels, and the direction is
    /// worth being careful about: **positive means the content has moved up
    /// and left**, so a container scrolled to the bottom has a positive `y`.
    /// A renderer never sees this - it is already in the boxes.
    ///
    /// Filled in by `Ui` from what it remembers of this element, so a caller
    /// declares `.clip = .scrollY` and never touches it.
    offset: geometry.Vec2 = .{ .x = 0, .y = 0 },

    pub const none: Clip = .{};

    /// Ply's `clip_x()`, `clip_y()`, `clip()`.
    pub const x: Clip = .{ .horizontal = true };
    pub const y: Clip = .{ .vertical = true };
    pub const both: Clip = .{ .horizontal = true, .vertical = true };

    /// Ply's `scroll_x()`, `scroll_y()`, `scroll()`. Each clips the axis it
    /// scrolls, because content that is not cut off has nowhere to scroll to.
    pub const scrollX: Clip = .{ .horizontal = true, .scroll_x = true };
    pub const scrollY: Clip = .{ .vertical = true, .scroll_y = true };
    pub const scroll: Clip = .{
        .horizontal = true,
        .vertical = true,
        .scroll_x = true,
        .scroll_y = true,
    };

    /// Whether this element cuts anything off at all.
    pub inline fn clips(self: Clip) bool {
        return self.horizontal or self.vertical;
    }

    /// Whether it clips along one axis. The solver asks this at three points,
    /// once per rule in the doc comment above.
    pub inline fn onAxis(self: Clip, x_axis: bool) bool {
        return if (x_axis) self.horizontal else self.vertical;
    }

    /// Whether it scrolls at all, and so needs its position remembered.
    pub inline fn scrolls(self: Clip) bool {
        return self.scroll_x or self.scroll_y;
    }
};

/// Holding a resolved box to an aspect ratio, after the layout has decided
/// how much room it gets.
///
/// Not a `Sizing`, and the difference is worth being clear about. A `ratio`
/// sizing decides how big an element *asks* to be, and takes part in the
/// sharing out of space. `contain` and `cover` run afterwards and change only
/// the box, so a picture can be letterboxed inside the room it was given
/// without moving anything beside it.
pub const SlotFit = struct {
    ratio: f32,
    mode: Mode,

    pub const Mode = enum {
        /// The largest box of this ratio that fits inside the room given.
        contain,
        /// The smallest box of this ratio that covers the room given.
        cover,
    };
};

test "the defaults are what an element that says nothing gets" {
    const d: Declaration = .{};
    try testing.expectEqual(Sizing.Kind.fit, d.width.kind);
    try testing.expectEqual(Sizing.Kind.fit, d.height.kind);
    try testing.expectEqual(Padding.none, d.padding);
    try testing.expectEqual(@as(u16, 0), d.gap);
    try testing.expectEqual(Direction.left_to_right, d.direction);
    try testing.expect(d.background_color.invisible());
}

test "declaration literals read as the API is meant to be written" {
    // The whole point of the `Sizing` shape: this is what a caller types, and
    // there is no macro anywhere in it.
    const d: Declaration = .{
        .width = .grow,
        .height = .fixed(40),
        .padding = .all(12),
        .gap = 8,
        .direction = .top_to_bottom,
    };

    try testing.expectEqual(Sizing.Kind.grow, d.width.kind);
    try testing.expectEqual(Sizing.Kind.fixed, d.height.kind);
    try testing.expectEqual(@as(f32, 40), d.height.min);
    try testing.expectEqual(@as(f32, 40), d.height.max);
    try testing.expectEqual(@as(u16, 12), d.padding.left);
}

test "a fixed size is a min and a max that agree" {
    // Which is what makes the grow and shrink passes leave it alone without
    // either of them having to know what `fixed` means.
    const size: Sizing = .fixed(100);
    try testing.expectEqual(@as(f32, 100), size.clamp(50));
    try testing.expectEqual(@as(f32, 100), size.clamp(500));
    try testing.expect(!size.dependsOnParent());
}

test "grow and percent are decided by the parent, fit and fixed are not" {
    try testing.expect(Sizing.grow.dependsOnParent());
    try testing.expect(Sizing.percent(0.5).dependsOnParent());
    try testing.expect(!Sizing.fit.dependsOnParent());
    try testing.expect(!Sizing.fixed(10).dependsOnParent());
}

test "clamping holds a size inside its bounds" {
    const bounded: Sizing = .fitBetween(50, 200);
    try testing.expectEqual(@as(f32, 50), bounded.clamp(10));
    try testing.expectEqual(@as(f32, 120), bounded.clamp(120));
    try testing.expectEqual(@as(f32, 200), bounded.clamp(1000));

    // An unbounded fit has a max that will not get in the way.
    try testing.expectEqual(@as(f32, 1e9), Sizing.fit.clamp(1e9));
}

test "grow weights are a share, and one is the default" {
    try testing.expectEqual(@as(f32, 1), Sizing.grow.weight);
    try testing.expectEqual(@as(f32, 2), Sizing.growWeighted(2).weight);
    try testing.expectEqual(Sizing.Kind.grow, Sizing.growWeighted(2).kind);
}

test "the direction says which axis is the main one" {
    try testing.expect(Direction.left_to_right.isMainAxisX());
    try testing.expect(!Direction.top_to_bottom.isMainAxisX());
}

test "a declaration hands back the layout it asked for" {
    const d: Declaration = .{
        .width = .percent(0.5),
        .padding = .xy(16, 8),
        .align_x = .center,
        .align_y = .center,
        .direction = .top_to_bottom,
    };
    const l = d.layout();

    try testing.expectEqual(Sizing.Kind.percent, l.sizing.width.kind);
    try testing.expectEqual(@as(f32, 0.5), l.sizing.width.fraction);
    try testing.expectEqual(@as(u16, 32), l.padding.horizontal());
    try testing.expectEqual(geometry.AlignX.center, l.align_x);
    try testing.expectEqual(Direction.top_to_bottom, l.direction);

    // And `onAxis` answers for whichever axis is being solved.
    try testing.expectEqual(Sizing.Kind.percent, l.sizing.onAxis(true).kind);
    try testing.expectEqual(Sizing.Kind.fit, l.sizing.onAxis(false).kind);
}

test "a border is inside the box by default, as everybody sets CSS to be" {
    const b: Border = .all(.hex(0xFF0000), 2);
    try testing.expectEqual(BorderPosition.inside, b.position);
    try testing.expectEqual(@as(u16, 2), b.width.top);
    try testing.expect(!b.width.isNone());
    try testing.expect(BorderWidth.none.isNone());
}
