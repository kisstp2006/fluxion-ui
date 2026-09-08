// SPDX-License-Identifier: BSD-2-Clause

//! The layout, from a tree of declarations to a list of things to draw.
//!
//! One frame is three phases, and they run in this order for a reason:
//!
//!   1. **Fit**, going up. As each element is closed, it takes the size its
//!      children turned out to need. This happens *during* the declaration -
//!      `close` does it - because by then everything inside is already known.
//!   2. **Grow and shrink**, going down, once per axis. Now that a parent has
//!      a size, the spare space is shared out among the children that asked
//!      to grow, and any overflow is taken back off the largest ones. X
//!      first, then Y, because a `ratio` height depends on a settled width.
//!   3. **Position and emit**, depth first. Every element now has a size, so
//!      one walk down the tree puts each box where it goes and writes the
//!      commands out back to front.
//!
//! That is Clay's pipeline, which is Ply's pipeline, and the order is not a
//! preference: a grow pass cannot run before its parent has a size, and a
//! parent that fits its children cannot have one before they do.
//!
//! ```zig
//! var ui: Ui = .init(gpa);
//! defer ui.deinit();
//!
//! ui.begin(.init(1280, 720));
//! {
//!     ui.open(.{ .width = .grow, .height = .grow, .padding = .all(24), .gap = 12 });
//!     defer ui.close();
//!
//!     ui.open(.{ .width = .fixed(200), .height = .grow, .background_color = .hex(0x262220) });
//!     ui.close();
//! }
//! for (try ui.end()) |command| { ... }
//! ```
//!
//! **`open` and `close` must be balanced**, and `defer ui.close()` inside a
//! block is how to be sure they are. An element left open is a programming
//! error, not a layout that leans: `end` answers `error.ElementLeftOpen`
//! rather than guessing what was meant.
//!
//! Nothing here draws. What comes out is `commands.RenderCommand`, and what
//! draws those is somebody else - see `commands`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const color = @import("color.zig");
const commands = @import("commands.zig");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const text_mod = @import("text.zig");

const BoundingBox = geometry.BoundingBox;
const Color = color.Color;
const CornerRadius = geometry.CornerRadius;
const Dimensions = geometry.Dimensions;
const LayoutConfig = layout.LayoutConfig;
const RenderCommand = commands.RenderCommand;

const Ui = @This();

/// How deep the tree may go. A UI that nests two hundred deep has a loop in
/// it, and finding out here is better than finding out in a stack overflow.
pub const max_depth = 256;

/// The seed the element names are hashed with. Any constant would do; this
/// one is written down so that a name hashes to the same number in every
/// build, which is what makes a recorded layout comparable between runs.
const id_seed: u64 = 0xF1D_0000_0001;

/// What can go wrong that is worth stopping for.
pub const Error = error{
    /// `end` was called with an element still open. Almost always a missing
    /// `defer ui.close()`.
    ElementLeftOpen,
    /// `close` was called with nothing open.
    NothingToClose,
    /// The tree nested deeper than `max_depth`.
    TooDeep,
    /// Both axes of one element were given `ratio` sizing, so neither has
    /// anything to resolve against.
    RatioOnBothAxes,
} || Allocator.Error;

/// A position, in pixels from the top left of the surface.
///
/// A local type rather than `Dimensions`, because `position.width` for an x
/// coordinate reads as a mistake even when it is not one, and because the
/// walk below is where an axis mix-up would be hardest to see.
const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    const zero: Point = .{};

    inline fn onAxis(self: Point, x_axis: bool) f32 {
        return if (x_axis) self.x else self.y;
    }
};

/// One element, as the solver sees it. Not the declaration - that is
/// `layout.Declaration`, which is what the caller writes.
const Element = struct {
    id: u32,
    config: LayoutConfig,

    background_color: Color,
    corner_radius: CornerRadius,
    border: ?layout.Border,
    z_index: i16,
    /// An aspect ratio the resolved box is held to once the layout has run.
    /// See `layout.SlotFit`.
    slot_fit: ?layout.SlotFit,

    /// Which run of text this element draws, if it is one. Index into `runs`.
    run: ?u32 = null,

    /// The size it currently believes it is. Filled by the fit pass, then
    /// adjusted by the grow and shrink passes.
    dimensions: Dimensions = .zero,
    /// The smallest it could be without its content spilling. What the shrink
    /// pass will not go below.
    min_dimensions: Dimensions = .zero,

    /// Where it ended up. Filled by the position pass, for *every* element -
    /// including the ones that paint nothing. A transparent container still
    /// occupies a rectangle, and hit testing, scrolling and a debug inspector
    /// all need to know which.
    box: BoundingBox = .zero,

    /// Where this element's children are in `children`. Only meaningful once
    /// the element has been closed.
    children_start: u32 = 0,
    children_length: u32 = 0,
};

/// An element that has been opened and not yet closed.
const Open = struct {
    element: u32,
    /// How long `pending` was when this element was opened. Everything pushed
    /// after that point is one of its children - which is how `close` finds
    /// them in constant time instead of searching.
    pending_at: u32,
};

/// A run of text, and where its lines ended up.
const TextRun = struct {
    /// Borrowed from the caller, and valid until the next `begin`. A UI
    /// declares its text from strings it already has - a field, a literal, a
    /// buffer it formatted - and copying every one of them every frame would
    /// be the largest allocation in the library by far.
    content: []const u8,
    style: text_mod.TextStyle,
    element: u32,
    lines_start: u32 = 0,
    lines_len: u32 = 0,
};

/// One line of a wrapped run.
const Line = struct {
    /// Where it starts in the run, and how many bytes it is.
    start: u32,
    len: u32,
    /// How wide it came out, for aligning it against the others.
    width: f32,
};

/// One entry of the position-and-emit walk.
const Frame = struct {
    element: u32,
    /// Where this element's top left ended up.
    position: Point,
    /// Where the next child goes, relative to `position`. Starts at the
    /// padding plus the main-axis alignment, and advances as children are
    /// placed.
    next_child: Point,
    /// How many of this element's children have been placed.
    placed: u32 = 0,
};

gpa: Allocator,

/// Every element declared this frame, in the order they were opened. Index
/// zero is the root.
elements: std.ArrayList(Element),
/// Every element's children, flattened. An element's are
/// `children[start..][0..length]`.
children: std.ArrayList(u32),
/// Children of elements that are still open, waiting to be claimed by
/// `close`.
pending: std.ArrayList(u32),
/// The elements currently open, innermost last.
open_stack: std.ArrayList(Open),

/// This frame's output.
output: std.ArrayList(RenderCommand),

/// The text declared this frame. One entry per `text` call.
runs: std.ArrayList(TextRun),
/// Every run's lines, flattened, after wrapping.
lines: std.ArrayList(Line),

/// How to find out how wide a piece of text is.
///
/// Null until `setMeasurer`, and a `text` call without one lays out as an
/// element of zero size - which is wrong, but wrong in a way that shows on
/// screen rather than one that stops the program. A UI with no text does not
/// need one at all.
measurer: ?text_mod.Measurer = null,

/// Scratch for the walks, kept between frames so that a steady-state frame
/// does not allocate at all.
queue: std.ArrayList(u32),
resizable: std.ArrayList(u32),
walk: std.ArrayList(Frame),

/// How big the surface is.
surface: Dimensions = .zero,

/// The first error `open` or `close` ran into, kept until `end`.
///
/// A UI declaration is a hundred calls in a row, and `try` on every one of
/// them would drown the thing being described. So the two hot calls report
/// nothing and `end` reports for them - which is the same trade Ply makes,
/// and the one an immediate-mode API always makes.
deferred: ?Error = null,

/// Make a `Ui`. The allocator is the only one it will ever use.
///
/// It keeps its arrays between frames and clears them rather than freeing, so
/// a UI whose shape has settled stops allocating after a few frames. An arena
/// from [Fluxion Mem](https://github.com/kisstp2006/fluxion-mem) works and is
/// not needed - the point of one is to make freeing cheap, and this frees
/// once.
pub fn init(gpa: Allocator) Ui {
    return .{
        .gpa = gpa,
        .elements = .empty,
        .children = .empty,
        .pending = .empty,
        .open_stack = .empty,
        .output = .empty,
        .runs = .empty,
        .lines = .empty,
        .queue = .empty,
        .resizable = .empty,
        .walk = .empty,
    };
}

