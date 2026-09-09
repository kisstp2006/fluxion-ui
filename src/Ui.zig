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
const input = @import("input.zig");
const layout = @import("layout.zig");
const markup_mod = @import("markup.zig");
const text_mod = @import("text.zig");
const text_input = @import("text_input.zig");

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

    /// What it takes to be a text input, or null for an ordinary element.
    field: ?text_input.Config = null,
    /// What this input **draws**, in `strings`: the text, or the placeholder,
    /// or a row of bullets. Built when the element is declared and read when
    /// it is drawn.
    ///
    /// Built then rather than at drawing time, and an offset rather than a
    /// slice, for two reasons that are really the same one. The config's own
    /// `placeholder` points at whatever the caller had, which may be a stack
    /// buffer that is gone by the time the frame is drawn. And a text command
    /// holds a slice, so every one of them has to still be looking at its own
    /// text when the frame is handed over - a scratch buffer refilled per
    /// field leaves every command but the last pointing at the wrong string,
    /// which is a bug this library has now had twice.
    ///
    /// `strings` is only appended to while elements are being declared, never
    /// while they are being drawn, so a slice taken during drawing stays put.
    shown_start: u32 = 0,
    shown_len: u32 = 0,

    /// What it does with content larger than itself. See `layout.Clip`.
    clip: layout.Clip = .none,

    /// Set when this element is out of the flow. See `layout.Floating`.
    floating: ?layout.Floating = null,
    /// A picture drawn in its box instead of a plain fill. See `layout.Image`.
    image: ?layout.Image = null,
    /// A turn applied to this element and everything inside it, and one
    /// applied to its own box alone. See `layout.Rotation`.
    rotate: ?layout.Rotation = null,
    rotate_shape: ?layout.Rotation = null,
    /// What was in force when this element was drawn, which is what the hit
    /// test undoes to ask whether the pointer is on it.
    motion: geometry.Transform = .identity,
    /// What a floating element is allowed to be pointed at through, worked
    /// out when it is placed: the thing it is clipped to, or the whole
    /// surface. Null for everything else, which inherits from its parent.
    float_visible: ?BoundingBox = null,

    /// When this element was drawn, counting from zero.
    ///
    /// Declaration order and paint order are not the same once anything
    /// floats: a menu declared halfway down the tree is drawn after all of
    /// it. The hit test wants paint order - the last thing drawn is the thing
    /// on top - and this is how it gets it without the elements having to be
    /// stored in that order.
    paint: u32 = 0,

    /// Where in `elements` its parent is. The root is its own parent, which
    /// is what stops the walk up the tree rather than a sentinel nobody
    /// remembers to check.
    parent: u32 = 0,
    /// Whether the pointer stops here. See `layout.Declaration.capture`.
    capture: bool = false,
    /// Whether a press here leaves the focus where it is. See
    /// `layout.Declaration.preserve_focus`.
    preserve_focus: bool = false,
    /// What the pointer looks like over it. See `Ui.cursor`.
    cursor: ?layout.CursorShape = null,

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

/// One element, as something the pointer can land on.
const Hit = struct {
    id: u32,
    box: BoundingBox,
    /// Everything the clipping ancestors between here and the root leave
    /// visible. A point outside it is outside this element however much its
    /// own box says otherwise - which is what stops a scrolled-away row
    /// answering a click.
    visible: BoundingBox,
    /// When it was drawn. See `Element.paint`.
    paint: u32,
    /// Index into `hits` of the parent's entry, or itself for the root.
    parent: u32,
    /// Whether it is out of the flow, which ends the walk up the tree: a
    /// floating element is not inside its declared parent on screen, so the
    /// parent is not under the pointer when the float is.
    floating: bool,
    /// What turned it, so the pointer can be asked in the element's own
    /// frame. See `holds`.
    motion: geometry.Transform,
    capture: bool,
    preserve_focus: bool,
    /// Whether this is a text input, which a press has more to do about.
    field: bool,
    /// Whether dragging in it selects text.
    drag_select: bool,
    /// Whether the interface would do something with a click here - either
    /// because something is drawn under the pointer or because the element
    /// asked to be clicked. See `Ui.wantsPointer`.
    solid: bool,
    /// What it asked the pointer to look like, if anything. See `Ui.cursor`.
    cursor: ?layout.CursorShape,

    /// Whether a point is on this element.
    ///
    /// The motion is undone rather than the box turned: a rotated box is not a
    /// box any more, and asking whether a point is inside one means four edge
    /// tests. Moving the pointer into the element's own frame instead is a
    /// transpose and a subtraction, and then it is the same rectangle test as
    /// everything else - which is the whole reason `Transform` is a rigid motion
    /// and not a matrix.
    ///
    /// `visible` is asked in surface coordinates, because what clips is a scissor
    /// and a scissor never turns.
    fn holds(self: Hit, point: geometry.Vec2) bool {
        if (!self.visible.contains(point)) return false;
        if (self.motion.isIdentity()) return self.box.contains(point);
        return self.box.contains(self.motion.unapply(point));
    }
};

/// Where one scroll container is, and how much there is to scroll through.
pub const Scroll = struct {
    /// How far the content has been moved, in pixels. **Positive means up and
    /// left**, so a container scrolled to the bottom has a positive `y`.
    position: geometry.Vec2 = .{ .x = 0, .y = 0 },
    /// How big everything inside turned out to be.
    content: Dimensions = .zero,
    /// How big the window onto it is - the element's own inner size.
    viewport: Dimensions = .zero,
    scroll_x: bool = false,
    scroll_y: bool = false,
    /// Whether dragging the content scrolls it. See `layout.Clip`.
    no_drag_scroll: bool = false,

    /// How fast the content is still moving, in pixels a second, after the
    /// finger let go. Same sign as `position`.
    ///
    /// A list that stops dead when the finger leaves the glass feels stuck to
    /// it; one that carries on and slows down feels like a thing. That is the
    /// whole of what this is for, and it is why `Ui.tick` exists to be given
    /// a `dt` at all.
    momentum: geometry.Vec2 = .{ .x = 0, .y = 0 },

    /// Whether the element was declared in the frame just finished. One that
    /// was not is dropped, so a page that stops showing a list stops
    /// remembering where it was scrolled to.
    live: bool = false,

    /// How long since anything moved this container, in seconds. What
    /// `layout.Scrollbar.hide_after_seconds` counts. `Ui.tick` adds to it and
    /// `Ui.begin` puts it back to zero on anything that moved.
    idle: f32 = 0,
    /// Set by anything that moves the container, and folded into `idle` at
    /// the top of the next frame. See `Ui.begin`.
    active: bool = false,

    /// The furthest it can be scrolled: how much content there is past the
    /// window. Never negative - content smaller than its window does not
    /// scroll, and a stored position from when it was larger is clamped away.
    pub fn limit(self: Scroll) geometry.Vec2 {
        return .{
            .x = @max(0, self.content.width - self.viewport.width),
            .y = @max(0, self.content.height - self.viewport.height),
        };
    }

    pub inline fn overflowsX(self: Scroll) bool {
        return self.scroll_x and self.content.width > self.viewport.width;
    }

    pub inline fn overflowsY(self: Scroll) bool {
        return self.scroll_y and self.content.height > self.viewport.height;
    }

    /// How far through the content the window is, from zero to one. What a
    /// scrollbar thumb is positioned by.
    pub fn progress(self: Scroll) geometry.Vec2 {
        const max = self.limit();
        return .{
            .x = if (max.x > 0) std.math.clamp(self.position.x / max.x, 0, 1) else 0,
            .y = if (max.y > 0) std.math.clamp(self.position.y / max.y, 0, 1) else 0,
        };
    }

    fn clamped(self: Scroll) geometry.Vec2 {
        const max = self.limit();
        return .{
            .x = if (self.scroll_x) std.math.clamp(self.position.x, 0, max.x) else 0,
            .y = if (self.scroll_y) std.math.clamp(self.position.y, 0, max.y) else 0,
        };
    }
};

/// One scrollbar, as the frame just finished drew it.
///
/// Kept so the next frame can answer "is the pointer on the thumb", which is
/// the same one-frame lag every other hit test has and for the same reason:
/// where the thumb is depends on a layout that has not run yet when the
/// pointer is set.
const Bar = struct {
    /// The scroll container - or text input - this belongs to.
    element: u32,
    /// Whether the element is a text input rather than a scroll container.
    /// The two keep their scroll positions in different places, and a drag
    /// has to write to the right one.
    field: bool,
    vertical: bool,
    thumb: BoundingBox,
    /// How far the content can move, and how far the thumb can, which is the
    /// ratio a drag is converted through.
    max_scroll: f32,
    thumb_travel: f32,
};

/// One element that asked to be told about something, and what to tell it.
///
/// Kept in a list of their own rather than on the element, because almost no
/// element has any: a page of two hundred boxes with one button in it walks a
/// list of one when the frame ends.
const Listener = struct {
    id: u32,
    on_hover: ?layout.Callback,
    on_press: ?layout.Callback,
    on_release: ?layout.Callback,
    on_focus: ?layout.Callback,
    on_unfocus: ?layout.Callback,

    fn any(declaration: layout.Declaration) bool {
        return declaration.on_hover != null or declaration.on_press != null or
            declaration.on_release != null or declaration.on_focus != null or
            declaration.on_unfocus != null;
    }
};

/// One element that is out of the flow.
const Float = struct {
    /// Where it is in `elements`.
    element: u32,
    /// The element it was declared inside, which is who `.parent` means.
    declared_in: u32,
};

/// A press on a text input, waiting for the layout to say where it landed.
const PendingClick = struct {
    element: u32,
    at: geometry.Vec2,
    /// Whether to extend the selection rather than replace it. Shift, or a
    /// drag in progress, which amount to the same thing here.
    select: bool,
    /// Whether this was the second click in a row, which selects a word.
    word: bool,
};

/// The content of a scroll container, with the pointer held down on it.
///
/// Ply's `ActiveDrag::ScrollContainer`. Not the same as dragging the bar: the
/// bar moves the opposite way to the content and by a different amount, while
/// this is the content stuck to the finger.
const ContentDrag = struct {
    element: u32,
    /// Where the pointer was when it started, and where the content was.
    /// Both fixed, so the content tracks the finger exactly rather than
    /// accumulating a rounding error per frame.
    origin: geometry.Vec2,
    scrolled: geometry.Vec2,
    /// How far it had moved as of the last frame, for working out how fast it
    /// is going now.
    previous: geometry.Vec2 = .{ .x = 0, .y = 0 },
    /// Whether it has moved far enough to count as a scroll rather than a
    /// tap. Once it has, whatever was pressed is let go of. See `setPointer`.
    scrolling: bool = false,
};

/// A scrollbar thumb with the pointer held down on it.
const ThumbDrag = struct {
    element: u32,
    field: bool,
    vertical: bool,
    /// Where the pointer was when the drag started, along the dragged axis,
    /// and where the content was. Both fixed for the length of the drag, so
    /// the thumb tracks the pointer exactly rather than accumulating a
    /// rounding error per frame.
    origin: f32,
    scrolled: f32,
};

/// A run of text, and where its lines ended up.
const TextRun = struct {
    /// Where the copy of the text is in `strings`.
    ///
    /// An offset rather than a slice, because appending the *next* run may
    /// move the buffer - and a slice taken before that would then point at
    /// freed memory, which is the whole class of bug this copy exists to
    /// prevent.
    start: u32,
    len: u32,
    style: text_mod.TextStyle,
    element: u32,
    lines_start: u32 = 0,
    lines_len: u32 = 0,
    /// Where this run's markup spans are in `spans`, or a length of zero for
    /// a run of plain text - which takes a shorter path through `emitText`
    /// and comes out as exactly the commands it always did.
    spans_start: u32 = 0,
    spans_len: u32 = 0,
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

    /// What everything in this element is turned by, inherited from its
    /// ancestors and its own `rotate`.
    motion: geometry.Transform = .identity,

    /// For a wrapping element: the line being placed, how many of it are
    /// down, and where the *next* line starts across the main axis.
    ///
    /// Carried on the frame rather than worked out again per child, because
    /// a line has to be measured whole before its first child can be aligned
    /// in it - each line is aligned on its own, which is the difference
    /// between a wrapped row and a row that happens to be in two pieces.
    line: WrapLine = .{ .count = 0, .main = 0, .cross = 0 },
    line_placed: usize = 0,
    line_cross_at: f32 = 0,
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

/// Every element that can be pointed at, as the frame just finished left it.
///
/// Kept between frames because that is when the question is asked: `hovered`
/// is called while the tree is being declared, and where an element ends up is
/// not known until the tree is finished. See `input`.
hits: std.ArrayList(Hit),

/// Where the pointer is and what its button is doing.
pointer: input.Pointer = .{},
/// The elements under the pointer, outermost first. Ply's `pointer_over_ids`.
over: std.ArrayList(u32),
/// The elements that were under it when the button went down, and still are
/// as far as this is concerned - Ply keeps the whole chain until the button
/// comes up, so dragging off a button and back does not lose the press.
held: std.ArrayList(u32),
/// Which element has the keyboard, or zero for none.
focus: u32 = 0,

/// The elements that are out of the flow, in the order they were declared.
///
/// Each is a layout root of its own: sized on its own after the flow is
/// sized, placed on its own after the flow is placed, and drawn after all of
/// it. Ply calls these its tree roots and keeps the main tree as the first
/// one; here the main tree is element zero and these are beside it.
floats: std.ArrayList(Float),

/// What to call when the frame ends. See `Listener`.
listeners: std.ArrayList(Listener),
/// The focus as the callbacks last saw it.
///
/// Not the same as `focus`, and the difference is the point: a change is
/// noticed by comparing them when the frame ends, so a focus moved by a
/// click, by `setFocus`, or by nothing at all is all the same to whoever
/// asked to be told about it.
focus_reported: u32 = 0,
/// Counts the elements as they are drawn, for `Element.paint`.
painted: u32 = 0,
/// What the element being drawn is turned by, stamped onto every command it
/// emits. Set by `positionAndEmit` and read by the six emitters, which is a
/// great deal less threading than passing it to all of them.
stamp: geometry.Transform = .identity,

/// What each text input holds, kept between frames.
///
/// Beside the scroll positions and for the same reason: what the reader has
/// typed is theirs, and redeclaring the page must not take it back.
edits: std.AutoHashMapUnmanaged(u32, text_input.TextEdit),

/// A click on a text input that has not yet been turned into a cursor.
///
/// Ply's `pending_text_click`, and the reason it has to wait is that a click
/// arrives in pixels and a cursor lives in the string. What lies between them
/// is a measurement that only happens while the frame is being drawn, so the
/// click is written down here and answered in `emitField`.
pending_click: ?PendingClick = null,
/// The field a drag is selecting in, while the button is down.
selecting: ?u32 = null,
/// Whether shift is held. See `setShift`.
shift: bool = false,
/// Seconds since this `Ui` was made, advanced by `tick`. What the cursor
/// blinks on and what tells one click from a double click.
now: f64 = 0,

/// What the last `copy` or `cut` produced.
///
/// Kept because a cut deletes the text it is handing over, so the slice a
/// caller is given cannot point into the field it came from. Good until the
/// next copy or cut.
clipboard: std.ArrayList(u8),

/// Refilled for each field as it is drawn.
field_lines: std.ArrayList(text_input.VisualLine),
field_boundaries: std.ArrayList(f32),

/// The scrollbars drawn this frame, for the next frame to be pointed at.
bars: std.ArrayList(Bar),
/// The thumb the pointer went down on, until it comes up again.
drag: ?ThumbDrag = null,
/// The content the pointer went down on, until it comes up again.
content_drag: ?ContentDrag = null,
/// Whether the pointer is a finger rather than a mouse. See `setTouch`.
touch: bool = false,
/// How long the last frame was, from `tick`. What momentum is measured
/// against, and zero until somebody says otherwise.
dt: f32 = 0,
/// A shape the program asked for this frame, which beats anything the tree
/// worked out for itself. Cleared by `begin`. See `setCursor`.
requested_cursor: ?layout.CursorShape = null,

/// What each scroll container was scrolled to, kept between frames.
///
/// The one piece of state in this library that outlives a frame. A layout is
/// otherwise a pure function of its declaration, and a scroll position cannot
/// be: it is what the person reading has done to the page, and redeclaring
/// the page must not undo it.
scrolls: std.AutoHashMapUnmanaged(u32, Scroll),

/// The text declared this frame. One entry per `text` call.
runs: std.ArrayList(TextRun),
/// Every run's lines, flattened, after wrapping.
lines: std.ArrayList(Line),

/// Every markup run's spans, flattened. See `markup_mod.Span`.
spans: std.ArrayList(markup_mod.Span),
/// And every span's effects. A span names its own by range, and a text
/// command carries the slice - the renderer is where a wave becomes a
/// displacement, because the renderer is where the glyphs are.
effects: std.ArrayList(markup_mod.Effect),

/// The text declared this frame, copied.
///
/// **Copied, not borrowed**, and that is worth the paragraph. A caller writes
/// `ui.text(label, ...)` where `label` was formatted into a stack buffer a
/// line ago, and the layout does not read it until `end` - by which time the
/// buffer is gone and what gets drawn is whatever is on the stack now. It is
/// not a hypothetical: the first example written against a borrowing version
/// of this API had exactly that bug, and it showed as a list of empty boxes.
///
/// Ply copies too, into a fresh `String` per element per frame. This is one
/// buffer, cleared and refilled - so it is the same safety for an allocation
/// that stops happening once the interface has settled.
strings: std.ArrayList(u8),

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
/// What every length in a declaration is multiplied by. See
/// `layout.Surface.scale`.
scale: f32 = 1,
/// How far in from each edge of the surface the interface keeps. See
/// `layout.Surface.safe_area`.
safe_area: geometry.Padding = .none,

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
        .hits = .empty,
        .floats = .empty,
        .listeners = .empty,
        .edits = .empty,
        .clipboard = .empty,
        .field_lines = .empty,
        .field_boundaries = .empty,
        .bars = .empty,
        .over = .empty,
        .held = .empty,
        .scrolls = .empty,
        .runs = .empty,
        .lines = .empty,
        .spans = .empty,
        .effects = .empty,
        .strings = .empty,
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
    self.hits.deinit(self.gpa);
    self.floats.deinit(self.gpa);
    self.listeners.deinit(self.gpa);
    var typed = self.edits.valueIterator();
    while (typed.next()) |edit| edit.deinit(self.gpa);
    self.edits.deinit(self.gpa);
    self.clipboard.deinit(self.gpa);
    self.field_lines.deinit(self.gpa);
    self.field_boundaries.deinit(self.gpa);
    self.bars.deinit(self.gpa);
    self.over.deinit(self.gpa);
    self.held.deinit(self.gpa);
    self.scrolls.deinit(self.gpa);
    self.runs.deinit(self.gpa);
    self.lines.deinit(self.gpa);
    self.spans.deinit(self.gpa);
    self.effects.deinit(self.gpa);
    self.strings.deinit(self.gpa);
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
pub fn begin(self: *Ui, surface: layout.Surface) void {
    self.surface = surface.size;
    // A scale of zero would lay out an interface with nothing in it, and a
    // negative one is not a thing at all. Both read as a field somebody
    // forgot to fill in, so both are taken as one.
    self.scale = if (surface.scale > 0) surface.scale else 1;
    self.safe_area = surface.safe_area;
    self.deferred = null;
    self.requested_cursor = null;

    self.elements.clearRetainingCapacity();
    self.floats.clearRetainingCapacity();
    self.listeners.clearRetainingCapacity();
    self.children.clearRetainingCapacity();
    self.pending.clearRetainingCapacity();
    self.open_stack.clearRetainingCapacity();
    self.output.clearRetainingCapacity();
    self.runs.clearRetainingCapacity();
    self.lines.clearRetainingCapacity();
    self.spans.clearRetainingCapacity();
    self.effects.clearRetainingCapacity();
    self.strings.clearRetainingCapacity();

    // Nothing has been declared yet, so nothing is live. Whatever is still
    // not live when the frame ends was not on the page and is forgotten.
    //
    // The idle clock is cleared here rather than at the end of the frame
    // because everything that moves a container - the wheel, a thumb drag,
    // `scrollTo` - happens between one frame and the next. Clearing here
    // means a bar that hides itself comes back on the frame the wheel turned
    // rather than the one after. `tick` is what makes it count up again.
    var seen = self.scrolls.valueIterator();
    while (seen.next()) |scroll| {
        scroll.live = false;
        if (scroll.active) scroll.idle = 0;
        scroll.active = false;
    }

    var typed = self.edits.valueIterator();
    while (typed.next()) |edit| {
        edit.live = false;
        edit.beginFrame();
    }
}

/// Which element is currently open, or zero when none is - which happens
/// only for the root, whose parent is itself.
fn innermost(self: *Ui) u32 {
    if (self.open_stack.items.len == 0) return 0;
    return self.open_stack.items[self.open_stack.items.len - 1].element;
}

/// The clip an element asked for, with the scroll position this `Ui`
/// remembers already in it.
///
/// Ply does the same thing at the same point - it fills `child_offset` from
/// the stored position as the element is configured - and the reason is that
/// positioning happens long afterwards, by which time the declaration is
/// gone. The caller writes `.clip = .scrollY` and never touches the offset.
fn remembered(self: *Ui, declaration: layout.Declaration) layout.Clip {
    var clip = declaration.clip;
    if (!clip.scrolls()) return clip;

    const name = identify(declaration.id, @intCast(self.elements.items.len));
    if (self.scrolls.get(name)) |scroll| clip.offset = scroll.clamped();
    return clip;
}

/// Where a scroll container is, or null if there is no such element or it was
/// not on the page last frame.
///
/// Named rather than numbered, so a caller asks the way it declared.
pub fn scrollOf(self: *Ui, name: []const u8) ?Scroll {
    return self.scrolls.get(identify(name, 0));
}

/// Move a scroll container by this much, in pixels.
///
/// Takes effect on the next frame, and is clamped when that frame ends - so
/// a wheel event that runs past the bottom of a list stops at the bottom
/// rather than scrolling into nothing. Nudging an element that does not
/// scroll, or does not exist, does nothing.
pub fn scrollBy(self: *Ui, name: []const u8, dx: f32, dy: f32) void {
    const scroll = self.scrolls.getPtr(identify(name, 0)) orelse return;
    nudge(scroll, dx, dy);
}

/// Move whatever the pointer is over. What a wheel event actually wants.
///
/// `scrollBy` needs a name, so a program with two lists has to work out which
/// one the wheel is over before it can move it - and working that out is the
/// hit test this library already did. This is that question answered here.
///
/// **The innermost container under the pointer wins, one axis at a time**,
/// and only one with somewhere to go on that axis counts. So a list inside a
/// scrolling page takes the wheel while the page stays put, and a page that
/// holds a strip scrolling sideways splits a trackpad swipe between the two.
///
/// Returns whether anything moved, so a game can zoom its camera with the
/// wheel the interface did not want - the same shape of answer as
/// `wantsPointer`, and true for the same kind of reason.
///
/// A container at the end of its travel is not "somewhere to go" for this: it
/// still takes the wheel and stays where it is, rather than handing what is
/// left to its parent. Browsers hand it on; a game interface has one list
/// deep far more often than two, and a page that lurches when a list reaches
/// its bottom is the worse surprise of the two.
pub fn scrollHovered(self: *Ui, dx: f32, dy: f32) bool {
    var moved = false;
    if (dx != 0) {
        if (self.innermostScrolling(true)) |scroll| {
            nudge(scroll, dx, 0);
            moved = true;
        }
    }
    if (dy != 0) {
        if (self.innermostScrolling(false)) |scroll| {
            nudge(scroll, 0, dy);
            moved = true;
        }
    }
    return moved;
}

/// The innermost container under the pointer that overflows on this axis.
/// `over` is outermost first, so this reads it backwards - the same walk
/// `grabContent` does, and for the same reason.
fn innermostScrolling(self: *Ui, x_axis: bool) ?*Scroll {
    var i = self.over.items.len;
    while (i > 0) {
        i -= 1;
        const scroll = self.scrolls.getPtr(self.over.items[i]) orelse continue;
        if (if (x_axis) scroll.overflowsX() else scroll.overflowsY()) return scroll;
    }
    return null;
}

/// Move a container and stop it coasting. What every mover but a drag does:
/// a wheel turned mid-coast means "not there, here", and a list that carried
/// on afterwards would be arguing with the hand.
fn nudge(scroll: *Scroll, dx: f32, dy: f32) void {
    scroll.position.x += dx;
    scroll.position.y += dy;
    scroll.position = scroll.clamped();
    scroll.momentum = .{ .x = 0, .y = 0 };
    scroll.active = true;
}

/// Put a scroll container at this position, in pixels from the top left of
/// its content.
pub fn scrollTo(self: *Ui, name: []const u8, x: f32, y: f32) void {
    const key = identify(name, 0);
    const scroll = self.scrolls.getPtr(key) orelse return;
    scroll.position = .{ .x = x, .y = y };
    scroll.position = scroll.clamped();
    scroll.momentum = .{ .x = 0, .y = 0 };
    scroll.active = true;
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

fn openChecked(self: *Ui, raw: layout.Declaration) Error!void {
    if (self.open_stack.items.len >= max_depth) return error.TooDeep;

    // Every length the caller wrote, multiplied once, here. Nothing past this
    // line knows the interface has a scale at all - which is the point of
    // doing it at the top of the layout rather than in every game. See
    // `layout.Surface.scale`.
    const declaration = raw.scaled(self.scale);

    const index: u32 = @intCast(self.elements.items.len);
    try self.elements.append(self.gpa, .{
        .id = identify(declaration.id, index),
        .config = declaration.layout(),
        .background_color = declaration.background_color,
        .corner_radius = declaration.corner_radius,
        .border = declaration.border,
        .z_index = declaration.z_index,
        .slot_fit = declaration.slotFit(),
        .clip = self.remembered(declaration),
        .parent = self.innermost(),
        .capture = declaration.capture,
        .preserve_focus = declaration.preserve_focus,
        .cursor = declaration.cursor,
        .floating = declaration.floating,
        .image = declaration.image,
        .rotate = declaration.rotate,
        .rotate_shape = declaration.rotate_shape,
    });

    // The new element is a child of whatever is open, unless it is the root -
    // or unless it floats, in which case it is nobody's child. That one line
    // is most of what floating means: its siblings are placed as though it
    // were not declared, it adds nothing to the parent's fit size, and
    // nothing moves when it appears.
    if (Listener.any(declaration)) {
        try self.listeners.append(self.gpa, .{
            .id = self.elements.items[index].id,
            .on_hover = declaration.on_hover,
            .on_press = declaration.on_press,
            .on_release = declaration.on_release,
            .on_focus = declaration.on_focus,
            .on_unfocus = declaration.on_unfocus,
        });
    }

    if (declaration.floating) |_| {
        try self.floats.append(self.gpa, .{ .element = index, .declared_in = self.innermost() });
    } else if (self.open_stack.items.len > 0) {
        try self.pending.append(self.gpa, index);
    }

    try self.open_stack.append(self.gpa, .{
        .element = index,
        .pending_at = @intCast(self.pending.items.len),
    });
}

/// A run of text. Ply's `ui.text(text, |t| ...)`.
///
/// Not an `open` and a `close`: a text element has no children and its size
/// comes from measuring rather than from summing, so it is added whole.
///
/// **The string is copied**, so a caller may hand over a stack buffer it
/// formatted a line ago and forget about it. See `strings`.
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

fn textChecked(self: *Ui, run: []const u8, style: text_mod.TextStyle) Error!void {
    // Copied first, and everything below measures the copy - so a caller
    // whose buffer is about to go out of scope is already safe.
    const start: u32 = @intCast(self.strings.items.len);
    try self.strings.appendSlice(self.gpa, run);
    try self.addRun(start, @intCast(run.len), style, 0, 0);
}

/// A run of text with styles written into it: `{color=red|like this}`.
///
/// A separate call rather than something `text` does for itself, which is
/// where this parts company with Ply. Ply turns markup on for the whole
/// program with a build feature, so every string it draws is parsed and every
/// brace in every label has to be escaped. Asking for it a run at a time
/// costs one word and means `text` is never surprising.
///
/// The tags are taken out here, so everything after this - measuring,
/// wrapping, the boxes, the commands - works on the text the reader will
/// actually see. See `markup` for what a tag can say, and for what happens to
/// one that is malformed.
///
/// ```zig
/// ui.markup("Press {color=red|Escape} to leave", .{ .font_size = 14 });
/// ```
pub fn markup(self: *Ui, raw: []const u8, style: text_mod.TextStyle) void {
    self.markupChecked(raw, style) catch |err| self.remember(err);
}

fn markupChecked(self: *Ui, raw: []const u8, style: text_mod.TextStyle) Error!void {
    const start: u32 = @intCast(self.strings.items.len);
    const spans_start: u32 = @intCast(self.spans.items.len);
    const parsed = try markup_mod.parse(&self.strings, &self.spans, null, &self.effects, self.gpa, raw);
    try self.addRun(
        start,
        @intCast(parsed.text.len),
        style,
        spans_start,
        @intCast(parsed.spans.len),
    );
}

/// Make an element out of text that is already in `strings`, and measure it.
///
/// The half `text` and `markup` share. By the time this runs the difference
/// between them is gone: there is a stretch of `strings` to be measured, and
/// maybe some spans saying how to colour it.
fn addRun(
    self: *Ui,
    start: u32,
    len: u32,
    wanted: text_mod.TextStyle,
    spans_start: u32,
    spans_len: u32,
) Error!void {
    // Measured, wrapped, stored and drawn at the interface's scale, so this
    // is the only line in the text half that has to know there is one.
    const style = wanted.scaled(self.scale);

    const index: u32 = @intCast(self.elements.items.len);
    const content = self.strings.items[start..][0..len];

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
        .parent = self.innermost(),
        .run = @intCast(self.runs.items.len),
        .dimensions = measured,
        .min_dimensions = smallest,
    });

    try self.runs.append(self.gpa, .{
        .start = start,
        .len = len,
        .style = style,
        .element = index,
        .spans_start = spans_start,
        .spans_len = spans_len,
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

/// Declare a text input. Ply's `.text_input(|t| ...)` on an element.
///
/// Two arguments, like `text`, and for the same reason: the box is a
/// declaration like any other - a width, a height, padding, a background, a
/// border - and the config is only what makes it editable.
///
/// ```zig
/// ui.textInput(
///     .{ .id = "name", .width = .grow, .height = .fixed(32), .padding = .xy(8, 6) },
///     .{ .placeholder = "Your name" },
/// );
/// ```
///
/// **Give it a width.** A `.fit` width comes out as the padding and nothing
/// else, because a box that resized itself as the reader typed would be
/// unusable. A `.fit` height is one line, which Ply does not do and which
/// stops an input nobody gave a height from being an invisible box the reader
/// can focus and type into and never see.
///
/// The text is reached by name afterwards: `textValueOf("name")`.
pub fn textInput(self: *Ui, declaration: layout.Declaration, config: text_input.Config) void {
    self.textInputChecked(declaration, config) catch |err| self.remember(err);
}

fn textInputChecked(self: *Ui, declaration: layout.Declaration, asked: text_input.Config) Error!void {
    const config = asked.scaled(self.scale);
    try self.openChecked(declaration);
    const index = self.innermost();

    // The one shape the layout knows without being told. A declaration that
    // says otherwise still wins - a read-only field showing an arrow is a
    // reasonable thing to want.
    if (declaration.cursor == null) self.elements.items[index].cursor = .ibeam;

    const entry = try self.edits.getOrPut(self.gpa, self.elements.items[index].id);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    entry.value_ptr.live = true;
    entry.value_ptr.multiline = config.multiline;
    entry.value_ptr.max_length = config.max_length;
    if (entry.value_ptr.markup != config.markup) {
        // Turning it on has to build the view of the text that the cursor
        // moves through; turning it off has to stop using it.
        entry.value_ptr.markup = config.markup;
        try entry.value_ptr.settle(self.gpa);
    }

    // What this input will draw, worked out now while the caller's
    // placeholder is still theirs to lend. See `Element.shown_start`.
    const start: u32 = @intCast(self.strings.items.len);
    const shown = try text_input.display(
        &self.strings,
        self.gpa,
        entry.value_ptr.shown(),
        config.placeholder,
        config.password,
    );

    self.elements.items[index].field = config;
    self.elements.items[index].shown_start = start;
    self.elements.items[index].shown_len = @intCast(shown.len);

    try self.closeChecked();

    if (declaration.height.kind == .fit) {
        if (self.measurer) |measurer| {
            const wanted = measurer.lineHeight(config.style()) +
                self.elements.items[index].config.padding.onAxis(false);
            self.elements.items[index].dimensions.height =
                @max(self.elements.items[index].dimensions.height, wanted);
            self.elements.items[index].min_dimensions.height =
                @max(self.elements.items[index].min_dimensions.height, wanted);
        }
    }
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
    // What this element clips, which changes what its children may ask of
    // it. Rule one of three: a clipped axis takes nothing from its children's
    // minimum, so a long list does not make the box round it un-shrinkable.
    const clip = self.elements.items[index].clip;
    const clips_main = clip.onAxis(along_x);
    const clips_cross = clip.onAxis(!along_x);

    for (mine) |child_index| {
        const child = self.elements.items[child_index];
        main += child.dimensions.onAxis(along_x);
        cross = @max(cross, child.dimensions.onAxis(!along_x));
        if (!clips_main) {
            // A wrapping element's smallest is one child, not all of them:
            // they can go on separate lines. Without this a row of five
            // fixed children cannot be squeezed below the five of them, so
            // it never gets narrow enough to wrap and `wrap` does nothing at
            // all - which is how this was found.
            if (config.wrap) {
                main_min = @max(main_min, child.min_dimensions.onAxis(along_x) +
                    (if (along_x) padding_x else padding_y));
            } else {
                main_min += child.min_dimensions.onAxis(along_x);
            }
        }
        if (!clips_cross) cross_min = @max(cross_min, child.min_dimensions.onAxis(!along_x));
        try self.children.append(self.gpa, child_index);
    }

    main += gaps;
    // The gaps go with the children they separate, so a wrapping element -
    // whose smallest line is one child - does not count any of them.
    if (!clips_main and !config.wrap) main_min += gaps;
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

    // The root is the surface, whatever it asked for - less whatever the
    // display cannot show.
    const safe = self.safeBox();
    self.elements.items[0].dimensions = .init(safe.width, safe.height);

    try self.sizeAlongAxis(true, 0);
    try self.sizeFloats(true);
    self.resolveRatios(true);

    // Text wraps once the widths are settled, and only then is a paragraph's
    // height known - so the heights it changed have to reach its ancestors
    // before the vertical pass runs. Doing this the other way round is what
    // makes a wrapped paragraph overflow the box drawn round it.
    try self.wrapText();
    self.propagateHeights();

    try self.sizeAlongAxis(false, 0);
    try self.sizeFloats(false);
    self.resolveRatios(false);
    try self.applySlotFit();

    self.painted = 0;
    self.bars.clearRetainingCapacity();
    try self.positionAndEmit(0, .{ .x = safe.x, .y = safe.y });
    try self.placeFloats();
    try self.measureScroll();
    try self.recordHits();
    try self.sweepFields();
    self.notify();
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

        // The widest child, for a parent that clips across this axis and so
        // must not squeeze them. Computed before anything is resized.
        var widest: f32 = 0;
        if (parent.clip.onAxis(x_axis)) {
            for (children) |child_index| {
                widest = @max(widest, self.elements.items[child_index].dimensions.onAxis(x_axis));
            }
        }

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
                //
                // Rule three: unless the parent clips this axis, in which case
                // a child wider than its container is exactly the point.
                const room = if (parent.clip.onAxis(x_axis)) @max(inner, widest) else inner;
                const smallest = child.min_dimensions.onAxis(x_axis);
                const held = @max(smallest, @min(child.dimensions.onAxis(x_axis), room));
                setSize(child, x_axis, held);
            }
        }

        for (children) |child_index| try self.queue.append(self.gpa, child_index);
    }
}

