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
const input = @import("input.zig");

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

    /// The lengths multiplied by an interface scale, and nothing else.
    ///
    /// `fraction` is a share of a parent that has already been scaled, and a
    /// `weight` is a share of what is spare - so both mean the same thing at
    /// any size. Only `min` and `max` are pixels. See `Surface.scale`.
    pub inline fn scaled(self: Sizing, by: f32) Sizing {
        var out = self;
        out.min = geometry.scaleLength(self.min, by);
        out.max = geometry.scaleLength(self.max, by);
        return out;
    }

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
    /// Whether children that do not fit start a new line. See
    /// `Declaration.wrap`.
    wrap: bool = false,
    /// The space between one line of wrapped children and the next, across
    /// the main axis. `gap` is the space along it.
    wrap_gap: u16 = 0,

    pub const default: LayoutConfig = .{};

    /// Every length in it multiplied by an interface scale. See
    /// `Surface.scale`.
    pub fn scaled(self: LayoutConfig, by: f32) LayoutConfig {
        var out = self;
        out.sizing = .{
            .width = self.sizing.width.scaled(by),
            .height = self.sizing.height.scaled(by),
        };
        out.padding = self.padding.scaled(by);
        out.gap = geometry.scaleWhole(self.gap, by);
        out.wrap_gap = geometry.scaleWhole(self.wrap_gap, by);
        return out;
    }
};