pub fn deinit(self: *Ui) void {
    self.elements.deinit(self.gpa);
    self.children.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.open_stack.deinit(self.gpa);
    self.output.deinit(self.gpa);
    self.runs.deinit(self.gpa);
    self.lines.deinit(self.gpa);
    self.queue.deinit(self.gpa);
    self.resizable.deinit(self.gpa);
    self.walk.deinit(self.gpa);
    self.* = undefined;
}

/// Start a frame on a surface of this size.
///
/// Everything from the previous frame is dropped, including the command list
/// the last `end` handed back - so a renderer that means to keep commands
/// past this point copies them.
pub fn begin(self: *Ui, surface: Dimensions) void {
    self.surface = surface;
    self.deferred = null;

    self.elements.clearRetainingCapacity();
    self.children.clearRetainingCapacity();
    self.pending.clearRetainingCapacity();
    self.open_stack.clearRetainingCapacity();
    self.output.clearRetainingCapacity();
    self.runs.clearRetainingCapacity();
    self.lines.clearRetainingCapacity();
}

/// Say how to measure text. See `text_mod.Measurer`.
///
/// Set once, before the first frame. A program using
/// [Fluxion Font](https://github.com/kisstp2006/fluxion-font) wires its own
/// here; a test, a terminal or a code editor can use
/// `text_mod.Measurer.monospace`.
pub fn setMeasurer(self: *Ui, measurer: text_mod.Measurer) void {
    self.measurer = measurer;
}

/// Open an element. Every `open` needs a `close`, and `defer` is how.
pub fn open(self: *Ui, declaration: layout.Declaration) void {
    self.openChecked(declaration) catch |err| self.remember(err);
}

fn openChecked(self: *Ui, declaration: layout.Declaration) Error!void {
    if (self.open_stack.items.len >= max_depth) return error.TooDeep;

    const index: u32 = @intCast(self.elements.items.len);
    try self.elements.append(self.gpa, .{
        .id = identify(declaration.id, index),
        .config = declaration.layout(),
        .background_color = declaration.background_color,
        .corner_radius = declaration.corner_radius,
        .border = declaration.border,
        .z_index = declaration.z_index,
        .slot_fit = declaration.slotFit(),
    });

    // The new element is a child of whatever is open, unless it is the root.
    if (self.open_stack.items.len > 0) try self.pending.append(self.gpa, index);

    try self.open_stack.append(self.gpa, .{
        .element = index,
        .pending_at = @intCast(self.pending.items.len),
    });
}

/// A run of text. Ply's `ui.text(text, |t| ...)`.
///
/// Not an `open` and a `close`: a text element has no children and its size
/// comes from measuring rather than from summing, so it is added whole. The
/// string is borrowed and must outlive the frame - see `TextRun.content`.
///
/// ```zig
/// ui.text("Hello, Fluxion!", .{ .font_size = 32, .color = .hex(0xFFFFFF) });
/// ```
///
/// The element it makes is as wide as the text would be unbroken and as
/// narrow as its longest word - which is the whole reason the shrink pass
/// exists. Every other kind of element has a minimum equal to its content and
/// so cannot give way; a paragraph can.
pub fn text(self: *Ui, content: []const u8, style: text_mod.TextStyle) void {
    self.textChecked(content, style) catch |err| self.remember(err);
}

fn textChecked(self: *Ui, content: []const u8, style: text_mod.TextStyle) Error!void {
    const index: u32 = @intCast(self.elements.items.len);

    // Without a measurer there is nothing to measure with, and a zero-sized
    // element is a visible mistake rather than a silent one.
    const measured: geometry.Dimensions, const smallest: geometry.Dimensions =
        if (self.measurer) |measurer| blk: {
            const line_height = measurer.lineHeight(style);
            const height = line_height * @as(f32, @floatFromInt(text_mod.hardLineCount(content)));
            break :blk .{
                .init(text_mod.unwrappedWidth(content, style, measurer), height),
                .init(text_mod.widestWord(content, style, measurer), height),
            };
        } else .{ .zero, .zero };

    try self.elements.append(self.gpa, .{
        .id = identify(null, index),
        .config = .{},
        .background_color = .transparent,
        .corner_radius = .sharp,
        .border = null,
        .z_index = 0,
        .slot_fit = null,
        .run = @intCast(self.runs.items.len),
        .dimensions = measured,
        .min_dimensions = smallest,
    });

    try self.runs.append(self.gpa, .{
        .content = content,
        .style = style,
        .element = index,
    });

    // A text element is somebody's child, and never the root: text at the top
    // level has nothing to be measured against.
    if (self.open_stack.items.len > 0) try self.pending.append(self.gpa, index);
}

/// An element with no children: `open` and `close` in one call.
///
/// Ply spells this `ui.element()...empty()`, and it is worth having for the
/// same reason Ply has it - a leaf is the commonest thing in any UI, and
/// writing an `open` and a `close` around nothing is two lines saying one
/// thing. Everything `open` takes, this takes.
///
/// ```zig
/// ui.empty(.{ .width = .fixed(12), .height = .fixed(12), .background_color = .hex(0x53A3F2) });
/// ```
pub fn empty(self: *Ui, declaration: layout.Declaration) void {
    self.open(declaration);
    self.close();
}

/// Close the innermost open element, and give it the size its children need.
///
/// This is phase one, and it happens here rather than in `end` because it
/// can: everything inside the element has already been declared and measured,
/// so the sum is available exactly now and never has to be revisited.
pub fn close(self: *Ui) void {
    self.closeChecked() catch |err| self.remember(err);
}

fn closeChecked(self: *Ui) Error!void {
    const frame = self.open_stack.pop() orelse return error.NothingToClose;
    const index = frame.element;
    const config = self.elements.items[index].config;
    const along_x = config.direction.isMainAxisX();

    // Everything pushed onto `pending` after this element opened is one of
    // its children.
    const mine = self.pending.items[frame.pending_at..];
    const child_count: u32 = @intCast(mine.len);

    const padding_x = config.padding.onAxis(true);
    const padding_y = config.padding.onAxis(false);
    const gaps: f32 = if (child_count > 1)
        @floatFromInt((child_count - 1) * config.gap)
    else
        0;

    // The main axis sums; the cross axis takes the widest.
    var main: f32 = if (along_x) padding_x else padding_y;
    var main_min: f32 = main;
    var cross: f32 = 0;
    var cross_min: f32 = 0;

    const children_start: u32 = @intCast(self.children.items.len);
    for (mine) |child_index| {
        const child = self.elements.items[child_index];
        main += child.dimensions.onAxis(along_x);
        main_min += child.min_dimensions.onAxis(along_x);
        cross = @max(cross, child.dimensions.onAxis(!along_x));
        cross_min = @max(cross_min, child.min_dimensions.onAxis(!along_x));
        try self.children.append(self.gpa, child_index);
    }

    main += gaps;
    main_min += gaps;
    cross += if (along_x) padding_y else padding_x;
    cross_min += if (along_x) padding_y else padding_x;

    // The children have been claimed; they live in `children` now.
    self.pending.shrinkRetainingCapacity(frame.pending_at);

    const element = &self.elements.items[index];
    element.children_start = children_start;
    element.children_length = child_count;
    element.dimensions = if (along_x) .init(main, cross) else .init(cross, main);
    element.min_dimensions = if (along_x) .init(main_min, cross_min) else .init(cross_min, main_min);

    applyOwnSizing(element);
}

/// Hold an element to the size it asked for itself, now the fit is known.
fn applyOwnSizing(element: *Element) void {
    const sizing = element.config.sizing;

    inline for (.{ true, false }) |x_axis| {
        const wanted = if (x_axis) sizing.width else sizing.height;
        const size = if (x_axis) &element.dimensions.width else &element.dimensions.height;
        const smallest = if (x_axis) &element.min_dimensions.width else &element.min_dimensions.height;

        switch (wanted.kind) {
            // A percentage has nothing to be a percentage *of* until the
            // parent is sized, so it contributes nothing to the fit and is
            // filled in by the grow pass.
            .percent => {
                size.* = 0;
                smallest.* = 0;
            },
            // A ratio waits for the other axis, for the same reason.
            .ratio => {},
            else => {
                size.* = wanted.clamp(size.*);
                smallest.* = wanted.clamp(smallest.*);
            },
        }
    }
}

fn remember(self: *Ui, err: Error) void {
    if (self.deferred == null) self.deferred = err;
}

