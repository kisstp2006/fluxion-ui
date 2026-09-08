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

    /// Where in `elements` its parent is. The root is its own parent, which
    /// is what stops the walk up the tree rather than a sentinel nobody
    /// remembers to check.
    parent: u32 = 0,
    /// Whether the pointer stops here. See `layout.Declaration.capture`.
    capture: bool = false,
    /// Whether a press here leaves the focus where it is. See
    /// `layout.Declaration.preserve_focus`.
    preserve_focus: bool = false,

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
    /// Index into `hits` of the parent's entry, or itself for the root.
    parent: u32,
    capture: bool,
    preserve_focus: bool,
    /// Whether this is a text input, which a press has more to do about.
    field: bool,
    /// Whether dragging in it selects text.
    drag_select: bool,
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
    /// Whether the element was declared in the frame just finished. One that
    /// was not is dropped, so a page that stops showing a list stops
    /// remembering where it was scrolled to.
    live: bool = false,

    /// How many frames since anything moved this container. What
    /// `layout.Scrollbar.hide_after_frames` counts, and it counts frames
    /// rather than seconds because that is what Ply does and because a
    /// library that has never been told the frame rate cannot count seconds.
    idle: u32 = 0,
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
    self.strings.clearRetainingCapacity();

    // Nothing has been declared yet, so nothing is live. Whatever is still
    // not live when the frame ends was not on the page and is forgotten.
    //
    // The idle counter is folded in here rather than at the end of the frame
    // because everything that moves a container - the wheel, a thumb drag,
    // `scrollTo` - happens between one frame and the next. Counting here
    // means a bar that hides itself comes back on the frame the wheel turned
    // rather than the one after.
    var seen = self.scrolls.valueIterator();
    while (seen.next()) |scroll| {
        scroll.live = false;
        if (scroll.active) scroll.idle = 0 else scroll.idle +|= 1;
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
    const key = identify(name, 0);
    const scroll = self.scrolls.getPtr(key) orelse return;
    scroll.position.x += dx;
    scroll.position.y += dy;
    scroll.position = scroll.clamped();
    scroll.active = true;
}