/// What `Ui.open` takes: everything an element is, in one literal.
///
/// Flat rather than nested, because a nested `.layout = .{ .sizing = .{ ... } }`
/// is three lines of punctuation before anything is said. Ply nests it and
/// then provides builder methods to hide the nesting; a Zig struct literal
/// with defaults needs neither.
pub const Declaration = struct {
    /// A name for this element, so that state - hover, focus, scroll, what
    /// was typed - follows it between frames, wherever it is declared.
    ///
    /// Elements without one are numbered by their parent and their place
    /// among its unnamed children, so something appearing in another part of
    /// the tree leaves them alone. Another unnamed element appearing *before*
    /// one in the same parent still renumbers it, and so does its parent
    /// being renumbered - so anything whose state has to survive that wants a
    /// name. See `Ui.identifyUnnamed`.
    ///
    /// Read as the element is declared, so it may be formatted into a buffer
    /// that is reused straight afterwards.
    id: ?[]const u8 = null,

    width: Sizing = .fit,
    height: Sizing = .fit,
    padding: Padding = .none,
    gap: u16 = 0,
    align_x: AlignX = .left,
    align_y: AlignY = .top,
    direction: Direction = .left_to_right,

    /// Let children that do not fit start a new line. Ply's
    /// `layout(|l| l.wrap())`.
    ///
    /// A row of tags, a toolbar, a gallery of thumbnails: anything whose
    /// children should carry on underneath rather than be squeezed or run off
    /// the edge. Along the main axis, so a `left_to_right` element wraps into
    /// rows and a `top_to_bottom` one into columns.
    ///
    /// **Only bites when the main axis is constrained.** A row that fits its
    /// content has room for all of it and never wraps; one that is `.fixed`,
    /// `.grow`, `.percent` or squeezed by its parent wraps at its edge. A
    /// growing child is broken on by its *minimum*, not by the size it will
    /// grow to - which is what stops the answer depending on itself.
    ///
    /// A wrapping **column** whose width is `.fit` is the one shape that does
    /// not settle: the extra columns are known only after the heights are
    /// shared out, by which time the widths are already decided, so its
    /// ancestors made room for one column. Give such a column a width and it
    /// behaves. A row has neither problem, because the axis it wraps along is
    /// the one that is settled first.
    wrap: bool = false,
    /// The space between one wrapped line and the next, across the main axis.
    /// Ply's `wrap_gap`. `gap` is still the space along the line.
    wrap_gap: u16 = 0,

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

    /// What the pointer looks like over this element, or null to leave it to
    /// whatever is underneath. See `CursorShape` and `Ui.cursor`.
    ///
    /// A resize handle says `.resize_ew`, a map says `.crosshair`, a link
    /// says `.pointing_hand`. A text input says `.ibeam` on its own and does
    /// not need telling.
    cursor: ?CursorShape = null,

    /// Take it out of the flow and hang it off something. See `Floating`.
    floating: ?Floating = null,

    /// Called every frame the pointer is over this element - on *hover*, not
    /// on entering it, which is Ply's meaning too. See `Callback`.
    on_hover: ?Callback = null,
    /// Called once, on the frame the button goes down on this element.
    on_press: ?Callback = null,
    /// Called once, on the frame it comes up, with `on_target` saying whether
    /// it came up on the element it went down on.
    on_release: ?Callback = null,
    /// Called when this element takes the keyboard, and when it loses it.
    on_focus: ?Callback = null,
    on_unfocus: ?Callback = null,

    /// A picture drawn in this element's box, instead of a plain fill. See
    /// `Image`.
    image: ?Image = null,

    /// Turn this element **and everything inside it**. Ply's
    /// `rotate_visual`.
    rotate: ?Rotation = null,
    /// Turn only this element's own box, leaving its children where they
    /// were. Ply's `rotate_shape`.
    rotate_shape: ?Rotation = null,

    /// Whether the pointer stops here rather than reaching what is behind.
    /// Ply's `.capture()`, and what a button inside a draggable panel wants:
    /// dragging the button must not also drag the panel.
    capture: bool = false,
    /// Whether pressing here leaves the keyboard where it is. Ply's
    /// `.preserve_focus()`, for a toolbar control that should not take the
    /// caret out of the field beside it.
    preserve_focus: bool = false,

    /// Let this element take the focus from the keyboard or a pad, and say
    /// how. `.focus = .{}` is enough to be in the Tab order. See `Focus`.
    ///
    /// A text input takes the focus without being told to; its declaration
    /// only needs this to change where it comes in the order.
    focus: ?Focus = null,

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
            .wrap = self.wrap,
            .wrap_gap = self.wrap_gap,
        };
    }

    /// The aspect ratio this element is held to after the layout has run, and
    /// which way it is held. See `SlotFit`.
    pub fn slotFit(self: Declaration) ?SlotFit {
        if (self.contain) |ratio| return .{ .ratio = ratio, .mode = .contain };
        if (self.cover) |ratio| return .{ .ratio = ratio, .mode = .cover };
        return null;
    }

    /// This declaration with every length multiplied by an interface scale.
    ///
    /// **Every field here that means pixels, and none of the ones that mean
    /// fractions.** `contain` and `cover` are aspect ratios, a `percent`
    /// width is a share of a parent that has already been scaled, a grow
    /// weight is a share of what is spare, and a rotation's pivot is a
    /// fraction of a box - all four mean the same thing at any size, and
    /// multiplying them would be a bug rather than a scale.
    ///
    /// The one list, so that a new length is one line here rather than a
    /// thing every game gets wrong on its own. See `Surface.scale`.
    pub fn scaled(self: Declaration, by: f32) Declaration {
        if (by == 1) return self;

        var out = self;
        out.width = self.width.scaled(by);
        out.height = self.height.scaled(by);
        out.padding = self.padding.scaled(by);
        out.gap = geometry.scaleWhole(self.gap, by);
        out.wrap_gap = geometry.scaleWhole(self.wrap_gap, by);
        out.corner_radius = self.corner_radius.scaled(by);
        out.clip = self.clip.scaled(by);
        if (self.border) |line| out.border = line.scaled(by);
        if (self.floating) |float| out.floating = float.scaled(by);
        if (self.image) |picture| out.image = picture.scaled(by);
        return out;
    }
};