/// Finish the frame and hand back what to draw.
///
/// The list is owned by the `Ui` and is valid until the next `begin`.
pub fn end(self: *Ui) Error![]const RenderCommand {
    if (self.deferred) |err| {
        self.deferred = null;
        return err;
    }
    if (self.open_stack.items.len != 0) return error.ElementLeftOpen;
    if (self.elements.items.len == 0) return self.output.items;

    try self.checkRatios();

    // The root is the surface, whatever it asked for.
    self.elements.items[0].dimensions = self.surface;

    try self.sizeAlongAxis(true, 0);
    self.resolveRatios(true);

    // Text wraps once the widths are settled, and only then is a paragraph's
    // height known - so the heights it changed have to reach its ancestors
    // before the vertical pass runs. Doing this the other way round is what
    // makes a wrapped paragraph overflow the box drawn round it.
    try self.wrapText();
    self.propagateHeights();

    try self.sizeAlongAxis(false, 0);
    self.resolveRatios(false);
    try self.applySlotFit();

    try self.positionAndEmit();
    return self.output.items;
}

fn checkRatios(self: *Ui) Error!void {
    for (self.elements.items) |element| {
        if (element.config.sizing.width.kind == .ratio and
            element.config.sizing.height.kind == .ratio)
        {
            return error.RatioOnBothAxes;
        }
    }
}

/// Turn a settled axis into the other one, for elements sized by ratio.
fn resolveRatios(self: *Ui, x_axis_settled: bool) void {
    for (self.elements.items) |*element| {
        const wanted = element.config.sizing.onAxis(!x_axis_settled);
        if (wanted.kind != .ratio or wanted.fraction <= 0) continue;

        if (x_axis_settled) {
            element.dimensions.height = element.dimensions.width / wanted.fraction;
        } else {
            element.dimensions.width = element.dimensions.height * wanted.fraction;
        }
    }
}

// -------------------------------------------------------------------------
// Phase two: grow and shrink
// -------------------------------------------------------------------------

/// Share out the spare space on one axis, parents before children.
///
/// Breadth first, because a child cannot know its share until its parent has
/// a final size, and a parent's is final as soon as *its* parent's is.
fn sizeAlongAxis(self: *Ui, x_axis: bool, from: u32) Error!void {
    self.queue.clearRetainingCapacity();
    try self.queue.append(self.gpa, from);

    var at: usize = 0;
    while (at < self.queue.items.len) : (at += 1) {
        const parent_index = self.queue.items[at];
        const parent = self.elements.items[parent_index];
        const config = parent.config;

        const inner = @max(0, parent.dimensions.onAxis(x_axis) - config.padding.onAxis(x_axis));
        const children = self.childrenOf(parent);

        // Percentages resolve first: they are a share of the parent, not of
        // what is left after the others, so they take no part in the
        // distribution that follows.
        for (children) |child_index| {
            const child = &self.elements.items[child_index];
            const wanted = child.config.sizing.onAxis(x_axis);
            if (wanted.kind != .percent) continue;
            setSize(child, x_axis, wanted.clamp(inner * wanted.fraction));
        }

        if (config.direction.isMainAxisX() == x_axis) {
            try self.distributeMainAxis(parent_index, x_axis, inner);
        } else {
            // On the cross axis there is nothing to share: each child is
            // measured against the whole inner size on its own.
            for (children) |child_index| {
                const child = &self.elements.items[child_index];
                const wanted = child.config.sizing.onAxis(x_axis);

                if (wanted.kind == .grow) {
                    setSize(child, x_axis, @min(inner, wanted.max));
                }

                // And then *every* child is held inside the parent, growing
                // or not, but never squeezed below what its own content
                // needs. This is the line that makes a paragraph in a column
                // wrap to the column: without it a `fit` child keeps the
                // width it measured, which for text is the whole run
                // unbroken, and the wrap pass is handed a width it can never
                // break at.
                const smallest = child.min_dimensions.onAxis(x_axis);
                const held = @max(smallest, @min(child.dimensions.onAxis(x_axis), inner));
                setSize(child, x_axis, held);
            }
        }

        for (children) |child_index| try self.queue.append(self.gpa, child_index);
    }
}

/// Give out, or take back, the difference between what the children add up to
/// and what the parent has room for.
fn distributeMainAxis(self: *Ui, parent_index: u32, x_axis: bool, inner: f32) Error!void {
    const parent = self.elements.items[parent_index];
    const children = self.childrenOf(parent);
    if (children.len == 0) return;

    var content: f32 = if (children.len > 1)
        @floatFromInt(@as(u32, @intCast(children.len - 1)) * parent.config.gap)
    else
        0;
    for (children) |child_index| {
        content += self.elements.items[child_index].dimensions.onAxis(x_axis);
    }

    const spare = inner - content;
    if (@abs(spare) < epsilon) return;

    if (spare > 0) {
        try self.grow(children, x_axis, spare);
    } else {
        try self.shrink(children, x_axis, -spare);
    }
}

const epsilon = 0.001;

/// Hand `spare` pixels to the children that asked to grow.
///
/// Weighted, and the weighting is why this is a loop rather than one
/// division. Each child's claim on the space is its size divided by its
/// weight; the ones with the smallest claim are furthest behind, so they are
/// brought up to the next-smallest claim, and then that larger group moves
/// together. Repeat until the space is gone or everything has hit its
/// maximum. Ply added the weights over Clay; without them this is Clay's loop
/// exactly.
fn grow(self: *Ui, children: []const u32, x_axis: bool, spare_in: f32) Error!void {
    var spare = spare_in;

    self.resizable.clearRetainingCapacity();
    for (children) |child_index| {
        const child = self.elements.items[child_index];
        const wanted = child.config.sizing.onAxis(x_axis);
        if (wanted.kind != .grow or wanted.weight <= 0) continue;
        if (child.dimensions.onAxis(x_axis) >= wanted.max) continue;
        try self.resizable.append(self.gpa, child_index);
    }

    // Bounded: every pass either exhausts the space or retires a child, so
    // the child count is a ceiling rather than a hope.
    var passes: usize = 0;
    while (spare > epsilon and self.resizable.items.len > 0 and passes <= children.len + 1) : (passes += 1) {
        var smallest = std.math.floatMax(f32);
        var next_smallest = std.math.floatMax(f32);
        var weight_at_smallest: f32 = 0;

        for (self.resizable.items) |child_index| {
            const child = self.elements.items[child_index];
            const wanted = child.config.sizing.onAxis(x_axis);
            const claim = child.dimensions.onAxis(x_axis) / wanted.weight;

            if (claim < smallest - epsilon) {
                next_smallest = smallest;
                smallest = claim;
                weight_at_smallest = wanted.weight;
            } else if (claim <= smallest + epsilon) {
                weight_at_smallest += wanted.weight;
            } else if (claim < next_smallest) {
                next_smallest = claim;
            }
        }
        if (weight_at_smallest <= 0) break;

        // How far the trailing group can move: up to where the next group
        // is, or as far as the remaining space stretches, whichever is less.
        const to_next = if (next_smallest == std.math.floatMax(f32))
            std.math.floatMax(f32)
        else
            next_smallest - smallest;
        const step = @min(to_next, spare / weight_at_smallest);
        if (step <= 0) break;

        var given: f32 = 0;
        for (self.resizable.items) |child_index| {
            const child = &self.elements.items[child_index];
            const wanted = child.config.sizing.onAxis(x_axis);
            const current = child.dimensions.onAxis(x_axis);
            if (current / wanted.weight > smallest + epsilon) continue;

            const grown = @min(current + step * wanted.weight, wanted.max);
            given += grown - current;
            setSize(child, x_axis, grown);
        }

        spare -= given;
        if (given <= epsilon) break;
        self.retireAtCeiling(x_axis);
    }
}

/// Drop the children that have reached their maximum from the working set.
fn retireAtCeiling(self: *Ui, x_axis: bool) void {
    var kept: usize = 0;
    for (self.resizable.items) |child_index| {
        const child = self.elements.items[child_index];
        const wanted = child.config.sizing.onAxis(x_axis);
        if (child.dimensions.onAxis(x_axis) >= wanted.max) continue;
        self.resizable.items[kept] = child_index;
        kept += 1;
    }
    self.resizable.shrinkRetainingCapacity(kept);
}