/// One run of children that fits on a line, and how big that line is.
const WrapLine = struct {
    /// How many children, starting from wherever it was asked about.
    count: usize,
    /// How long the line is along the main axis, and how thick across it.
    main: f32,
    cross: f32,
};

/// How much room a child asks for when deciding where a line breaks.
///
/// A growing child is broken on by its **minimum**, not by the size it will
/// grow to - which is Ply's rule and the thing that stops the answer
/// depending on itself. Where the lines fall decides how much space each one
/// has to share out, and how much a child grew depends on that; asking the
/// grown size first would be a loop.
fn breakSize(self: *Ui, child_index: u32, x_axis: bool) f32 {
    const child = self.elements.items[child_index];
    const wanted = child.config.sizing.onAxis(x_axis);
    return if (wanted.kind == .grow) wanted.min else child.dimensions.onAxis(x_axis);
}

/// The next line of a wrapping container, starting at the `from`th child.
///
/// Always takes at least one child: a child wider than the whole container
/// goes on a line of its own and overflows it, which is the only answer that
/// terminates.
fn wrapLine(self: *Ui, parent: Element, from: usize, x_axis: bool, inner: f32) WrapLine {
    const children = self.childrenOf(parent);
    const gap: f32 = @floatFromInt(parent.config.gap);

    var line: WrapLine = .{ .count = 0, .main = 0, .cross = 0 };
    var breaking: f32 = 0;

    for (children[from..]) |child_index| {
        const step = self.breakSize(child_index, x_axis);
        const with_gap = if (line.count == 0) step else gap + step;
        if (line.count > 0 and breaking + with_gap > inner + epsilon) break;

        breaking += with_gap;
        const child = self.elements.items[child_index];
        line.main += if (line.count == 0) child.dimensions.onAxis(x_axis) else gap + child.dimensions.onAxis(x_axis);
        line.cross = @max(line.cross, child.dimensions.onAxis(!x_axis));
        line.count += 1;
    }

    return line;
}

/// How thick a wrapping container's content is across the main axis, and how
/// many lines it took.
fn wrapCross(self: *Ui, parent: Element, x_axis: bool, inner: f32) f32 {
    const children = self.childrenOf(parent);
    const wrap_gap: f32 = @floatFromInt(parent.config.wrap_gap);

    var total: f32 = 0;
    var lines: usize = 0;
    var at: usize = 0;
    while (at < children.len) : (lines += 1) {
        const line = self.wrapLine(parent, at, x_axis, inner);
        if (line.count == 0) break;
        total += line.cross;
        at += line.count;
    }
    if (lines > 1) total += @as(f32, @floatFromInt(lines - 1)) * wrap_gap;
    return total;
}

/// Give out, or take back, the difference between what the children add up to
/// and what the parent has room for.
fn distributeMainAxis(self: *Ui, parent_index: u32, x_axis: bool, inner: f32) Error!void {
    const parent = self.elements.items[parent_index];
    const children = self.childrenOf(parent);
    if (children.len == 0) return;

    // A wrapping container shares its space out one line at a time: the
    // children on a line grow into what is left of *that* line, and a line
    // with room to spare does not stretch a child on the line below it.
    if (parent.config.wrap) {
        var at: usize = 0;
        while (at < children.len) {
            const line = self.wrapLine(parent, at, x_axis, inner);
            if (line.count == 0) break;
            try self.distributeRun(parent, children[at..][0..line.count], x_axis, inner);
            at += line.count;
        }
        return;
    }

    try self.distributeRun(parent, children, x_axis, inner);
}

fn distributeRun(self: *Ui, parent: Element, children: []const u32, x_axis: bool, inner: f32) Error!void {
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
        // Rule two: a container that clips this axis lets its children run
        // off the end rather than squeezing them. That overflow *is* the
        // content a scroll position moves through - squeezing it away would
        // leave nothing to scroll.
        if (parent.clip.onAxis(x_axis)) return;
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

        const content = self.strings.items[run.start..][0..run.len];
        var words: text_mod.Words = .init(content, run.style, measurer);
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

        // A wrapping row is as tall as its lines stacked up, not as tall as
        // its tallest child. The width is settled by now, which is what makes
        // the lines knowable here at all.
        if (config.wrap and !stacked) {
            const inner = @max(0, element.dimensions.width - config.padding.onAxis(true));
            const stack = self.wrapCross(element, true, inner) + config.padding.onAxis(false);
            self.elements.items[i].dimensions.height = config.sizing.height.clamp(stack);
            self.elements.items[i].min_dimensions.height = config.sizing.height.clamp(stack);
            continue;
        }

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
        const content = self.strings.items[run.start..][0..run.len];

        if (run.spans_len == 0) {
            try self.emitPiece(
                element,
                run.style,
                content[line.start..][0..line.len],
                .init(x, y, line.width, line_height),
                run.style.color,
                &.{},
                0,
            );
            continue;
        }

        try self.emitSpanned(
            element,
            run.style,
            content,
            line.start,
            line.start + line.len,
            self.spans.items[run.spans_start..][0..run.spans_len],
            x,
            y,
            line_height,
        );
    }
}

/// Draw one line in as many commands as its spans ask for.
///
/// Shared by a run of markup and a text input holding some, which have the
/// same job from different directions: a stretch of text, a list of spans
/// over the string it came from, and somewhere to put it.
///
/// The pen walks along adding each piece's own width rather than measuring
/// the prefix again, which is Ply's arithmetic too - and it means a pair of
/// letters either side of a tag boundary is not kerned against each other.
/// There is nowhere for that kerning to live: they are two draws.
fn emitSpanned(
    self: *Ui,
    element: Element,
    style: text_mod.TextStyle,
    content: []const u8,
    from: usize,
    to: usize,
    spans: []const markup_mod.Span,
    x: f32,
    y: f32,
    line_height: f32,
) Error!void {
    const measurer = self.measurer orelse return;
    var pen = x;

    for (spans) |span| {
        const first = @max(span.start, from);
        const last = @min(span.end, to);
        if (first >= last) continue;

        const piece = content[first..last];
        const effects = self.effects.items[span.effects_start..][0..span.effects_len];
        // How many characters of the whole run come before this piece, so a
        // wave travels along a sentence rather than restarting at every
        // change of colour.
        const along: u32 = @intCast(text_input.characters(content[0..first]));
        const width = measurer.measure(piece, style).width;
        defer pen += width;
        if (span.hidden) continue;

        if (span.shadow) |shadow| {
            // The offset is in ems, so a shadow set once looks the same at
            // every size.
            const em: f32 = @floatFromInt(style.font_size);
            try self.emitPiece(
                element,
                style,
                piece,
                .init(pen + shadow.offset.x * em, y + shadow.offset.y * em, width, line_height),
                .{
                    .r = shadow.color.r,
                    .g = shadow.color.g,
                    .b = shadow.color.b,
                    .a = std.math.clamp(shadow.color.a * span.opacity, 0, 1),
                },
                effects,
                along,
            );
        }

        try self.emitPiece(
            element,
            style,
            piece,
            .init(pen, y, width, line_height),
            span.colorOver(style.color),
            effects,
            along,
        );
    }
}

fn emitPiece(
    self: *Ui,
    element: Element,
    style: text_mod.TextStyle,
    piece: []const u8,
    box: BoundingBox,
    ink: Color,
    effects: []const markup_mod.Effect,
    first: u32,
) Error!void {
    if (piece.len == 0 or ink.invisible()) return;
    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .id = element.id,
        .z_index = element.z_index,
        .transform = self.stamp,
        .config = .{ .text = .{
            .text = piece,
            .color = ink,
            .font_size = style.font_size,
            .letter_spacing = style.letter_spacing,
            .line_height = @intFromFloat(@round(box.height)),
            .font = style.font,
            .effects = effects,
            .first = first,
        } },
    });
}

// -------------------------------------------------------------------------
// Phase three: position, and write the commands out
// -------------------------------------------------------------------------

/// Walk the tree depth first, placing every box and emitting what to draw.
///
/// Depth first with children in order is what puts the list in back-to-front
/// order without anything having to sort it: a parent's background is written
/// before its children are visited, and its border after they are done.
fn positionAndEmit(self: *Ui, root: u32, at: Point) Error!void {
    self.walk.clearRetainingCapacity();
    try self.walk.append(self.gpa, .{
        .element = root,
        .position = at,
        .next_child = self.startOffset(self.elements.items[root]),
        .line_cross_at = self.crossLeadOf(self.elements.items[root]),
    });
    self.elements.items[root].box = .at(at.x, at.y, self.elements.items[root].dimensions);
    self.elements.items[root].paint = self.painted;
    self.painted += 1;

    const root_motion = self.turnOf(root, .identity);
    self.walk.items[0].motion = root_motion;
    self.elements.items[root].motion = root_motion;
    self.stamp = self.ownTurnOf(root, root_motion);

    try self.emitBackground(root, self.elements.items[root].box);
    try self.emitText(root, self.elements.items[root].box);
    try self.emitField(root, self.elements.items[root].box);
    if (self.elements.items[root].clip.clips()) {
        try self.emitScissor(.scissor_start, self.elements.items[root].box);
    }

    while (self.walk.items.len > 0) {
        // Read what is needed out of the top frame before anything can grow
        // the array underneath it. A pointer into an `ArrayList` does not
        // survive an append to that list, and the append is four lines down.
        const depth = self.walk.items.len - 1;
        const frame = self.walk.items[depth];
        const element = self.elements.items[frame.element];
        const children = self.childrenOf(element);

        if (frame.placed >= children.len) {
            // The clip is let go before the border is drawn, so an element's
            // own outline is not cut off by the rectangle it imposes on its
            // children. A border clipped by its own scissor loses a pixel on
            // every side, which looks like a rounding bug and is not.
            if (element.clip.clips()) try self.emitScissor(.scissor_end, element.box);
            self.stamp = self.ownTurnOf(frame.element, frame.motion);
            try self.emitBorder(frame.element, element.box);
            try self.emitScrollbars(frame.element, element.box);
            _ = self.walk.pop();
            continue;
        }

        const along_x = element.config.direction.isMainAxisX();
        const inner = @max(0, element.dimensions.onAxis(along_x) -
            element.config.padding.onAxis(along_x));

        // A wrapping element starts a line whenever the one before it is
        // finished, which includes the very first child.
        if (element.config.wrap and frame.line_placed >= frame.line.count) {
            const started = frame.placed > 0;
            const line = self.wrapLine(element, frame.placed, along_x, inner);

            var across = self.walk.items[depth].line_cross_at;
            if (started) across += frame.line.cross + @as(f32, @floatFromInt(element.config.wrap_gap));

            // Each line is aligned along the main axis on its own, so a last
            // row of two in a centred wrap sits under the middle of the rest
            // rather than under its left edge.
            const lead = self.leadOf(element, along_x) +
                (if (along_x)
                    geometry.leadingSpaceX(inner - line.main, element.config.align_x)
                else
                    geometry.leadingSpaceY(inner - line.main, element.config.align_y));

            self.walk.items[depth].line = line;
            self.walk.items[depth].line_placed = 0;
            self.walk.items[depth].line_cross_at = across;
            if (along_x) {
                self.walk.items[depth].next_child = .{ .x = lead, .y = across };
            } else {
                self.walk.items[depth].next_child = .{ .x = across, .y = lead };
            }
        }

        const running = self.walk.items[depth];
        const child_index = children[running.placed];
        const child = self.elements.items[child_index];

        // Along the main axis the offset has been advancing as children were
        // placed. Across it, each child is aligned on its own - inside its
        // own line when the element wraps, and inside the whole inner box
        // when it does not.
        const cross_room = @max(0, (if (element.config.wrap)
            running.line.cross
        else
            element.dimensions.onAxis(!along_x) - element.config.padding.onAxis(!along_x)) -
            child.dimensions.onAxis(!along_x));
        const cross = if (along_x)
            geometry.leadingSpaceY(cross_room, element.config.align_y)
        else
            geometry.leadingSpaceX(cross_room, element.config.align_x);

        const x = running.position.x + running.next_child.x + (if (along_x) 0 else cross);
        const y = running.position.y + running.next_child.y + (if (along_x) cross else 0);

        // Advance the parent's cursor past this child and the gap after it -
        // the gap after the last child of a line is the wrap gap, not this
        // one, and it has already been counted.
        const last_here = if (element.config.wrap)
            running.line_placed + 1 >= running.line.count
        else
            running.placed + 1 >= children.len;
        const gap: f32 = if (last_here) 0 else @floatFromInt(element.config.gap);
        const step = child.dimensions.onAxis(along_x) + gap;
        if (along_x) {
            self.walk.items[depth].next_child.x += step;
        } else {
            self.walk.items[depth].next_child.y += step;
        }
        self.walk.items[depth].placed += 1;
        self.walk.items[depth].line_placed += 1;

        self.elements.items[child_index].box = .at(x, y, child.dimensions);
        self.elements.items[child_index].paint = self.painted;
        self.painted += 1;

        // A turn on this child applies to it and to everything inside it, so
        // it is what the child's own frame inherits. A turn on its *shape*
        // applies to its own drawing and stops there.
        const inherited = self.turnOf(child_index, running.motion);
        self.elements.items[child_index].motion = inherited;
        self.stamp = self.ownTurnOf(child_index, inherited);

        try self.emitBackground(child_index, self.elements.items[child_index].box);
        try self.emitText(child_index, self.elements.items[child_index].box);
        try self.emitField(child_index, self.elements.items[child_index].box);

        // The background goes down first and is not clipped by the element's
        // own rectangle; everything inside it is.
        if (child.clip.clips()) {
            try self.emitScissor(.scissor_start, self.elements.items[child_index].box);
        }

        if (self.walk.items.len >= max_depth) return error.TooDeep;
        try self.walk.append(self.gpa, .{
            .element = child_index,
            .position = .{ .x = x, .y = y },
            .next_child = self.startOffset(child),
            .line_cross_at = self.crossLeadOf(child),
            .motion = inherited,
        });
    }
}

/// The same on the cross axis: where the first line of a wrapping element
/// sits before any of it has been measured.
fn crossLeadOf(self: *Ui, element: Element) f32 {
    return self.leadOf(element, !element.config.direction.isMainAxisX());
}

/// What an element and everything inside it is turned by.
fn turnOf(self: *Ui, index: u32, inherited: geometry.Transform) geometry.Transform {
    const element = self.elements.items[index];
    const turn = element.rotate orelse return inherited;
    if (turn.isNone()) return inherited;
    return turn.motion(element.box).then(inherited);
}

/// What an element's **own** drawing is turned by: the above, and then its
/// shape rotation, which its children do not inherit.
fn ownTurnOf(self: *Ui, index: u32, inherited: geometry.Transform) geometry.Transform {
    const element = self.elements.items[index];
    const turn = element.rotate_shape orelse return inherited;
    if (turn.isNone()) return inherited;
    return turn.motion(element.box).then(inherited);
}

/// The padding on the leading edge of the main axis, and the scroll position.
///
/// Where a line of a wrapping element starts before its own alignment is
/// added. `startOffset` folds the alignment of the whole content in, which is
/// exactly what a wrapping element cannot use.
fn leadOf(self: *Ui, element: Element, along_x: bool) f32 {
    _ = self;
    const config = element.config;
    return if (along_x)
        @as(f32, @floatFromInt(config.padding.left)) - element.clip.offset.x
    else
        @as(f32, @floatFromInt(config.padding.top)) - element.clip.offset.y;
}

/// Where the first child of an element goes, relative to the element: the
/// padding, plus whatever the main-axis alignment pushes it by.
fn startOffset(self: *Ui, element: Element) Point {
    const config = element.config;
    const along_x = config.direction.isMainAxisX();
    const children = self.childrenOf(element);

    // The scroll position moves the content, not the window: a container
    // scrolled down has a positive `y`, so its children start that far *above*
    // where they otherwise would. Everything after this - alignment, gaps,
    // the boxes handed to the renderer - is the same arithmetic it always was.
    var offset: Point = .{
        .x = @as(f32, @floatFromInt(config.padding.left)) - element.clip.offset.x,
        .y = @as(f32, @floatFromInt(config.padding.top)) - element.clip.offset.y,
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

/// One end of a clip pair.
///
/// The rectangle is the element's whole box rather than its inside: a
/// container clips at its own edge, and its padding is part of what it shows.
///
/// A scissor is axis-aligned and stays that way under a turn: the graphics
/// API has no other kind. A rotated element that clips therefore clips by
/// its unrotated box, which is Ply's behaviour too and is said out loud in
/// the README rather than left to be found.
fn emitScissor(self: *Ui, kind: commands.Config, box: BoundingBox) Error!void {
    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .config = kind,
    });
}

fn emitBackground(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    if (box.empty()) return;

    // An image takes the place of the fill rather than sitting on top of it:
    // the command carries the fill, so a renderer paints one rectangle and
    // one picture rather than being handed two of everything.
    if (element.image) |picture| {
        try self.output.append(self.gpa, .{
            .bounding_box = box,
            .id = element.id,
            .z_index = element.z_index,
            .transform = self.stamp,
            .config = .{ .image = .{
                .background_color = if (picture.background_color.invisible())
                    element.background_color
                else
                    picture.background_color,
                .corner_radius = element.corner_radius.clampTo(box.width, box.height),
                .texture = picture.texture,
                .source = picture.source,
                .tint = picture.tint,
            } },
        });
        return;
    }

    if (element.background_color.invisible()) return;

    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .id = element.id,
        .z_index = element.z_index,
        .transform = self.stamp,
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
        .transform = self.stamp,
        .config = .{ .border = .{
            .color = border.color,
            .width = border.width,
            .position = border.position,
            .corner_radius = element.corner_radius.clampTo(box.width, box.height),
        } },
    });
}

/// Draw a text input: the selection, the text, and the cursor.
///
/// Also where a click on it is finally answered, because everything a click
/// needs to know - which line, which character, how far the text has been
/// scrolled - is measured here and nowhere else. Ply resolves its
/// `pending_text_click` at the same point in its own frame.
fn emitField(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    const config = element.field orelse return;
    const measurer = self.measurer orelse return;
    const edit = self.edits.getPtr(element.id) orelse return;
    if (box.empty()) return;

    const padding = element.config.padding;
    const inner: BoundingBox = .init(
        box.x + @as(f32, @floatFromInt(padding.left)),
        box.y + @as(f32, @floatFromInt(padding.top)),
        @max(0, box.width - padding.onAxis(true)),
        @max(0, box.height - padding.onAxis(false)),
    );

    // What is drawn is not always what is stored: the placeholder when there
    // is nothing, bullets when it is a password. Built when this element was
    // declared, so every command emitted below keeps looking at its own text.
    const blank = edit.shown().len == 0;
    const shown = self.strings.items[element.shown_start..][0..element.shown_len];
    const style = if (blank) config.placeholderStyle() else config.style();
    const step = measurer.lineHeight(config.style());

    self.field_lines.clearRetainingCapacity();
    const lines = try text_input.wrapLines(
        &self.field_lines,
        self.gpa,
        shown,
        inner.width,
        config.multiline,
        style,
        measurer,
    );

    // A press that landed on this field is turned into a cursor position
    // here, where the measurements are.
    if (self.pending_click) |click| {
        if (click.element == element.id) {
            self.pending_click = null;

            const down = click.at.y - inner.y + edit.scroll.y;
            var row: usize = if (step > 0)
                @intFromFloat(@max(0, @floor(down / step)))
            else
                0;
            if (row >= lines.len) row = lines.len - 1;
            const line = lines[row];

            self.field_boundaries.clearRetainingCapacity();
            const xs = try text_input.boundaries(
                &self.field_boundaries,
                self.gpa,
                shown[line.start..line.end],
                style,
                measurer,
            );
            const column = text_input.nearestBoundary(click.at.x - inner.x + edit.scroll.x, xs);

            // The column is a character index into what is *drawn*, and the
            // cursor is a byte offset into what is *stored*. For a password
            // those are three bytes apart per character, which is why the
            // crossing is counted in characters.
            const offset = if (blank) 0 else text_input.offsetOfCharacter(
                edit.text.items,
                text_input.characters(shown[0..line.start]) + column,
            );

            if (click.word) edit.selectWordAt(offset) else edit.clickTo(offset, click.select);
        }
    }

    // Where the cursor is, in the drawn text.
    const cursor_display = if (blank) 0 else text_input.offsetOfCharacter(
        shown,
        text_input.characters(edit.shown()[0..edit.cursor]),
    );
    const spot = text_input.locate(lines, cursor_display);
    const cursor_line = lines[spot.line];
    const cursor_x = measurer.measure(shown[cursor_line.start..spot.at], style).width;

    const has_keyboard = self.focus != 0 and self.focus == element.id;
    if (has_keyboard) {
        edit.revealX(cursor_x, inner.width);
        if (config.multiline) {
            edit.revealY(spot.line, step, inner.height);
        } else {
            edit.scroll.y = 0;
        }
    }

    // The text moves inside the box, so it has to be cut off at its edge -
    // otherwise a name longer than the field is drawn straight across
    // whatever is beside it.
    try self.emitScissor(.scissor_start, box);

    const origin_x = inner.x - edit.scroll.x;
    const origin_y = inner.y - edit.scroll.y;

    // The selection, under the text, once per line it covers.
    const highlight: ?text_input.Range = if (blank) null else if (edit.selection()) |range| .{
        .start = text_input.offsetOfCharacter(shown, text_input.characters(edit.shown()[0..range.start])),
        .end = text_input.offsetOfCharacter(shown, text_input.characters(edit.shown()[0..range.end])),
    } else null;

    // A markup field colours what it drew. The spans are offsets into the
    // text the reader sees, which is the same string `shown` is a copy of -
    // unless it is a password or a placeholder, and neither of those has
    // anything to colour.
    const spans: []const markup_mod.Span =
        if (config.markup and !blank and !config.password) edit.spans.items else &.{};

    var widest: f32 = 0;
    for (lines, 0..) |line, row| {
        const run = shown[line.start..line.end];
        const line_y = origin_y + step * @as(f32, @floatFromInt(row));

        if (highlight) |range| {
            const from = @max(line.start, range.start);
            const to = @min(line.end, range.end);
            if (from < to) {
                const left = measurer.measure(shown[line.start..from], style).width;
                const right = measurer.measure(shown[line.start..to], style).width;
                try self.output.append(self.gpa, .{
                    .bounding_box = .init(origin_x + left, line_y, right - left, step),
                    .id = element.id,
                    .z_index = element.z_index,
                    .transform = self.stamp,
                    .config = .{ .rectangle = .{
                        .color = config.selection_color,
                        .corner_radius = .sharp,
                    } },
                });
            }
        }

        if (run.len > 0) {
            const width = measurer.measure(run, style).width;
            widest = @max(widest, width);
            if (spans.len == 0) {
                try self.emitPiece(
                    element,
                    style,
                    run,
                    .init(origin_x, line_y, width, step),
                    style.color,
                    &.{},
                    0,
                );
            } else {
                try self.emitSpanned(
                    element,
                    style,
                    shown,
                    line.start,
                    line.end,
                    spans,
                    origin_x,
                    line_y,
                    step,
                );
            }
        }
    }

    // The cursor, on top, and only while the field has the keyboard.
    if (has_keyboard and edit.cursorVisible()) {
        try self.output.append(self.gpa, .{
            .bounding_box = .init(
                origin_x + cursor_x,
                origin_y + step * @as(f32, @floatFromInt(spot.line)),
                2,
                step,
            ),
            .id = element.id,
            .z_index = element.z_index,
            .transform = self.stamp,
            .config = .{ .rectangle = .{
                .color = config.cursor_color,
                .corner_radius = .sharp,
            } },
        });
    }

    try self.emitScissor(.scissor_end, box);

    // And a bar down the edge if one was asked for, measured the way a scroll
    // container's is: against the whole box, with the padding counted into
    // the content.
    if (config.scrollbar) |bar_config| {
        const alpha = visibility(bar_config, edit.idle);
        if (alpha > 0) {
            const content_height = step * @as(f32, @floatFromInt(lines.len)) + padding.onAxis(false);
            const content_width = widest + padding.onAxis(true);
            if (config.multiline) {
                if (barGeometry(box, content_height, edit.scroll.y, bar_config, true)) |bar| {
                    try self.emitBar(element, bar_config, alpha, bar, true, true);
                }
            }
            if (barGeometry(box, content_width, edit.scroll.x, bar_config, false)) |bar| {
                try self.emitBar(element, bar_config, alpha, bar, false, true);
            }
        }
    }
}