/// What `Ui.begin` is given: how big the surface is, and the two numbers that
/// turn one interface into an interface for *that* surface.
///
/// ```zig
/// ui.begin(.init(width, height));                     // the ordinary case
/// ui.begin(.{
///     .size = .init(3840, 2160),
///     .scale = 2,
///     .safe_area = .all(48),
/// });
/// ```
pub const Surface = struct {
    /// How big it is, in real pixels. What the root is laid out in, and what
    /// the commands come out measured in.
    size: geometry.Dimensions,

    /// What to multiply every length in every declaration by.
    ///
    /// A game at 3840 by 2160 wants an interface twice the size, not twice as
    /// much of it. Everything a declaration says in pixels is multiplied -
    /// fixed sizes, minima and maxima, padding, gaps, corner radii, border
    /// widths, floating offsets, scrollbar thicknesses, font sizes, letter
    /// spacing and line heights - and everything that says a fraction is left
    /// alone. See `Declaration.scaled`.
    ///
    /// **Doing it here rather than in the game** is the whole of why it
    /// exists. A game that multiplies its own numbers gets the ones it
    /// remembers, and forgets the font sizes, or the corner radii, or the one
    /// panel somebody else wrote.
    ///
    /// A zero or a negative is taken as one: an interface scaled to nothing
    /// is not something anybody meant to ask for.
    scale: f32 = 1,

    /// How far in from each edge the interface must keep, in the same pixels
    /// as `size`.
    ///
    /// A television overscans, a phone has a notch and a home indicator, and
    /// a handheld has rounded corners. The root is laid out inside this, and
    /// anything floating against the surface is placed inside it too, so an
    /// interface written for a rectangle becomes an interface for the part of
    /// one that can be seen.
    ///
    /// **It moves things; it does not cut them.** Nothing is clipped to it -
    /// a background asked to `.grow` fills the whole surface as before, which
    /// is what a full-bleed backdrop behind a safe interface wants.
    ///
    /// **Not multiplied by `scale`**, because it does not come from the
    /// design. `size` is what the display is and this is which part of it can
    /// be seen; the two are measured with the same ruler.
    safe_area: geometry.Padding = .none,

    /// A surface this big, at scale one, with no safe area. What
    /// `ui.begin(.init(w, h))` means, and why every program written before
    /// any of this existed still compiles.
    pub inline fn init(width: f32, height: f32) Surface {
        return .{ .size = .init(width, height) };
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

    /// The line's thickness multiplied by an interface scale. See
    /// `Surface.scale`.
    pub inline fn scaled(self: Border, by: f32) Border {
        var out = self;
        out.width = self.width.scaled(by);
        return out;
    }
};

/// How thick the line is on each side.
pub const BorderWidth = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub const none: BorderWidth = .{};

    /// Every side multiplied by an interface scale. See `Surface.scale`.
    pub inline fn scaled(self: BorderWidth, by: f32) BorderWidth {
        return .{
            .left = geometry.scaleWhole(self.left, by),
            .right = geometry.scaleWhole(self.right, by),
            .top = geometry.scaleWhole(self.top, by),
            .bottom = geometry.scaleWhole(self.bottom, by),
        };
    }

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

/// What the pointer should look like over an element.
///
/// The ten shapes every desktop already has, under
/// [Fluxion Platform](https://github.com/kisstp2006/fluxion-platform)'s names
/// so that a program passing one to the other can switch on the tag and be
/// done. Named rather than drawn, because the system's own arrow is the one
/// that matches the theme, the size and the display's scale.
///
/// This is a *request*: nothing here draws a cursor or asks a window for one.
/// The layout says what the pointer is over and `Ui.cursor` reads it back;
/// setting it on the window is the program's line of code, once a frame.
pub const CursorShape = enum {
    /// The ordinary pointer, and what everything is when nothing says
    /// otherwise.
    arrow,
    /// The text caret. A text input asks for this without being told to.
    ibeam,
    /// Precise selection.
    crosshair,
    /// The hand, for a link.
    ///
    /// **Not something this works out for itself.** A hand over anything
    /// clickable is the web's convention and not a desktop's - native buttons
    /// keep the arrow - so an interface that wants it says so, per element.
    pointing_hand,
    /// Horizontal resize, as on a left or right edge.
    resize_ew,
    /// Vertical resize.
    resize_ns,
    /// The diagonal from top left to bottom right.
    resize_nwse,
    /// The other diagonal.
    resize_nesw,
    /// Move, or resize in every direction at once.
    resize_all,
    /// The circle-and-bar: not somewhere this can be dropped.
    not_allowed,
};

/// How an element takes the focus from the keyboard or a pad. Ply's
/// `.accessibility(|a| a.focusable())` and the numbers that go with it.
///
/// ```zig
/// ui.open(.{ .id = "play", .focus = .{} });                     // in the Tab order
/// ui.open(.{ .id = "quit", .focus = .{ .tab_index = 3 } });     // and where
/// ```
///
/// **Asked for, not worked out.** Nothing here decides that an element with
/// a callback is a button: an immediate-mode button is usually an element
/// whose branch asks `justReleased()`, and there is nothing on it to see. So
/// an element that wants the keyboard says so, the same way a text input is
/// the one thing that says so without being told.
///
/// Ply keeps these on its accessibility config, which is out of scope here -
/// but none of this needs a screen reader, and in a game it is how a pad
/// walks a menu.
pub const Focus = struct {
    /// Where it comes when Tab walks the interface: lower first, and every
    /// element that has one before every element that does not, which come
    /// in the order they were declared. Ties keep that order too. Ply's
    /// `tab_index`, and the browsers' rule.
    ///
    /// Rarely wanted. Declaration order is reading order, and an interface
    /// whose Tab order has to be spelt out is usually declared in the wrong
    /// order.
    tab_index: ?i16 = null,

    /// Where the arrow keys - or a pad's d-pad - go from here, by name, when
    /// the nearest element that way is not the right one. Ply's `focus_up`
    /// and its three siblings. Leave them out and `Ui.navigate` searches.
    ///
    /// **Read as the element is declared**, like `id`, so a name formatted
    /// into a buffer that the next element reuses is safe - the mistake
    /// `Floating.to` used to make. A name that was not on the page last frame
    /// is passed over, and the search decides instead.
    up: ?[]const u8 = null,
    down: ?[]const u8 = null,
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
};

/// Something to call when an element is pointed at or focused. Ply's
/// `on_hover` and its four siblings.
///
/// A context pointer and a function, which is what a closure is once the
/// sugar is taken away - and the same shape `text.Measurer` already has. Ply
/// writes `.on_press(|| count += 1)` and Rust captures `count`; Zig has no
/// closures, so the thing being captured is passed as the context and the
/// callback casts it back:
///
/// ```zig
/// fn pressed(context: ?*anyopaque, event: Callback.Event) void {
///     const count: *u32 = @ptrCast(@alignCast(context.?));
///     count.* += 1;
///     _ = event;
/// }
///
/// ui.empty(.{ .id = "button", .on_press = .{ .context = &count, .call = pressed } });
/// ```
///
/// **They are called when the frame is over**, from `Ui.end`, after the
/// commands are built - which is where Ply calls its own. A callback may look
/// at anything and change the program's own state; what it must not do is
/// declare elements, because the frame it would declare them into has already
/// been handed over.
///
/// Everything but the focus pair can be had by asking instead - `hovered()`,
/// `justReleased()` - and asking is usually the better shape in an
/// immediate-mode interface, because the answer is right there in the branch
/// that drew the button. These are for the times it is not: a callback can be
/// registered by whatever *owns* the button rather than by whatever draws it.
pub const Callback = struct {
    /// Passed back untouched. Whatever the callback needs to reach.
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, event: Event) void,

    /// What happened. One shape for all five, where Ply has three - the
    /// fields that do not apply are simply the ones nobody reads.
    pub const Event = struct {
        /// Which element: its name hashed, as `Ui.identify` does it, or the
        /// number an unnamed one goes by - see `Declaration.id`.
        id: u32,
        /// Where the pointer was and what its button was doing. The state a
        /// focus change was noticed in, for those two.
        pointer: input.Pointer,
        /// For a release: whether the pointer was still on the element when
        /// the button came up, which is the difference between a click and a
        /// drag away. False for everything else. Ply passes the same flag.
        on_target: bool = false,
    };
};