/// Take `excess` pixels back off the children, largest first.
///
/// The mirror of `grow`, and largest-first for a reason worth stating: taking
/// the same amount from everything would flatten a deliberate size difference
/// long before it ran out of room. Shrinking the biggest down to the size of
/// the second biggest, then both down to the third, keeps the order the
/// author asked for as long as there is any room at all. Nothing goes below
/// its own `min` or below what its children need.
fn shrink(self: *Ui, children: []const u32, x_axis: bool, excess_in: f32) Error!void {
    var excess = excess_in;

    self.resizable.clearRetainingCapacity();
    for (children) |child_index| {
        const child = self.elements.items[child_index];
        const wanted = child.config.sizing.onAxis(x_axis);
        // Fixed elements are not negotiable, and percentages already had
        // their share taken out of the parent.
        if (wanted.kind == .fixed or wanted.kind == .percent) continue;
        if (child.dimensions.onAxis(x_axis) <= floorOf(child, x_axis)) continue;
        try self.resizable.append(self.gpa, child_index);
    }

    var passes: usize = 0;
    while (excess > epsilon and self.resizable.items.len > 0 and passes <= children.len + 1) : (passes += 1) {
        var largest: f32 = 0;
        var next_largest: f32 = 0;
        var count_at_largest: f32 = 0;

        for (self.resizable.items) |child_index| {
            const size = self.elements.items[child_index].dimensions.onAxis(x_axis);
            if (size > largest + epsilon) {
                next_largest = largest;
                largest = size;
                count_at_largest = 1;
            } else if (size >= largest - epsilon) {
                count_at_largest += 1;
            } else if (size > next_largest) {
                next_largest = size;
            }
        }
        if (count_at_largest <= 0) break;

        const step = @min(largest - next_largest, excess / count_at_largest);
        if (step <= 0) break;

        var taken: f32 = 0;
        for (self.resizable.items) |child_index| {
            const child = &self.elements.items[child_index];
            const current = child.dimensions.onAxis(x_axis);
            if (current < largest - epsilon) continue;

            const shrunk = @max(current - step, floorOf(child.*, x_axis));
            taken += current - shrunk;
            setSize(child, x_axis, shrunk);
        }

        excess -= taken;
        if (taken <= epsilon) break;
        self.retireAtFloor(x_axis);
    }
}

fn retireAtFloor(self: *Ui, x_axis: bool) void {
    var kept: usize = 0;
    for (self.resizable.items) |child_index| {
        const child = self.elements.items[child_index];
        if (child.dimensions.onAxis(x_axis) <= floorOf(child, x_axis)) continue;
        self.resizable.items[kept] = child_index;
        kept += 1;
    }
    self.resizable.shrinkRetainingCapacity(kept);
}

/// The smallest an element may be made: its declared minimum, or what its own
/// content needs, whichever is larger.
fn floorOf(element: Element, x_axis: bool) f32 {
    return @max(element.config.sizing.onAxis(x_axis).min, element.min_dimensions.onAxis(x_axis));
}

inline fn setSize(element: *Element, x_axis: bool, size: f32) void {
    if (x_axis) element.dimensions.width = size else element.dimensions.height = size;
}