/// Give each floating element a size on one axis, then size its subtree.
///
/// A floating element has no parent to grow into, so it is grown into
/// whatever it is attached to instead - which is what makes a dropdown as
/// wide as the button it hangs off, and a modal `.grow` cover the window.
/// Ply sizes its floating roots at the same point and for the same reason.
///
/// The target has already been sized on this axis: it is in the flow, and the
/// flow was sized a moment ago. A float attached to another float declared
/// later has not been, and falls back to its own fit size rather than to a
/// number that is not there yet.
fn sizeFloats(self: *Ui, x_axis: bool) Error!void {
    const safe = self.safeBox();
    for (self.floats.items) |float| {
        const target = self.floatTarget(float);
        const room = if (target) |index|
            self.elements.items[index].dimensions.onAxis(x_axis)
        else if (x_axis) safe.width else safe.height;

        const element = &self.elements.items[float.element];
        const wanted = element.config.sizing.onAxis(x_axis);
        const size = switch (wanted.kind) {
            .grow => room,
            .percent => room * wanted.fraction,
            // `fit` was worked out when it closed, and `fixed` is fixed.
            else => element.dimensions.onAxis(x_axis),
        };

        const held = std.math.clamp(size, wanted.min, if (wanted.max > 0) wanted.max else size);
        if (x_axis) element.dimensions.width = held else element.dimensions.height = held;

        try self.sizeAlongAxis(x_axis, float.element);
    }
}

/// The part of the surface an interface may use.
///
/// The whole thing, less the safe area. What the root is laid out in and what
/// a float with nothing to hang off is measured and placed against - so an
/// interface written for a rectangle keeps clear of a television's edges
/// without a line of it knowing.
///
/// **Nothing is clipped to it.** An inset that also cut would stop a
/// full-bleed backdrop reaching the corners of the screen, and a backdrop is
/// exactly the thing that should not keep clear.
fn safeBox(self: *Ui) BoundingBox {
    const inset = self.safe_area;
    return .init(
        @floatFromInt(inset.left),
        @floatFromInt(inset.top),
        @max(0, self.surface.width - inset.onAxis(true)),
        @max(0, self.surface.height - inset.onAxis(false)),
    );
}

/// Which element a float hangs off, or null for the surface.
fn floatTarget(self: *Ui, float: Float) ?u32 {
    const config = self.elements.items[float.element].floating orelse return null;
    return switch (config.attach) {
        .parent => if (float.element == 0) null else float.declared_in,
        .root => null,
        .id => blk: {
            const name = config.to orelse break :blk null;
            const wanted = identify(name, 0);
            for (self.elements.items, 0..) |element, i| {
                if (element.id == wanted) break :blk @intCast(i);
            }
            break :blk null;
        },
    };
}

/// Put each floating element where its anchor says, and draw it.
///
/// After the whole flow has been placed, because that is when the boxes it
/// anchors against exist. In `z_index` order, and in declaration order within
/// one - the later of two menus at the same depth is the one on top.
fn placeFloats(self: *Ui) Error!void {
    // Stable, so ties keep the order they were declared in. Ply bubble-sorts
    // its roots, which is stable too.
    std.sort.insertion(Float, self.floats.items, self, lowerFloat);

    for (self.floats.items) |float| {
        const config = self.elements.items[float.element].floating orelse continue;
        const target = self.floatTarget(float);
        const against: BoundingBox = if (target) |index|
            self.elements.items[index].box
        else
            self.safeBox();

        const size = self.elements.items[float.element].dimensions;
        const at: Point = .{
            .x = against.x + geometry.leadingSpaceX(against.width, config.anchor.parent_x) -
                geometry.leadingSpaceX(size.width, config.anchor.element_x) + config.offset.x,
            .y = against.y + geometry.leadingSpaceY(against.height, config.anchor.parent_y) -
                geometry.leadingSpaceY(size.height, config.anchor.element_y) + config.offset.y,
        };

        // What it can be seen and pointed at through. A float is not inside
        // its declared parent on screen, so it does not inherit whatever that
        // parent clips - unless it asked to be clipped to it.
        self.elements.items[float.element].float_visible = if (config.clip) against else null;

        if (config.clip) try self.emitScissor(.scissor_start, against);
        try self.positionAndEmit(float.element, at);
        if (config.clip) try self.emitScissor(.scissor_end, against);
    }
}

fn lowerFloat(self: *Ui, a: Float, b: Float) bool {
    const first = if (self.elements.items[a.element].floating) |config| config.z_index else 0;
    const second = if (self.elements.items[b.element].floating) |config| config.z_index else 0;
    return first < second;
}

/// Where one scrollbar goes, and what a drag of it is worth.
const BarGeometry = struct {
    track: BoundingBox,
    thumb: BoundingBox,
    /// How far the content can move.
    max_scroll: f32,
    /// How far the thumb can. A drag is `max_scroll / thumb_travel` pixels of
    /// content per pixel of pointer, which is why both are kept.
    thumb_travel: f32,
};

/// Ply's `compute_vertical_scrollbar_geometry` and its horizontal twin, which
/// are the same function mirrored, so here they are one.
///
/// Null when there is nothing to scroll: a bar with no travel is not drawn
/// short, it is not drawn.
///
/// The measurements are against the element's **whole** box, and `content`
/// must include its padding to match - a bar runs the height of the container
/// rather than the height of its inside, and sits on top of the content
/// rather than beside it. That is Ply's choice and the browsers' one.
fn barGeometry(
    box: BoundingBox,
    content: f32,
    scrolled: f32,
    config: layout.Scrollbar,
    vertical: bool,
) ?BarGeometry {
    const viewport = if (vertical) box.height else box.width;
    const max_scroll = @max(0, content - viewport);
    if (viewport <= 0 or max_scroll <= 0) return null;

    const thickness = @max(1, config.width);
    const track_len = viewport;

    // As much of the track as the window is of the content - so the thumb is
    // a picture of how much there is to read - but never so short that it
    // cannot be grabbed, and never longer than the track it slides in.
    const share = track_len * (viewport / @max(content, viewport));
    const thumb_len = @min(track_len, @max(share, @max(1, config.min_thumb_size)));
    const thumb_travel = @max(0, track_len - thumb_len);

    const offset: f32 = if (thumb_travel <= 0)
        0
    else
        (std.math.clamp(scrolled, 0, max_scroll) / max_scroll) * thumb_travel;

    return if (vertical) .{
        .track = .init(box.x + box.width - thickness, box.y, thickness, track_len),
        .thumb = .init(box.x + box.width - thickness, box.y + offset, thickness, thumb_len),
        .max_scroll = max_scroll,
        .thumb_travel = thumb_travel,
    } else .{
        .track = .init(box.x, box.y + box.height - thickness, track_len, thickness),
        .thumb = .init(box.x + offset, box.y + box.height - thickness, thumb_len, thickness),
        .max_scroll = max_scroll,
        .thumb_travel = thumb_travel,
    };
}

/// How visible a bar is, given how long its container has been still.
///
/// Ply's `scrollbar_visibility_alpha` curve, in seconds: full for
/// `hide_after_seconds`, then a fade lasting a quarter as long again - so a
/// bar told to hide after two seconds spends half a second fading. Ply's
/// quarter and Ply's shape; only the clock is different.
///
/// A zero hides it always, which is how a caller turns the bar off without
/// giving up the configuration.
fn visibility(config: layout.Scrollbar, idle: f32) f32 {
    const hide = config.hide_after_seconds orelse return 1;
    if (hide <= 0) return 0;
    if (idle <= hide) return 1;

    const through = (idle - hide) / (hide * 0.25);
    return std.math.clamp(1 - through, 0, 1);
}

/// The same colour, dimmed by the fade.
fn faded(base: Color, alpha: f32) Color {
    var out = base;
    out.a = std.math.clamp(base.a * alpha, 0, 1);
    return out;
}

/// Draw the bars for one scroll container, and write down where their thumbs
/// ended up so the next frame can be pointed at them.
///
/// Emitted after the element's scissor has closed, next to the border and for
/// the same reason: the bar lies flush against the inside edge of the box, so
/// clipping it with that very rectangle shaves the outer half-pixel of
/// antialiasing off it. Ply draws it inside and pays that half pixel.
fn emitScrollbars(self: *Ui, index: u32, box: BoundingBox) Error!void {
    const element = self.elements.items[index];
    const config = element.clip.scrollbar orelse return;
    if (!element.clip.scrolls() or box.empty()) return;

    // A container being declared for the first time has nothing stored yet -
    // that is written when the frame ends - so it counts as freshly moved and
    // its bar shows immediately. Waiting for the store would make every
    // scrollbar in the program appear one frame after its content.
    const idle = if (self.scrolls.get(element.id)) |scroll| scroll.idle else 0;
    const alpha = visibility(config, idle);
    if (alpha <= 0) return;

    const padding = element.config.padding;
    const content = self.contentOf(element);

    // Vertical first, which is Ply's order, so where a container that scrolls
    // both ways has its two thumbs meet in the corner the horizontal one is
    // drawn on top. Which of them a press there *grabs* is a separate
    // question, and `thumbUnder` answers it the other way round.
    if (element.clip.scroll_y) {
        if (barGeometry(box, content.height + padding.onAxis(false), element.clip.offset.y, config, true)) |bar| {
            try self.emitBar(element, config, alpha, bar, true, false);
        }
    }
    if (element.clip.scroll_x) {
        if (barGeometry(box, content.width + padding.onAxis(true), element.clip.offset.x, config, false)) |bar| {
            try self.emitBar(element, config, alpha, bar, false, false);
        }
    }
}

fn emitBar(
    self: *Ui,
    element: Element,
    config: layout.Scrollbar,
    alpha: f32,
    bar: BarGeometry,
    vertical: bool,
    field: bool,
) Error!void {
    const radius: geometry.CornerRadius = .all(config.corner_radius);

    if (config.track_color) |track| {
        try self.output.append(self.gpa, .{
            .bounding_box = bar.track,
            .id = element.id,
            .z_index = element.z_index,
            .transform = self.stamp,
            .config = .{ .rectangle = .{
                .color = faded(track, alpha),
                .corner_radius = radius.clampTo(bar.track.width, bar.track.height),
            } },
        });
    }

    try self.output.append(self.gpa, .{
        .bounding_box = bar.thumb,
        .id = element.id,
        .z_index = element.z_index,
        .transform = self.stamp,
        .config = .{ .rectangle = .{
            .color = faded(config.thumb_color, alpha),
            .corner_radius = radius.clampTo(bar.thumb.width, bar.thumb.height),
        } },
    });

    try self.bars.append(self.gpa, .{
        .element = element.id,
        .field = field,
        .vertical = vertical,
        .thumb = bar.thumb,
        .max_scroll = bar.max_scroll,
        .thumb_travel = bar.thumb_travel,
    });
}

/// How big everything inside an element turned out to be, measured from where
/// its first child would sit if it were not scrolled.
///
/// From the children's boxes rather than the sizes they asked for, because a
/// child that grew or wrapped is a different size from the one it declared.
/// The scroll position is added back because the children have already been
/// moved by it - forgetting that gives a container whose limit shrinks as it
/// is scrolled, and which creeps to a stop halfway down.
fn contentOf(self: *Ui, element: Element) Dimensions {
    const padding = element.config.padding;
    const origin_x = element.box.x + @as(f32, @floatFromInt(padding.left));
    const origin_y = element.box.y + @as(f32, @floatFromInt(padding.top));

    var content: Dimensions = .zero;
    for (self.childrenOf(element)) |child_index| {
        const child = self.elements.items[child_index];
        content.width = @max(content.width, child.box.right() + element.clip.offset.x - origin_x);
        content.height = @max(content.height, child.box.bottom() + element.clip.offset.y - origin_y);
    }
    return content;
}