/// A turn, and which way round. Ply's `VisualRotationConfig` and its shape
/// twin, which differ only in what they turn.
///
/// ```zig
/// .rotate = .degrees(-4),                       // this and everything in it
/// .rotate_shape = .{ .radians = 0.3 },          // only its own box
/// ```
///
/// **It changes nothing about the layout.** An element takes up the room its
/// unrotated box does, and the boxes beside it do not move - which is Ply's
/// behaviour and the only one that makes sense: a badge tilted four degrees
/// should not reflow the page.
pub const Rotation = struct {
    radians: f32 = 0,
    /// Where the turn happens, in fractions of the element's own box. The
    /// middle by default; `.{ .x = 0, .y = 0 }` is its top left corner.
    ///
    /// Ply has a pivot on its visual rotation and none on its shape rotation.
    /// Both have one here, because there is no reason for them to differ and
    /// one fewer thing to remember.
    pivot: geometry.Vec2 = .{ .x = 0.5, .y = 0.5 },
    /// Mirrored before the turn, as Ply applies its flips.
    flip_x: bool = false,
    flip_y: bool = false,

    /// The same in degrees, which is how a designer says it.
    pub inline fn degrees(angle: f32) Rotation {
        return .{ .radians = angle * std.math.pi / 180.0 };
    }

    /// Whether it leaves everything where it was.
    pub inline fn isNone(self: Rotation) bool {
        return self.radians == 0 and !self.flip_x and !self.flip_y;
    }

    /// The motion this is, for an element with this box.
    pub fn motion(self: Rotation, box: geometry.BoundingBox) geometry.Transform {
        return .about(
            .{
                .x = box.x + box.width * self.pivot.x,
                .y = box.y + box.height * self.pivot.y,
            },
            self.radians,
            self.flip_x,
            self.flip_y,
        );
    }
};