/// Hold the elements that asked for an aspect ratio to it, and re-solve what
/// is inside them.
///
/// This runs after both axes have settled, and that is the whole difference
/// between `contain` and a `ratio` sizing. A `ratio` takes part in the
/// sharing out of space, so it moves its siblings. `contain` and `cover`
/// change only the box the element already won, so a picture is letterboxed
/// inside its slot and nothing beside it notices.
///
/// The children have to be solved again afterwards, because they were sized
/// against a box that has just changed underneath them.
fn applySlotFit(self: *Ui) Error!void {
    for (0..self.elements.items.len) |i| {
        const index: u32 = @intCast(i);
        const fit = self.elements.items[index].slot_fit orelse continue;

        const size = self.elements.items[index].dimensions;
        if (size.width <= 0 or size.height <= 0 or fit.ratio <= 0) continue;

        self.elements.items[index].dimensions = switch (fit.mode) {
            // The largest box of this ratio that fits inside the room given.
            .contain => .init(
                @min(size.width, size.height * fit.ratio),
                @min(size.height, size.width / fit.ratio),
            ),
            // The smallest box of this ratio that covers it.
            .cover => .init(
                @max(size.width, size.height * fit.ratio),
                @max(size.height, size.width / fit.ratio),
            ),
        };

        if (self.elements.items[index].children_length > 0) {
            try self.sizeAlongAxis(true, index);
            try self.sizeAlongAxis(false, index);
        }
    }
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

/// Break every run into lines that fit the width it was given, and make each
/// text element as tall as the lines it ended up with.
fn wrapText(self: *Ui) Error!void {
    const measurer = self.measurer orelse return;
    self.lines.clearRetainingCapacity();

    for (self.runs.items) |*run| {
        const width = self.elements.items[run.element].dimensions.width;
        const line_height = measurer.lineHeight(run.style);

        run.lines_start = @intCast(self.lines.items.len);
        run.lines_len = 0;

        var words: text_mod.Words = .init(run.content, run.style, measurer);
        var start: ?u32 = null;
        var stop: u32 = 0;
        var line_width: f32 = 0;
        // The space before the next word, held back because a line that ends
        // here does not include it.
        var gap: f32 = 0;

        while (words.next()) |word| {
            if (word.isBreak()) {
                // The one break the text asks for itself. Honoured under
                // every mode but `.none`, and it ends the line even when the
                // line is empty - two newlines in a row are a blank line.
                if (run.style.wrap != .none) {
                    try self.lines.append(self.gpa, .{
                        .start = start orelse word.start,
                        .len = if (start) |from| stop - from else 0,
                        .width = line_width,
                    });
                    run.lines_len += 1;
                    start = null;
                    stop = 0;
                    line_width = 0;
                    gap = 0;
                }
                continue;
            }

            const wraps = run.style.wrap == .words;
            if (start != null and wraps and line_width + gap + word.width > width + 0.001) {
                try self.lines.append(self.gpa, .{
                    .start = start.?,
                    .len = stop - start.?,
                    .width = line_width,
                });
                run.lines_len += 1;
                start = word.start;
                stop = word.start + word.len;
                line_width = word.width;
                gap = word.space;
                continue;
            }

            if (start == null) {
                start = word.start;
                line_width = word.width;
            } else {
                line_width += gap + word.width;
            }
            stop = word.start + word.len;
            gap = word.space;
        }

        // Whatever is left, and an empty run still occupies one line - a
        // paragraph of nothing is a paragraph the height of one line, which
        // is what a text input with no text in it needs to be.
        if (start != null or run.lines_len == 0) {
            try self.lines.append(self.gpa, .{
                .start = start orelse 0,
                .len = if (start) |from| stop - from else 0,
                .width = line_width,
            });
            run.lines_len += 1;
        }

        self.elements.items[run.element].dimensions.height =
            line_height * @as(f32, @floatFromInt(run.lines_len));
    }
}

/// Give every container that fits its children the height they turned out to
/// need.
///
/// Only worth doing after `wrapText`, and only for the elements whose height
/// was decided by their contents: a paragraph that wrapped to three lines
/// where one was assumed has just made its parent taller, and its parent's
/// parent after that.
///
/// Backwards through the elements, which is post-order without a stack: they
/// were appended as the tree was declared, so a child always has a higher
/// index than its parent and is therefore reached first.
fn propagateHeights(self: *Ui) void {
    var i = self.elements.items.len;
    while (i > 0) {
        i -= 1;
        const element = self.elements.items[i];
        if (element.run != null) continue;
        if (element.config.sizing.height.kind != .fit) continue;
        if (element.children_length == 0) continue;

        const config = element.config;
        const stacked = !config.direction.isMainAxisX();

        var height: f32 = 0;
        var smallest: f32 = 0;
        for (self.childrenOf(element)) |child_index| {
            const child = self.elements.items[child_index];
            if (stacked) {
                height += child.dimensions.height;
                smallest += child.min_dimensions.height;
            } else {
                height = @max(height, child.dimensions.height);
                smallest = @max(smallest, child.min_dimensions.height);
            }
        }

        if (stacked and element.children_length > 1) {
            const gaps: f32 = @floatFromInt((element.children_length - 1) * config.gap);
            height += gaps;
            smallest += gaps;
        }

        const padding = config.padding.onAxis(false);
        self.elements.items[i].dimensions.height = config.sizing.height.clamp(height + padding);
        self.elements.items[i].min_dimensions.height = config.sizing.height.clamp(smallest + padding);
    }
}

/// Write out one command per line of a run.
fn emitText(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    const run_index = element.run orelse return;
    const measurer = self.measurer orelse return;

    const run = self.runs.items[run_index];
    if (run.style.color.invisible()) return;

    const line_height = measurer.lineHeight(run.style);

    for (0..run.lines_len) |i| {
        const line = self.lines.items[run.lines_start + i];
        if (line.len == 0) continue;

        // Each line is aligned inside the element's width on its own, which
        // is what makes a centred paragraph centred line by line rather than
        // as one block.
        const x = box.x + geometry.leadingSpaceX(box.width - line.width, run.style.alignment);
        const y = box.y + line_height * @as(f32, @floatFromInt(i));

        try self.output.append(self.gpa, .{
            .bounding_box = .init(x, y, line.width, line_height),
            .id = element.id,
            .z_index = element.z_index,
            .config = .{ .text = .{
                .text = run.content[line.start..][0..line.len],
                .color = run.style.color,
                .font_size = run.style.font_size,
                .letter_spacing = run.style.letter_spacing,
                .line_height = @intFromFloat(@round(line_height)),
                .font = run.style.font,
            } },
        });
    }
}

// -------------------------------------------------------------------------
// Phase three: position, and write the commands out
// -------------------------------------------------------------------------

/// Walk the tree depth first, placing every box and emitting what to draw.
///
/// Depth first with children in order is what puts the list in back-to-front
/// order without anything having to sort it: a parent's background is written
/// before its children are visited, and its border after they are done.
fn positionAndEmit(self: *Ui) Error!void {
    self.walk.clearRetainingCapacity();
    try self.walk.append(self.gpa, .{
        .element = 0,
        .position = .zero,
        .next_child = self.startOffset(self.elements.items[0]),
    });
    self.elements.items[0].box = .at(0, 0, self.elements.items[0].dimensions);
    try self.emitBackground(0, self.elements.items[0].box);
    try self.emitText(0, self.elements.items[0].box);

    while (self.walk.items.len > 0) {
        // Read what is needed out of the top frame before anything can grow
        // the array underneath it. A pointer into an `ArrayList` does not
        // survive an append to that list, and the append is four lines down.
        const depth = self.walk.items.len - 1;
        const frame = self.walk.items[depth];
        const element = self.elements.items[frame.element];
        const children = self.childrenOf(element);

        if (frame.placed >= children.len) {
            // Everything inside is done, so the border goes on top of it.
            try self.emitBorder(frame.element, element.box);
            _ = self.walk.pop();
            continue;
        }

        const child_index = children[frame.placed];
        const child = self.elements.items[child_index];
        const along_x = element.config.direction.isMainAxisX();

        // Along the main axis the offset has been advancing as children were
        // placed. Across it, each child is aligned on its own.
        const cross_room = @max(0, element.dimensions.onAxis(!along_x) -
            element.config.padding.onAxis(!along_x) -
            child.dimensions.onAxis(!along_x));
        const cross = if (along_x)
            geometry.leadingSpaceY(cross_room, element.config.align_y)
        else
            geometry.leadingSpaceX(cross_room, element.config.align_x);

        const x = frame.position.x + frame.next_child.x + (if (along_x) 0 else cross);
        const y = frame.position.y + frame.next_child.y + (if (along_x) cross else 0);

        // Advance the parent's cursor past this child and the gap after it.
        const gap: f32 = if (frame.placed + 1 < children.len)
            @floatFromInt(element.config.gap)
        else
            0;
        const step = child.dimensions.onAxis(along_x) + gap;
        if (along_x) {
            self.walk.items[depth].next_child.x += step;
        } else {
            self.walk.items[depth].next_child.y += step;
        }
        self.walk.items[depth].placed += 1;

        self.elements.items[child_index].box = .at(x, y, child.dimensions);
        try self.emitBackground(child_index, self.elements.items[child_index].box);
        try self.emitText(child_index, self.elements.items[child_index].box);

        if (self.walk.items.len >= max_depth) return error.TooDeep;
        try self.walk.append(self.gpa, .{
            .element = child_index,
            .position = .{ .x = x, .y = y },
            .next_child = self.startOffset(child),
        });
    }
}

/// Where the first child of an element goes, relative to the element: the
/// padding, plus whatever the main-axis alignment pushes it by.
fn startOffset(self: *Ui, element: Element) Point {
    const config = element.config;
    const along_x = config.direction.isMainAxisX();
    const children = self.childrenOf(element);

    var offset: Point = .{
        .x = @floatFromInt(config.padding.left),
        .y = @floatFromInt(config.padding.top),
    };
    if (children.len == 0) return offset;

    var content: f32 = if (children.len > 1)
        @floatFromInt(@as(u32, @intCast(children.len - 1)) * config.gap)
    else
        0;
    for (children) |child_index| {
        content += self.elements.items[child_index].dimensions.onAxis(along_x);
    }

    const room = @max(0, element.dimensions.onAxis(along_x) - config.padding.onAxis(along_x) - content);
    if (along_x) {
        offset.x += geometry.leadingSpaceX(room, config.align_x);
    } else {
        offset.y += geometry.leadingSpaceY(room, config.align_y);
    }
    return offset;
}

fn emitBackground(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    if (element.background_color.invisible() or box.empty()) return;

    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .id = element.id,
        .z_index = element.z_index,
        .config = .{ .rectangle = .{
            .color = element.background_color,
            .corner_radius = element.corner_radius.clampTo(box.width, box.height),
        } },
    });
}

fn emitBorder(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    const border = element.border orelse return;
    if (border.color.invisible() or border.width.isNone() or box.empty()) return;

    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .id = element.id,
        .z_index = element.z_index,
        .config = .{ .border = .{
            .color = border.color,
            .width = border.width,
            .position = border.position,
            .corner_radius = element.corner_radius.clampTo(box.width, box.height),
        } },
    });
}

// -------------------------------------------------------------------------
// Odds and ends
// -------------------------------------------------------------------------

inline fn childrenOf(self: *Ui, element: Element) []const u32 {
    return self.children.items[element.children_start..][0..element.children_length];
}

/// A number for an element, stable between frames.
///
/// A named element hashes its name, so it keeps the same number wherever it
/// moves in the tree - which is what will let hover, focus and scroll follow
/// it. An unnamed one takes its position in the declaration order, which is
/// stable as long as the shape of the tree is.
///
/// [Fluxion Hash](https://github.com/kisstp2006/fluxion-hash) is where this
/// belongs once state has to survive between frames. Until then a hash from
/// the standard library is one fewer dependency to pin.
fn identify(name: ?[]const u8, index: u32) u32 {
    const label = name orelse return index +% 1;
    return @truncate(std.hash.Wyhash.hash(id_seed, label));
}

/// The commands this frame produced, wrapped so they can be asked questions.
/// See `commands.List`.
pub fn list(self: *Ui) commands.List {
    return .{ .items = self.output.items };
}

/// The box an element ended up in, by name. Null if there is no such element,
/// or the frame has not finished yet.
///
/// Every element is findable this way, not only the ones that painted
/// something: a transparent container is where the layout put it, and a
/// caller asking where the body pane went should not have to give it a colour
/// to find out.
pub fn boxOf(self: *Ui, name: []const u8) ?BoundingBox {
    const wanted = identify(name, 0);
    for (self.elements.items) |element| {
        if (element.id == wanted) return element.box;
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// Every one of these is a layout with a known right answer, checked against
// the boxes that came out. That is the only way to test a layout engine: the
// passes are not separately meaningful, and an intermediate size is not worth
// asserting on because the next pass is allowed to change it.
//
// The elements are given a background so that they emit a command and can be
// found by name. An element that draws nothing is laid out just the same, but
// there is nothing to look at afterwards.

const paint: Color = .hex(0xFFFFFF);

/// Declare a leaf that can be found by name afterwards.
fn leaf(ui: *Ui, name: []const u8, d: layout.Declaration) void {
    var named = d;
    named.id = name;
    named.background_color = paint;
    ui.open(named);
    ui.close();
}

test "a fixed size is what it says" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .fixed(200), .height = .fixed(100) });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(0, 0, 200, 100), ui.boxOf("a").?);
}