/// Work out how much content each scroll container has, and remember it.
///
/// Only possible once everything has a box, which is why this runs last. See
/// `contentOf` for the measurement itself.
fn measureScroll(self: *Ui) Error!void {
    for (self.elements.items) |element| {
        if (!element.clip.scrolls()) continue;

        const padding = element.config.padding;
        const content = self.contentOf(element);

        const entry = try self.scrolls.getOrPut(self.gpa, element.id);
        if (!entry.found_existing) entry.value_ptr.* = .{};

        entry.value_ptr.content = content;
        entry.value_ptr.viewport = .init(
            @max(0, element.box.width - padding.onAxis(true)),
            @max(0, element.box.height - padding.onAxis(false)),
        );
        entry.value_ptr.scroll_x = element.clip.scroll_x;
        entry.value_ptr.scroll_y = element.clip.scroll_y;
        entry.value_ptr.no_drag_scroll = element.clip.no_drag_scroll;
        entry.value_ptr.live = true;
        // A container that has shrunk, or whose content has, may be scrolled
        // past its end. Clamping here rather than when it is nudged is what
        // makes that self-correcting.
        entry.value_ptr.position = entry.value_ptr.clamped();
    }

    // Anything that was not declared this frame is off the page, and where it
    // was scrolled to is no longer anybody's business.
    var stale: [64]u32 = undefined;
    var count: usize = 0;
    var seen = self.scrolls.iterator();
    while (seen.next()) |entry| {
        if (entry.value_ptr.live) continue;
        if (count < stale.len) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (stale[0..count]) |key| _ = self.scrolls.remove(key);
}

// -------------------------------------------------------------------------
// Telling the program what happened
// -------------------------------------------------------------------------

/// Call everything that asked to be told, now the frame is over.
///
/// The last thing `end` does, which is where Ply calls its own and is the
/// only point at which it is safe: the commands are built, so a callback that
/// changes the program's state changes it for the *next* frame rather than
/// for the one being handed over. Declaring elements from in here would
/// declare them into a frame that has already gone.
///
/// The order is Ply's: focus first, then hover, then press, then release.
fn notify(self: *Ui) void {
    if (self.listeners.items.len == 0) {
        // Nobody is listening, so nothing can be missed by not looking - but
        // the focus still has to be caught up, or the first listener ever
        // registered would be told about every focus change since the start.
        self.focus_reported = self.focus;
        return;
    }

    if (self.focus != self.focus_reported) {
        const left = self.focus_reported;
        const taken = self.focus;
        self.focus_reported = taken;
        if (left != 0) self.tell(left, .unfocus, false);
        if (taken != 0) self.tell(taken, .focus, false);
    }

    // Hover is every frame the pointer is over, not the frame it arrived -
    // which is Ply's meaning of the word and what `hovered()` answers.
    for (self.over.items) |id| self.tell(id, .hover, false);

    if (self.pointer.justPressed()) {
        for (self.held.items) |id| self.tell(id, .press, false);
    }

    if (self.pointer.justReleased()) {
        for (self.held.items) |id| self.tell(id, .release, self.isOver(id));
    }
}

const Told = enum { hover, press, release, focus, unfocus };

fn tell(self: *Ui, id: u32, what: Told, on_target: bool) void {
    for (self.listeners.items) |listener| {
        if (listener.id != id) continue;
        const callback = switch (what) {
            .hover => listener.on_hover,
            .press => listener.on_press,
            .release => listener.on_release,
            .focus => listener.on_focus,
            .unfocus => listener.on_unfocus,
        } orelse return;

        callback.call(callback.context, .{
            .id = id,
            .pointer = self.pointer,
            .on_target = on_target,
        });
        return;
    }
}

// -------------------------------------------------------------------------
// Pointing at things
// -------------------------------------------------------------------------

/// Write down where everything ended up, so the next frame can be asked what
/// is under the pointer.
///
/// Parents come before children in `elements`, so one forward pass can build
/// each element's visible rectangle from its parent's - no stack, and no
/// second walk of the tree.
fn recordHits(self: *Ui) Error!void {
    self.hits.clearRetainingCapacity();
    try self.hits.ensureTotalCapacity(self.gpa, self.elements.items.len);

    for (self.elements.items, 0..) |element, i| {
        const parent = element.parent;
        // Everything an element's clipping ancestors leave showing. The root
        // is bounded by the surface, which is also its own box.
        const visible: BoundingBox = if (i == 0)
            element.box
        else if (element.float_visible) |box|
            box
        else if (element.floating != null)
            .init(0, 0, self.surface.width, self.surface.height)
        else block: {
            const outer = self.hits.items[parent];
            const from_parent = if (self.elements.items[parent].clip.clips())
                outer.visible.intersect(self.elements.items[parent].box)
            else
                outer.visible;
            break :block from_parent;
        };

        self.hits.appendAssumeCapacity(.{
            .id = element.id,
            .box = element.box,
            .visible = visible,
            .motion = element.motion,
            .paint = element.paint,
            .parent = parent,
            .floating = element.floating != null,
            .capture = element.capture,
            .preserve_focus = element.preserve_focus,
            .field = element.field != null,
            .drag_select = if (element.field) |config| config.drag_select else false,
            .solid = self.solidToPointer(element),
            .cursor = element.cursor,
        });
    }
}

/// Move time along, in seconds.
///
/// **Call it once a frame, before `begin`.** Four things need a clock and
/// none of them can have one of its own: the cursor blinks on it, a second
/// click is told from a double click by it, a list that has been let go of
/// coasts on it, and a scrollbar told to hide itself waits on it.
///
/// Everything timed here is in seconds, which is the one place this parts
/// company with Ply: Ply counts frames, and a fade tuned at sixty frames a
/// second is half as long at a hundred and twenty. A game already knows its
/// frame time - the engine calls it `Time.delta` - and handing it over once a
/// frame is cheaper than being wrong on every machine but one.
///
/// A program that never calls this gets a solid cursor, no double clicks, no
/// momentum and a scrollbar that never fades. All four are the same good
/// failure: a library with no clock does not guess at one.
pub fn tick(self: *Ui, dt: f32) void {
    self.now += dt;
    self.dt = dt;

    var typed = self.edits.valueIterator();
    while (typed.next()) |edit| {
        edit.blink += dt;
        edit.idle += dt;
    }

    // Anything that moved has its clock put back to zero where the frame is
    // folded - `begin` for a container, `sweepFields` for an input - so all
    // this has to do is let time pass.
    var seen = self.scrolls.valueIterator();
    while (seen.next()) |scroll| scroll.idle += dt;

    self.coast(dt);
}

/// Say whether the pointer is a finger.
///
/// One bit, and it decides one thing: `layout.Clip.no_drag_scroll` turns
/// dragging off for a mouse and leaves it on for a touch, because on a touch
/// screen there is nothing else to scroll with. A program that never says is
/// taken to be using a mouse, which is the safer of the two to assume.
pub fn setTouch(self: *Ui, is_touch: bool) void {
    self.touch = is_touch;
}

/// Carry the scroll containers on after the finger has let go.
///
/// Exponential decay, which is what makes it frame-rate independent: half a
/// second of coasting looks the same whether it took thirty frames or three
/// hundred. Ply's constants, and Ply's rule that a container being dragged
/// does not also coast - the finger is already saying where it goes.
///
/// A program that never calls `tick` gets no momentum at all, which is the
/// honest answer for a library with no clock of its own.
fn coast(self: *Ui, dt: f32) void {
    if (dt <= 0) return;
    const decay = @exp(-scroll_deceleration * dt);

    var seen = self.scrolls.iterator();
    while (seen.next()) |entry| {
        const scroll = entry.value_ptr;

        if (self.content_drag) |drag| {
            if (drag.element == entry.key_ptr.*) continue;
        }
        if (@abs(scroll.momentum.x) <= scroll_stops_below and
            @abs(scroll.momentum.y) <= scroll_stops_below) continue;

        scroll.position.x += scroll.momentum.x * dt;
        scroll.position.y += scroll.momentum.y * dt;
        scroll.momentum.x *= decay;
        scroll.momentum.y *= decay;
        if (@abs(scroll.momentum.x) < scroll_stops_below) scroll.momentum.x = 0;
        if (@abs(scroll.momentum.y) < scroll_stops_below) scroll.momentum.y = 0;

        // Hitting either end takes the speed with it, or a list would go on
        // pressing against its own bottom for a second after it got there.
        const limit = scroll.limit();
        if (scroll.position.x <= 0 or scroll.position.x >= limit.x) scroll.momentum.x = 0;
        if (scroll.position.y <= 0 or scroll.position.y >= limit.y) scroll.momentum.y = 0;

        scroll.position = scroll.clamped();
        scroll.active = true;
    }
}

/// Ply's three numbers. The decay reaches under a hundredth in a second, the
/// floor is where a list is close enough to stopped to be stopped, and the
/// smoothing is how much of this frame's speed to believe over the last.
const scroll_deceleration: f32 = 5;
const scroll_stops_below: f32 = 5;
const scroll_smoothing: f32 = 0.4;
/// How far a drag has to go before it stops being a tap. Ply has no such
/// rule; see `setPointer`.
const scroll_becomes_drag: f32 = 6;

/// Say whether shift is held.
///
/// The one modifier the pointer needs: shift-clicking a text input extends
/// the selection rather than replacing it. Every other modifier reaches this
/// library already decided, as a `text_input.Action`.
pub fn setShift(self: *Ui, held: bool) void {
    self.shift = held;
}

/// Whether a click landing on this element is the interface's business.
///
/// Two ways to qualify, and a game needs both. Something is **drawn** here -
/// a fill, a border, a picture - so the interface is covering this pixel and
/// a click through it into the world would be wrong. Or the element **asked**
/// to be clicked: a callback, a text field, a capture, a list that scrolls.
///
/// An element that lays out and paints nothing does not qualify, which is
/// what keeps a transparent root from swallowing the whole screen - and a
/// game's interface is mostly transparent root.
fn solidToPointer(self: *Ui, element: Element) bool {
    // A callback lives in `listeners` rather than on the element, so this is
    // the one part that has to be looked up. Only the three pointer ones
    // count: an element that asked to be told about the *keyboard* has not
    // asked to swallow a click.
    for (self.listeners.items) |listener| {
        if (listener.id != element.id) continue;
        if (listener.on_hover != null or listener.on_press != null or
            listener.on_release != null) return true;
    }

    if (!element.background_color.invisible()) return true;
    if (element.image != null) return true;
    if (element.border) |line| {
        if (!line.color.invisible() and !line.width.isNone()) return true;
    }
    if (element.field != null) return true;
    if (element.capture) return true;
    if (element.clip.scrolls()) return true;
    return false;
}

/// Say where the pointer is and whether its button is down.
///
/// **Call it before `begin`**, once a frame. It advances the button through
/// `input.PointerState` - so "just pressed" fires exactly once however many
/// times it is asked - and works out what is under the pointer from where
/// things were when the last frame finished.
///
/// Ply calls this `set_pointer_state` and calls it at the same point.
pub fn setPointer(self: *Ui, x: f32, y: f32, down: bool) void {
    self.pointer.position = .{ .x = x, .y = y };
    self.pointer.state = self.pointer.state.advance(down);

    // A scrollbar is not an element, so it does not shadow what is under it
    // for hovering - the pointer resting on a bar still hovers the row
    // beneath, as it does in Ply. Only the press below is intercepted.
    self.over.clearRetainingCapacity();
    self.chainUnder(self.pointer.position) catch {};

    if (self.pointer.justPressed()) {
        if (self.thumbUnder(self.pointer.position)) |grabbed| {
            // Ply hands the whole press to the scrollbar and returns: nothing
            // is under the pointer, nothing is pressed, and the focus stays
            // where it was. Grabbing the bar beside a text field must not
            // take the caret out of it.
            self.drag = grabbed;
            self.over.clearRetainingCapacity();
            self.held.clearRetainingCapacity();
            return;
        }
        self.held.clearRetainingCapacity();
        self.held.appendSlice(self.gpa, self.over.items) catch {};
        self.takeFocus();
        self.pressField();
        self.grabContent();
    } else if (self.pointer.isUp()) {
        self.drag = null;
        self.selecting = null;
        // The drag ends but the speed does not: what it was going at when the
        // finger left is what carries it on. See `coast`.
        self.content_drag = null;
        // The chain is kept for the frame the button comes up in, so
        // `justReleased` has something to answer about, and dropped after.
        if (self.pointer.state == .idle) self.held.clearRetainingCapacity();
    }

    // Not on the frame the button went down: the pointer has not moved yet,
    // and Ply waits the same frame for the same reason.
    if (self.drag) |grabbed| self.dragThumb(grabbed);

    if (self.content_drag) |*drag| {
        if (self.pointer.isDown() and !self.pointer.justPressed()) self.dragContent(drag);
    }

    // A drag inside a text input keeps asking for the cursor to be put where
    // the pointer is, with the selection dragged along behind it.
    if (self.selecting) |id| {
        if (self.pointer.isDown() and !self.pointer.justPressed()) {
            self.pending_click = .{
                .element = id,
                .at = self.pointer.position,
                .select = true,
                .word = false,
            };
        }
    }
}

/// Take hold of the innermost scroll container under the pointer, if one
/// wants to be dragged.
///
/// Innermost first, so a list inside a page scrolls rather than the page -
/// and only a container that actually overflows, or a press anywhere on a
/// short list would arm a drag that can never move.
///
/// The press is **not** consumed, which is Ply's behaviour: what is under the
/// pointer is still pressed, and stays pressed until the drag turns out to be
/// a scroll. See `dragContent`.
fn grabContent(self: *Ui) void {
    if (self.selecting != null or self.drag != null) return;

    var i = self.over.items.len;
    while (i > 0) {
        i -= 1;
        const id = self.over.items[i];
        const scroll = self.scrolls.getPtr(id) orelse continue;
        if (scroll.no_drag_scroll and !self.touch) continue;
        if (!scroll.overflowsX() and !scroll.overflowsY()) continue;

        self.content_drag = .{
            .element = id,
            .origin = self.pointer.position,
            .scrolled = scroll.position,
        };
        return;
    }
}

/// Move the content by as far as the finger has gone, and remember how fast.
///
/// Against where the drag started rather than against the last frame, so the
/// content stays under the finger however many frames it lasts. The speed is
/// the one thing measured per frame, because speed is what a per-frame
/// difference *is*.
fn dragContent(self: *Ui, drag: *ContentDrag) void {
    const scroll = self.scrolls.getPtr(drag.element) orelse return;

    // The content follows the finger, so scrolling *down* through a list is
    // dragging *up* the page - which is why this is a subtraction and the
    // scrollbar's is not.
    const moved: geometry.Vec2 = .{
        .x = self.pointer.position.x - drag.origin.x,
        .y = self.pointer.position.y - drag.origin.y,
    };
    scroll.position = .{
        .x = if (scroll.scroll_x) drag.scrolled.x - moved.x else scroll.position.x,
        .y = if (scroll.scroll_y) drag.scrolled.y - moved.y else scroll.position.y,
    };
    scroll.position = scroll.clamped();
    scroll.active = true;

    // Once it has gone far enough to be a scroll rather than a tap, whatever
    // was pressed is let go of.
    //
    // **Ply does not do this**, and a list of buttons is where it shows: drag
    // to scroll, let go, and the button under the finger fires. Every touch
    // platform cancels the tap instead, and the absence of it reads as a bug
    // rather than as a decision.
    if (!drag.scrolling and (@abs(moved.x) > scroll_becomes_drag or
        @abs(moved.y) > scroll_becomes_drag))
    {
        drag.scrolling = true;
        self.held.clearRetainingCapacity();
    }

    // Ply's filter: how fast it is going is mostly what it was going, plus a
    // little of this frame - so one stuttering frame does not throw the
    // whole thing across the screen.
    const step: geometry.Vec2 = .{
        .x = moved.x - drag.previous.x,
        .y = moved.y - drag.previous.y,
    };
    drag.previous = moved;
    if (self.dt <= 0) return;
    if (@abs(step.x) <= 0.5 and @abs(step.y) <= 0.5) return;

    scroll.momentum = .{
        .x = scroll.momentum.x * (1 - scroll_smoothing) - (step.x / self.dt) * scroll_smoothing,
        .y = scroll.momentum.y * (1 - scroll_smoothing) - (step.y / self.dt) * scroll_smoothing,
    };
}

/// Whether the pointer is dragging a scroll container's content.
pub fn draggingContent(self: *Ui) bool {
    return self.content_drag != null;
}

/// Write down a press that landed on a text input, for `emitField` to answer.
///
/// Nothing is decided here on purpose. Where in the string the pointer is
/// depends on a measurement that has not happened yet - the frame this press
/// belongs to has not been declared, let alone laid out - so all that is
/// settled now is *which* field, and whether this is the second click.
fn pressField(self: *Ui) void {
    if (self.over.items.len == 0) return;
    const target = self.over.items[self.over.items.len - 1];

    for (self.hits.items) |hit| {
        if (hit.id != target) continue;
        if (!hit.field) return;

        const edit = self.edits.getPtr(target) orelse return;
        // Ply's rule: the same element, within four tenths of a second.
        const twice = edit.last_click_at == target and (self.now - edit.last_click) < 0.4;
        edit.last_click = self.now;
        edit.last_click_at = target;

        self.pending_click = .{
            .element = target,
            .at = self.pointer.position,
            .select = self.shift,
            .word = twice,
        };
        if (hit.drag_select) self.selecting = target;
        return;
    }
}

/// The bar for one axis of one container, as the last frame drew it.
fn barOf(self: *Ui, element: u32, vertical: bool) ?Bar {
    for (self.bars.items) |bar| {
        if (bar.element == element and bar.vertical == vertical) return bar;
    }
    return null;
}

/// The thumb under a point, ready to be dragged, if there is one.
///
/// Backwards, which is paint order, so the bar of the innermost container
/// wins where two containers overlap.
fn thumbUnder(self: *Ui, point: geometry.Vec2) ?ThumbDrag {
    var i = self.bars.items.len;
    while (i > 0) {
        i -= 1;
        var bar = self.bars.items[i];
        if (!bar.thumb.contains(point)) continue;

        // One container's own two thumbs meet in the corner when both are
        // scrolled to the end, and there the point is on both. Ply checks the
        // vertical axis first and returns, so the vertical one wins - and
        // since it is emitted first, it is the entry just before this one.
        // Dragging sideways by accident when reaching for the bottom of a
        // long list is the thing this avoids.
        if (!bar.vertical and i > 0) {
            const above = self.bars.items[i - 1];
            if (above.element == bar.element and above.vertical and above.thumb.contains(point)) {
                bar = above;
            }
        }

        const scrolled = self.scrolledTo(bar.element, bar.field) orelse continue;
        return .{
            .element = bar.element,
            .field = bar.field,
            .vertical = bar.vertical,
            .origin = if (bar.vertical) point.y else point.x,
            .scrolled = if (bar.vertical) scrolled.y else scrolled.x,
        };
    }
    return null;
}

/// How far a scrollable thing has been scrolled.
///
/// Two kinds of thing have a scrollbar and they keep the same two numbers in
/// different places: a scroll container in `scrolls`, a text input in the
/// state that also holds its text. Everything a bar does goes through here
/// and its opposite below, so the rest of the scrollbar code never has to
/// know which it is looking at.
fn scrolledTo(self: *Ui, element: u32, field: bool) ?geometry.Vec2 {
    if (field) {
        const edit = self.edits.getPtr(element) orelse return null;
        return edit.scroll;
    }
    const scroll = self.scrolls.get(element) orelse return null;
    return scroll.position;
}

/// Move the content by as much as the thumb has been dragged.
///
/// Against where the drag started rather than against the last frame, so the
/// thumb stays under the pointer however many frames the drag lasts. A
/// per-frame delta would drift, and would drift most where it is most
/// noticeable: a long document, where one pixel of thumb is many of content.
///
/// The travel and the limit are re-read from this frame's bar rather than
/// remembered from the press, so a list that grows while it is being dragged
/// is dragged at the new rate. Ply recomputes them too.
fn dragThumb(self: *Ui, grabbed: ThumbDrag) void {
    const bar = self.barOf(grabbed.element, grabbed.vertical) orelse return;

    const pointer = if (grabbed.vertical) self.pointer.position.y else self.pointer.position.x;
    const moved: f32 = if (bar.thumb_travel <= 0)
        0
    else
        grabbed.scrolled + (pointer - grabbed.origin) * (bar.max_scroll / bar.thumb_travel);
    const to = std.math.clamp(moved, 0, bar.max_scroll);

    if (grabbed.field) {
        const edit = self.edits.getPtr(grabbed.element) orelse return;
        if (grabbed.vertical) edit.scroll.y = to else edit.scroll.x = to;
        edit.active = true;
        return;
    }

    const scroll = self.scrolls.getPtr(grabbed.element) orelse return;
    if (grabbed.vertical) {
        scroll.position.y = to;
    } else {
        scroll.position.x = to;
    }
    scroll.position = scroll.clamped();
    scroll.active = true;
}

/// Whether the pointer is dragging a scrollbar.
///
/// For a host that has its own idea of what a press means: while this is
/// true, the press belongs to the scrollbar and nothing under it is being
/// pressed.
pub fn draggingScrollbar(self: *Ui) bool {
    return self.drag != null;
}

/// Fill `over` with the elements under a point, outermost first.
///
/// Backwards through the hit list, because that is paint order: the last
/// thing drawn is the thing on top, so the last box containing the point is
/// the one being pointed at. Then up the tree from there, which gives the
/// ancestors - and stops at anything that captures.
fn chainUnder(self: *Ui, point: geometry.Vec2) Error!void {
    if (self.hits.items.len == 0) return;

    // The one drawn last, which is not the one stored last once anything
    // floats: a menu declared halfway down the tree is drawn after all of it.
    var topmost: ?u32 = null;
    var latest: u32 = 0;
    for (self.hits.items, 0..) |hit, i| {
        if (!hit.holds(point)) continue;
        if (topmost == null or hit.paint > latest) {
            topmost = @intCast(i);
            latest = hit.paint;
        }
    }

    const found = topmost orelse return;

    // Up to the root, or to whatever takes the pointer for itself. A button
    // inside a draggable panel captures, so dragging the button does not also
    // drag the panel.
    var chain: [max_depth]u32 = undefined;
    var depth: usize = 0;
    var at = found;
    while (depth < chain.len) {
        chain[depth] = at;
        depth += 1;
        // A float ends the chain for the same reason `capture` does: what is
        // above it in the tree is not what is under it on the screen.
        if (self.hits.items[at].capture or self.hits.items[at].floating) break;
        const parent = self.hits.items[at].parent;
        if (parent == at) break;
        at = parent;
    }

    // Outermost first, which is the order Ply hands them over in.
    var back = depth;
    while (back > 0) {
        back -= 1;
        try self.over.append(self.gpa, self.hits.items[chain[back]].id);
    }
}

/// Move the keyboard to whatever was just pressed.
///
/// The innermost element under the pointer takes it, unless it asked not to.
/// Ply's `preserve_focus` is for a toolbar button that should not take the
/// caret out of the text field beside it - pressing it does something, and
/// the field stays focused.
fn takeFocus(self: *Ui) void {
    if (self.over.items.len == 0) {
        self.focus = 0;
        return;
    }

    const innermost_id = self.over.items[self.over.items.len - 1];
    for (self.hits.items) |hit| {
        if (hit.id == innermost_id and hit.preserve_focus) return;
    }
    self.focus = innermost_id;
}

fn isOver(self: *Ui, id: u32) bool {
    for (self.over.items) |over| {
        if (over == id) return true;
    }
    return false;
}

fn isHeld(self: *Ui, id: u32) bool {
    for (self.held.items) |held| {
        if (held == id) return true;
    }
    return false;
}

// -- asked of the element currently open --

/// Whether the pointer is over the element being declared. Ply's
/// `ui.hovered()`.
pub fn hovered(self: *Ui) bool {
    return self.isOver(self.openId());
}

/// Whether the button went down on this element and has not come up. Ply's
/// `ui.pressed()`.
pub fn pressed(self: *Ui) bool {
    return self.pointer.isDown() and self.isHeld(self.openId());
}

/// Whether the button went down on this element this frame. Ply's
/// `ui.just_pressed()`.
pub fn justPressed(self: *Ui) bool {
    return self.pointer.justPressed() and self.isHeld(self.openId());
}

/// Whether the button came up on this element this frame. Ply's
/// `ui.just_released()`.
///
/// The one to hang a button on: it fires once, and only if the press started
/// here - so dragging in from somewhere else and letting go does nothing.
pub fn justReleased(self: *Ui) bool {
    return self.pointer.justReleased() and self.isHeld(self.openId()) and self.hovered();
}

/// Whether this element has the keyboard. Ply's `ui.focused()`.
pub fn focused(self: *Ui) bool {
    return self.focus != 0 and self.focus == self.openId();
}

fn openId(self: *Ui) u32 {
    if (self.open_stack.items.len == 0) return 0;
    return self.elements.items[self.innermost()].id;
}

// -- asked by name, from anywhere --

/// Whether the pointer is over this element. Ply's `pointer_over(id)`.
pub fn isPointerOver(self: *Ui, name: []const u8) bool {
    return self.isOver(identify(name, 0));
}

/// Ply's `is_pressed(id)`.
pub fn isElementPressed(self: *Ui, name: []const u8) bool {
    return self.pointer.isDown() and self.isHeld(identify(name, 0));
}

/// Ply's `is_just_released(id)`.
pub fn isElementReleased(self: *Ui, name: []const u8) bool {
    const id = identify(name, 0);
    return self.pointer.justReleased() and self.isHeld(id) and self.isOver(id);
}

/// Whether the interface wants this click.
///
/// The one question a game asks before it shoots. Dear ImGui calls it
/// `WantCaptureMouse`, and every program that puts an interface over a world
/// needs it: when a button is under the cursor, exactly one of "press the
/// button" and "fire the gun" should happen.
///
/// True when the pointer is over something the interface either drew or asked
/// to be clicked - see `solidToPointer`. A transparent root over a game does
/// not count, which is the whole point: a heads-up display is mostly nothing.
///
/// Answered from where things were when the last frame finished, like every
/// other pointer question here, so a game asks it after the interface's frame
/// and before its own input runs.
pub fn wantsPointer(self: *Ui) bool {
    for (self.over.items) |id| {
        const hit = self.hitOf(id) orelse continue;
        if (hit.solid) return true;
    }
    return false;
}

/// What the pointer over this element was recorded as, or null if it was not
/// on the page when the last frame finished.
fn hitOf(self: *Ui, id: u32) ?Hit {
    for (self.hits.items) |hit| {
        if (hit.id == id) return hit;
    }
    return null;
}

/// What the pointer should look like, for the program to hand to its window.
///
/// Ply keeps a shape and hands it back; this works one out as well, because
/// the interface is the half that knows the pointer is over a text field and
/// the game is the half that has a window to set it on.
///
/// In order: a shape the program asked for with `setCursor` this frame, then
/// the **innermost** element under the pointer that named one - a text input
/// naming `.ibeam` without being asked - and an arrow when nothing does.
///
/// ```zig
/// try window.setCursorShape(switch (ui.cursor()) {
///     .arrow => .arrow,
///     .ibeam => .ibeam,
///     // ... the names are the same on both sides
/// });
/// ```
///
/// One frame old, like every other pointer question here.
pub fn cursor(self: *Ui) layout.CursorShape {
    if (self.requested_cursor) |shape| return shape;

    // Backwards: `over` runs outermost first, and the shape a handle asks for
    // must not be overruled by the panel it sits in.
    var i = self.over.items.len;
    while (i > 0) {
        i -= 1;
        const hit = self.hitOf(self.over.items[i]) orelse continue;
        if (hit.cursor) |shape| return shape;
    }
    return .arrow;
}

/// Ask for a shape for the rest of this frame, whatever is under the pointer.
///
/// Ply's `set_cursor`, with one difference: **Ply's persists until it is set
/// again, and this lasts until the next `begin`.** A shape that outlived its
/// frame could never be taken back by a tree that works its own out, and
/// saying it every frame is how everything else here is written. Pass null to
/// drop it again within a frame.
///
/// What it is for is the drag that has left what started it: a window edge
/// being pulled should keep the resize cursor while the pointer is halfway
/// across the screen, and no element is under it to say so.
pub fn setCursor(self: *Ui, shape: ?layout.CursorShape) void {
    self.requested_cursor = shape;
}

/// Whether the interface wants the keys.
///
/// True only when a **text input** has the focus, which is the case that
/// matters: W means "walk" until somebody is typing a name into a box, and
/// then it means W. A focused button does not take the keyboard - a game
/// still wants its own bindings while one is highlighted.
pub fn wantsKeyboard(self: *Ui) bool {
    if (self.focus == 0) return false;
    return self.edits.contains(self.focus);
}

/// The elements under the pointer, outermost first. Ply's
/// `pointer_over_ids()`.
pub fn pointerOver(self: *Ui) []const u32 {
    return self.over.items;
}

/// Give the keyboard to an element, by name.
pub fn setFocus(self: *Ui, name: []const u8) void {
    self.focus = identify(name, 0);
}

pub fn clearFocus(self: *Ui) void {
    self.focus = 0;
}

/// Whether this element has the keyboard.
pub fn isFocused(self: *Ui, name: []const u8) bool {
    return self.focus != 0 and self.focus == identify(name, 0);
}

// -------------------------------------------------------------------------
// Typing
// -------------------------------------------------------------------------

/// Do something to the focused text input.
///
/// **Call it before `begin`**, with whatever the keyboard produced. Nothing
/// happens if no text input has the focus, which is what lets a program hand
/// every key over without checking first.
///
/// What comes back is the text a `copy` or a `cut` wants put on the
/// clipboard, and null otherwise - this library has no clipboard of its own
/// and no way to reach the system's. The slice is good until the next copy or
/// cut.
///
/// ```zig
/// if (key == .left) _ = ui.textAction(.moveTo(.left, shift));
/// if (key == .c and ctrl) if (ui.textAction(.copy)) |taken| clipboard.set(taken);
/// ```
pub fn textAction(self: *Ui, action: text_input.Action) ?[]const u8 {
    return self.textActionChecked(action) catch |err| {
        self.remember(err);
        return null;
    };
}

fn textActionChecked(self: *Ui, action: text_input.Action) Error!?[]const u8 {
    if (self.focus == 0) return null;
    const edit = self.edits.getPtr(self.focus) orelse return null;

    // The undo entry is pushed *before* the edit, so what it holds is the
    // state to come back to. Which actions push, and which of those group
    // with the one before, is `text_input.EditKind`.
    switch (action) {
        .backspace => try edit.pushUndo(self.gpa, .backspace),
        .delete => try edit.pushUndo(self.gpa, .delete),
        .backspace_word, .delete_word => try edit.pushUndo(self.gpa, .delete_word),
        .cut => try edit.pushUndo(self.gpa, .cut),
        .paste => try edit.pushUndo(self.gpa, .paste),
        // Only in a multiline input, where Enter is an edit rather than an
        // answer.
        .submit => if (edit.multiline) try edit.pushUndo(self.gpa, .insert),
        else => {},
    }

    const before = edit.revision;
    var taken: ?[]const u8 = null;

    switch (action) {
        .move => |motion| edit.move(motion),
        .backspace => try edit.backspace(self.gpa),
        .delete => try edit.deleteForward(self.gpa),
        .backspace_word => try edit.backspaceWord(self.gpa),
        .delete_word => try edit.deleteWordForward(self.gpa),
        .select_all => edit.selectAll(),
        .copy => taken = try self.remember_clipboard(edit.selected()),
        .cut => {
            taken = try self.remember_clipboard(edit.selected());
            _ = try edit.deleteSelection(self.gpa);
            edit.resetBlink();
        },
        .paste => |run| try edit.insert(self.gpa, run, edit.max_length),
        .submit => {
            edit.submitted = true;
            if (edit.multiline) try edit.insert(self.gpa, "\n", edit.max_length);
        },
        .undo => _ = try edit.undo(self.gpa),
        .redo => _ = try edit.redo(self.gpa),
    }

    if (edit.revision != before) edit.changed = true;
    edit.active = true;
    return taken;
}

fn remember_clipboard(self: *Ui, run: []const u8) Error![]const u8 {
    self.clipboard.clearRetainingCapacity();
    try self.clipboard.appendSlice(self.gpa, run);
    return self.clipboard.items;
}

/// Type into the focused text input. Ply's `process_text_input_char`.
///
/// One character or several - a program that gets a whole string out of its
/// window layer may hand the whole string over. Consecutive calls group into
/// one undo, so typing a word and pressing Ctrl+Z takes back the word.
pub fn typeText(self: *Ui, run: []const u8) void {
    self.typeTextChecked(run) catch |err| self.remember(err);
}

fn typeTextChecked(self: *Ui, run: []const u8) Error!void {
    if (self.focus == 0) return;
    const edit = self.edits.getPtr(self.focus) orelse return;

    try edit.pushUndo(self.gpa, .insert);
    const before = edit.revision;
    try edit.insert(self.gpa, run, edit.max_length);
    if (edit.revision != before) edit.changed = true;
    edit.active = true;
}

/// What a text input holds, or null if there is no such element or it was not
/// on the page last frame.
pub fn textValueOf(self: *Ui, name: []const u8) ?[]const u8 {
    const edit = self.edits.getPtr(identify(name, 0)) orelse return null;
    return edit.value();
}

/// Put text into an input, from the program rather than the keyboard.
///
/// Does not push an undo: filling a form in is not an edit the reader made,
/// and letting Ctrl+Z take it back would undo something they never did.
pub fn setTextValue(self: *Ui, name: []const u8, run: []const u8) void {
    const edit = self.edits.getPtr(identify(name, 0)) orelse return;
    edit.setValue(self.gpa, run) catch |err| self.remember(err);
    edit.active = true;
}

/// Whether the text changed this frame - a key, a paste, an undo. What an
/// `on_changed` callback would be told, asked for instead.
pub fn textChanged(self: *Ui, name: []const u8) bool {
    const edit = self.edits.getPtr(identify(name, 0)) orelse return false;
    return edit.changed_this_frame;
}

/// Whether Enter was pressed in this input this frame. Ply's `on_submit`.
pub fn textSubmitted(self: *Ui, name: []const u8) bool {
    const edit = self.edits.getPtr(identify(name, 0)) orelse return false;
    return edit.submitted_this_frame;
}

/// Everything one text input remembers, for a caller that wants the cursor or
/// the selection rather than only the text.
pub fn editOf(self: *Ui, name: []const u8) ?*text_input.TextEdit {
    return self.edits.getPtr(identify(name, 0));
}

/// Forget the inputs that were not declared this frame.
///
/// The mirror of the sweep `measureScroll` does, and it clears the idle clock
/// a hiding scrollbar reads while it is there.
fn sweepFields(self: *Ui) Error!void {
    var stale: [64]u32 = undefined;
    var count: usize = 0;

    var seen = self.edits.iterator();
    while (seen.next()) |entry| {
        if (entry.value_ptr.active) entry.value_ptr.idle = 0;
        entry.value_ptr.active = false;

        if (entry.value_ptr.live) continue;
        if (count < stale.len) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }

    for (stale[0..count]) |key| {
        if (self.edits.fetchRemove(key)) |gone| {
            var edit = gone.value;
            edit.deinit(self.gpa);
        }
    }
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

// -------------------------------------------------------------------------
// Clipping and scrolling
// -------------------------------------------------------------------------
//
// The three rules a clip changes are each a place the layout would otherwise
// refuse to overflow, and each has a test that fails without it. Then the
// scissor pair, then the scroll position.

test "a clip container lets its children overflow rather than squeezing them" {
    // Rule two. Without it the two hundred pixels of content would be
    // compressed into a hundred, and there would be nothing left to scroll.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{ .id = "window", .width = .fixed(100), .height = .fixed(100), .clip = .both });
        defer ui.close();
        leaf(&ui, "wide", .{ .width = .fixed(300), .height = .fixed(50) });
    }
    ui.close();
    _ = try ui.end();

    // The child kept every pixel it asked for and runs off the right.
    try testing.expectEqual(@as(f32, 300), ui.boxOf("wide").?.width);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("window").?.width);
}

test "the same container without a clip squeezes them instead" {
    // The other half of the same test: `fitBetween` gives way when nothing
    // says it may overflow, and that is the behaviour a clip turns off.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{ .id = "window", .width = .fixed(100), .height = .fixed(100) });
        defer ui.close();
        leaf(&ui, "wide", .{ .width = .fitBetween(0, 300), .height = .fixed(50) });
        leaf(&ui, "also", .{ .width = .fitBetween(0, 300), .height = .fixed(50) });
    }
    ui.close();
    _ = try ui.end();

    // Two children that between them wanted more than the hundred available
    // are held inside it.
    const total = ui.boxOf("wide").?.width + ui.boxOf("also").?.width;
    try testing.expect(total <= 100.01);
}

test "a clipped axis does not raise the container's minimum" {
    // Rule one. A long list inside a scroll container must not make the
    // container itself un-shrinkable, or the panel round it cannot be
    // resized.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(200, 400));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(200), .height = .grow });
        defer ui.close();

        ui.open(.{ .id = "list", .width = .fit, .height = .grow, .clip = .scrollX });
        {
            defer ui.close();
            leaf(&ui, "row", .{ .width = .fixed(600), .height = .fixed(20) });
        }
        leaf(&ui, "beside", .{ .width = .fixed(150), .height = .grow, .background_color = paint });
    }
    ui.close();
    _ = try ui.end();

    // The fixed sibling kept its width, so the list gave way - which it could
    // only do because its six-hundred-pixel row does not count towards its
    // minimum.
    try testing.expectEqual(@as(f32, 150), ui.boxOf("beside").?.width);
    try testing.expect(ui.boxOf("list").?.width <= 50.01);
}

test "a child may be wider than the container across a clipped axis" {
    // Rule three. In a column, width is the cross axis, and a child is
    // normally held inside the parent there.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "column",
            .width = .fixed(100),
            .height = .fixed(200),
            .direction = .top_to_bottom,
            .clip = .both,
        });
        defer ui.close();
        leaf(&ui, "wide", .{ .width = .fixed(400), .height = .fixed(30) });
    }
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 400), ui.boxOf("wide").?.width);
}

test "a clip emits a scissor pair around its children and nothing else" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "window",
            .width = .fixed(100),
            .height = .fixed(100),
            .clip = .both,
            .background_color = paint,
            .border = .all(paint, 1),
        });
        defer ui.close();
        leaf(&ui, "inside", .{ .width = .fixed(300), .height = .fixed(50) });
    }
    ui.close();
    const drawn = try ui.end();

    // Background, clip on, the child, clip off, border - in that order. The
    // background is not clipped by the element's own rectangle and neither is
    // the border, which would otherwise lose a pixel on every side.
    try testing.expectEqual(5, drawn.len);
    try testing.expectEqual(commands.Config.rectangle, std.meta.activeTag(drawn[0].config));
    try testing.expectEqual(commands.Config.scissor_start, std.meta.activeTag(drawn[1].config));
    try testing.expectEqual(commands.Config.rectangle, std.meta.activeTag(drawn[2].config));
    try testing.expectEqual(commands.Config.scissor_end, std.meta.activeTag(drawn[3].config));
    try testing.expectEqual(commands.Config.border, std.meta.activeTag(drawn[4].config));

    // The scissor is the element's whole box, padding included.
    try testing.expectEqual(ui.boxOf("window").?, drawn[1].bounding_box);
    try testing.expect(commands.List.scissorsBalanced(.{ .items = drawn }));
}

test "a clip inside a clip leaves the pairs balanced" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(200), .height = .fixed(200), .clip = .both });
        defer ui.close();
        ui.open(.{ .width = .fixed(100), .height = .fixed(100), .clip = .both });
        defer ui.close();
        leaf(&ui, "deep", .{ .width = .fixed(300), .height = .fixed(30) });
    }
    ui.close();
    const drawn = try ui.end();

    const emitted: commands.List = .{ .items = drawn };
    try testing.expect(emitted.scissorsBalanced());
    try testing.expectEqual(2, emitted.count(.scissor_start));
    try testing.expectEqual(2, emitted.count(.scissor_end));
}

test "a container that does not clip emits no scissor at all" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{ .width = .fixed(100), .height = .fixed(100) });
        defer ui.close();
        leaf(&ui, "inside", .{ .width = .fixed(50), .height = .fixed(50) });
    }
    ui.close();
    const drawn = try ui.end();

    const emitted: commands.List = .{ .items = drawn };
    try testing.expectEqual(0, emitted.count(.scissor_start));
}

test "a scroll container remembers how much content it has" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "list",
            .width = .fixed(200),
            .height = .fixed(100),
            .direction = .top_to_bottom,
            .clip = .scrollY,
        });
        defer ui.close();
        for (0..10) |_| {
            ui.empty(.{ .width = .grow, .height = .fixed(30), .background_color = paint });
        }
    }
    ui.close();
    _ = try ui.end();

    const scroll = ui.scrollOf("list").?;
    try testing.expectEqual(@as(f32, 300), scroll.content.height);
    try testing.expectEqual(@as(f32, 100), scroll.viewport.height);
    // Two hundred pixels of content past the bottom of the window.
    try testing.expectEqual(@as(f32, 200), scroll.limit().y);
    try testing.expect(scroll.overflowsY());
    try testing.expect(!scroll.overflowsX());
}

test "scrolling moves the content and stops at the end" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const declare = struct {
        fn frame(u: *Ui) !void {
            u.begin(.init(400, 400));
            u.open(.{ .width = .grow, .height = .grow });
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .scrollY,
                });
                defer u.close();
                for (0..10) |i| {
                    var d: layout.Declaration = .{
                        .width = .grow,
                        .height = .fixed(30),
                        .background_color = paint,
                    };
                    if (i == 0) d.id = "first";
                    u.open(d);
                    u.close();
                }
            }
            u.close();
            _ = try u.end();
        }
    }.frame;

    // The first frame is where the container is measured, so there is
    // something to scroll before the second.
    try declare(&ui);
    const before = ui.boxOf("first").?.y;

    ui.scrollBy("list", 0, 50);
    try declare(&ui);
    try testing.expectApproxEqAbs(before - 50, ui.boxOf("first").?.y, 0.01);

    // Past the end, and it stops at the end rather than scrolling into
    // nothing.
    ui.scrollBy("list", 0, 10_000);
    try declare(&ui);
    try testing.expectEqual(@as(f32, 200), ui.scrollOf("list").?.position.y);
    try testing.expectApproxEqAbs(before - 200, ui.boxOf("first").?.y, 0.01);

    // And back past the start.
    ui.scrollBy("list", 0, -10_000);
    try declare(&ui);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.position.y);
    try testing.expectApproxEqAbs(before, ui.boxOf("first").?.y, 0.01);
}

test "the scroll limit does not shrink as the container is scrolled" {
    // The mistake this catches: measuring the content from where the children
    // ended up, without adding the scroll position back. A container like
    // that creeps to a stop halfway down.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const declare = struct {
        fn frame(u: *Ui) !void {
            u.begin(.init(400, 400));
            u.open(.{ .width = .grow, .height = .grow });
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .scrollY,
                });
                defer u.close();
                for (0..10) |_| {
                    u.empty(.{ .width = .grow, .height = .fixed(30), .background_color = paint });
                }
            }
            u.close();
            _ = try u.end();
        }
    }.frame;

    try declare(&ui);
    const limit = ui.scrollOf("list").?.limit().y;

    for (0..4) |_| {
        ui.scrollBy("list", 0, 40);
    }
    try declare(&ui);

    try testing.expectEqual(limit, ui.scrollOf("list").?.limit().y);
    try testing.expectEqual(@as(f32, 300), ui.scrollOf("list").?.content.height);
}

test "scrollTo puts it where it was told, within the limits" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const declare = struct {
        fn frame(u: *Ui) !void {
            u.begin(.init(400, 400));
            u.open(.{ .width = .grow, .height = .grow });
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .scrollY,
                });
                defer u.close();
                for (0..10) |_| {
                    u.empty(.{ .width = .grow, .height = .fixed(30), .background_color = paint });
                }
            }
            u.close();
            _ = try u.end();
        }
    }.frame;

    try declare(&ui);
    ui.scrollTo("list", 0, 120);
    try declare(&ui);
    try testing.expectEqual(@as(f32, 120), ui.scrollOf("list").?.position.y);

    ui.scrollTo("list", 0, 9999);
    try declare(&ui);
    try testing.expectEqual(@as(f32, 200), ui.scrollOf("list").?.position.y);
}

test "content smaller than its window does not scroll" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "roomy",
            .width = .fixed(200),
            .height = .fixed(300),
            .direction = .top_to_bottom,
            .clip = .scrollY,
        });
        defer ui.close();
        ui.empty(.{ .width = .grow, .height = .fixed(40), .background_color = paint });
    }
    ui.close();
    _ = try ui.end();

    const scroll = ui.scrollOf("roomy").?;
    try testing.expectEqual(@as(f32, 0), scroll.limit().y);
    try testing.expect(!scroll.overflowsY());
    try testing.expectEqual(@as(f32, 0), scroll.progress().y);
}

test "a container that leaves the page is forgotten" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "list",
            .width = .fixed(100),
            .height = .fixed(50),
            .direction = .top_to_bottom,
            .clip = .scrollY,
        });
        defer ui.close();
        ui.empty(.{ .width = .grow, .height = .fixed(200), .background_color = paint });
    }
    ui.close();
    _ = try ui.end();
    try testing.expect(ui.scrollOf("list") != null);

    // A frame without it at all.
    ui.begin(.init(400, 400));
    openRoot(&ui);
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(null, ui.scrollOf("list"));
}