/// A picture drawn in an element's box. Ply's `.image(...)`.
///
/// **A number, not a texture.** The layout half of this library has never
/// heard of a GPU and does not want to: what the number means is a table the
/// program gave its renderer, and `render.Renderer.setTextures` is where the
/// two meet. A program with one atlas of icons registers it once and then
/// names slices of it.
///
/// **It does not size the element.** Nothing here knows how many pixels the
/// texture is, so an image element is as big as it was declared - which is
/// Ply's behaviour too. `contain` and `cover` are how a picture is held to
/// its own proportions inside the room it was given.
pub const Image = struct {
    /// Which texture, as an index into whatever table the renderer was given.
    texture: u32 = 0,
    /// Painted under it, and visible wherever the image is transparent or
    /// does not cover the box.
    background_color: Color = .transparent,
    /// Which part of the texture to draw, in fractions of the whole from
    /// zero to one - so `.init(0, 0, 0.25, 0.25)` is the top left quarter.
    ///
    /// **Not in Ply**, and the reason to have it is that every real interface
    /// has one sheet of icons rather than a texture per icon. Without it a
    /// program cannot name a piece of one.
    source: geometry.BoundingBox = .init(0, 0, 1, 1),
    /// Multiplied into the image. White leaves it alone, and anything else
    /// tints it - which is how one white icon becomes every colour of icon.
    /// Also not in Ply.
    tint: Color = .white,
    nine_slice: ?NineSlice = null,

    pub fn scaled(self: Image, by: f32) Image {
        var out = self;
        if (self.nine_slice) |slice| out.nine_slice = slice.scaled(by);
        return out;
    }
};

/// Four fixed borders around a stretchable centre. Source borders are
/// fractions of `Image.source`; destination borders are interface pixels.
pub const NineSlice = struct {
    source_left: f32,
    source_right: f32,
    source_top: f32,
    source_bottom: f32,
    border: geometry.Padding,

    pub fn scaled(self: NineSlice, by: f32) NineSlice {
        var out = self;
        out.border = self.border.scaled(by);
        return out;
    }
};