test "the root takes the surface, whatever it asked for" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1280, 720));
    ui.open(.{ .id = "root", .width = .fixed(10), .height = .fixed(10), .background_color = paint });
    ui.close();
    _ = try ui.end();

    // The surface is not a suggestion: there is nowhere else for the root to
    // be, so its own sizing does not get a say.
    try testing.expectEqual(BoundingBox.init(0, 0, 1280, 720), ui.boxOf("root").?);
}

test "two growing children split what is left evenly" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "left", .{ .width = .grow, .height = .grow });
        leaf(&ui, "right", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(0, 0, 400, 600), ui.boxOf("left").?);
    try testing.expectEqual(BoundingBox.init(400, 0, 400, 600), ui.boxOf("right").?);
}

test "a grow weight is a share, not a size" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(900, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "one", .{ .width = .growWeighted(1), .height = .grow });
        leaf(&ui, "two", .{ .width = .growWeighted(2), .height = .grow });
    }
    _ = try ui.end();

    // 900 split one to two is 300 and 600, and the second starts where the
    // first ends. This is what Ply added over Clay.
    try testing.expectApproxEqAbs(300, ui.boxOf("one").?.width, 0.01);
    try testing.expectApproxEqAbs(600, ui.boxOf("two").?.width, 0.01);
    try testing.expectApproxEqAbs(300, ui.boxOf("two").?.x, 0.01);
}

test "a fixed sibling takes its share off the top before growing starts" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "sidebar", .{ .width = .fixed(200), .height = .grow });
        leaf(&ui, "content", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 200), ui.boxOf("sidebar").?.width);
    try testing.expectEqual(@as(f32, 600), ui.boxOf("content").?.width);
    try testing.expectEqual(@as(f32, 200), ui.boxOf("content").?.x);
}

test "padding is taken out of the inside, and children start after it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .padding = .all(24) });
        defer ui.close();
        leaf(&ui, "inner", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(24, 24, 752, 552), ui.boxOf("inner").?);
}

test "the gap goes between children and not after the last one" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(320, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow, .gap = 10 });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .grow, .height = .grow });
        leaf(&ui, "b", .{ .width = .grow, .height = .grow });
        leaf(&ui, "c", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    // Three children, two gaps: 320 less 20 is 300, so 100 each.
    try testing.expectApproxEqAbs(100, ui.boxOf("a").?.width, 0.01);
    try testing.expectApproxEqAbs(110, ui.boxOf("b").?.x, 0.01);
    try testing.expectApproxEqAbs(220, ui.boxOf("c").?.x, 0.01);
    // And the last one ends at the edge, with no trailing gap.
    try testing.expectApproxEqAbs(320, ui.boxOf("c").?.right(), 0.01);
}

test "a parent that fits is exactly as big as what is in it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();

        ui.open(.{ .id = "fitted", .padding = .all(10), .gap = 5, .background_color = paint });
        defer ui.close();
        leaf(&ui, "x", .{ .width = .fixed(30), .height = .fixed(40) });
        leaf(&ui, "y", .{ .width = .fixed(50), .height = .fixed(20) });
    }
    _ = try ui.end();

    // 10 + 30 + 5 + 50 + 10 across, and 10 + max(40, 20) + 10 down.
    const fitted = ui.boxOf("fitted").?;
    try testing.expectEqual(@as(f32, 105), fitted.width);
    try testing.expectEqual(@as(f32, 60), fitted.height);
}

test "a column stacks downwards" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom, .gap = 8 });
        defer ui.close();
        leaf(&ui, "top", .{ .width = .grow, .height = .fixed(40) });
        leaf(&ui, "bottom", .{ .width = .grow, .height = .fixed(60) });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(0, 0, 800, 40), ui.boxOf("top").?);
    try testing.expectEqual(BoundingBox.init(0, 48, 800, 60), ui.boxOf("bottom").?);
}

test "centring puts the spare space on both sides" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .align_x = .center, .align_y = .center });
        defer ui.close();
        leaf(&ui, "middle", .{ .width = .fixed(200), .height = .fixed(100) });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(300, 250, 200, 100), ui.boxOf("middle").?);
}

test "aligning to the far edge puts all the spare space in front" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{
            .width = .grow,
            .height = .grow,
            .align_x = .right,
            .align_y = .bottom,
        });
        defer ui.close();
        leaf(&ui, "corner", .{ .width = .fixed(100), .height = .fixed(50) });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(700, 550, 100, 50), ui.boxOf("corner").?);
}

test "a percentage is a share of the inside, not of the whole" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .padding = .all(50) });
        defer ui.close();
        leaf(&ui, "half", .{ .width = .percent(0.5), .height = .fixed(10) });
    }
    _ = try ui.end();

    // The inside is 700, so half of it is 350 and not 400.
    try testing.expectApproxEqAbs(350, ui.boxOf("half").?.width, 0.01);
}

test "fixed children that do not fit overflow rather than being squeezed" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(300, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .fixed(200), .height = .grow });
        leaf(&ui, "b", .{ .width = .fixed(200), .height = .grow });
    }
    _ = try ui.end();

    // A fixed size is not a negotiating position. Two of them in a container
    // too small keep their width and run off the end, which is what lets a
    // clip container scroll and what a silent squeeze would hide.
    try testing.expectEqual(@as(f32, 200), ui.boxOf("a").?.width);
    try testing.expectEqual(@as(f32, 200), ui.boxOf("b").?.width);
    try testing.expectEqual(@as(f32, 200), ui.boxOf("b").?.x);
}

test "shrinking stops at what the content needs" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(100, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        // Two elements that will not go below eighty, in a hundred pixels.
        leaf(&ui, "one", .{ .width = .fitBetween(80, 200), .height = .grow });
        leaf(&ui, "two", .{ .width = .fitBetween(80, 200), .height = .grow });
    }
    _ = try ui.end();

    // The shrink pass runs - there is 160 of content in 100 pixels - and
    // finds nothing it may take, because the floor is the whole of each
    // element. Overflowing is the right answer: the alternative is content
    // nobody can read.
    try testing.expectApproxEqAbs(80, ui.boxOf("one").?.width, 0.01);
    try testing.expectApproxEqAbs(80, ui.boxOf("two").?.width, 0.01);
}

// The largest-first ordering inside `shrink` is ported and in place, and it
// is not reachable from a declaration yet. An element can only be shrunk
// below its own content when its content is able to reflow into a smaller
// box - which in Ply means text that can wrap or a clip container that does
// not pass its children's minimum upwards. Both are the next milestone, and
// the test for the ordering belongs with them rather than here, where it
// could only be written by reaching past the public API.

test "a growing child will not go past its maximum" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "capped", .{ .width = .growBetween(0, 100), .height = .grow });
        leaf(&ui, "free", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    // The capped one stops at 100 and hands the rest back, rather than taking
    // its even half and leaving a hole beside it.
    try testing.expectApproxEqAbs(100, ui.boxOf("capped").?.width, 0.01);
    try testing.expectApproxEqAbs(700, ui.boxOf("free").?.width, 0.01);
}

test "a ratio takes its size from the axis that settled first" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(1600, 900));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "wide", .{ .width = .fixed(320), .height = .ratio(16.0 / 9.0) });
    }
    _ = try ui.end();

    // Width settles first, so the height follows: 320 over 16/9 is 180.
    try testing.expectApproxEqAbs(180, ui.boxOf("wide").?.height, 0.01);
}

test "nesting positions each level inside the one above it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .padding = .all(10) });
        defer ui.close();

        ui.open(.{ .id = "mid", .width = .grow, .height = .grow, .padding = .all(20), .background_color = paint });
        defer ui.close();

        leaf(&ui, "deep", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    try testing.expectEqual(BoundingBox.init(10, 10, 780, 580), ui.boxOf("mid").?);
    try testing.expectEqual(BoundingBox.init(30, 30, 740, 540), ui.boxOf("deep").?);
}

test "the command list comes out back to front" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{
            .id = "parent",
            .width = .grow,
            .height = .grow,
            .background_color = .hex(0x111111),
            .border = .all(.hex(0xFF0000), 2),
        });
        defer ui.close();
        leaf(&ui, "child", .{ .width = .fixed(100), .height = .fixed(100) });
    }
    const drawn = try ui.end();

    // Background, then the child over it, then the border over both - which
    // is what makes a border round a group look right instead of being drawn
    // under its own contents.
    try testing.expectEqual(3, drawn.len);
    try testing.expectEqual(commands.Config.rectangle, std.meta.activeTag(drawn[0].config));
    try testing.expectEqual(commands.Config.rectangle, std.meta.activeTag(drawn[1].config));
    try testing.expectEqual(commands.Config.border, std.meta.activeTag(drawn[2].config));

    try testing.expectEqual(identify("parent", 0), drawn[0].id);
    try testing.expectEqual(identify("child", 0), drawn[1].id);
    try testing.expectEqual(identify("parent", 0), drawn[2].id);
}