test "an element with no clip has no scroll state to remember" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 400));
    openRoot(&ui);
    leaf(&ui, "plain", .{ .width = .fixed(100), .height = .fixed(100) });
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(null, ui.scrollOf("plain"));
    // And nudging something that does not scroll is not an error.
    ui.scrollBy("plain", 0, 100);
    ui.scrollBy("nothing at all", 0, 100);
}

test "progress runs from zero to one across the content" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const declare = struct {
        fn frame(u: *Ui) !void {
            u.begin(.init(400, 400));
            u.open(.{ .width = .grow, .height = .grow });
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .scrollY,
                });
                defer u.close();
                for (0..10) |_| {
                    u.empty(.{ .width = .grow, .height = .fixed(30), .background_color = paint });
                }
            }
            u.close();
            _ = try u.end();
        }
    }.frame;

    try declare(&ui);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.progress().y);

    ui.scrollTo("list", 0, 100);
    try declare(&ui);
    try testing.expectApproxEqAbs(0.5, ui.scrollOf("list").?.progress().y, 0.001);

    ui.scrollTo("list", 0, 200);
    try declare(&ui);
    try testing.expectEqual(@as(f32, 1), ui.scrollOf("list").?.progress().y);
}

// -------------------------------------------------------------------------
// Pointing at things
// -------------------------------------------------------------------------
//
// Every one of these runs two frames, and that is not an accident: the first
// lays the tree out, the second asks about it. `hovered` is called while the
// tree is being declared, so it can only answer from where things were last
// time - see `input`. A test that ran one frame would find nothing hovered
// and would be testing nothing.

/// Two panels side by side, with a button in the second.
fn panels(u: *Ui) !void {
    u.begin(.init(400, 200));
    {
        u.open(.{ .width = .grow, .height = .grow });
        defer u.close();

        u.empty(.{ .id = "left", .width = .fixed(200), .height = .grow, .background_color = paint });

        u.open(.{ .id = "right", .width = .grow, .height = .grow, .background_color = paint });
        defer u.close();
        u.empty(.{ .id = "button", .width = .fixed(80), .height = .fixed(30), .background_color = paint });
    }
    _ = try u.end();
}

test "the pointer finds the element under it, and its ancestors with it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);

    // Over the button, which sits at the top left of the right-hand panel.
    ui.setPointer(210, 10, false);
    try panels(&ui);

    try testing.expect(ui.isPointerOver("button"));
    // And the panel behind it, because a chain is ancestors *and* the thing
    // itself - a hover style on a card should not switch off because the
    // pointer is over a label inside it.
    try testing.expect(ui.isPointerOver("right"));
    try testing.expect(!ui.isPointerOver("left"));

    // Outermost first.
    const chain = ui.pointerOver();
    try testing.expectEqual(identify("button", 0), chain[chain.len - 1]);
}

test "the pointer somewhere else finds nothing of ours" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setPointer(10, 10, false);
    try panels(&ui);

    try testing.expect(ui.isPointerOver("left"));
    try testing.expect(!ui.isPointerOver("right"));
    try testing.expect(!ui.isPointerOver("button"));
}

test "hovered can be asked inline, while the element is open" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui, seen: *bool) !void {
            u.begin(.init(400, 200));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();

                u.open(.{ .id = "target", .width = .fixed(100), .height = .fixed(50) });
                defer u.close();
                // The whole point of the API: asked here, about this.
                seen.* = u.hovered();
            }
            _ = try u.end();
        }
    }.run;

    var hovered_now = false;
    try frame(&ui, &hovered_now);
    ui.setPointer(50, 25, false);
    try frame(&ui, &hovered_now);
    try testing.expect(hovered_now);

    ui.setPointer(300, 100, false);
    try frame(&ui, &hovered_now);
    try testing.expect(!hovered_now);
}

test "the topmost element wins where two overlap" {
    // A real overlap, which takes some arranging without floating elements:
    // the first panel does not clip, so its three-hundred-pixel child runs
    // out over the panel beside it. The one declared later is painted later
    // and is therefore on top.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 200));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();

                u.open(.{ .width = .fixed(100), .height = .fixed(100) });
                {
                    defer u.close();
                    // Overflows its parent by two hundred pixels.
                    u.empty(.{ .id = "under", .width = .fixed(300), .height = .fixed(100) });
                }
                u.empty(.{ .id = "over", .width = .fixed(200), .height = .fixed(100) });
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui);

    // At x = 150 both boxes are present: `under` runs from 0 to 300, and
    // `over` from 100 to 300.
    ui.setPointer(150, 50, false);
    try frame(&ui);

    try testing.expect(ui.isPointerOver("over"));
    try testing.expect(!ui.isPointerOver("under"));

    // And where only the first one reaches, it is found.
    ui.setPointer(50, 50, false);
    try frame(&ui);
    try testing.expect(ui.isPointerOver("under"));
}

test "a press fires once, holds while down, and releases once" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setPointer(210, 10, false);
    try panels(&ui);

    // Down.
    ui.setPointer(210, 10, true);
    try panels(&ui);
    try testing.expect(ui.pointer.justPressed());
    try testing.expect(ui.isElementPressed("button"));

    // Still down: pressed stays, just-pressed does not.
    ui.setPointer(210, 10, true);
    try panels(&ui);
    try testing.expect(!ui.pointer.justPressed());
    try testing.expect(ui.isElementPressed("button"));

    // Up: released once.
    ui.setPointer(210, 10, false);
    try panels(&ui);
    try testing.expect(ui.isElementReleased("button"));
    try testing.expect(!ui.isElementPressed("button"));

    // And not again.
    ui.setPointer(210, 10, false);
    try panels(&ui);
    try testing.expect(!ui.isElementReleased("button"));
}

test "a press that started elsewhere does not release here" {
    // Dragging in from outside and letting go must not fire a button. This is
    // the difference between `justReleased` and "the pointer is up over me".
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);

    // Press on the left panel.
    ui.setPointer(10, 10, false);
    try panels(&ui);
    ui.setPointer(10, 10, true);
    try panels(&ui);
    try testing.expect(ui.isElementPressed("left"));

    // Drag over the button and let go.
    ui.setPointer(210, 10, true);
    try panels(&ui);
    ui.setPointer(210, 10, false);
    try panels(&ui);

    try testing.expect(!ui.isElementReleased("button"));
}

test "dragging off a button and back keeps it pressed" {
    // Ply keeps the chain the pointer went down on until the button comes up,
    // so a press survives a wobble. Matched here rather than improved on.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setPointer(210, 10, false);
    try panels(&ui);
    ui.setPointer(210, 10, true);
    try panels(&ui);

    // Off it, still held.
    ui.setPointer(10, 150, true);
    try panels(&ui);
    try testing.expect(ui.isElementPressed("button"));
    // But not hovered, so a release out here would not fire it.
    try testing.expect(!ui.isPointerOver("button"));
}

test "an element that captures keeps the pointer from its ancestors" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 200));
            {
                u.open(.{ .id = "panel", .width = .grow, .height = .grow, .background_color = paint });
                defer u.close();
                u.empty(.{
                    .id = "grabby",
                    .width = .fixed(80),
                    .height = .fixed(30),
                    .capture = true,
                    .background_color = paint,
                });
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    ui.setPointer(10, 10, false);
    try frame(&ui);

    // The button is pointed at and the panel under it is not - which is what
    // stops dragging a knob from also dragging the window it is on.
    try testing.expect(ui.isPointerOver("grabby"));
    try testing.expect(!ui.isPointerOver("panel"));
    try testing.expectEqual(1, ui.pointerOver().len);
}

test "a clipped-away element is not under the pointer, wherever its box is" {
    // The box says the row is at y = 400; the scissor says only the first
    // hundred pixels are showing. A hit test that looked at the box alone
    // would let a scrolled-away row answer a click.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 400));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();

                u.open(.{
                    .id = "window",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .both,
                });
                defer u.close();

                u.empty(.{ .id = "showing", .width = .grow, .height = .fixed(50), .background_color = paint });
                u.empty(.{ .id = "hidden", .width = .grow, .height = .fixed(50), .background_color = paint });
                u.empty(.{ .id = "gone", .width = .grow, .height = .fixed(50), .background_color = paint });
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui);

    // Inside the window, over the first row.
    ui.setPointer(50, 20, false);
    try frame(&ui);
    try testing.expect(ui.isPointerOver("showing"));

    // The third row's box is at y = 100..150, which is outside the
    // hundred-pixel window. Pointing where it would be finds nothing.
    ui.setPointer(50, 120, false);
    try frame(&ui);
    try testing.expect(!ui.isPointerOver("gone"));
    try testing.expect(!ui.isPointerOver("window"));
}

test "scrolling changes what is under the pointer" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 400));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();

                u.open(.{
                    .id = "list",
                    .width = .fixed(200),
                    .height = .fixed(100),
                    .direction = .top_to_bottom,
                    .clip = .scrollY,
                });
                defer u.close();

                u.empty(.{ .id = "one", .width = .grow, .height = .fixed(50), .background_color = paint });
                u.empty(.{ .id = "two", .width = .grow, .height = .fixed(50), .background_color = paint });
                u.empty(.{ .id = "three", .width = .grow, .height = .fixed(50), .background_color = paint });
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    ui.setPointer(50, 20, false);
    try frame(&ui);
    try testing.expect(ui.isPointerOver("one"));

    // Scroll down by one row: the same place on screen is now the second.
    ui.scrollTo("list", 0, 50);
    try frame(&ui);
    ui.setPointer(50, 20, false);
    try frame(&ui);

    try testing.expect(ui.isPointerOver("two"));
    try testing.expect(!ui.isPointerOver("one"));
}

test "pressing gives an element the keyboard" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setPointer(210, 10, false);
    try panels(&ui);

    try testing.expect(!ui.isFocused("button"));

    ui.setPointer(210, 10, true);
    try panels(&ui);
    try testing.expect(ui.isFocused("button"));

    // Pressing somewhere else moves it.
    ui.setPointer(10, 150, false);
    try panels(&ui);
    ui.setPointer(10, 150, true);
    try panels(&ui);
    try testing.expect(!ui.isFocused("button"));
    try testing.expect(ui.isFocused("left"));
}

test "preserve_focus leaves the keyboard where it was" {
    // A toolbar button pressed while a text field has the caret: the button
    // does its work and the field keeps the caret.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 200));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();
                u.empty(.{ .id = "field", .width = .fixed(200), .height = .grow, .background_color = paint });
                u.empty(.{
                    .id = "bold",
                    .width = .fixed(40),
                    .height = .fixed(40),
                    .preserve_focus = true,
                    .background_color = paint,
                });
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    ui.setPointer(10, 10, false);
    try frame(&ui);
    ui.setPointer(10, 10, true);
    try frame(&ui);
    try testing.expect(ui.isFocused("field"));

    // Press the toolbar button.
    ui.setPointer(210, 10, false);
    try frame(&ui);
    ui.setPointer(210, 10, true);
    try frame(&ui);

    try testing.expect(ui.isElementPressed("bold"));
    try testing.expect(ui.isFocused("field"));
}

test "pressing nothing clears the focus" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setPointer(210, 10, true);
    try panels(&ui);
    try testing.expect(ui.isFocused("button"));

    // Off the surface entirely.
    ui.setPointer(-50, -50, false);
    try panels(&ui);
    ui.setPointer(-50, -50, true);
    try panels(&ui);
    try testing.expect(!ui.isFocused("button"));
}

test "focus can be set and cleared by hand" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try panels(&ui);
    ui.setFocus("button");
    try testing.expect(ui.isFocused("button"));

    ui.clearFocus();
    try testing.expect(!ui.isFocused("button"));
    try testing.expect(!ui.isFocused("left"));
}

test "the first frame has nothing under the pointer, and says so" {
    // Nothing has been laid out yet, so there is nothing to be over. Asking
    // must answer no rather than reading an empty list off the end.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.setPointer(50, 50, true);
    try testing.expectEqual(0, ui.pointerOver().len);
    try testing.expect(!ui.isPointerOver("anything"));
    try testing.expect(!ui.isElementPressed("anything"));
}

test "the inline queries and the ones by name agree" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var inline_hovered = false;
    var inline_pressed = false;

    const frame = struct {
        fn run(u: *Ui, h: *bool, p: *bool) !void {
            u.begin(.init(400, 200));
            {
                u.open(.{ .width = .grow, .height = .grow });
                defer u.close();
                u.open(.{ .id = "target", .width = .fixed(100), .height = .fixed(50) });
                defer u.close();
                h.* = u.hovered();
                p.* = u.pressed();
            }
            _ = try u.end();
        }
    }.run;

    try frame(&ui, &inline_hovered, &inline_pressed);
    ui.setPointer(50, 25, true);
    try frame(&ui, &inline_hovered, &inline_pressed);

    try testing.expectEqual(ui.isPointerOver("target"), inline_hovered);
    try testing.expectEqual(ui.isElementPressed("target"), inline_pressed);
    try testing.expect(inline_hovered);
    try testing.expect(inline_pressed);
}

test "text is copied, so a buffer that goes out of scope is still drawn" {
    // The bug this exists to stop, and it is not hypothetical: a list whose
    // labels are formatted into a stack buffer inside the loop drew a column
    // of empty boxes, because by the time `end` measured them the buffer had
    // been reused. Ply copies; so does this.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 200));
    {
        ui.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom });
        defer ui.close();

        for (0..3) |i| {
            // Exactly the shape that failed: a buffer whose lifetime ends
            // with this iteration.
            var scratch: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&scratch, "Item {d}", .{i}) catch "?";
            ui.text(label, .{ .font_size = 16, .color = paint });
            // Scribble over it, which is what the next iteration would do.
            @memset(&scratch, 0xAA);
        }
    }
    const drawn = try ui.end();

    try testing.expectEqual(3, drawn.len);
    try testing.expectEqualStrings("Item 0", drawn[0].config.text.text);
    try testing.expectEqualStrings("Item 1", drawn[1].config.text.text);
    try testing.expectEqualStrings("Item 2", drawn[2].config.text.text);
}

test "the copies are thrown away and the buffer reused each frame" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    for (0..3) |_| {
        ui.begin(.init(400, 200));
        {
            ui.open(.{ .width = .grow, .height = .grow });
            defer ui.close();
            ui.text("Hello", .{ .font_size = 16, .color = paint });
        }
        _ = try ui.end();

        // Five bytes a frame, not fifteen by the third: the buffer is
        // cleared and refilled, so a settled interface stops allocating.
        try testing.expectEqual(5, ui.strings.items.len);
    }
}

// -------------------------------------------------------------------------
// Scrollbars
// -------------------------------------------------------------------------

// The numbers below are Ply's, from a container a hundred pixels square with
// three hundred by two hundred and fifty of content in it - the same fixture
// its own scrollbar test uses, so the arithmetic can be compared line by
// line. A six pixel bar down the right of that box starts at x 94.

/// The bar a container drew on one axis, as the record the pointer is
/// answered from has it.
fn barIn(ui: *Ui, name: []const u8, vertical: bool) ?Bar {
    return ui.barOf(identify(name, 0), vertical);
}

/// Whether a rectangle really was emitted at this box - the record above says
/// where the bar went, this says a renderer was told about it.
fn drawnAt(drawn: []const commands.RenderCommand, box: BoundingBox) bool {
    for (drawn) |command| {
        if (std.meta.activeTag(command.config) != .rectangle) continue;
        if (std.meta.eql(command.bounding_box, box)) return true;
    }
    return false;
}

/// Ply's own scrollbar fixture: a hundred square window onto 300x250.
fn scrollFixture(u: *Ui, clip: layout.Clip) ![]const commands.RenderCommand {
    u.begin(.init(400, 300));
    openRoot(u);
    {
        u.open(.{ .id = "scroll", .width = .fixed(100), .height = .fixed(100), .clip = clip });
        defer u.close();
        leaf(u, "content", .{ .width = .fixed(300), .height = .fixed(250) });
    }
    u.close();
    return try u.end();
}

test "a scroll container draws a thumb as long a share of the track as it shows of the content" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const drawn = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));

    // A hundred pixel window onto two hundred and fifty: two fifths of the
    // track, so forty pixels of thumb, at the top because nothing has been
    // scrolled yet.
    const down = barIn(&ui, "scroll", true).?;
    try testing.expectEqual(BoundingBox.init(94, 0, 6, 40), down.thumb);
    try testing.expectEqual(@as(f32, 150), down.max_scroll);
    try testing.expectEqual(@as(f32, 60), down.thumb_travel);

    // And across: a hundred onto three hundred is a third.
    const across = barIn(&ui, "scroll", false).?;
    try testing.expectEqual(@as(f32, 94), across.thumb.y);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 3.0), across.thumb.width, 0.001);
    try testing.expectEqual(@as(f32, 200), across.max_scroll);

    // Both were handed to the renderer, and neither left a scissor open.
    try testing.expect(drawnAt(drawn, down.thumb));
    try testing.expect(drawnAt(drawn, across.thumb));
    const emitted: commands.List = .{ .items = drawn };
    try testing.expect(emitted.scissorsBalanced());
}

test "the thumb ends flush with the track when the content is scrolled to the end" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));
    ui.scrollTo("scroll", 200, 150);
    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));

    // Scrolled to the bottom, the thumb is at the bottom - and exactly at it,
    // which is the check that catches an off-by-a-thumb-length.
    const down = barIn(&ui, "scroll", true).?;
    try testing.expectEqual(@as(f32, 60), down.thumb.y);
    try testing.expectEqual(@as(f32, 100), down.thumb.bottom());

    const across = barIn(&ui, "scroll", false).?;
    try testing.expectApproxEqAbs(@as(f32, 100), across.thumb.right(), 0.001);
}

test "halfway through the content puts the thumb halfway along its travel" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));
    ui.scrollTo("scroll", 0, 75);
    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));

    // Half of a hundred and fifty scrolled, so half of sixty travelled - and
    // not half the *track*, which is the mistake that puts the thumb past the
    // end of a short one.
    try testing.expectEqual(@as(f32, 30), barIn(&ui, "scroll", true).?.thumb.y);
}

test "a very long document still gets a thumb that can be grabbed" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "scroll",
            .width = .fixed(100),
            .height = .fixed(100),
            .clip = layout.Clip.scrollY.bar(.{}),
        });
        defer ui.close();
        leaf(&ui, "content", .{ .width = .fixed(50), .height = .fixed(5000) });
    }
    ui.close();
    _ = try ui.end();

    // Two per cent of a hundred pixel track is two pixels of thumb, which is
    // not a thing anybody can hit. The floor is twenty.
    try testing.expectEqual(@as(f32, 20), barIn(&ui, "scroll", true).?.thumb.height);
}

test "nothing is drawn where there is nothing to scroll" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "scroll",
            .width = .fixed(100),
            .height = .fixed(100),
            .clip = layout.Clip.scroll.bar(.{}),
        });
        defer ui.close();
        leaf(&ui, "content", .{ .width = .fixed(40), .height = .fixed(40) });
    }
    ui.close();
    _ = try ui.end();

    // A bar with no travel is not drawn short, it is not drawn - so a list
    // that turns out to fit costs nothing to have asked for one.
    try testing.expectEqual(@as(usize, 0), ui.bars.items.len);
}

test "an axis that does not scroll gets no bar however far its content runs" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));

    // The content is three times too wide, but the container was never asked
    // to scroll sideways, so there is nothing for a bar there to move.
    try testing.expect(barIn(&ui, "scroll", true) != null);
    try testing.expect(barIn(&ui, "scroll", false) == null);
}

test "the track is drawn only when it is asked for" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const bare = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    const without = (commands.List{ .items = bare }).count(.rectangle);

    const dressed = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{ .track_color = .hex(0x202020) }));
    const with = (commands.List{ .items = dressed }).count(.rectangle);

    // The default bar is an overlay: a thumb and nothing behind it.
    try testing.expectEqual(without + 1, with);
    try testing.expect(drawnAt(dressed, .init(94, 0, 6, 100)));
}

test "dragging the thumb moves the content by the content's share of the drag" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));

    // Down on the middle of the thumb, which spans y 0 to 40 at x 94.
    ui.setPointer(97, 20, true);
    try testing.expect(ui.draggingScrollbar());
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));

    // Sixty pixels of thumb travel stand for a hundred and fifty of content,
    // so each pixel of pointer is two and a half of content.
    ui.setPointer(97, 32, true);
    try testing.expectEqual(@as(f32, 30), ui.scrollOf("scroll").?.position.y);

    // And the content really moved: the child is thirty pixels higher up.
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    try testing.expectEqual(@as(f32, -30), ui.boxOf("content").?.y);
}

test "the drag is measured from where it started, not from the last frame" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    ui.setPointer(97, 20, true);
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));

    // Wander down, back up past the start, and down again. Anything that
    // accumulated per-frame deltas would drift; this ends where the arithmetic
    // says it should, which is at the start.
    for ([_]f32{ 30, 40, 24, 10 }) |y| {
        ui.setPointer(97, y, true);
        _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    }
    // Ten pixels above where it started, which is four below the top of the
    // content - so the drag is doing something, and doing it from the origin.
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("scroll").?.position.y);

    ui.setPointer(97, 36, true);
    try testing.expectEqual(@as(f32, 40), ui.scrollOf("scroll").?.position.y);
    ui.setPointer(97, 20, true);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("scroll").?.position.y);
}

test "dragging past the end of the track stops at the end of the content" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    ui.setPointer(97, 20, true);
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));

    ui.setPointer(97, 4000, true);
    try testing.expectEqual(@as(f32, 150), ui.scrollOf("scroll").?.position.y);

    // Letting go ends the drag, and moving afterwards moves nothing.
    ui.setPointer(97, 0, false);
    try testing.expect(!ui.draggingScrollbar());
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{}));
    ui.setPointer(97, 0, false);
    try testing.expectEqual(@as(f32, 150), ui.scrollOf("scroll").?.position.y);
}

test "grabbing the bar does not press what is underneath it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "scroll",
                    .width = .fixed(100),
                    .height = .fixed(100),
                    .clip = layout.Clip.scrollY.bar(.{}),
                });
                defer u.close();
                leaf(u, "row", .{ .width = .fixed(100), .height = .fixed(250) });
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    ui.setFocus("elsewhere");

    // The row runs the full width, so this press is on the thumb *and* on the
    // row. Ply gives the whole press to the bar: nothing under it is pressed,
    // and the focus stays where it was put.
    ui.setPointer(97, 20, true);
    try testing.expect(ui.draggingScrollbar());
    try testing.expect(!ui.isElementPressed("row"));
    try testing.expect(!ui.isPointerOver("row"));
    try testing.expect(ui.isFocused("elsewhere"));
}

test "a press beside the thumb is an ordinary press" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try (struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "scroll",
                    .width = .fixed(100),
                    .height = .fixed(100),
                    .clip = layout.Clip.scrollY.bar(.{}),
                });
                defer u.close();
                leaf(u, "row", .{ .width = .fixed(100), .height = .fixed(250) });
            }
            u.close();
            _ = try u.end();
        }
    }.run)(&ui);

    // Ten pixels in from the left, nowhere near the bar.
    ui.setPointer(10, 20, true);
    try testing.expect(!ui.draggingScrollbar());
    try testing.expect(ui.isElementPressed("row"));
}

test "where the two thumbs meet in the corner, the vertical one is grabbed" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));
    ui.scrollTo("scroll", 200, 150);
    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));

    // Scrolled to the end both ways, the two thumbs overlap in the bottom
    // right corner and a press there is on both of them. Ply checks the
    // vertical axis first, so that is the one that moves - reaching for the
    // bottom of a long list should not send it sideways.
    const before = ui.scrollOf("scroll").?.position;
    ui.setPointer(97, 97, true);
    _ = try scrollFixture(&ui, layout.Clip.scroll.bar(.{}));

    ui.setPointer(97, 77, true);
    const after = ui.scrollOf("scroll").?.position;
    try testing.expect(after.y < before.y);
    try testing.expectEqual(before.x, after.x);
}

test "a bar told to hide fades out when nothing moves, and comes straight back" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const config: layout.Scrollbar = .{ .hide_after_seconds = 1 };
    const frame = 1.0 / 60.0;

    // Shown on the very first frame, before anything is stored about it.
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) != null);

    // Half a second of stillness is well inside the hold.
    for (0..30) |_| {
        ui.tick(frame);
        _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    }
    try testing.expect(barIn(&ui, "scroll", true) != null);

    // A second of hold and a quarter of a second of fade, and it is gone -
    // and cannot be grabbed either.
    for (0..50) |_| {
        ui.tick(frame);
        _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    }
    try testing.expect(barIn(&ui, "scroll", true) == null);
    ui.setPointer(97, 20, true);
    try testing.expect(!ui.draggingScrollbar());
    ui.setPointer(97, 20, false);

    // Scrolling brings it back on the next frame rather than the one after,
    // which is the whole point of clearing the clock at the top of the frame
    // instead of the bottom.
    ui.scrollTo("scroll", 0, 40);
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) != null);
}

test "the fade takes the same time however fast the frames go" {
    // The whole reason this counts seconds. Ply counts frames, so the same
    // configuration is four times as quick to hide on a machine running four
    // times as smoothly - and every one of these three would disagree.
    const config: layout.Scrollbar = .{ .hide_after_seconds = 1 };

    for ([_]f32{ 1.0 / 30.0, 1.0 / 60.0, 1.0 / 144.0 }) |frame| {
        var ui = withText(testing.allocator);
        defer ui.deinit();
        _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));

        var elapsed: f32 = 0;
        while (elapsed < 0.99) : (elapsed += frame) {
            ui.tick(frame);
            _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
        }
        try testing.expect(barIn(&ui, "scroll", true) != null);

        while (elapsed < 1.3) : (elapsed += frame) {
            ui.tick(frame);
            _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
        }
        try testing.expect(barIn(&ui, "scroll", true) == null);
    }
}

test "a program with no clock keeps its bars" {
    // The failure this is allowed to have. Nothing calls `tick`, so no time
    // passes, so a bar told to hide after a second never does - which is the
    // safer of the two ways for a library with no clock to be wrong.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    for (0..600) |_| _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{ .hide_after_seconds = 1 }));
    try testing.expect(barIn(&ui, "scroll", true) != null);
}

test "hiding after zero seconds is a bar that is never drawn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{ .hide_after_seconds = 0 }));
    try testing.expectEqual(@as(usize, 0), ui.bars.items.len);
}

test "a padded container's bar runs its whole height" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "scroll",
            .width = .fixed(100),
            .height = .fixed(100),
            .padding = .all(10),
            .clip = layout.Clip.scrollY.bar(.{ .track_color = .hex(0x202020) }),
        });
        defer ui.close();
        leaf(&ui, "content", .{ .width = .fixed(50), .height = .fixed(230) });
    }
    ui.close();
    const drawn = try ui.end();

    // Ply measures the bar against the whole box and against a content size
    // that includes the padding, so the track is the full hundred and the
    // limit is the same hundred and fifty as the unpadded fixture. A bar
    // measured against the inside instead would be eighty long and would
    // disagree with the wheel about how far there is to go.
    try testing.expect(drawnAt(drawn, .init(94, 0, 6, 100)));
    try testing.expectEqual(@as(f32, 150), barIn(&ui, "scroll", true).?.max_scroll);
    try testing.expectEqual(@as(f32, 150), ui.scrollOf("scroll").?.limit().y);
}

test "the fade curve is Ply's" {
    // Held for the whole hold, then a fade a quarter as long again. Ply's
    // eighty frames and twenty of fade, at the frame rate it was written for.
    const config: layout.Scrollbar = .{ .hide_after_seconds = 2 };
    try testing.expectEqual(@as(f32, 1), visibility(config, 0));
    try testing.expectEqual(@as(f32, 1), visibility(config, 2));
    try testing.expectEqual(@as(f32, 0.75), visibility(config, 2.125));
    try testing.expectEqual(@as(f32, 0.5), visibility(config, 2.25));
    try testing.expectEqual(@as(f32, 0), visibility(config, 2.5));
    try testing.expectEqual(@as(f32, 0), visibility(config, 100));

    // No hold at all means always shown, which is the default.
    try testing.expectEqual(@as(f32, 1), visibility(.{}, 100));
}

// -------------------------------------------------------------------------
// Text input
// -------------------------------------------------------------------------

// Measured with `mono`, so at a font size of sixteen a character is eight
// pixels wide and a line is sixteen tall. Every click below is a multiple of
// eight for that reason, and every expected cursor position is too.
//
// A click takes two frames, and not by accident: `setPointer` can only say
// *which* field was pressed, because where in the string the pointer landed
// depends on a measurement that has not happened yet. The frame after
// resolves it. A test that ran one frame would find the cursor where it
// started and would be testing nothing.

/// A frame with one text input in it, in a two hundred pixel box.
fn oneField(u: *Ui, config: text_input.Config) ![]const commands.RenderCommand {
    u.begin(.init(400, 200));
    openRoot(u);
    u.textInput(
        .{ .id = "name", .width = .fixed(200), .height = .fixed(20), .background_color = paint },
        config,
    );
    u.close();
    return try u.end();
}

/// The text commands a frame emitted, in order.
fn drawnText(drawn: []const commands.RenderCommand, out: *[8][]const u8) []const []const u8 {
    var count: usize = 0;
    for (drawn) |command| {
        if (command.config != .text) continue;
        if (count == out.len) break;
        out[count] = command.config.text.text;
        count += 1;
    }
    return out[0..count];
}