test "a nine-slice scales only its destination border" {
    const slice: NineSlice = .{
        .source_left = 0.25,
        .source_right = 0.25,
        .source_top = 0.25,
        .source_bottom = 0.25,
        .border = .all(8),
    };
    const scaled = slice.scaled(1.5);
    try testing.expectEqual(geometry.Padding.all(12), scaled.border);
    try testing.expectEqual(@as(f32, 0.25), scaled.source_left);
}

/// An element positioned against another one rather than laid out in the
/// flow. Ply's `FloatingConfig`.
///
/// **It is not its parent's child for layout purposes.** Its siblings are
/// placed as if it were not declared, it does not count towards the parent's
/// fit size, and nothing shifts when it appears or goes away - which is the
/// whole point. A menu, a tooltip, a dropdown and a modal are all this one
/// feature, and every one of them has to be able to appear without the page
/// under it moving.
///
/// Where it goes is two anchor points and an offset: a point on this element
/// is put on a point of whatever it is attached to.
///
/// ```zig
/// ui.open(.{
///     .id = "menu",
///     .width = .fixed(180),
///     .floating = .{ .anchor = .below, .offset = .{ .x = 0, .y = 4 } },
/// });
/// defer ui.close();
/// ```
pub const Floating = struct {
    /// What it hangs off. See `Attach`.
    attach: Attach = .parent,
    /// Which element, when `attach` is `.id`. Looked up once the whole tree
    /// is laid out, so it may name something declared later - which Ply's
    /// cannot, because it resolves as the element is declared.
    ///
    /// The name itself is read as this element is declared, like `id`, so it
    /// may be formatted into a buffer that the next float reuses.
    to: ?[]const u8 = null,
    /// Which point of this element goes on which point of the target.
    anchor: Anchor = .{},
    /// Moved by this much afterwards, in pixels. The gap between a button and
    /// the menu under it.
    offset: geometry.Vec2 = .{ .x = 0, .y = 0 },
    /// Which floating element is drawn over which. Ties are drawn in the
    /// order they were declared.
    ///
    /// Not the same as `Declaration.z_index`, which is a number carried on
    /// every command for a renderer that wants to sort. This one decides the
    /// order the floating elements are *emitted* in, which is what actually
    /// puts one over another.
    z_index: i16 = 0,
    /// Whether to cut it off at the edge of what it is attached to. Ply's
    /// `clip_by_parent`.
    clip: bool = false,

    pub const Attach = enum {
        /// The element it was declared inside. The usual one.
        parent,
        /// The whole surface, so a modal can be declared wherever it is
        /// convenient and still cover the window.
        root,
        /// The element named by `to`.
        id,
    };

    /// Which point of the floating element is put on which point of the
    /// target. Ply's `anchor((element_x, element_y), (parent_x, parent_y))`,
    /// as a struct - so a caller names only the ends they care about.
    pub const Anchor = struct {
        element_x: geometry.AlignX = .left,
        element_y: geometry.AlignY = .top,
        parent_x: geometry.AlignX = .left,
        parent_y: geometry.AlignY = .top,

        /// The four that get written. Everything else is worth spelling out.
        pub const below: Anchor = .{ .parent_y = .bottom };
        pub const above: Anchor = .{ .element_y = .bottom };
        pub const after: Anchor = .{ .parent_x = .right };
        pub const before: Anchor = .{ .element_x = .right };
        /// Middle on middle, which is where a dialog goes.
        pub const centered: Anchor = .{
            .element_x = .center,
            .element_y = .center,
            .parent_x = .center,
            .parent_y = .center,
        };
    };

    /// The nudge off the anchor multiplied by an interface scale. The anchor
    /// itself is a pair of alignments and means the same at any size. See
    /// `Surface.scale`.
    pub inline fn scaled(self: Floating, by: f32) Floating {
        var out = self;
        out.offset = .{ .x = self.offset.x * by, .y = self.offset.y * by };
        return out;
    }
};