test "an element that paints nothing is still laid out" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        // A spacer: no colour, so no command, but it still takes its room.
        ui.open(.{ .width = .fixed(100), .height = .grow });
        ui.close();
        leaf(&ui, "after", .{ .width = .grow, .height = .grow });
    }
    const drawn = try ui.end();

    try testing.expectEqual(1, drawn.len);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("after").?.x);
    try testing.expectEqual(@as(f32, 700), ui.boxOf("after").?.width);
}

test "an element left open is an error, not a guess" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    ui.open(.{ .width = .grow });
    ui.open(.{ .width = .grow });
    ui.close();

    try testing.expectError(error.ElementLeftOpen, ui.end());
}

test "closing what was never opened is reported by end" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    ui.open(.{});
    ui.close();
    ui.close();

    try testing.expectError(error.NothingToClose, ui.end());
}

test "a ratio on both axes has nothing to resolve against" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        ui.open(.{ .width = .ratio(1), .height = .ratio(1) });
        ui.close();
    }

    try testing.expectError(error.RatioOnBothAxes, ui.end());
}

test "the same declaration gives the same layout every frame" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    var first: BoundingBox = undefined;
    for (0..3) |i| {
        ui.begin(.init(800, 600));
        {
            ui.open(.{ .width = .grow, .height = .grow, .padding = .all(16), .gap = 8 });
            defer ui.close();
            leaf(&ui, "a", .{ .width = .grow, .height = .fixed(40) });
            leaf(&ui, "b", .{ .width = .fixed(120), .height = .fixed(40) });
        }
        const drawn = try ui.end();
        try testing.expectEqual(2, drawn.len);

        if (i == 0) {
            first = ui.boxOf("a").?;
        } else {
            try testing.expectEqual(first, ui.boxOf("a").?);
        }
    }
}

test "an empty frame is a frame, and produces nothing" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    const drawn = try ui.end();
    try testing.expectEqual(0, drawn.len);
}

test "a named element keeps its number wherever it moves" {
    // Which is what will let hover and focus follow it between frames.
    try testing.expectEqual(identify("save-button", 0), identify("save-button", 99));
    try testing.expect(identify("save", 0) != identify("load", 0));
}

// -------------------------------------------------------------------------
// Parity with Ply
// -------------------------------------------------------------------------
//
// The rules below are Ply's, not this library's, and each of them is a place
// where a reasonable-looking implementation would differ. They are written
// down as tests because "behaves like the original" is a claim, and a claim
// with no test under it is a hope.

test "a grow weight of zero behaves as fit, not as grow-by-nothing" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(600, 100));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "zero", .{ .width = .growWeighted(0), .height = .grow });
        leaf(&ui, "one", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    // Ply turns a zero weight into `fit` when the declaration is made, and
    // the difference is visible: an element that stayed growable with no
    // share would keep the space away from its sibling. Here the sibling
    // takes all of it.
    try testing.expectEqual(layout.Sizing.Kind.fit, layout.Sizing.growWeighted(0).kind);
    try testing.expectApproxEqAbs(0, ui.boxOf("zero").?.width, 0.01);
    try testing.expectApproxEqAbs(600, ui.boxOf("one").?.width, 0.01);
}

test "a zero weight keeps the bounds it was given" {
    // Turning into `fit` must not throw the min and max away, or
    // `grow!(min: 100, weight: 0)` would collapse to nothing.
    const bounded = layout.Sizing.growWith(.{ .min = 100, .max = 200, .weight = 0 });
    try testing.expectEqual(layout.Sizing.Kind.fit, bounded.kind);
    try testing.expectEqual(@as(f32, 100), bounded.min);
    try testing.expectEqual(@as(f32, 200), bounded.max);
}

test "contain letterboxes inside the room it was given" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        // A slot 400 wide and 600 tall, holding a 16:9 picture.
        leaf(&ui, "picture", .{ .width = .fixed(400), .height = .fixed(600), .contain = 16.0 / 9.0 });
    }
    _ = try ui.end();

    // The widest 16:9 box that fits in 400x600 is 400x225. The width was
    // already the limit, so it stays and the height comes down.
    const picture = ui.boxOf("picture").?;
    try testing.expectApproxEqAbs(400, picture.width, 0.01);
    try testing.expectApproxEqAbs(225, picture.height, 0.01);
}

test "cover fills the room and spills past it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "picture", .{ .width = .fixed(400), .height = .fixed(600), .cover = 16.0 / 9.0 });
    }
    _ = try ui.end();

    // The smallest 16:9 box that covers 400x600 is 1066x600 - wider than the
    // slot, which is the point: a cropped background fills its corner.
    const picture = ui.boxOf("picture").?;
    try testing.expectApproxEqAbs(1066.67, picture.width, 0.1);
    try testing.expectApproxEqAbs(600, picture.height, 0.01);
}

test "slot fit changes the box and not its siblings" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow });
        defer ui.close();
        leaf(&ui, "shrunk", .{ .width = .fixed(400), .height = .fixed(600), .contain = 1.0 });
        leaf(&ui, "beside", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    // This is the whole difference between `contain` and a `ratio` sizing. A
    // ratio would have taken part in the sharing out of space and moved the
    // sibling; contain runs afterwards, so the sibling is where it was.
    try testing.expectApproxEqAbs(400, ui.boxOf("shrunk").?.height, 0.01);
    try testing.expectApproxEqAbs(400, ui.boxOf("beside").?.x, 0.01);
    try testing.expectApproxEqAbs(400, ui.boxOf("beside").?.width, 0.01);
}

test "empty is open and close in one call" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        ui.open(.{ .width = .grow, .height = .grow, .gap = 10 });
        defer ui.close();
        ui.empty(.{ .id = "a", .width = .fixed(100), .height = .fixed(50), .background_color = paint });
        ui.empty(.{ .id = "b", .width = .fixed(100), .height = .fixed(50), .background_color = paint });
    }
    const drawn = try ui.end();

    try testing.expectEqual(2, drawn.len);
    try testing.expectEqual(BoundingBox.init(0, 0, 100, 50), ui.boxOf("a").?);
    try testing.expectEqual(BoundingBox.init(110, 0, 100, 50), ui.boxOf("b").?);
}

test "padding is written in the order CSS writes it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    {
        // Top 10, right 20, bottom 30, left 40 - Ply's `padding((t, r, b, l))`.
        ui.open(.{ .width = .grow, .height = .grow, .padding = .trbl(10, 20, 30, 40) });
        defer ui.close();
        leaf(&ui, "inner", .{ .width = .grow, .height = .grow });
    }
    _ = try ui.end();

    const inner = ui.boxOf("inner").?;
    try testing.expectEqual(@as(f32, 40), inner.x);
    try testing.expectEqual(@as(f32, 10), inner.y);
    try testing.expectEqual(@as(f32, 800 - 60), inner.width);
    try testing.expectEqual(@as(f32, 600 - 40), inner.height);
}

test "the alignment names are the ones a reader of Ply will type" {
    // Not a behaviour test - a spelling one. `center`, not `centre`, and
    // `middle` for the border, because that is what Ply calls them.
    try testing.expectEqual(geometry.AlignX.center, @as(geometry.AlignX, .center));
    try testing.expectEqual(geometry.AlignY.center, @as(geometry.AlignY, .center));
    try testing.expectEqual(layout.BorderPosition.middle, @as(layout.BorderPosition, .middle));
    try testing.expectEqual(layout.BorderPosition.inside, layout.Border.all(paint, 1).position);
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------
//
// Measured with `monospace(0.5, 1.0)`, so at a font size of 16 a character is
// eight pixels wide and a line is sixteen tall. Every number below is that
// arithmetic, which is the point of using it: a wrapping bug shows up as a
// number that is wrong by a whole character rather than by a rounding.

const mono: text_mod.Measurer = .monospace(0.5, 1.0);
const sixteen: text_mod.TextStyle = .{ .font_size = 16, .color = paint };

/// A `Ui` with a measurer already set.
fn withText(gpa: std.mem.Allocator) Ui {
    var ui: Ui = .init(gpa);
    ui.setMeasurer(mono);
    return ui;
}

/// Open a root that fills the whole surface.
///
/// The element under test goes inside it, because the root cannot choose its
/// own size - it is the surface, whatever it asked for - and a test that
/// measured the root would be measuring the window. Closed by hand before
/// `end` rather than with a `defer`, which would fire after it.
fn openRoot(ui: *Ui) void {
    ui.open(.{ .width = .grow, .height = .grow });
}

test "text is as wide as it measures and one line tall" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("Hello", sixteen);
    }
    ui.close();
    _ = try ui.end();

    // Five characters at eight pixels, and one sixteen-pixel line.
    try testing.expectEqual(BoundingBox.init(0, 0, 40, 16), ui.boxOf("row").?);
}