/// The one rectangle drawn in this colour, if there is one.
fn rectangleIn(drawn: []const commands.RenderCommand, colour: Color) ?BoundingBox {
    for (drawn) |command| {
        if (command.config != .rectangle) continue;
        if (std.meta.eql(command.config.rectangle.color, colour)) return command.bounding_box;
    }
    return null;
}

test "an empty input draws its placeholder, and a typed one draws the text" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var seen: [8][]const u8 = undefined;
    const empty_frame = try oneField(&ui, .{ .placeholder = "Your name" });
    try testing.expectEqualStrings("Your name", drawnText(empty_frame, &seen)[0]);

    ui.setTextValue("name", "Kiss");
    const typed = try oneField(&ui, .{ .placeholder = "Your name" });
    try testing.expectEqualStrings("Kiss", drawnText(typed, &seen)[0]);
}

test "the placeholder is copied, so a caller may format it into a buffer" {
    // The bug `ui.text` already had once. A placeholder is nearly always a
    // literal, and "nearly always" is exactly how that one happened.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var scratch: [32]u8 = undefined;
    const drawn = blk: {
        const label = try std.fmt.bufPrint(&scratch, "Field {d}", .{7});
        break :blk try oneField(&ui, .{ .placeholder = label });
    };
    @memset(&scratch, 0xAA);

    var seen: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Field 7", drawnText(drawn, &seen)[0]);
}

test "two inputs in one frame each draw their own text" {
    // The bug this is here for drew every field's text as the last field's,
    // because they shared one scratch buffer and a text command holds a
    // slice. It is the same trap `ui.text` fell into once, and only a frame
    // with more than one input in it can see it.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const two = struct {
        fn run(u: *Ui) ![]const commands.RenderCommand {
            u.begin(.init(400, 200));
            openRoot(u);
            u.textInput(.{ .id = "first", .width = .fixed(100), .height = .fixed(20) }, .{});
            u.textInput(.{ .id = "second", .width = .fixed(100), .height = .fixed(20) }, .{ .placeholder = "empty" });
            u.textInput(.{ .id = "third", .width = .fixed(100), .height = .fixed(20) }, .{});
            u.close();
            return try u.end();
        }
    }.run;

    _ = try two(&ui);
    ui.setTextValue("first", "one");
    ui.setTextValue("third", "a much longer third one");
    const drawn = try two(&ui);

    var seen: [8][]const u8 = undefined;
    const lines = drawnText(drawn, &seen);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("one", lines[0]);
    try testing.expectEqualStrings("empty", lines[1]);
    try testing.expectEqualStrings("a much longer third one", lines[2]);
}

test "typing goes into the focused input and nowhere else" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Nothing focused: the keys go nowhere rather than into the first field
    // that happens to exist.
    _ = try oneField(&ui, .{});
    ui.typeText("hello");
    try testing.expectEqualStrings("", ui.textValueOf("name").?);

    // Click it, and they land.
    ui.setPointer(20, 10, true);
    _ = try oneField(&ui, .{});
    try testing.expect(ui.isFocused("name"));

    ui.typeText("hello");
    try testing.expectEqualStrings("hello", ui.textValueOf("name").?);

    // `textChanged` is about the frame, not about the instant: keys arrive
    // between frames, so the answer is the same whether it is asked while
    // declaring or after the commands are out.
    try testing.expect(!ui.textChanged("name"));
    _ = try oneField(&ui, .{});
    try testing.expect(ui.textChanged("name"));
    _ = try oneField(&ui, .{});
    try testing.expect(!ui.textChanged("name"));
}

test "the cursor is drawn where the text ends, and only while focused" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const caret: Color = .hex(0xFF0000);
    ui.setTextValue("name", "abc");

    // Not focused: no cursor at all, however solid the blink says it is.
    const unfocused = try oneField(&ui, .{ .cursor_color = caret });
    try testing.expect(rectangleIn(unfocused, caret) == null);

    // Setting the value from the program leaves the cursor where it was,
    // only clamping it - which is Ply's rule and is why this types instead.
    try testing.expectEqual(@as(usize, 0), ui.editOf("name").?.cursor);

    ui.setFocus("name");
    ui.typeText("abc");
    const with_keyboard = try oneField(&ui, .{ .cursor_color = caret });

    // Three characters at eight pixels, and two pixels wide.
    const drawn_at = rectangleIn(with_keyboard, caret).?;
    try testing.expectEqual(@as(f32, 24), drawn_at.x);
    try testing.expectEqual(@as(f32, 2), drawn_at.width);
}

test "a selection is washed over exactly the characters it covers" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const wash: Color = .hex(0x00FF00);
    _ = try oneField(&ui, .{ .selection_color = wash });
    ui.setTextValue("name", "hello world");

    const edit = ui.editOf("name").?;
    edit.anchor = 2;
    edit.cursor = 7;

    const drawn = try oneField(&ui, .{ .selection_color = wash });
    const box = rectangleIn(drawn, wash).?;
    try testing.expectEqual(@as(f32, 16), box.x);
    try testing.expectEqual(@as(f32, 40), box.width);
}

test "clicking puts the cursor at the nearest character boundary" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try oneField(&ui, .{});
    ui.setTextValue("name", "hello");
    _ = try oneField(&ui, .{});

    // Between the second and third character, nearer the third.
    ui.setPointer(21, 10, true);
    _ = try oneField(&ui, .{});
    try testing.expectEqual(@as(usize, 3), ui.editOf("name").?.cursor);

    // Past the end of the text, but still inside the box, lands after the
    // last character. A second later, so that this is a click and not the
    // second half of a double click.
    ui.setPointer(21, 10, false);
    ui.tick(1.0);
    ui.setPointer(150, 10, true);
    _ = try oneField(&ui, .{});
    try testing.expectEqual(@as(usize, 5), ui.editOf("name").?.cursor);

    // Outside it entirely is not a press on the field at all, so the cursor
    // stays where it was put.
    ui.setPointer(150, 10, false);
    ui.tick(1.0);
    ui.setPointer(390, 10, true);
    _ = try oneField(&ui, .{});
    try testing.expectEqual(@as(usize, 5), ui.editOf("name").?.cursor);
}

test "double clicking selects the word under the pointer" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try oneField(&ui, .{});
    ui.setTextValue("name", "hello world");
    _ = try oneField(&ui, .{});

    // Two presses inside Ply's four tenths of a second. The clock only moves
    // when a program says so, which is what makes this testable at all.
    ui.setPointer(60, 10, true);
    _ = try oneField(&ui, .{});
    ui.setPointer(60, 10, false);
    ui.tick(0.1);
    ui.setPointer(60, 10, true);
    _ = try oneField(&ui, .{});

    try testing.expectEqualStrings("world", ui.editOf("name").?.selected());

    // The same two presses a second apart are two clicks, not one double.
    ui.setPointer(60, 10, false);
    ui.tick(1.0);
    ui.setPointer(60, 10, true);
    _ = try oneField(&ui, .{});
    try testing.expect(ui.editOf("name").?.selection() == null);
}

test "dragging inside an input selects, when it was asked to" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const config: text_input.Config = .{ .drag_select = true };
    _ = try oneField(&ui, config);
    ui.setTextValue("name", "hello world");
    _ = try oneField(&ui, config);

    ui.setPointer(0, 10, true);
    _ = try oneField(&ui, config);
    ui.setPointer(40, 10, true);
    _ = try oneField(&ui, config);

    try testing.expectEqualStrings("hello", ui.editOf("name").?.selected());
}

test "a password draws bullets, and a click still lands on the right character" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const config: text_input.Config = .{ .password = true };
    _ = try oneField(&ui, config);
    // Accented, so the bullets and the text are different lengths in bytes -
    // three characters stored in four bytes, drawn as nine.
    ui.setTextValue("name", "tűz");
    const drawn = try oneField(&ui, config);

    var seen: [8][]const u8 = undefined;
    try testing.expectEqualStrings(text_input.bullet ** 3, drawnText(drawn, &seen)[0]);

    // A click on the second bullet is a cursor after the second *character*,
    // which is byte three because the "ű" is two of them.
    ui.setPointer(16, 10, true);
    _ = try oneField(&ui, config);
    try testing.expectEqual(@as(usize, 3), ui.editOf("name").?.cursor);
}

test "an input longer than its box scrolls to keep the cursor in view" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.setFocus("name");
    _ = try oneField(&ui, .{});
    // Fifty characters at eight pixels is four hundred, in a box of two
    // hundred. The cursor is at the end, so the text is scrolled by the
    // difference and not one pixel more.
    ui.setTextValue("name", "x" ** 50);
    ui.editOf("name").?.cursor = 50;
    _ = try oneField(&ui, .{});

    try testing.expectEqual(@as(f32, 200), ui.editOf("name").?.scroll.x);

    // Home brings it back to the start.
    _ = ui.textAction(.moveTo(.start, false));
    _ = try oneField(&ui, .{});
    try testing.expectEqual(@as(f32, 0), ui.editOf("name").?.scroll.x);
}

test "copy hands the selection over and cut takes it away" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.setFocus("name");
    _ = try oneField(&ui, .{});
    ui.setTextValue("name", "hello world");
    ui.editOf("name").?.anchor = 0;
    ui.editOf("name").?.cursor = 5;

    try testing.expectEqualStrings("hello", ui.textAction(.copy).?);
    try testing.expectEqualStrings("hello world", ui.textValueOf("name").?);

    // What a cut hands back is a copy, and it has to be: the text it points
    // at is gone by the time the caller reads it.
    const taken = ui.textAction(.cut).?;
    try testing.expectEqualStrings("hello", taken);
    try testing.expectEqualStrings(" world", ui.textValueOf("name").?);

    // And it goes back where it came from.
    _ = ui.textAction(.{ .paste = taken });
    try testing.expectEqualStrings("hello world", ui.textValueOf("name").?);
}

test "Enter submits a single-line input and adds a line to a multiline one" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.setFocus("name");
    _ = try oneField(&ui, .{});
    ui.typeText("hello");

    _ = ui.textAction(.submit);
    _ = try oneField(&ui, .{});
    try testing.expect(ui.textSubmitted("name"));
    try testing.expectEqualStrings("hello", ui.textValueOf("name").?);

    // The flag lasts exactly the frame it was asked about.
    _ = try oneField(&ui, .{});
    try testing.expect(!ui.textSubmitted("name"));

    const multi: text_input.Config = .{ .multiline = true };
    _ = try oneField(&ui, multi);
    _ = ui.textAction(.submit);
    _ = try oneField(&ui, multi);
    try testing.expectEqualStrings("hello\n", ui.textValueOf("name").?);
}

test "a multiline input draws one command per line" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const config: text_input.Config = .{ .multiline = true };
    _ = try oneField(&ui, config);
    ui.setTextValue("name", "one\ntwo\nthree");
    const drawn = try oneField(&ui, config);

    var seen: [8][]const u8 = undefined;
    const lines = drawnText(drawn, &seen);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("two", lines[1]);
}

test "a multiline input wraps to its width, and a single-line one never does" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Two hundred pixels holds twenty-five characters at eight pixels each.
    const words = "alpha beta gamma delta epsilon zeta";

    const multi: text_input.Config = .{ .multiline = true };
    _ = try oneField(&ui, multi);
    ui.setTextValue("name", words);
    const wrapped = try oneField(&ui, multi);

    var seen: [8][]const u8 = undefined;
    const lines = drawnText(wrapped, &seen);
    try testing.expect(lines.len > 1);
    // Broken between words, not through one.
    for (lines) |line| try testing.expect(line[line.len - 1] != ' ');

    // The same text in a single-line field is one line however long it is: it
    // scrolls sideways instead, which is the whole difference between them.
    const single = try oneField(&ui, .{});
    try testing.expectEqual(@as(usize, 1), drawnText(single, &seen).len);
}

test "a text input can have a scrollbar, and it is dragged like any other" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Sixty tall, which holds under four of the six lines - and comfortably
    // more than the twenty pixel floor under the thumb, or the thumb would
    // fill the track and have nowhere to be dragged to.
    const tall = struct {
        fn run(u: *Ui) ![]const commands.RenderCommand {
            u.begin(.init(400, 200));
            openRoot(u);
            u.textInput(
                .{ .id = "notes", .width = .fixed(200), .height = .fixed(60) },
                .{ .multiline = true, .scrollbar = .{} },
            );
            u.close();
            return try u.end();
        }
    }.run;

    _ = try tall(&ui);
    ui.setTextValue("notes", "one\ntwo\nthree\nfour\nfive\nsix");
    _ = try tall(&ui);

    // Ninety-six pixels of lines in a sixty pixel box: there is something to
    // scroll, so there is a bar, and it belongs to the field rather than to a
    // scroll container that does not exist.
    const bar = ui.barOf(identify("notes", 0), true).?;
    try testing.expect(bar.field);
    try testing.expectEqual(@as(f32, 36), bar.max_scroll);
    try testing.expect(bar.thumb_travel > 0);

    ui.setPointer(bar.thumb.x + 3, bar.thumb.y + 4, true);
    try testing.expect(ui.draggingScrollbar());
    _ = try tall(&ui);

    // Five pixels of thumb are worth `max_scroll / thumb_travel` of text, and
    // the text is what moves.
    ui.setPointer(bar.thumb.x + 3, bar.thumb.y + 9, true);
    const moved = ui.editOf("notes").?.scroll.y;
    try testing.expectApproxEqAbs(5 * (bar.max_scroll / bar.thumb_travel), moved, 0.01);
}

test "what was typed survives being redeclared, and goes when the field does" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.setFocus("name");
    _ = try oneField(&ui, .{});
    ui.typeText("remember me");
    _ = try oneField(&ui, .{});
    _ = try oneField(&ui, .{});
    try testing.expectEqualStrings("remember me", ui.textValueOf("name").?);

    // A frame without it, and it is somebody else's memory - the same rule a
    // scroll position follows.
    ui.begin(.init(400, 200));
    openRoot(&ui);
    ui.close();
    _ = try ui.end();
    try testing.expect(ui.textValueOf("name") == null);
}

test "an input that fits its content is one line tall" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 200));
    openRoot(&ui);
    ui.textInput(.{ .id = "name", .width = .fixed(200), .padding = .all(4) }, .{});
    ui.close();
    _ = try ui.end();

    // Sixteen for the line and four of padding each side. Ply never fit-sizes
    // one at all, which leaves an invisible box the reader can type into.
    try testing.expectEqual(@as(f32, 24), ui.boxOf("name").?.height);
}

test "the text is cut off at the edge of its box" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try oneField(&ui, .{});
    ui.setTextValue("name", "x" ** 80);
    const drawn = try oneField(&ui, .{});

    // A name longer than the field would otherwise be drawn straight across
    // whatever is beside it.
    const emitted: commands.List = .{ .items = drawn };
    try testing.expect(emitted.scissorsBalanced());
    try testing.expectEqual(@as(usize, 1), emitted.count(.scissor_start));
}

test "shift-clicking extends the selection from where the cursor was" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try oneField(&ui, .{});
    ui.setTextValue("name", "hello world");
    ui.editOf("name").?.cursor = 0;
    _ = try oneField(&ui, .{});

    ui.setShift(true);
    ui.setPointer(40, 10, true);
    _ = try oneField(&ui, .{});
    ui.setShift(false);

    try testing.expectEqualStrings("hello", ui.editOf("name").?.selected());
}

// -------------------------------------------------------------------------
// Markup
// -------------------------------------------------------------------------

// Measured with `mono`, so a character is eight pixels wide and a line is
// sixteen tall at a font size of sixteen. The point of every test here is
// that the tags are gone by the time any of that arithmetic happens: the
// layout measures what the reader sees.

/// Every text command a frame emitted, whole.
fn drawnPieces(drawn: []const commands.RenderCommand, out: *[16]commands.RenderCommand) []const commands.RenderCommand {
    var count: usize = 0;
    for (drawn) |command| {
        if (command.config != .text) continue;
        if (count == out.len) break;
        out[count] = command;
        count += 1;
    }
    return out[0..count];
}

test "a markup run is as wide as the text, not as wide as the tags" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fit, .height = .fit });
        defer ui.close();
        ui.markup("{color=red|abc}", sixteen);
    }
    ui.close();
    _ = try ui.end();

    // Three characters at eight pixels. The raw string is fifteen, and an
    // element that measured it would be five times too wide - which is what
    // Ply's layout does unless the measurer knows about markup.
    try testing.expectEqual(@as(f32, 24), ui.boxOf("row").?.width);
}

test "each stretch of a line is drawn in its own colour" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    ui.markup("ab{color=red|cd}ef", sixteen);
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);
    try testing.expectEqual(@as(usize, 3), pieces.len);

    try testing.expectEqualStrings("ab", pieces[0].config.text.text);
    try testing.expectEqual(@as(f32, 0), pieces[0].bounding_box.x);
    try testing.expectEqual(paint, pieces[0].config.text.color);

    // The pen walks along, so the red piece starts where the first one ended.
    try testing.expectEqualStrings("cd", pieces[1].config.text.text);
    try testing.expectEqual(@as(f32, 16), pieces[1].bounding_box.x);
    try testing.expectEqual(markup_mod.parseColor("red"), pieces[1].config.text.color);

    try testing.expectEqualStrings("ef", pieces[2].config.text.text);
    try testing.expectEqual(@as(f32, 32), pieces[2].bounding_box.x);
    try testing.expectEqual(paint, pieces[2].config.text.color);
}

test "plain text still comes out as one command a line" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    ui.text("no tags here", sixteen);
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    try testing.expectEqual(@as(usize, 1), drawnPieces(drawn, &out).len);
}

test "a span that crosses a line break is drawn on both lines" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    {
        // Eighty pixels holds ten characters.
        ui.open(.{ .id = "column", .width = .fixed(80), .height = .fit, .direction = .top_to_bottom });
        defer ui.close();
        ui.markup("one {color=red|two three} four", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);

    // The wrap happens between words of the *text*, so "two" and "three" end
    // up on different lines - and the one span becomes a piece on each.
    var red: usize = 0;
    var rows: [8]f32 = undefined;
    var found: usize = 0;
    for (pieces) |piece| {
        if (std.meta.eql(piece.config.text.color, markup_mod.parseColor("red"))) {
            red += 1;
            if (found < rows.len) {
                rows[found] = piece.bounding_box.y;
                found += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), red);
    try testing.expect(rows[0] != rows[1]);
}

test "hidden text keeps its room and is not drawn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    ui.markup("ab{hide|cd}ef", sixteen);
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);

    // Two commands, not three - and the last one is still four characters in,
    // because the hidden pair took up its room.
    try testing.expectEqual(@as(usize, 2), pieces.len);
    try testing.expectEqualStrings("ef", pieces[1].config.text.text);
    try testing.expectEqual(@as(f32, 32), pieces[1].bounding_box.x);
}

test "a shadow is drawn under its text, offset in ems" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    ui.markup("{shadow_color=blue|x}", sixteen);
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);
    try testing.expectEqual(@as(usize, 2), pieces.len);

    // Ply's default offset is a third of an em back and down, so at sixteen
    // pixels it is 4.8 - which is the whole reason it is in ems and not in
    // pixels.
    try testing.expectEqual(markup_mod.parseColor("blue"), pieces[0].config.text.color);
    try testing.expectApproxEqAbs(@as(f32, -4.8), pieces[0].bounding_box.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4.8), pieces[0].bounding_box.y, 0.001);

    // And the text itself is on top, where it would have been anyway.
    try testing.expectEqual(paint, pieces[1].config.text.color);
    try testing.expectEqual(@as(f32, 0), pieces[1].bounding_box.x);
}

test "opacity multiplies the alpha of whatever colour is in force" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(800, 200));
    openRoot(&ui);
    ui.markup("{opacity=0.5|{opacity=0.5|x}}", sixteen);
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);
    try testing.expectEqual(@as(f32, 0.25), pieces[0].config.text.color.a);
}

test "markup wraps on the text it shows, not on the string it was given" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Long tags around short words. A wrapper working on the raw string would
    // break this into a column; working on the text, it is one line.
    ui.begin(.init(800, 200));
    openRoot(&ui);
    {
        ui.open(.{ .id = "column", .width = .fixed(80), .height = .fit, .direction = .top_to_bottom });
        defer ui.close();
        ui.markup("{color=lightblue|a} {color=lightblue|b}", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);
    for (pieces) |piece| try testing.expectEqual(@as(f32, 0), piece.bounding_box.y);
}

test "the text a caller handed over is copied, tags and all" {
    // The same trap `text` and the placeholder fell into: the parse writes
    // into the frame's own buffer, so the raw string may be a stack buffer
    // that is gone a line later.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var scratch: [64]u8 = undefined;
    ui.begin(.init(800, 200));
    openRoot(&ui);
    {
        const raw = try std.fmt.bufPrint(&scratch, "n = {d} and {{color=red|{d}}}", .{ 1, 2 });
        ui.markup(raw, sixteen);
    }
    ui.close();
    const drawn = try ui.end();
    @memset(&scratch, 0xAA);

    var out: [16]commands.RenderCommand = undefined;
    const pieces = drawnPieces(drawn, &out);
    try testing.expectEqualStrings("n = 1 and ", pieces[0].config.text.text);
    try testing.expectEqualStrings("2", pieces[1].config.text.text);
}

// -------------------------------------------------------------------------
// Floating
// -------------------------------------------------------------------------

// A hundred by forty button at the top left of the surface, with something
// hanging off it. Every number below is against that box, so the arithmetic
// can be read without keeping the whole tree in mind.

/// A row with a button in it, and a floating element declared inside the
/// button. `after` is whatever else the row should hold.
fn withMenu(u: *Ui, float: layout.Floating, size: layout.Sizing) ![]const commands.RenderCommand {
    u.begin(.init(400, 300));
    openRoot(u);
    {
        u.open(.{ .id = "button", .width = .fixed(100), .height = .fixed(40), .background_color = paint });
        defer u.close();

        u.open(.{
            .id = "menu",
            .width = size,
            .height = .fixed(60),
            .background_color = paint,
            .floating = float,
        });
        u.close();
    }
    u.close();
    return try u.end();
}

test "a floating element is placed where its anchor says" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Its top left onto the button's bottom left: a dropdown.
    _ = try withMenu(&ui, .{ .anchor = .below }, .fixed(80));
    try testing.expectEqual(BoundingBox.init(0, 40, 80, 60), ui.boxOf("menu").?);

    // Its bottom left onto the button's top left: a tooltip above.
    _ = try withMenu(&ui, .{ .anchor = .above }, .fixed(80));
    try testing.expectEqual(BoundingBox.init(0, -60, 80, 60), ui.boxOf("menu").?);

    // Beside it, on either side.
    _ = try withMenu(&ui, .{ .anchor = .after }, .fixed(80));
    try testing.expectEqual(@as(f32, 100), ui.boxOf("menu").?.x);
    _ = try withMenu(&ui, .{ .anchor = .before }, .fixed(80));
    try testing.expectEqual(@as(f32, -80), ui.boxOf("menu").?.x);

    // Middle on middle: eighty wide centred on a hundred is ten in, sixty
    // tall centred on forty is ten *out*.
    _ = try withMenu(&ui, .{ .anchor = .centered }, .fixed(80));
    try testing.expectEqual(BoundingBox.init(10, -10, 80, 60), ui.boxOf("menu").?);
}

test "an offset moves it after the anchor has decided" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try withMenu(&ui, .{ .anchor = .below, .offset = .{ .x = 6, .y = 4 } }, .fixed(80));
    try testing.expectEqual(BoundingBox.init(6, 44, 80, 60), ui.boxOf("menu").?);
}

test "nothing in the flow moves because something floats" {
    // The whole point. A menu appearing must not push the page about.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const row = struct {
        fn run(u: *Ui, menu: bool) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{ .id = "row", .width = .fit, .height = .fit, .gap = 8 });
                defer u.close();

                leaf(u, "first", .{ .width = .fixed(50), .height = .fixed(20) });
                if (menu) {
                    u.open(.{
                        .id = "menu",
                        .width = .fixed(200),
                        .height = .fixed(200),
                        .floating = .{ .anchor = .below },
                    });
                    u.close();
                }
                leaf(u, "second", .{ .width = .fixed(50), .height = .fixed(20) });
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try row(&ui, false);
    const without = ui.boxOf("second").?;
    const row_without = ui.boxOf("row").?;

    try row(&ui, true);
    try testing.expectEqual(without, ui.boxOf("second").?);
    // And the row did not grow to hold two hundred pixels of menu.
    try testing.expectEqual(row_without, ui.boxOf("row").?);
}

test "a floating element grows into what it is attached to" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // No parent to grow into, so it grows into the button - which is what
    // makes a dropdown the width of the control it drops from.
    _ = try withMenu(&ui, .{ .anchor = .below }, .grow);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("menu").?.width);

    _ = try withMenu(&ui, .{ .anchor = .below }, .percent(0.5));
    try testing.expectEqual(@as(f32, 50), ui.boxOf("menu").?.width);
}

test "attaching to the root measures against the surface" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try withMenu(&ui, .{ .attach = .root, .anchor = .centered }, .grow);

    // Four hundred wide, and centred on a three hundred tall surface.
    const box = ui.boxOf("menu").?;
    try testing.expectEqual(@as(f32, 400), box.width);
    try testing.expectEqual(@as(f32, 0), box.x);
    try testing.expectEqual(@as(f32, 120), box.y);
}

test "attaching by name finds an element declared later" {
    // Ply resolves the name as the element is declared, so it can only name
    // something already seen. This resolves once the tree is laid out, so the
    // order does not matter.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "tip",
            .width = .fixed(30),
            .height = .fixed(10),
            .floating = .{ .attach = .id, .to = "later", .anchor = .below },
        });
        ui.close();

        leaf(&ui, "spacer", .{ .width = .fixed(70), .height = .fixed(25) });
        leaf(&ui, "later", .{ .width = .fixed(50), .height = .fixed(25) });
    }
    ui.close();
    _ = try ui.end();

    // "later" sits after the spacer, and the tip hangs off its bottom left.
    try testing.expectEqual(BoundingBox.init(70, 25, 30, 10), ui.boxOf("tip").?);
}

test "a floating element is drawn over the page, whatever order it was declared in" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "under", .width = .fixed(100), .height = .fixed(40), .background_color = paint });
        defer ui.close();
        ui.open(.{
            .id = "over",
            .width = .fixed(100),
            .height = .fixed(40),
            .background_color = paint,
            .floating = .{},
        });
        ui.close();
    }
    // Declared before the float, drawn after it if paint order were
    // declaration order.
    leaf(&ui, "sibling", .{ .width = .fixed(400), .height = .fixed(300) });
    ui.close();
    const drawn = try ui.end();

    // The float's rectangle is the last one out.
    var last: u32 = 0;
    for (drawn) |command| {
        if (std.meta.activeTag(command.config) == .rectangle) last = command.id;
    }
    try testing.expectEqual(identify("over", 0), last);
}

test "the pointer finds a floating element before what is under it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{ .id = "page", .width = .grow, .height = .grow, .background_color = paint });
                defer u.close();
                u.open(.{
                    .id = "menu",
                    .width = .fixed(100),
                    .height = .fixed(50),
                    .background_color = paint,
                    .floating = .{ .attach = .root },
                });
                u.close();
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    ui.setPointer(50, 25, false);
    try frame(&ui);

    try testing.expect(ui.isPointerOver("menu"));
    // And the page beneath it is not, because a float is not inside what it
    // was declared in - it only remembers who to hang off.
    try testing.expect(!ui.isPointerOver("page"));

    // Beside the menu, the page is found as usual.
    ui.setPointer(300, 200, false);
    try frame(&ui);
    try testing.expect(ui.isPointerOver("page"));
    try testing.expect(!ui.isPointerOver("menu"));
}

test "z_index decides which float is on top, and ties keep their order" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const two = struct {
        fn run(u: *Ui, first: i16, second: i16) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            u.open(.{
                .id = "low",
                .width = .fixed(100),
                .height = .fixed(100),
                .background_color = paint,
                .floating = .{ .attach = .root, .z_index = first },
            });
            u.close();
            u.open(.{
                .id = "high",
                .width = .fixed(100),
                .height = .fixed(100),
                .background_color = paint,
                .floating = .{ .attach = .root, .z_index = second },
            });
            u.close();
            u.close();
            _ = try u.end();
        }
    }.run;

    // Same z: the later one wins, which is declaration order.
    try two(&ui, 0, 0);
    ui.setPointer(50, 50, false);
    try two(&ui, 0, 0);
    try testing.expect(ui.isPointerOver("high"));

    // A higher z on the first one turns it round.
    try two(&ui, 5, 0);
    ui.setPointer(50, 50, false);
    try two(&ui, 5, 0);
    try testing.expect(ui.isPointerOver("low"));
}

test "a float is not clipped by what it was declared in, unless it asks" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui, clip: bool) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                // A small clipping box with something hanging well outside it.
                u.open(.{
                    .id = "window",
                    .width = .fixed(60),
                    .height = .fixed(60),
                    .clip = .both,
                    .background_color = paint,
                });
                defer u.close();
                u.open(.{
                    .id = "tip",
                    .width = .fixed(100),
                    .height = .fixed(30),
                    .background_color = paint,
                    .floating = .{ .anchor = .below, .clip = clip },
                });
                u.close();
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    // Hanging below the window, outside it entirely.
    try frame(&ui, false);
    ui.setPointer(50, 70, false);
    try frame(&ui, false);
    try testing.expect(ui.isPointerOver("tip"));

    // Clipped to it, the same point is outside what is showing.
    try frame(&ui, true);
    ui.setPointer(50, 70, false);
    try frame(&ui, true);
    try testing.expect(!ui.isPointerOver("tip"));
}