/// Put a scroll container at this position, in pixels from the top left of
/// its content.
pub fn scrollTo(self: *Ui, name: []const u8, x: f32, y: f32) void {
    const key = identify(name, 0);
    const scroll = self.scrolls.getPtr(key) orelse return;
    scroll.position = .{ .x = x, .y = y };
    scroll.position = scroll.clamped();
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
        .clip = self.remembered(declaration),
        .parent = self.innermost(),
        .capture = declaration.capture,
        .preserve_focus = declaration.preserve_focus,
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
    const index: u32 = @intCast(self.elements.items.len);

    // Copied first, and everything below measures the copy - so a caller
    // whose buffer is about to go out of scope is already safe.
    const start: u32 = @intCast(self.strings.items.len);
    try self.strings.appendSlice(self.gpa, run);
    const content = self.strings.items[start..][0..run.len];

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
        .len = @intCast(run.len),
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

fn textInputChecked(self: *Ui, declaration: layout.Declaration, config: text_input.Config) Error!void {
    try self.openChecked(declaration);
    const index = self.innermost();

    const entry = try self.edits.getOrPut(self.gpa, self.elements.items[index].id);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    entry.value_ptr.live = true;
    entry.value_ptr.multiline = config.multiline;
    entry.value_ptr.max_length = config.max_length;

    // What this input will draw, worked out now while the caller's
    // placeholder is still theirs to lend. See `Element.shown_start`.
    const start: u32 = @intCast(self.strings.items.len);
    const shown = try text_input.display(
        &self.strings,
        self.gpa,
        entry.value_ptr.text.items,
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
        if (!clips_main) main_min += child.min_dimensions.onAxis(along_x);
        if (!clips_cross) cross_min = @max(cross_min, child.min_dimensions.onAxis(!along_x));
        try self.children.append(self.gpa, child_index);
    }

    main += gaps;
    if (!clips_main) main_min += gaps;
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
    try self.measureScroll();
    try self.recordHits();
    try self.sweepFields();
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
                .text = self.strings.items[run.start..][0..run.len][line.start..][0..line.len],
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
    self.bars.clearRetainingCapacity();
    try self.walk.append(self.gpa, .{
        .element = 0,
        .position = .zero,
        .next_child = self.startOffset(self.elements.items[0]),
    });
    self.elements.items[0].box = .at(0, 0, self.elements.items[0].dimensions);
    try self.emitBackground(0, self.elements.items[0].box);
    try self.emitText(0, self.elements.items[0].box);
    try self.emitField(0, self.elements.items[0].box);
    if (self.elements.items[0].clip.clips()) {
        try self.emitScissor(.scissor_start, self.elements.items[0].box);
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
            try self.emitBorder(frame.element, element.box);
            try self.emitScrollbars(frame.element, element.box);
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
        });
    }
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
fn emitScissor(self: *Ui, kind: commands.Config, box: BoundingBox) Error!void {
    try self.output.append(self.gpa, .{
        .bounding_box = box,
        .config = kind,
    });
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
    const blank = edit.text.items.len == 0;
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
        text_input.characters(edit.text.items[0..edit.cursor]),
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
        .start = text_input.offsetOfCharacter(shown, text_input.characters(edit.text.items[0..range.start])),
        .end = text_input.offsetOfCharacter(shown, text_input.characters(edit.text.items[0..range.end])),
    } else null;

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
            try self.output.append(self.gpa, .{
                .bounding_box = .init(origin_x, line_y, width, step),
                .id = element.id,
                .z_index = element.z_index,
                .config = .{ .text = .{
                    .text = run,
                    .color = style.color,
                    .font_size = style.font_size,
                    .letter_spacing = style.letter_spacing,
                    .line_height = @intFromFloat(@round(step)),
                    .font = style.font,
                } },
            });
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
/// Ply's `scrollbar_visibility_alpha`, fade curve and all: it holds at full
/// for `hide_after_frames`, then fades over a quarter as many frames again -
/// so a bar told to hide after eighty frames spends twenty fading. A zero
/// hides it always, which is how a caller turns the bar off without giving up
/// the configuration.
fn visibility(config: layout.Scrollbar, idle: u32) f32 {
    const hide = config.hide_after_frames orelse return 1;
    if (hide == 0) return 0;
    if (idle <= hide) return 1;

    const fade = @max(1, @ceil(@as(f32, @floatFromInt(hide)) * 0.25));
    const through = @as(f32, @floatFromInt(idle - hide)) / fade;
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
            .parent = parent,
            .capture = element.capture,
            .preserve_focus = element.preserve_focus,
            .field = element.field != null,
            .drag_select = if (element.field) |config| config.drag_select else false,
        });
    }
}

/// Move time along, in seconds.
///
/// **Call it once a frame, before `begin`.** Two things need a clock and
/// neither can have one of its own: the cursor blinks on it, and it is what
/// tells a second click from a double click. A program that never calls this
/// gets a solid cursor and no double clicks, which is a good failure - not a
/// wrong one.
pub fn tick(self: *Ui, dt: f32) void {
    self.now += dt;
    var typed = self.edits.valueIterator();
    while (typed.next()) |edit| edit.blink += dt;
}