test "a paragraph wraps to the width it was given" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        // Eighty pixels is ten characters.
        ui.open(.{ .id = "column", .width = .fixed(80), .height = .fit });
        defer ui.close();
        ui.text("aaa bbb ccc ddd", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // "aaa bbb" is seven characters and fits in ten; adding " ccc" would
    // make eleven and does not. Then "ccc ddd" fits the same way, so it is
    // two lines and the column is two lines tall.
    try testing.expectEqual(2, drawn.len);
    try testing.expectEqual(@as(f32, 32), ui.boxOf("column").?.height);

    try testing.expectEqualStrings("aaa bbb", drawn[0].config.text.text);
    try testing.expectEqualStrings("ccc ddd", drawn[1].config.text.text);
}

test "a wrapped paragraph makes its parent taller" {
    // The reason `wrapText` runs before the vertical pass and `propagateHeights`
    // runs after it. Getting the order wrong makes a paragraph overflow the
    // box drawn round it, which is a bug that only shows on long text.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "card", .width = .fixed(80), .height = .fit, .padding = .all(10) });
        defer ui.close();
        ui.text("aaa bbb ccc ddd eee", sixteen);
    }
    ui.close();
    _ = try ui.end();

    // Sixty pixels of text inside the padding, so the run wraps into more
    // than one line and the card is as tall as all of them plus its padding.
    const card = ui.boxOf("card").?;
    const lines = (card.height - 20) / 16;
    try testing.expect(lines >= 3);
    try testing.expectApproxEqAbs(@round(lines), lines, 0.001);
}

test "a paragraph can be shrunk down to its longest word, and no further" {
    // This is the test the shrink pass has been waiting for. Every other kind
    // of element has a minimum equal to its content and so cannot give way;
    // a paragraph can, down to the word that will not break.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(200, 600));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(200), .height = .grow });
        defer ui.close();
        // Wants 200 (twenty-five characters), gives way to 88 - the width of
        // "enormously", which is eleven characters.
        ui.open(.{ .id = "prose", .width = .fitBetween(0, 1000), .height = .fit });
        {
            defer ui.close();
            ui.text("an enormously wide word", sixteen);
        }
        ui.empty(.{ .id = "fixed", .width = .fixed(160), .height = .grow, .background_color = paint });
    }
    ui.close();
    _ = try ui.end();

    const prose = ui.boxOf("prose").?;
    const fixed = ui.boxOf("fixed").?;

    // The fixed sibling kept every pixel, and the prose gave up the rest.
    try testing.expectEqual(@as(f32, 160), fixed.width);
    try testing.expect(prose.width < 184);
    // But not below its longest word - "enormously" is eighty pixels.
    try testing.expect(prose.width >= 80);
}

test "a newline breaks a line wherever the text asks" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "block", .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("ab\ncdef", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    try testing.expectEqual(2, drawn.len);
    try testing.expectEqualStrings("ab", drawn[0].config.text.text);
    try testing.expectEqualStrings("cdef", drawn[1].config.text.text);

    // Two lines tall, and as wide as the widest of them.
    try testing.expectEqual(@as(f32, 32), ui.boxOf("block").?.height);
    try testing.expectEqual(@as(f32, 32), ui.boxOf("block").?.width);
}

test "two newlines in a row are a blank line" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "block", .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("ab\n\ncd", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // Three lines of height, but only two of them have anything to draw.
    try testing.expectEqual(@as(f32, 48), ui.boxOf("block").?.height);
    try testing.expectEqual(2, drawn.len);
}

test "wrapping can be turned off, and then nothing breaks" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "chip", .width = .fixed(40), .height = .fit });
        defer ui.close();
        ui.text("aaa bbb ccc", .{ .font_size = 16, .color = paint, .wrap = .none });
    }
    ui.close();
    const drawn = try ui.end();

    // One line, overflowing its container - which is what a label in a
    // fixed-width chip wants, paired with a clip.
    try testing.expectEqual(1, drawn.len);
    try testing.expectEqual(@as(f32, 16), ui.boxOf("chip").?.height);
    try testing.expectEqual(@as(f32, 88), drawn[0].bounding_box.width);
}

test "a line is aligned inside the width it was given" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(200), .height = .fit });
        defer ui.close();
        // Twenty-six characters into twenty-five: the last word wraps, and
        // the two lines come out very different widths.
        ui.text("aaaaa bbbbb ccccc ddddd ee", .{
            .font_size = 16,
            .color = paint,
            .alignment = .center,
        });
    }
    ui.close();
    const drawn = try ui.end();

    // Alignment is within the text element, not within its parent - so it
    // only says anything once the lines differ. The long line fills 184 of
    // the 200 and barely moves; the short one is sixteen wide and is pushed
    // to the middle.
    try testing.expectEqual(2, drawn.len);
    try testing.expectApproxEqAbs(8, drawn[0].bounding_box.x, 0.01);
    try testing.expectApproxEqAbs(92, drawn[1].bounding_box.x, 0.01);
}

test "the lines of a paragraph stack downwards" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(80), .height = .fit, .padding = .all(4) });
        defer ui.close();
        ui.text("aaa bbb ccc ddd", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    try testing.expect(drawn.len >= 2);
    // Each line sits one line height below the last, starting at the padding.
    try testing.expectEqual(@as(f32, 4), drawn[0].bounding_box.y);
    try testing.expectEqual(@as(f32, 20), drawn[1].bounding_box.y);
}

test "text with no colour is laid out and not drawn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("Hello", .{ .font_size = 16, .color = .transparent });
    }
    ui.close();
    const drawn = try ui.end();

    try testing.expectEqual(0, drawn.len);
    // It still took its room, which is what makes it useful as a spacer that
    // is exactly as wide as some text will be.
    try testing.expectEqual(@as(f32, 40), ui.boxOf("row").?.width);
}

test "empty text is one line tall and draws nothing" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "field", .width = .fixed(100), .height = .fit });
        defer ui.close();
        ui.text("", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // A text input with nothing in it is still a line tall, which is what
    // stops an empty field collapsing.
    try testing.expectEqual(@as(f32, 16), ui.boxOf("field").?.height);
    try testing.expectEqual(0, drawn.len);
}

test "text without a measurer lays out as nothing rather than crashing" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("Hello", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // Wrong, and wrong in a way that is visible on screen rather than one
    // that takes the program down.
    try testing.expectEqual(0, drawn.len);
    try testing.expectEqual(@as(f32, 0), ui.boxOf("row").?.width);
}

test "a longer word than the container gets a line to itself" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .id = "narrow", .width = .fixed(24), .height = .fit });
        defer ui.close();
        ui.text("ab enormous cd", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // The long word overflows rather than being cut in half - breaking
    // inside a word needs hyphenation rules this library has not got.
    try testing.expectEqual(3, drawn.len);
    try testing.expectEqualStrings("enormous", drawn[1].config.text.text);
    try testing.expect(drawn[1].bounding_box.width > 24);
}

test "the style carries through to the command a renderer sees" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 600));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fit, .height = .fit });
        defer ui.close();
        ui.text("Hi", .{
            .font_size = 32,
            .color = .hex(0xFF8800),
            .letter_spacing = 1,
            .font = 3,
        });
    }
    ui.close();
    const drawn = try ui.end();

    try testing.expectEqual(1, drawn.len);
    const run = drawn[0].config.text;
    try testing.expectEqual(32, run.font_size);
    try testing.expectEqual(1, run.letter_spacing);
    try testing.expectEqual(3, run.font);
    try testing.expectEqual(Color.hex(0xFF8800), run.color);
}