test "clipping a float to its parent emits a balanced scissor" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const drawn = try withMenu(&ui, .{ .anchor = .below, .clip = true }, .fixed(80));
    const emitted: commands.List = .{ .items = drawn };
    try testing.expect(emitted.scissorsBalanced());
    try testing.expectEqual(@as(usize, 1), emitted.count(.scissor_start));
}

test "a float can hold a whole tree of its own" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "button", .width = .fixed(120), .height = .fixed(30) });
        defer ui.close();

        ui.open(.{
            .id = "menu",
            .width = .grow,
            .height = .fit,
            .padding = .all(4),
            .gap = 2,
            .direction = .top_to_bottom,
            .floating = .{ .anchor = .below },
        });
        defer ui.close();
        leaf(&ui, "one", .{ .width = .grow, .height = .fixed(20) });
        leaf(&ui, "two", .{ .width = .grow, .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    // The float grew to the button, fitted its two rows, and laid them out
    // inside its own padding - the same solver, on a root of its own.
    try testing.expectEqual(BoundingBox.init(0, 30, 120, 50), ui.boxOf("menu").?);
    try testing.expectEqual(BoundingBox.init(4, 34, 112, 20), ui.boxOf("one").?);
    try testing.expectEqual(BoundingBox.init(4, 56, 112, 20), ui.boxOf("two").?);
}

// -------------------------------------------------------------------------
// Wrapping
// -------------------------------------------------------------------------

// A hundred pixel row with forty pixel children in it: two to a line, and the
// third underneath. Every number below comes from that, so the arithmetic can
// be read without holding the whole tree in mind.

/// A wrapping row of `count` fixed children, `wide` pixels each.
fn wrapRow(u: *Ui, count: usize, wide: f32, gap: u16, wrap_gap: u16) !void {
    u.begin(.init(400, 300));
    openRoot(u);
    {
        u.open(.{
            .id = "row",
            .width = .fixed(100),
            .height = .fit,
            .gap = gap,
            .wrap = true,
            .wrap_gap = wrap_gap,
        });
        defer u.close();
        for (0..count) |i| {
            var name: [8]u8 = undefined;
            const id = std.fmt.bufPrint(&name, "c{d}", .{i}) catch "c";
            leaf(u, id, .{ .width = .fixed(wide), .height = .fixed(20) });
        }
    }
    u.close();
    _ = try u.end();
}

test "children that do not fit carry on underneath" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try wrapRow(&ui, 5, 40, 0, 0);

    try testing.expectEqual(BoundingBox.init(0, 0, 40, 20), ui.boxOf("c0").?);
    try testing.expectEqual(BoundingBox.init(40, 0, 40, 20), ui.boxOf("c1").?);
    // The third does not fit beside them, so it starts a line.
    try testing.expectEqual(BoundingBox.init(0, 20, 40, 20), ui.boxOf("c2").?);
    try testing.expectEqual(BoundingBox.init(40, 20, 40, 20), ui.boxOf("c3").?);
    try testing.expectEqual(BoundingBox.init(0, 40, 40, 20), ui.boxOf("c4").?);

    // And the row is as tall as its lines stacked up, not as tall as one
    // child - which is the part that has to reach its ancestors.
    try testing.expectEqual(@as(f32, 60), ui.boxOf("row").?.height);
}

test "a row with room for everything does not wrap" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try wrapRow(&ui, 2, 40, 0, 0);
    try testing.expectEqual(@as(f32, 0), ui.boxOf("c1").?.y);
    try testing.expectEqual(@as(f32, 20), ui.boxOf("row").?.height);
}

test "the gap goes along a line and the wrap gap between them" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // Two forties and a ten pixel gap is ninety, which fits; a third would
    // be a hundred and forty, which does not.
    try wrapRow(&ui, 3, 40, 10, 6);

    try testing.expectEqual(@as(f32, 50), ui.boxOf("c1").?.x);
    try testing.expectEqual(@as(f32, 0), ui.boxOf("c2").?.x);
    // Twenty of line, six of wrap gap.
    try testing.expectEqual(@as(f32, 26), ui.boxOf("c2").?.y);
    try testing.expectEqual(@as(f32, 46), ui.boxOf("row").?.height);
}

test "a child too wide for the row gets a line of its own and overflows it" {
    // The case that has to terminate. A line always takes at least one child,
    // however little room is left, or the loop never moves on.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fixed(100), .height = .fit, .wrap = true });
        defer ui.close();
        leaf(&ui, "small", .{ .width = .fixed(30), .height = .fixed(20) });
        leaf(&ui, "huge", .{ .width = .fixed(400), .height = .fixed(20) });
        leaf(&ui, "after", .{ .width = .fixed(30), .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 0), ui.boxOf("small").?.y);
    try testing.expectEqual(@as(f32, 20), ui.boxOf("huge").?.y);
    try testing.expectEqual(@as(f32, 400), ui.boxOf("huge").?.width);
    try testing.expectEqual(@as(f32, 40), ui.boxOf("after").?.y);
}

test "each line shares out its own space" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fixed(100), .height = .fit, .wrap = true });
        defer ui.close();
        for (0..3) |i| {
            var name: [8]u8 = undefined;
            const id = std.fmt.bufPrint(&name, "g{d}", .{i}) catch "g";
            leaf(&ui, id, .{ .width = .growBetween(40, 1000), .height = .fixed(20) });
        }
    }
    ui.close();
    _ = try ui.end();

    // Two forties fit on a line and a third does not, so the first two share
    // the hundred between them and the third has a line to itself.
    try testing.expectEqual(@as(f32, 50), ui.boxOf("g0").?.width);
    try testing.expectEqual(@as(f32, 50), ui.boxOf("g1").?.width);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("g2").?.width);
    try testing.expectEqual(@as(f32, 20), ui.boxOf("g2").?.y);
}

test "a growing child is broken on by its minimum, not by what it grows to" {
    // The rule that stops the answer depending on itself: where the lines
    // fall decides how much each one has to share out, and how much a child
    // grew depends on that.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "row", .width = .fixed(100), .height = .fit, .wrap = true });
        defer ui.close();
        // No minimum: each asks for nothing, so they all fit on one line and
        // then share it.
        leaf(&ui, "a", .{ .width = .grow, .height = .fixed(20) });
        leaf(&ui, "b", .{ .width = .grow, .height = .fixed(20) });
        leaf(&ui, "c", .{ .width = .grow, .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 0), ui.boxOf("c").?.y);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 3.0), ui.boxOf("a").?.width, 0.01);
}

test "each line is aligned along the main axis on its own" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "row",
            .width = .fixed(100),
            .height = .fit,
            .wrap = true,
            .align_x = .center,
        });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .fixed(40), .height = .fixed(20) });
        leaf(&ui, "b", .{ .width = .fixed(40), .height = .fixed(20) });
        leaf(&ui, "c", .{ .width = .fixed(40), .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    // The full line is eighty in a hundred, so it starts ten in. The last
    // line is one child, centred on its own - thirty in, not ten.
    try testing.expectEqual(@as(f32, 10), ui.boxOf("a").?.x);
    try testing.expectEqual(@as(f32, 30), ui.boxOf("c").?.x);
}

test "a child is aligned across its own line, not across the whole row" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "row",
            .width = .fixed(100),
            .height = .fit,
            .wrap = true,
            .align_y = .center,
        });
        defer ui.close();
        leaf(&ui, "tall", .{ .width = .fixed(40), .height = .fixed(40) });
        leaf(&ui, "short", .{ .width = .fixed(40), .height = .fixed(10) });
        leaf(&ui, "next", .{ .width = .fixed(40), .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    // The first line is forty tall, so the ten pixel child sits fifteen down
    // in it. If it were centred in the whole sixty pixel row it would be at
    // twenty-five, and it would be on top of the second line.
    try testing.expectEqual(@as(f32, 15), ui.boxOf("short").?.y);
    try testing.expectEqual(@as(f32, 40), ui.boxOf("next").?.y);
}

test "padding is inside the lines, not around each of them" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "row",
            .width = .fixed(100),
            .height = .fit,
            .padding = .all(10),
            .wrap = true,
        });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .fixed(40), .height = .fixed(20) });
        leaf(&ui, "b", .{ .width = .fixed(40), .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    // Eighty of inner width holds two forties exactly, so they stay on one
    // line, both inside the padding.
    try testing.expectEqual(BoundingBox.init(10, 10, 40, 20), ui.boxOf("a").?);
    try testing.expectEqual(BoundingBox.init(50, 10, 40, 20), ui.boxOf("b").?);
    try testing.expectEqual(@as(f32, 40), ui.boxOf("row").?.height);
}

test "a column wraps into columns" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "column",
            .width = .fixed(200),
            .height = .fixed(50),
            .direction = .top_to_bottom,
            .wrap = true,
        });
        defer ui.close();
        for (0..3) |i| {
            var name: [8]u8 = undefined;
            const id = std.fmt.bufPrint(&name, "d{d}", .{i}) catch "d";
            leaf(&ui, id, .{ .width = .fixed(30), .height = .fixed(20) });
        }
    }
    ui.close();
    _ = try ui.end();

    // Two twenties fit in fifty and a third does not, so the third starts a
    // column beside them.
    try testing.expectEqual(BoundingBox.init(0, 0, 30, 20), ui.boxOf("d0").?);
    try testing.expectEqual(BoundingBox.init(0, 20, 30, 20), ui.boxOf("d1").?);
    try testing.expectEqual(BoundingBox.init(30, 0, 30, 20), ui.boxOf("d2").?);
}

test "a wrapping row can be squeezed down to one child, and no further" {
    // The rule the nested test above found by failing: a wrapping row's
    // smallest is one of its children, not all of them. Without it a row of
    // fixed children can never be made narrow enough to wrap, and `wrap` does
    // nothing at all.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        // Narrower than one child, so the row is held at its widest child and
        // overflows - which is what any element does when it cannot fit.
        ui.open(.{ .id = "narrow", .width = .fixed(30), .height = .fit, .direction = .top_to_bottom });
        defer ui.close();

        ui.open(.{ .id = "row", .width = .grow, .height = .fit, .wrap = true });
        defer ui.close();
        leaf(&ui, "a", .{ .width = .fixed(40), .height = .fixed(20) });
        leaf(&ui, "b", .{ .width = .fixed(40), .height = .fixed(20) });
    }
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 40), ui.boxOf("row").?.width);
    // One child a line, so two lines.
    try testing.expectEqual(@as(f32, 40), ui.boxOf("row").?.height);
    try testing.expectEqual(@as(f32, 20), ui.boxOf("b").?.y);
}

test "a wrapping row inside a column reaches its ancestors with the right height" {
    // The reason the height is worked out where it is: a wrapped row that
    // told its parent it was one line tall would have the rest of the page
    // drawn over it.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "column", .width = .fixed(100), .height = .fit, .direction = .top_to_bottom });
        defer ui.close();
        {
            ui.open(.{ .id = "tags", .width = .grow, .height = .fit, .wrap = true });
            defer ui.close();
            for (0..5) |i| {
                var name: [8]u8 = undefined;
                const id = std.fmt.bufPrint(&name, "t{d}", .{i}) catch "t";
                leaf(&ui, id, .{ .width = .fixed(40), .height = .fixed(20) });
            }
        }
        leaf(&ui, "below", .{ .width = .grow, .height = .fixed(10) });
    }
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(f32, 60), ui.boxOf("tags").?.height);
    try testing.expectEqual(@as(f32, 60), ui.boxOf("below").?.y);
    try testing.expectEqual(@as(f32, 70), ui.boxOf("column").?.height);
}

// -------------------------------------------------------------------------
// Images
// -------------------------------------------------------------------------

// A picture is a number and a box. Nothing here knows how many pixels the
// texture is - the renderer does, and it is the one that has the table.

fn onlyImage(drawn: []const commands.RenderCommand) ?commands.Image {
    for (drawn) |command| {
        if (command.config == .image) return command.config.image;
    }
    return null;
}

test "an image takes the place of the fill rather than sitting on it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    ui.empty(.{
        .id = "picture",
        .width = .fixed(64),
        .height = .fixed(64),
        .corner_radius = .all(8),
        .background_color = paint,
        .image = .{ .texture = 3 },
    });
    ui.close();
    const drawn = try ui.end();

    // One command, not a rectangle and a picture: the fill rides on the
    // image command, so a renderer is not handed two of everything.
    const emitted: commands.List = .{ .items = drawn };
    try testing.expectEqual(@as(usize, 1), emitted.count(.image));
    try testing.expectEqual(@as(usize, 0), emitted.count(.rectangle));

    const picture = onlyImage(drawn).?;
    try testing.expectEqual(@as(u32, 3), picture.texture);
    try testing.expectEqual(paint, picture.background_color);
    try testing.expectEqual(@as(f32, 8), picture.corner_radius.top_left);
}

test "the image's own background wins over the element's" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    ui.empty(.{
        .id = "picture",
        .width = .fixed(10),
        .height = .fixed(10),
        .background_color = paint,
        .image = .{ .texture = 0, .background_color = .hex(0x112233) },
    });
    ui.close();
    const drawn = try ui.end();

    try testing.expectEqual(Color.hex(0x112233), onlyImage(drawn).?.background_color);
}

test "an image is sized by its declaration, and held to a ratio by contain" {
    // Nothing in the layout knows how big the texture is, so a picture is as
    // big as it was asked to be. `contain` is how it keeps its proportions.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    {
        ui.open(.{ .width = .grow, .height = .grow, .align_y = .center });
        defer ui.close();
        ui.empty(.{
            .id = "picture",
            .width = .fixed(200),
            .height = .fixed(200),
            .contain = 2,
            .image = .{ .texture = 0 },
        });
    }
    _ = try ui.end();

    // Twice as wide as it is tall, out of a two hundred square box. Where the
    // letterbox sits is the parent's alignment, as it is for anything else -
    // `contain` decides the size and nothing else.
    try testing.expectEqual(@as(f32, 200), ui.boxOf("picture").?.width);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("picture").?.height);
    try testing.expectEqual(@as(f32, 100), ui.boxOf("picture").?.y);
}

test "a source rectangle names a piece of a sheet" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    ui.empty(.{
        .id = "icon",
        .width = .fixed(16),
        .height = .fixed(16),
        .image = .{ .texture = 1, .source = .init(0.25, 0, 0.25, 0.5), .tint = .hex(0xFF8000) },
    });
    ui.close();
    const drawn = try ui.end();

    const picture = onlyImage(drawn).?;
    try testing.expectEqual(@as(f32, 0.25), picture.source.x);
    try testing.expectEqual(@as(f32, 0.5), picture.source.right());
    try testing.expectEqual(Color.hex(0xFF8000), picture.tint);
}

test "an image inside a clip is clipped like anything else" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "window", .width = .fixed(50), .height = .fixed(50), .clip = .both });
        defer ui.close();
        ui.empty(.{ .id = "picture", .width = .fixed(200), .height = .fixed(200), .image = .{} });
    }
    ui.close();
    const drawn = try ui.end();

    const emitted: commands.List = .{ .items = drawn };
    try testing.expect(emitted.scissorsBalanced());
    try testing.expectEqual(@as(usize, 1), emitted.count(.image));
    try testing.expectEqual(@as(usize, 1), emitted.count(.scissor_start));
}

// -------------------------------------------------------------------------
// Rotation
// -------------------------------------------------------------------------

// A turn changes nothing about the layout: the box an element takes up is the
// box it would have had, and its neighbours do not move. What changes is
// where the drawing of it lands, and where the pointer has to be to hit it.

/// The transform stamped on the first command belonging to this element.
fn motionIn(drawn: []const commands.RenderCommand, name: []const u8) ?geometry.Transform {
    const wanted = identify(name, 0);
    for (drawn) |command| {
        if (command.id == wanted) return command.transform;
    }
    return null;
}

test "a turn moves the drawing and leaves the layout alone" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui, turn: ?layout.Rotation) ![]const commands.RenderCommand {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{ .id = "row", .width = .fit, .height = .fit, .gap = 10 });
                defer u.close();
                u.empty(.{
                    .id = "badge",
                    .width = .fixed(40),
                    .height = .fixed(40),
                    .background_color = paint,
                    .rotate = turn,
                });
                leaf(u, "after", .{ .width = .fixed(40), .height = .fixed(40) });
            }
            u.close();
            return try u.end();
        }
    }.run;

    _ = try frame(&ui, null);
    const straight = ui.boxOf("badge").?;
    const beside = ui.boxOf("after").?;

    const drawn = try frame(&ui, .degrees(90));

    // Same boxes, both of them: a badge tilted on the page must not reflow
    // the page.
    try testing.expectEqual(straight, ui.boxOf("badge").?);
    try testing.expectEqual(beside, ui.boxOf("after").?);

    // But the command says where it really went. A quarter turn about the
    // middle of a square puts its top left corner at the top right.
    const motion = motionIn(drawn, "badge").?;
    const corner = motion.apply(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 40), corner.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), corner.y, 0.001);

    // And its neighbour is not turned at all.
    try testing.expect(motionIn(drawn, "after").?.isIdentity());
}

test "a turn on an element carries everything inside it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "card",
            .width = .fixed(100),
            .height = .fixed(100),
            .background_color = paint,
            .rotate = .degrees(180),
        });
        defer ui.close();
        leaf(&ui, "inside", .{ .width = .fixed(20), .height = .fixed(20) });
    }
    ui.close();
    const drawn = try ui.end();

    // Half a turn about the middle of the card sends its top left corner to
    // the bottom right, and takes the child with it.
    const child = motionIn(drawn, "inside").?;
    const at = child.apply(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 100), at.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100), at.y, 0.001);
}

test "a shape turn stops at the element's own box" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "card",
            .width = .fixed(100),
            .height = .fixed(100),
            .background_color = paint,
            .rotate_shape = .degrees(180),
        });
        defer ui.close();
        leaf(&ui, "inside", .{ .width = .fixed(20), .height = .fixed(20) });
    }
    ui.close();
    const drawn = try ui.end();

    // The card's own fill is turned...
    try testing.expect(!motionIn(drawn, "card").?.isIdentity());
    // ...and the child is where it was, which is the whole difference between
    // this and `rotate`.
    try testing.expect(motionIn(drawn, "inside").?.isIdentity());
}

test "turns nest" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{
            .id = "card",
            .width = .fixed(100),
            .height = .fixed(100),
            .rotate = .degrees(90),
        });
        defer ui.close();
        ui.empty(.{
            .id = "icon",
            .width = .fixed(20),
            .height = .fixed(20),
            .background_color = paint,
            .rotate = .degrees(90),
        });
    }
    ui.close();
    const drawn = try ui.end();

    // A quarter turn inside a quarter turn is a half turn about the icon's
    // own middle, moved by the card's turn - which is what composing means
    // and is why a transform is two axes rather than an angle.
    const icon = motionIn(drawn, "icon").?;
    const middle = icon.apply(.{ .x = 10, .y = 10 });
    // The icon's middle only moves by the card's turn: (10,10) about (50,50)
    // a quarter clockwise is (90,10).
    try testing.expectApproxEqAbs(@as(f32, 90), middle.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), middle.y, 0.001);

    // And a corner ends up half a turn from where the card alone would put it.
    const corner = icon.apply(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 100), corner.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), corner.y, 0.001);
}

test "the pointer finds a turned element where it was drawn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const frame = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            // A tall thin box turned a quarter, so it lies across the page.
            u.empty(.{
                .id = "bar",
                .width = .fixed(20),
                .height = .fixed(200),
                .background_color = paint,
                .rotate = .degrees(90),
            });
            u.close();
            _ = try u.end();
        }
    }.run;

    try frame(&ui);
    // The box is at (0,0,20,200) and turns about its middle (10,100), so it
    // ends up lying from (-90,90) to (110,110).
    ui.setPointer(100, 100, false);
    try frame(&ui);
    try testing.expect(ui.isPointerOver("bar"));

    // Where the *unturned* box was, there is nothing.
    ui.setPointer(10, 190, false);
    try frame(&ui);
    try testing.expect(!ui.isPointerOver("bar"));
}

test "a flip mirrors without moving the box" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    ui.empty(.{
        .id = "mirror",
        .width = .fixed(100),
        .height = .fixed(40),
        .background_color = paint,
        .rotate = .{ .flip_x = true },
    });
    ui.close();
    const drawn = try ui.end();

    const motion = motionIn(drawn, "mirror").?;
    // The left edge becomes the right edge and the other way about.
    try testing.expectApproxEqAbs(@as(f32, 100), motion.apply(.{ .x = 0, .y = 0 }).x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), motion.apply(.{ .x = 100, .y = 0 }).x, 0.001);
    // And nothing moved vertically.
    try testing.expectApproxEqAbs(@as(f32, 7), motion.apply(.{ .x = 0, .y = 7 }).y, 0.001);
}

test "a turn of nothing is not a turn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    ui.empty(.{
        .id = "still",
        .width = .fixed(10),
        .height = .fixed(10),
        .background_color = paint,
        .rotate = .{ .radians = 0 },
    });
    ui.close();
    const drawn = try ui.end();

    // Worth checking rather than assuming: an interface that sets a rotation
    // to zero should cost exactly what one that sets none costs.
    try testing.expect(motionIn(drawn, "still").?.isIdentity());
}

test "text inside a turned element is turned with it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    ui.begin(.init(400, 300));
    openRoot(&ui);
    {
        ui.open(.{ .id = "label", .width = .fit, .height = .fit, .rotate = .degrees(45) });
        defer ui.close();
        ui.text("tilted", sixteen);
    }
    ui.close();
    const drawn = try ui.end();

    // The run belongs to a text element of its own, so look for any text
    // command and check it carries the card's motion.
    for (drawn) |command| {
        if (std.meta.activeTag(command.config) != .text) continue;
        try testing.expect(!command.transform.isIdentity());
        return;
    }
    try testing.expect(false);
}

// -------------------------------------------------------------------------
// Callbacks
// -------------------------------------------------------------------------

// Every one of these runs two frames for the same reason the hit tests do:
// what is under the pointer is known only once a frame has been laid out, so
// the callbacks a frame registers are called about the frame before it.

/// What the callbacks below write into, instead of the variables a closure
/// in Ply would have captured.
const Tally = struct {
    hover: u32 = 0,
    press: u32 = 0,
    release: u32 = 0,
    focus: u32 = 0,
    unfocus: u32 = 0,
    /// The last release's answer to "did it come up where it went down".
    on_target: bool = false,
    /// The id the last call was about, to prove it is the right element.
    last: u32 = 0,

    fn onHover(context: ?*anyopaque, event: layout.Callback.Event) void {
        const self: *Tally = @ptrCast(@alignCast(context.?));
        self.hover += 1;
        self.last = event.id;
    }

    fn onPress(context: ?*anyopaque, event: layout.Callback.Event) void {
        const self: *Tally = @ptrCast(@alignCast(context.?));
        self.press += 1;
        self.last = event.id;
    }

    fn onRelease(context: ?*anyopaque, event: layout.Callback.Event) void {
        const self: *Tally = @ptrCast(@alignCast(context.?));
        self.release += 1;
        self.on_target = event.on_target;
        self.last = event.id;
    }

    fn onFocus(context: ?*anyopaque, event: layout.Callback.Event) void {
        const self: *Tally = @ptrCast(@alignCast(context.?));
        self.focus += 1;
        self.last = event.id;
    }

    fn onUnfocus(context: ?*anyopaque, event: layout.Callback.Event) void {
        const self: *Tally = @ptrCast(@alignCast(context.?));
        self.unfocus += 1;
        self.last = event.id;
    }

    /// A declaration with all five wired to this tally.
    fn watched(self: *Tally, name: []const u8) layout.Declaration {
        return .{
            .id = name,
            .width = .fixed(100),
            .height = .fixed(40),
            .background_color = paint,
            .on_hover = .{ .context = self, .call = onHover },
            .on_press = .{ .context = self, .call = onPress },
            .on_release = .{ .context = self, .call = onRelease },
            .on_focus = .{ .context = self, .call = onFocus },
            .on_unfocus = .{ .context = self, .call = onUnfocus },
        };
    }
};

/// One watched button at the top left, and nothing else.
fn watchedButton(u: *Ui, tally: *Tally) !void {
    u.begin(.init(400, 300));
    openRoot(u);
    u.empty(tally.watched("button"));
    u.close();
    _ = try u.end();
}

test "a press and a release reach the element that was pressed" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 0), tally.press);

    // Down on the button.
    ui.setPointer(50, 20, true);
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.press);
    try testing.expectEqual(identify("button", 0), tally.last);

    // Held: pressed does not fire again, which is what "once" means.
    ui.setPointer(50, 20, true);
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.press);
    try testing.expectEqual(@as(u32, 0), tally.release);

    // Up on it: released, and it came up where it went down.
    ui.setPointer(50, 20, false);
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.release);
    try testing.expect(tally.on_target);
}

test "a release away from the button says so" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    try watchedButton(&ui, &tally);

    ui.setPointer(50, 20, true);
    try watchedButton(&ui, &tally);
    // Dragged off and let go. The element still hears about it - it is what
    // went down - but it is told the pointer had left, which is the
    // difference between a click and a change of mind.
    ui.setPointer(300, 200, false);
    try watchedButton(&ui, &tally);

    try testing.expectEqual(@as(u32, 1), tally.release);
    try testing.expect(!tally.on_target);
}

test "hover is every frame the pointer is over, not the frame it arrived" {
    // Ply's meaning of the word, and the same one `hovered()` answers.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    try watchedButton(&ui, &tally);

    ui.setPointer(50, 20, false);
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.hover);

    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 2), tally.hover);

    // Off it, and it stops.
    ui.setPointer(300, 200, false);
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 2), tally.hover);
}

test "focus and unfocus fire once each, however the focus moved" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 0), tally.focus);

    // Given the keyboard by the program rather than by a click, which is the
    // case `hovered()` and its siblings cannot answer at all.
    ui.setFocus("button");
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.focus);
    try testing.expectEqual(@as(u32, 0), tally.unfocus);

    // Still focused: not told again.
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.focus);

    ui.clearFocus();
    try watchedButton(&ui, &tally);
    try testing.expectEqual(@as(u32, 1), tally.unfocus);
}

test "a click both focuses and presses, in that order" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    try watchedButton(&ui, &tally);

    ui.setPointer(50, 20, true);
    try watchedButton(&ui, &tally);

    try testing.expectEqual(@as(u32, 1), tally.focus);
    try testing.expectEqual(@as(u32, 1), tally.press);
}

test "a callback is only called about its own element" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var mine: Tally = .{};
    var theirs: Tally = .{};

    const two = struct {
        fn run(u: *Ui, a: *Tally, b: *Tally) !void {
            u.begin(.init(400, 300));
            {
                u.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom });
                defer u.close();
                u.empty(a.watched("first"));
                u.empty(b.watched("second"));
            }
            _ = try u.end();
        }
    }.run;

    try two(&ui, &mine, &theirs);
    // On the second button, which sits below the first.
    ui.setPointer(50, 60, true);
    try two(&ui, &mine, &theirs);

    try testing.expectEqual(@as(u32, 0), mine.press);
    try testing.expectEqual(@as(u32, 1), theirs.press);
    try testing.expectEqual(identify("second", 0), theirs.last);
}

test "an element with no callbacks costs nothing to walk past" {
    // The list only holds the elements that asked for something, so a page of
    // boxes with one button in it walks a list of one.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var tally: Tally = .{};
    ui.begin(.init(400, 300));
    openRoot(&ui);
    for (0..20) |i| {
        var name: [8]u8 = undefined;
        const id = std.fmt.bufPrint(&name, "b{d}", .{i}) catch "b";
        leaf(&ui, id, .{ .width = .fixed(10), .height = .fixed(10) });
    }
    ui.empty(tally.watched("button"));
    ui.close();
    _ = try ui.end();

    try testing.expectEqual(@as(usize, 1), ui.listeners.items.len);
}

test "the parent of a pressed element hears about it too" {
    // A press walks the chain, so a card wrapping a label is pressed when the
    // label is - the same rule `pressed()` follows, and the reason `capture`
    // exists to stop it.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    var outer: Tally = .{};
    var inner: Tally = .{};

    const nested = struct {
        fn run(u: *Ui, a: *Tally, b: *Tally) !void {
            u.begin(.init(400, 300));
            {
                var card = a.watched("card");
                card.width = .fixed(200);
                card.height = .fixed(100);
                u.open(card);
                defer u.close();

                var label = b.watched("label");
                label.width = .fixed(50);
                label.height = .fixed(20);
                u.empty(label);
            }
            _ = try u.end();
        }
    }.run;

    try nested(&ui, &outer, &inner);
    ui.setPointer(20, 10, true);
    try nested(&ui, &outer, &inner);

    try testing.expectEqual(@as(u32, 1), inner.press);
    try testing.expectEqual(@as(u32, 1), outer.press);
}

test "a callback may change what the next frame draws" {
    // What they are for. The callback runs after the commands are built, so
    // what it changes is the frame after - which is the only order that can
    // be right, and is why declaring elements from inside one is not allowed.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const Counter = struct {
        count: u32 = 0,

        fn bump(context: ?*anyopaque, event: layout.Callback.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            _ = event;
        }
    };
    var counter: Counter = .{};

    const frame = struct {
        fn run(u: *Ui, c: *Counter) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            u.empty(.{
                .id = "button",
                .width = .fixed(100),
                .height = .fixed(40),
                .background_color = paint,
                .on_press = .{ .context = c, .call = Counter.bump },
            });
            u.close();
            _ = try u.end();
        }
    }.run;

    try frame(&ui, &counter);
    ui.setPointer(50, 20, true);
    try frame(&ui, &counter);
    try testing.expectEqual(@as(u32, 1), counter.count);

    ui.setPointer(50, 20, false);
    try frame(&ui, &counter);
    ui.setPointer(50, 20, true);
    try frame(&ui, &counter);
    try testing.expectEqual(@as(u32, 2), counter.count);
}