/// The bar drawn down the edge of a scroll container.
///
/// Ply's `ScrollbarConfig`, defaults and all, and the defaults are the whole
/// design: a six pixel half-transparent grey overlay that sits on top of the
/// content rather than taking room from it. Turning it on is one word -
/// `.scrollbar = .{}` - and everything below has an answer already.
pub const Scrollbar = struct {
    /// How thick the bar is. Ply clamps this to at least one pixel and so
    /// does the geometry, so a zero here draws a hairline rather than
    /// nothing.
    width: f32 = 6,
    /// The thumb's rounding. Half the width gives the usual lozenge.
    corner_radius: f32 = 3,
    /// The part that moves.
    thumb_color: Color = .bytes(128, 128, 128, 128),
    /// The groove behind it, or null for none - which is the default, and is
    /// what makes the bar an overlay rather than a gutter.
    track_color: ?Color = null,
    /// How short the thumb may get. Without a floor, a long enough document
    /// gives a thumb of half a pixel that nobody can grab.
    min_thumb_size: f32 = 20,
    /// Fade the bar out after this many still seconds, or null to leave it
    /// showing. See `Ui.visibility` for the fade itself.
    ///
    /// **Seconds, where Ply counts frames**, and it is the one number here
    /// whose units differ from Ply's. A bar tuned to disappear after two
    /// seconds at sixty frames disappears after one at a hundred and twenty
    /// and after four on a machine having a bad time - so Ply's version is
    /// right at exactly one frame rate and wrong at every other. A game knows
    /// its frame time; the layout is told it once, by `Ui.tick`.
    ///
    /// Nothing fades in a program that never calls `Ui.tick`: no clock, no
    /// seconds, and a bar that stays is the safer of the two ways to be
    /// wrong.
    hide_after_seconds: ?f32 = null,

    /// Its three lengths multiplied by an interface scale. The hold is a time
    /// and stays as it is. See `Surface.scale`.
    pub inline fn scaled(self: Scrollbar, by: f32) Scrollbar {
        var out = self;
        out.width = self.width * by;
        out.corner_radius = self.corner_radius * by;
        out.min_thumb_size = self.min_thumb_size * by;
        return out;
    }
};

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
    /// Whether dragging the content itself scrolls it, for a pointer that is
    /// not a finger. Ply's `no_drag_scroll`, and the same meaning: a touch
    /// drag still scrolls, because on a touch screen there is nothing else.
    ///
    /// A list of buttons is the case for turning it off. Dragging one on a
    /// desktop is more likely to be a stray movement than a scroll, and the
    /// wheel and the scrollbar are both still there.
    ///
    /// See `Ui.setTouch` for what tells the two pointers apart.
    no_drag_scroll: bool = false,
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

    /// Whether to draw a scrollbar, and what it looks like. Null for none,
    /// which is Ply's default too - a container scrolls by wheel and by drag
    /// whether or not anything is drawn down its edge.
    ///
    /// Only ever shown on an axis that both scrolls *and* overflows, so
    /// turning it on for a list that turns out to be short costs nothing.
    scrollbar: ?Scrollbar = null,

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

    /// The bar's lengths multiplied by an interface scale.
    ///
    /// `offset` is not touched: it is where the container is scrolled to,
    /// which is already in the pixels the last frame put it in. See
    /// `Surface.scale`.
    pub inline fn scaled(self: Clip, by: f32) Clip {
        var out = self;
        if (self.scrollbar) |configured| out.scrollbar = configured.scaled(by);
        return out;
    }

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

    /// The same clip with a scrollbar on it. Ply's
    /// `.overflow(|o| o.scroll().scrollbar(|s| s))`, and written the same way
    /// round: the scrolling is decided first and the bar is dressing on top.
    ///
    /// ```zig
    /// .clip = Clip.scrollY.bar(.{}),
    /// .clip = Clip.scroll.bar(.{ .width = 10, .track_color = .hex(0x202020) }),
    /// ```
    pub inline fn bar(self: Clip, config: Scrollbar) Clip {
        var with = self;
        with.scrollbar = config;
        return with;
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