/// Say whether shift is held.
///
/// The one modifier the pointer needs: shift-clicking a text input extends
/// the selection rather than replacing it. Every other modifier reaches this
/// library already decided, as a `text_input.Action`.
pub fn setShift(self: *Ui, held: bool) void {
    self.shift = held;
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
    } else if (self.pointer.isUp()) {
        self.drag = null;
        self.selecting = null;
        // The chain is kept for the frame the button comes up in, so
        // `justReleased` has something to answer about, and dropped after.
        if (self.pointer.state == .idle) self.held.clearRetainingCapacity();
    }

    // Not on the frame the button went down: the pointer has not moved yet,
    // and Ply waits the same frame for the same reason.
    if (self.drag) |grabbed| self.dragThumb(grabbed);

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

    var topmost: ?u32 = null;
    var i = self.hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = self.hits.items[i];
        if (hit.box.contains(point) and hit.visible.contains(point)) {
            topmost = @intCast(i);
            break;
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
        if (self.hits.items[at].capture) break;
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
        .backspace => edit.backspace(),
        .delete => edit.deleteForward(),
        .backspace_word => edit.backspaceWord(),
        .delete_word => edit.deleteWordForward(),
        .select_all => edit.selectAll(),
        .copy => taken = try self.remember_clipboard(edit.selected()),
        .cut => {
            taken = try self.remember_clipboard(edit.selected());
            _ = edit.deleteSelection();
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
/// The mirror of the sweep `measureScroll` does, and it counts the idle
/// frames a hiding scrollbar needs while it is there.
fn sweepFields(self: *Ui) Error!void {
    var stale: [64]u32 = undefined;
    var count: usize = 0;

    var seen = self.edits.iterator();
    while (seen.next()) |entry| {
        if (entry.value_ptr.active) entry.value_ptr.idle = 0 else entry.value_ptr.idle +|= 1;
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

    const config: layout.Scrollbar = .{ .hide_after_frames = 2 };

    // Shown on the very first frame, before anything is stored about it.
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) != null);

    // Two idle frames are still within the hold.
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) != null);

    // A quarter of two, rounded up, is one frame of fade - and then it is
    // gone, and cannot be grabbed either.
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) == null);
    ui.setPointer(97, 20, true);
    try testing.expect(!ui.draggingScrollbar());
    ui.setPointer(97, 20, false);

    // Scrolling brings it back on the next frame rather than the one after,
    // which is the whole point of counting the idle frames at the top of the
    // frame instead of the bottom.
    ui.scrollTo("scroll", 0, 40);
    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(config));
    try testing.expect(barIn(&ui, "scroll", true) != null);
}

test "hide_after_frames of zero is a bar that is never drawn" {
    var ui = withText(testing.allocator);
    defer ui.deinit();

    _ = try scrollFixture(&ui, layout.Clip.scrollY.bar(.{ .hide_after_frames = 0 }));
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
    // Held for the whole hold, then a quarter as many frames of fade.
    const config: layout.Scrollbar = .{ .hide_after_frames = 80 };
    try testing.expectEqual(@as(f32, 1), visibility(config, 0));
    try testing.expectEqual(@as(f32, 1), visibility(config, 80));
    try testing.expectEqual(@as(f32, 0.75), visibility(config, 85));
    try testing.expectEqual(@as(f32, 0.5), visibility(config, 90));
    try testing.expectEqual(@as(f32, 0), visibility(config, 100));
    try testing.expectEqual(@as(f32, 0), visibility(config, 4000));

    // No hold at all means always shown, which is the default.
    try testing.expectEqual(@as(f32, 1), visibility(.{}, 4000));
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

    const cursor: Color = .hex(0xFF0000);
    ui.setTextValue("name", "abc");

    // Not focused: no cursor at all, however solid the blink says it is.
    const unfocused = try oneField(&ui, .{ .cursor_color = cursor });
    try testing.expect(rectangleIn(unfocused, cursor) == null);

    // Setting the value from the program leaves the cursor where it was,
    // only clamping it - which is Ply's rule and is why this types instead.
    try testing.expectEqual(@as(usize, 0), ui.editOf("name").?.cursor);

    ui.setFocus("name");
    ui.typeText("abc");
    const with_keyboard = try oneField(&ui, .{ .cursor_color = cursor });

    // Three characters at eight pixels, and two pixels wide.
    const drawn_at = rectangleIn(with_keyboard, cursor).?;
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