// -------------------------------------------------------------------------
// Dragging the content
// -------------------------------------------------------------------------

// A hundred pixel window onto three hundred of list, so there are two
// hundred pixels to scroll through. Every drag below is measured against
// that, and every one runs two frames before it can start: what is under the
// pointer is known only once a frame has been laid out.

/// A scrolling list, with `clip` saying how it may be scrolled.
fn scroller(u: *Ui, clip: layout.Clip) !void {
    u.begin(.init(400, 300));
    openRoot(u);
    {
        u.open(.{
            .id = "list",
            .width = .fixed(100),
            .height = .fixed(100),
            .clip = clip,
            .background_color = paint,
        });
        defer u.close();
        leaf(u, "content", .{ .width = .fixed(100), .height = .fixed(300) });
    }
    u.close();
    _ = try u.end();
}

test "dragging the content moves it under the finger" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try scroller(&ui, .scrollY);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.position.y);

    ui.setPointer(50, 80, true);
    try scroller(&ui, .scrollY);
    try testing.expect(ui.draggingContent());

    // Dragged thirty pixels *up* the screen, so the list scrolls thirty
    // pixels *down* - the content is stuck to the finger, which is the whole
    // difference between this and dragging the bar.
    ui.setPointer(50, 50, true);
    try testing.expectEqual(@as(f32, 30), ui.scrollOf("list").?.position.y);

    // Back past where it started: it stops at the top rather than going past.
    ui.setPointer(50, 200, true);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.position.y);

    ui.setPointer(50, 200, false);
    try testing.expect(!ui.draggingContent());
}

test "a drag is measured from where it started, not from the last frame" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try scroller(&ui, .scrollY);
    ui.setPointer(50, 90, true);
    try scroller(&ui, .scrollY);

    // Wander down and back. Anything accumulating per-frame deltas would
    // drift; this ends where the arithmetic says, which is where it began.
    for ([_]f32{ 60, 40, 70, 30, 90 }) |y| ui.setPointer(50, y, true);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.position.y);

    ui.setPointer(50, 50, true);
    try testing.expectEqual(@as(f32, 40), ui.scrollOf("list").?.position.y);
}

test "a list that does not overflow is not worth dragging" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const short = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(100),
                    .height = .fixed(100),
                    .clip = .scrollY,
                    .background_color = paint,
                });
                defer u.close();
                leaf(u, "content", .{ .width = .fixed(100), .height = .fixed(40) });
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try short(&ui);
    ui.setPointer(50, 50, true);
    try short(&ui);

    // Nothing to move, so no drag is armed at all - otherwise every press on
    // a short list would arm one that can never do anything.
    try testing.expect(!ui.draggingContent());
}

test "no_drag_scroll stops a mouse and lets a finger through" {
    // Ply's meaning exactly: the flag is about the mouse, because on a touch
    // screen dragging is the only way there is.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const clip: layout.Clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true };

    try scroller(&ui, clip);
    ui.setPointer(50, 80, true);
    try scroller(&ui, clip);
    try testing.expect(!ui.draggingContent());
    ui.setPointer(50, 80, false);

    ui.setTouch(true);
    try scroller(&ui, clip);
    ui.setPointer(50, 80, true);
    try scroller(&ui, clip);
    try testing.expect(ui.draggingContent());
}

test "the innermost list under the pointer is the one that moves" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const nested = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "page",
                    .width = .fixed(200),
                    .height = .fixed(200),
                    .clip = .scrollY,
                    .background_color = paint,
                });
                defer u.close();
                {
                    u.open(.{
                        .id = "inner",
                        .width = .fixed(100),
                        .height = .fixed(100),
                        .clip = .scrollY,
                        .background_color = paint,
                    });
                    defer u.close();
                    leaf(u, "rows", .{ .width = .fixed(100), .height = .fixed(300) });
                }
                leaf(u, "below", .{ .width = .fixed(100), .height = .fixed(300) });
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try nested(&ui);
    ui.setPointer(50, 50, true);
    try nested(&ui);
    ui.setPointer(50, 20, true);

    try testing.expectEqual(@as(f32, 30), ui.scrollOf("inner").?.position.y);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("page").?.position.y);
}

test "letting go leaves it coasting, and it slows to a stop" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try scroller(&ui, .scrollY);
    ui.tick(1.0 / 60.0);
    ui.setPointer(50, 90, true);
    try scroller(&ui, .scrollY);

    // Flicked upwards over three frames, sixty pixels a frame at sixty
    // frames a second, so it is going fast when the finger leaves.
    for ([_]f32{ 70, 50, 30 }) |y| {
        ui.tick(1.0 / 60.0);
        ui.setPointer(50, y, true);
    }
    const at_release = ui.scrollOf("list").?.position.y;
    try testing.expect(ui.scrollOf("list").?.momentum.y > 100);

    ui.setPointer(50, 30, false);

    // It carries on without the finger.
    ui.tick(1.0 / 60.0);
    const coasted = ui.scrollOf("list").?.position.y;
    try testing.expect(coasted > at_release);

    // And slows to a stop rather than running for ever.
    for (0..120) |_| ui.tick(1.0 / 60.0);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.momentum.y);
}

test "a coast is stopped by a wheel, and by being told where to go" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try scroller(&ui, .scrollY);
    ui.scrolls.getPtr(identify("list", 0)).?.momentum.y = 500;

    ui.scrollBy("list", 0, 10);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.momentum.y);

    ui.scrolls.getPtr(identify("list", 0)).?.momentum.y = 500;
    ui.scrollTo("list", 0, 50);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("list").?.momentum.y);
}

test "a container being dragged does not also coast" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try scroller(&ui, .scrollY);
    ui.setPointer(50, 90, true);
    try scroller(&ui, .scrollY);

    ui.tick(1.0 / 60.0);
    ui.setPointer(50, 60, true);
    const held_at = ui.scrollOf("list").?.position.y;
    try testing.expect(ui.scrollOf("list").?.momentum.y > 0);

    // The finger is still saying where it goes, so the speed it has built up
    // must not move it as well - or it would run away under the finger.
    ui.tick(1.0 / 60.0);
    try testing.expectEqual(held_at, ui.scrollOf("list").?.position.y);
}

test "a drag that turns into a scroll lets go of what it pressed" {
    // The one place this parts company with Ply. A list of buttons, dragged
    // and released, fires the button under the finger in Ply; every touch
    // platform cancels the tap instead, and the absence of it reads as a bug.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const buttons = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(100),
                    .height = .fixed(100),
                    .clip = .scrollY,
                    .direction = .top_to_bottom,
                    .background_color = paint,
                });
                defer u.close();
                for (0..10) |i| {
                    var name: [8]u8 = undefined;
                    const id = std.fmt.bufPrint(&name, "b{d}", .{i}) catch "b";
                    leaf(u, id, .{ .width = .fixed(100), .height = .fixed(30) });
                }
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try buttons(&ui);
    ui.setPointer(50, 10, true);
    try buttons(&ui);
    // Pressed, because a press that has not moved is still a tap.
    try testing.expect(ui.isElementPressed("b0"));

    // Two pixels is a twitch, not a scroll.
    ui.setPointer(50, 8, true);
    try testing.expect(ui.isElementPressed("b0"));

    // Twenty is a scroll, and the tap is off.
    ui.setPointer(50, 30 - 20, true);
    ui.setPointer(50, -10, true);
    try testing.expect(!ui.isElementPressed("b0"));

    ui.setPointer(50, -10, false);
    try buttons(&ui);
    try testing.expect(!ui.isElementReleased("b0"));
}

test "dragging a scrollbar is not dragging the content" {
    // Both are a press inside the same box, and only one of them may win.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const clip = layout.Clip.scrollY.bar(.{});
    try scroller(&ui, clip);

    // On the thumb, which hugs the right edge at x 94 to 100.
    ui.setPointer(97, 10, true);
    try testing.expect(ui.draggingScrollbar());
    try testing.expect(!ui.draggingContent());
}

// -------------------------------------------------------------------------
// The wheel, without a name
// -------------------------------------------------------------------------

/// Two lists side by side, each a hundred wide and a hundred tall, with three
/// hundred of content in them. The left one starts at x 0, the right at 100.
fn twoLists(u: *Ui) !void {
    u.begin(.init(400, 300));
    openRoot(u);
    for ([_][]const u8{ "left", "right" }) |name| {
        u.open(.{
            .id = name,
            .width = .fixed(100),
            .height = .fixed(100),
            .clip = .scrollY,
            .background_color = paint,
        });
        defer u.close();
        leaf(u, "rows", .{ .width = .fixed(100), .height = .fixed(300) });
    }
    u.close();
    _ = try u.end();
}

test "the wheel goes to the list under the pointer" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try twoLists(&ui);
    ui.setPointer(150, 50, false);
    try twoLists(&ui);

    try testing.expect(ui.scrollHovered(0, 40));
    try testing.expectEqual(@as(f32, 40), ui.scrollOf("right").?.position.y);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("left").?.position.y);

    // And follows the pointer to the other one, which is the whole reason
    // this exists rather than the caller working out the name itself.
    ui.setPointer(50, 50, false);
    try twoLists(&ui);
    _ = ui.scrollHovered(0, 25);
    try testing.expectEqual(@as(f32, 25), ui.scrollOf("left").?.position.y);
    try testing.expectEqual(@as(f32, 40), ui.scrollOf("right").?.position.y);
}

test "a wheel over nothing that scrolls moves nothing, and says so" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try twoLists(&ui);
    // Below both lists, on the root.
    ui.setPointer(200, 250, false);
    try twoLists(&ui);

    try testing.expect(!ui.scrollHovered(0, 40));
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("left").?.position.y);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("right").?.position.y);
}

test "the innermost list takes the wheel, one axis at a time" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // A page that scrolls both ways, holding a strip that only scrolls down.
    const nested = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            openRoot(u);
            {
                u.open(.{
                    .id = "page",
                    .width = .fixed(200),
                    .height = .fixed(200),
                    .clip = .scroll,
                    .background_color = paint,
                });
                defer u.close();
                {
                    u.open(.{
                        .id = "strip",
                        .width = .fixed(100),
                        .height = .fixed(100),
                        .clip = .scrollY,
                        .background_color = paint,
                    });
                    defer u.close();
                    leaf(u, "rows", .{ .width = .fixed(100), .height = .fixed(300) });
                }
                leaf(u, "wide", .{ .width = .fixed(600), .height = .fixed(600) });
            }
            u.close();
            _ = try u.end();
        }
    }.run;

    try nested(&ui);
    ui.setPointer(50, 50, false);
    try nested(&ui);

    // One swipe, both ways. Down is the strip's, because it is innermost and
    // has somewhere to go; sideways is the page's, because the strip has not.
    try testing.expect(ui.scrollHovered(30, 40));
    try testing.expectEqual(@as(f32, 40), ui.scrollOf("strip").?.position.y);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("strip").?.position.x);
    try testing.expectEqual(@as(f32, 30), ui.scrollOf("page").?.position.x);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("page").?.position.y);
}

test "the wheel stops a coast" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try twoLists(&ui);
    ui.setPointer(50, 50, false);
    try twoLists(&ui);
    ui.scrolls.getPtr(identify("left", 0)).?.momentum.y = 500;

    _ = ui.scrollHovered(0, 10);
    try testing.expectEqual(@as(f32, 0), ui.scrollOf("left").?.momentum.y);
}

// -------------------------------------------------------------------------
// Does the interface want this?
// -------------------------------------------------------------------------

// The two questions a game asks between the interface's frame and its own
// input. Both run two frames, like every other pointer question: what is
// under the cursor is known once a frame has been laid out.

/// A transparent root - a heads-up display - with one panel in the corner.
fn overlay(u: *Ui) !void {
    u.begin(.init(400, 300));
    {
        // No background: the game is behind this, not the interface.
        u.open(.{ .id = "hud", .width = .grow, .height = .grow });
        defer u.close();
        u.empty(.{
            .id = "panel",
            .width = .fixed(100),
            .height = .fixed(50),
            .background_color = paint,
        });
    }
    _ = try u.end();
}

test "a transparent overlay does not want the whole screen" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try overlay(&ui);

    // Over the panel: the interface drew here, so a click is its business.
    ui.setPointer(50, 25, false);
    try overlay(&ui);
    try testing.expect(ui.wantsPointer());

    // Anywhere else the root is under the pointer and paints nothing, so the
    // click belongs to whatever is behind - which is the whole point of
    // asking. A rule that counted "is anything under the cursor" would say
    // yes here, because the root always is.
    ui.setPointer(300, 200, false);
    try overlay(&ui);
    try testing.expect(!ui.wantsPointer());
}

test "an element that asked to be clicked counts even when it paints nothing" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const invisible = struct {
        fn nothing(context: ?*anyopaque, event: layout.Callback.Event) void {
            _ = context;
            _ = event;
        }

        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            {
                u.open(.{ .id = "hud", .width = .grow, .height = .grow });
                defer u.close();
                // No fill, no border, no picture - but a callback, so a click
                // here is meant for it.
                u.empty(.{
                    .id = "hotspot",
                    .width = .fixed(100),
                    .height = .fixed(50),
                    .on_press = .{ .call = nothing },
                });
            }
            _ = try u.end();
        }
    };

    try invisible.run(&ui);
    ui.setPointer(50, 25, false);
    try invisible.run(&ui);
    try testing.expect(ui.wantsPointer());
}

test "a whole-window application wants the pointer everywhere" {
    // The other end of the same rule: an application's root has a background,
    // so all of it is interface and every click is the interface's.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const application = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            u.empty(.{ .id = "window", .width = .grow, .height = .grow, .background_color = paint });
            _ = try u.end();
        }
    }.run;

    try application(&ui);
    ui.setPointer(200, 150, false);
    try application(&ui);
    try testing.expect(ui.wantsPointer());
}

test "a scrolling list wants the pointer even where it is empty" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const scrolling = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            {
                u.open(.{ .id = "hud", .width = .grow, .height = .grow });
                defer u.close();
                {
                    // No fill, but it scrolls - so a drag here is a scroll and
                    // not a swing of the camera.
                    u.open(.{ .id = "list", .width = .fixed(100), .height = .fixed(100), .clip = .scrollY });
                    defer u.close();
                    leaf(u, "rows", .{ .width = .fixed(100), .height = .fixed(300) });
                }
            }
            _ = try u.end();
        }
    }.run;

    try scrolling(&ui);
    ui.setPointer(50, 50, false);
    try scrolling(&ui);
    try testing.expect(ui.wantsPointer());
}

test "only a text field takes the keyboard" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const both = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            {
                u.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom });
                defer u.close();
                u.empty(.{ .id = "button", .width = .fixed(100), .height = .fixed(40), .background_color = paint });
                u.textInput(
                    .{ .id = "name", .width = .fixed(200), .height = .fixed(30) },
                    .{ .placeholder = "Your name" },
                );
            }
            _ = try u.end();
        }
    }.run;

    try both(&ui);
    try testing.expect(!ui.wantsKeyboard());

    // A focused button does not take W away from the game.
    ui.setFocus("button");
    try both(&ui);
    try testing.expect(!ui.wantsKeyboard());

    // A focused text field does, which is the whole case this exists for.
    ui.setFocus("name");
    try both(&ui);
    try testing.expect(ui.wantsKeyboard());

    ui.clearFocus();
    try both(&ui);
    try testing.expect(!ui.wantsKeyboard());
}

// -------------------------------------------------------------------------
// What the pointer looks like
// -------------------------------------------------------------------------

/// A panel that wants a crosshair, with a resize handle down its right edge
/// that wants something else, and a text field under both.
fn withHandles(u: *Ui) !void {
    u.begin(.init(400, 300));
    {
        u.open(.{
            .id = "panel",
            .width = .grow,
            .height = .grow,
            .cursor = .crosshair,
            .background_color = paint,
        });
        defer u.close();
        u.empty(.{
            .id = "handle",
            .width = .fixed(8),
            .height = .fixed(100),
            .cursor = .resize_ew,
            .background_color = paint,
        });
        u.textInput(
            .{ .id = "name", .width = .fixed(200), .height = .fixed(30) },
            .{},
        );
    }
    _ = try u.end();
}

test "an element says what the pointer looks like over it, innermost first" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try withHandles(&ui);

    // Over the handle, which is eight wide at the panel's top left.
    ui.setPointer(4, 40, false);
    try withHandles(&ui);
    try testing.expectEqual(layout.CursorShape.resize_ew, ui.cursor());

    // Over the panel and nothing else. The handle's shape must not leak out
    // of it, and the panel's must not overrule the handle's.
    ui.setPointer(300, 250, false);
    try withHandles(&ui);
    try testing.expectEqual(layout.CursorShape.crosshair, ui.cursor());
}

test "a text input asks for the caret without being told to" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try withHandles(&ui);

    // The field sits beside the handle, so anywhere past the first eight
    // pixels of that row is over it.
    ui.setPointer(100, 15, false);
    try withHandles(&ui);
    try testing.expectEqual(layout.CursorShape.ibeam, ui.cursor());
}

test "a declaration still wins over the caret an input asks for" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const arrowed = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            u.textInput(
                .{ .id = "name", .width = .fixed(200), .height = .fixed(30), .cursor = .arrow },
                .{},
            );
            _ = try u.end();
        }
    }.run;

    try arrowed(&ui);
    ui.setPointer(100, 15, false);
    try arrowed(&ui);
    try testing.expectEqual(layout.CursorShape.arrow, ui.cursor());
}

test "nothing under the pointer is an arrow" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const plain = struct {
        fn run(u: *Ui) !void {
            u.begin(.init(400, 300));
            u.empty(.{ .id = "panel", .width = .grow, .height = .grow, .background_color = paint });
            _ = try u.end();
        }
    }.run;

    try plain(&ui);
    ui.setPointer(200, 150, false);
    try plain(&ui);
    try testing.expectEqual(layout.CursorShape.arrow, ui.cursor());
}

test "asking for a shape beats the tree, and only for the frame that asked" {
    // What a drag needs: the pointer has left the handle it grabbed, and the
    // shape has to stay until the button comes up.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try withHandles(&ui);
    ui.setPointer(100, 15, false);

    // Over the text field, which would be a caret on its own.
    try withHandles(&ui);
    try testing.expectEqual(layout.CursorShape.ibeam, ui.cursor());

    ui.begin(.init(400, 300));
    ui.setCursor(.resize_ew);
    _ = try ui.end();
    try testing.expectEqual(layout.CursorShape.resize_ew, ui.cursor());

    // And gone with the frame that asked for it, rather than persisting the
    // way Ply's does - or nothing could ever put it back.
    try withHandles(&ui);
    try testing.expectEqual(layout.CursorShape.ibeam, ui.cursor());
}

// -------------------------------------------------------------------------
// An interface that scales
// -------------------------------------------------------------------------

/// One card with everything a scale touches on it: a fixed width, padding, a
/// gap, a corner radius, a border, a line of text and a fixed leaf.
fn sizedCard(u: *Ui, surface: layout.Surface) ![]const commands.RenderCommand {
    u.begin(surface);
    openRoot(u);
    {
        u.open(.{
            .id = "card",
            .width = .fixed(100),
            .height = .fit,
            .padding = .all(8),
            .gap = 4,
            .corner_radius = .all(6),
            .border = .all(paint, 2),
            .direction = .top_to_bottom,
            .background_color = paint,
        });
        defer u.close();
        u.text("abc", sixteen);
        leaf(u, "dot", .{ .width = .fixed(10), .height = .fixed(10) });
    }
    u.close();
    return u.end();
}

test "a scale multiplies every length" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try sizedCard(&ui, .init(400, 300));

    // A hundred wide; eight of padding twice over, sixteen of text, four of
    // gap and ten of dot make forty-six tall.
    const one = ui.boxOf("card").?;
    try testing.expectEqual(@as(f32, 100), one.width);
    try testing.expectEqual(@as(f32, 46), one.height);
    try testing.expectEqual(@as(f32, 10), ui.boxOf("dot").?.width);

    // Twice the size, not twice as much of it: every one of those numbers
    // doubles, the text included. A game that multiplied its own would have
    // to remember all six.
    _ = try sizedCard(&ui, .{ .size = .init(400, 300), .scale = 2 });
    const two = ui.boxOf("card").?;
    try testing.expectEqual(@as(f32, 200), two.width);
    try testing.expectEqual(@as(f32, 92), two.height);
    try testing.expectEqual(@as(f32, 20), ui.boxOf("dot").?.width);
}

test "the corner radius and the border scale with the box" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try sizedCard(&ui, .init(400, 300));
    try testing.expectEqual(@as(f32, 6), roundingOf(ui.output.items, ui.boxOf("card").?).?);

    // A radius that stayed put would be a hairline on a card at twice the
    // size, and a border that stayed put would be a scratch.
    const scaled = try sizedCard(&ui, .{ .size = .init(400, 300), .scale = 2 });
    try testing.expectEqual(@as(f32, 12), roundingOf(scaled, ui.boxOf("card").?).?);

    const box = ui.boxOf("card").?;
    var widest: f32 = 0;
    for (scaled) |command| {
        if (std.meta.activeTag(command.config) != .border) continue;
        if (!std.meta.eql(command.bounding_box, box)) continue;
        widest = @floatFromInt(command.config.border.width.left);
    }
    try testing.expectEqual(@as(f32, 4), widest);
}

/// How round the rectangle drawn at this box is, if one was.
fn roundingOf(drawn: []const commands.RenderCommand, box: BoundingBox) ?f32 {
    for (drawn) |command| {
        if (std.meta.activeTag(command.config) != .rectangle) continue;
        if (!std.meta.eql(command.bounding_box, box)) continue;
        return command.config.rectangle.corner_radius.top_left;
    }
    return null;
}

test "a share is a share at any scale" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const half = struct {
        fn run(u: *Ui, surface: layout.Surface) !void {
            u.begin(surface);
            openRoot(u);
            leaf(u, "half", .{ .width = .percent(0.5), .height = .fixed(20) });
            u.close();
            _ = try u.end();
        }
    }.run;

    try half(&ui, .init(400, 300));
    try testing.expectEqual(@as(f32, 200), ui.boxOf("half").?.width);

    // The surface is what it is, so half of it is what it was - and doubling
    // the fraction would have made this three quarters of the window. Only
    // the height, which is a length, moves.
    try half(&ui, .{ .size = .init(400, 300), .scale = 2 });
    try testing.expectEqual(@as(f32, 200), ui.boxOf("half").?.width);
    try testing.expectEqual(@as(f32, 40), ui.boxOf("half").?.height);
}

test "a scrollbar is drawn at the interface's scale" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const listed = struct {
        fn run(u: *Ui, surface: layout.Surface) ![]const commands.RenderCommand {
            u.begin(surface);
            openRoot(u);
            {
                u.open(.{
                    .id = "list",
                    .width = .fixed(100),
                    .height = .fixed(100),
                    .clip = layout.Clip.scrollY.bar(.{}),
                    .background_color = paint,
                });
                defer u.close();
                leaf(u, "rows", .{ .width = .fixed(100), .height = .fixed(300) });
            }
            u.close();
            return u.end();
        }
    }.run;

    // Six pixels of bar down the right of a hundred-pixel box, with a third
    // of it filled by the thumb.
    _ = try listed(&ui, .init(400, 300));
    const plain = barIn(&ui, "list", true).?;
    try testing.expectEqual(@as(f32, 94), plain.thumb.x);
    try testing.expectEqual(@as(f32, 6), plain.thumb.width);
    try testing.expectEqual(@as(f32, 200), plain.max_scroll);

    // Twelve down the right of a two-hundred-pixel box: a bar that stayed six
    // wide would be half as easy to grab on the screen it was scaled for.
    _ = try listed(&ui, .{ .size = .init(400, 300), .scale = 2 });
    const twice = barIn(&ui, "list", true).?;
    try testing.expectEqual(@as(f32, 188), twice.thumb.x);
    try testing.expectEqual(@as(f32, 12), twice.thumb.width);
    try testing.expectEqual(@as(f32, 400), twice.max_scroll);
    try testing.expectApproxEqAbs(plain.thumb.height * 2, twice.thumb.height, 0.001);
}

test "a scale of zero is a scale of one" {
    // Both readings of a zero here are mistakes - a field left unfilled, or
    // arithmetic that came out wrong - and neither meant "lay out nothing".
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try sizedCard(&ui, .{ .size = .init(400, 300), .scale = 0 });
    try testing.expectEqual(@as(f32, 100), ui.boxOf("card").?.width);

    _ = try sizedCard(&ui, .{ .size = .init(400, 300), .scale = -2 });
    try testing.expectEqual(@as(f32, 100), ui.boxOf("card").?.width);
}

// -------------------------------------------------------------------------
// Keeping clear of the edges
// -------------------------------------------------------------------------

/// A root that fills whatever it is given, with a leaf in its top left corner
/// and a menu floating against the surface.
fn edged(u: *Ui, surface: layout.Surface) !void {
    u.begin(surface);
    {
        u.open(.{ .id = "root", .width = .grow, .height = .grow, .background_color = paint });
        defer u.close();
        leaf(u, "corner", .{ .width = .fixed(20), .height = .fixed(20) });
        u.empty(.{
            .id = "menu",
            .width = .fixed(60),
            .height = .fixed(40),
            .background_color = paint,
            .floating = .{ .attach = .root, .anchor = .{ .element_x = .right, .parent_x = .right } },
        });
    }
    _ = try u.end();
}

test "a safe area insets the root, and everything comes with it" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try edged(&ui, .{ .size = .init(400, 300), .safe_area = .all(48) });

    const root = ui.boxOf("root").?;
    try testing.expectEqual(@as(f32, 48), root.x);
    try testing.expectEqual(@as(f32, 48), root.y);
    try testing.expectEqual(@as(f32, 304), root.width);
    try testing.expectEqual(@as(f32, 204), root.height);

    try testing.expectEqual(@as(f32, 48), ui.boxOf("corner").?.x);
    try testing.expectEqual(@as(f32, 48), ui.boxOf("corner").?.y);
}

test "the four sides are four numbers" {
    // A notch is not the same size as a home indicator, and neither is the
    // same as the side bezels.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try edged(&ui, .{
        .size = .init(400, 300),
        .safe_area = .{ .left = 10, .right = 20, .top = 30, .bottom = 40 },
    });

    const root = ui.boxOf("root").?;
    try testing.expectEqual(@as(f32, 10), root.x);
    try testing.expectEqual(@as(f32, 30), root.y);
    try testing.expectEqual(@as(f32, 370), root.width);
    try testing.expectEqual(@as(f32, 230), root.height);
}

test "something floating against the surface keeps clear of the edges too" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    try edged(&ui, .init(400, 300));
    try testing.expectEqual(@as(f32, 340), ui.boxOf("menu").?.x);

    // Against the right edge of what can be seen rather than the right edge
    // of the screen - a menu that hung off the surface would be half over the
    // bezel, which is the whole thing this exists to stop.
    try edged(&ui, .{ .size = .init(400, 300), .safe_area = .all(48) });
    try testing.expectEqual(@as(f32, 292), ui.boxOf("menu").?.x);
}

test "the safe area moves things and does not cut them" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    // A backdrop declared out of the flow and told to cover the surface: it
    // is placed inside the safe area, and what runs past the edge of that is
    // still drawn. Clipping to the inset would leave a television showing a
    // band of nothing round a picture it could perfectly well display.
    const behind = struct {
        fn run(u: *Ui, surface: layout.Surface) ![]const commands.RenderCommand {
            u.begin(surface);
            {
                u.open(.{ .id = "root", .width = .grow, .height = .grow });
                defer u.close();
                u.empty(.{
                    .id = "wide",
                    .width = .fixed(400),
                    .height = .fixed(300),
                    .background_color = paint,
                });
            }
            return u.end();
        }
    }.run;

    const drawn = try behind(&ui, .{ .size = .init(400, 300), .safe_area = .all(48) });
    try testing.expect(drawnAt(drawn, .init(48, 48, 400, 300)));
}

test "the pointer is in the surface's own pixels" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    const surface: layout.Surface = .{ .size = .init(400, 300), .safe_area = .all(48) };
    try edged(&ui, surface);

    // Inside the inset strip: the interface is not there, so nothing is
    // hovered. The commands come out in real pixels and so does the pointer -
    // the safe area is not a second coordinate system.
    ui.setPointer(10, 10, false);
    try edged(&ui, surface);
    try testing.expect(!ui.isPointerOver("root"));

    ui.setPointer(60, 60, false);
    try edged(&ui, surface);
    try testing.expect(ui.isPointerOver("corner"));
}

test "a scale and a safe area are arithmetic at the top, and compose" {
    // The engine's own line, checked as written.
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try sizedCard(&ui, .{ .size = .init(3840, 2160), .scale = 2, .safe_area = .all(48) });

    // The card is twice the size, and it starts where the display can show
    // it. The inset is *not* doubled: it is a fact about the screen rather
    // than a number out of the design.
    const box = ui.boxOf("card").?;
    try testing.expectEqual(@as(f32, 200), box.width);
    try testing.expectEqual(@as(f32, 48), box.x);
    try testing.expectEqual(@as(f32, 48), box.y);
}
