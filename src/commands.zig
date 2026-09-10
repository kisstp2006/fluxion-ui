// SPDX-License-Identifier: BSD-2-Clause

//! What a frame comes out as: a flat list of things to draw, in the order to
//! draw them.
//!
//! **This is the seam, and it is the reason the port is tractable at all.**
//! Ply already has it - `src/render_commands.rs` - and it is what lets a
//! layout engine written against macroquad be lifted onto
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) without the
//! layout knowing. Everything above this line is arithmetic on rectangles;
//! everything below it is a GPU. Neither has to know the other exists.
//!
//! A renderer is a function that takes `[]const RenderCommand` and draws it.
//! That is the entire contract. It can be the RHI backend that ships with
//! this library, one written against
//! [Fluxion WebGL](https://github.com/kisstp2006/fluxion-webgl) directly, a
//! test that counts rectangles, or a printer that writes the list out as
//! text - `Ui` has no opinion, and the layout tests in this package use the
//! last two.
//!
//! The list is **already sorted** and already clipped: back to front, scissor
//! rectangles paired, offscreen elements dropped. A renderer walks it once,
//! forwards, and never sorts anything.
//!
//! ```zig
//! for (ui.end()) |command| switch (command.config) {
//!     .rectangle => |r| drawRect(command.bounding_box, r.color, r.corner_radius),
//!     .border => |b| drawBorder(command.bounding_box, b),
//!     .scissor_start => pushClip(command.bounding_box),
//!     .scissor_end => popClip(),
//!     else => {},
//! };
//! ```

const std = @import("std");
const testing = std.testing;

const geometry = @import("geometry.zig");
const markup = @import("markup.zig");
const layout = @import("layout.zig");

const BoundingBox = geometry.BoundingBox;
const Color = @import("color.zig").Color;
const CornerRadius = geometry.CornerRadius;

/// A filled rectangle, possibly with rounded corners.
///
/// The overwhelming majority of any UI. A renderer that draws only this and
/// honours the scissor commands already shows a recognisable interface.
pub const Rectangle = struct {
    color: Color,
    corner_radius: CornerRadius = .sharp,
};

/// A line around the edge of the bounding box.
///
/// Separate from `Rectangle` rather than a field on it, because the two are
/// drawn at different times: an element's background goes down before its
/// children and its border goes on top of them, so a border with children
/// under it is two commands with the whole subtree in between.
pub const Border = struct {
    color: Color,
    width: layout.BorderWidth,
    corner_radius: CornerRadius = .sharp,
    position: layout.BorderPosition = .inside,
};

/// A run of text on one line, already measured and already wrapped.
///
/// The `text` slice points into the frame's own storage and is valid until
/// the next `Ui.begin`. A renderer that needs to keep it - to cache a glyph
/// run, say - copies it.
///
/// Nothing produces this yet. Text needs a font, a font needs a rasteriser,
/// and the ecosystem has not got one - see the README. The command exists now
/// so that the seam does not change shape when it arrives.
pub const Text = struct {
    text: []const u8,
    color: Color,
    font_size: u16,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
    /// Which font, as an index into whatever table the caller registered.
    /// Zero is "the default one".
    font: u16 = 0,

    /// What moves, tints or hides the glyphs of this run, and how many
    /// characters into the whole run its first glyph is.
    ///
    /// Borrowed for the frame, like `text`. Empty for almost everything, and
    /// a renderer that wants no part of animated text can ignore it and be
    /// right about every interface that does not use one.
    ///
    /// It reaches the renderer rather than being resolved before it, because
    /// where a letter of a wave sits depends on which letter it is - and the
    /// renderer is the only thing here that has ever seen a letter.
    effects: []const markup.Effect = &.{},
    /// How far into the run this piece starts, in characters. A wave has to
    /// travel along a whole sentence even when its middle is a different
    /// colour and so a different command.
    first: u32 = 0,
};

/// A rectangle of a texture.
pub const Image = struct {
    /// Painted under the image, and visible wherever the image is
    /// transparent or does not cover the box.
    background_color: Color = .transparent,
    corner_radius: CornerRadius = .sharp,
    /// Which texture, as an index into whatever table the caller registered.
    texture: u32,
    /// Which part of it to draw, in fractions of the whole from zero to one.
    /// The whole of it by default. See `layout.Image.source`.
    source: BoundingBox = .init(0, 0, 1, 1),
    /// Multiplied into the image. White leaves it alone.
    tint: Color = .white,
};

/// What a command actually asks for.
pub const Config = union(enum) {
    /// Lay this out but draw nothing. A spacer, or an element whose fill is
    /// fully transparent.
    none,
    rectangle: Rectangle,
    border: Border,
    text: Text,
    image: Image,
    /// Clip everything until the matching `scissor_end` to this command's
    /// bounding box. These nest, and a renderer keeps a stack.
    scissor_start,
    scissor_end,
};

/// One thing to draw.
pub const RenderCommand = struct {
    /// Where it goes, in pixels from the top left of the surface.
    bounding_box: BoundingBox,
    config: Config,
    /// Which element this came from, so that a renderer or a debug view can
    /// point back at it. Stable between frames for an element with an `id`,
    /// and for an unnamed one as long as its parent is and nothing unnamed
    /// appears before it there - see `layout.Declaration.id`.
    id: u32 = 0,
    /// Drawn above lower numbers. The list is already in this order; the
    /// field is here so a renderer can batch by it.
    z_index: i16 = 0,

    /// Where this command's box actually ends up, when something turned it.
    ///
    /// The identity for almost everything, and a renderer that wants no part
    /// of rotation can ignore it and be right about every interface that does
    /// not use one. It is on the command rather than in a group-begin and
    /// group-end pair - which is how Ply does it - so that a command says
    /// where it goes without anything having to remember what came before.
    ///
    /// `bounding_box` is still the box **before** the turn: that is what the
    /// layout decided, what the hit test undoes the motion to ask about, and
    /// what a rounded corner is measured against.
    transform: geometry.Transform = .identity,

    /// Whether drawing this would put any pixels on the screen.
    ///
    /// A fully transparent fill and a zero-area box are both common - the
    /// first is how an element says "lay me out but do not paint me", the
    /// second is what clipping produces - and neither is worth a draw call.
    /// `Ui` drops them before they reach the list, so a renderer should never
    /// see one; this is what says so.
    pub fn visible(self: RenderCommand) bool {
        return switch (self.config) {
            .none => false,
            .scissor_start, .scissor_end => true,
            .rectangle => |r| !self.bounding_box.empty() and !r.color.invisible(),
            .border => |b| !self.bounding_box.empty() and !b.color.invisible() and !b.width.isNone(),
            .text => |t| !t.color.invisible() and t.text.len > 0,
            .image => !self.bounding_box.empty(),
        };
    }

    pub fn format(self: RenderCommand, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {f}", .{ @tagName(self.config), self.bounding_box });
        switch (self.config) {
            .rectangle => |r| try w.print(" {f}", .{r.color}),
            .border => |b| try w.print(" {f} {d}px", .{ b.color, b.width.top }),
            .text => |t| try w.print(" {f} \"{s}\"", .{ t.color, t.text }),
            else => {},
        }
    }
};

/// A convenience for tests and for anything that wants to ask what came out
/// of a frame without walking the list by hand.
pub const List = struct {
    items: []const RenderCommand,

    /// How many commands of one kind there are.
    pub fn count(self: List, kind: std.meta.Tag(Config)) usize {
        var total: usize = 0;
        for (self.items) |command| {
            if (std.meta.activeTag(command.config) == kind) total += 1;
        }
        return total;
    }

    /// The first command belonging to `id`, or null.
    pub fn find(self: List, id: u32) ?RenderCommand {
        for (self.items) |command| {
            if (command.id == id) return command;
        }
        return null;
    }

    /// Whether every `scissor_start` has a `scissor_end` after it and none is
    /// left open at the end.
    ///
    /// Worth checking rather than assuming: an unbalanced pair leaves a
    /// renderer clipping everything drawn after this frame, and the symptom
    /// is the *next* frame going blank, which sends people looking in the
    /// wrong place entirely.
    pub fn scissorsBalanced(self: List) bool {
        var depth: i32 = 0;
        for (self.items) |command| {
            switch (command.config) {
                .scissor_start => depth += 1,
                .scissor_end => {
                    depth -= 1;
                    if (depth < 0) return false;
                },
                else => {},
            }
        }
        return depth == 0;
    }
};

test "an invisible command is one nothing would come of" {
    const box: BoundingBox = .init(0, 0, 100, 50);

    const painted: RenderCommand = .{
        .bounding_box = box,
        .config = .{ .rectangle = .{ .color = .hex(0xFF0000) } },
    };
    try testing.expect(painted.visible());

    // A transparent fill is how an element says "lay me out, do not paint me".
    const clear: RenderCommand = .{
        .bounding_box = box,
        .config = .{ .rectangle = .{ .color = .transparent } },
    };
    try testing.expect(!clear.visible());

    // And a box clipped away to nothing.
    const clipped: RenderCommand = .{
        .bounding_box = .init(0, 0, 0, 50),
        .config = .{ .rectangle = .{ .color = .hex(0xFF0000) } },
    };
    try testing.expect(!clipped.visible());
}

test "a border with no width draws nothing" {
    const outlined: RenderCommand = .{
        .bounding_box = .init(0, 0, 100, 50),
        .config = .{ .border = .{ .color = .hex(0xFFFFFF), .width = .none } },
    };
    try testing.expect(!outlined.visible());

    const real: RenderCommand = .{
        .bounding_box = .init(0, 0, 100, 50),
        .config = .{ .border = .{ .color = .hex(0xFFFFFF), .width = .all(2) } },
    };
    try testing.expect(real.visible());
}

test "scissor commands are always worth keeping" {
    // Even at zero area: a scissor of nothing is how a fully scrolled-away
    // container hides its children, and dropping it would show them.
    const clip: RenderCommand = .{ .bounding_box = .zero, .config = .scissor_start };
    try testing.expect(clip.visible());
}

test "a list can be asked what is in it" {
    const items = [_]RenderCommand{
        .{ .bounding_box = .init(0, 0, 100, 100), .config = .scissor_start },
        .{ .bounding_box = .init(0, 0, 50, 50), .config = .{ .rectangle = .{ .color = .white } }, .id = 7 },
        .{ .bounding_box = .init(0, 0, 50, 50), .config = .{ .rectangle = .{ .color = .black } } },
        .{ .bounding_box = .init(0, 0, 100, 100), .config = .scissor_end },
    };
    const list: List = .{ .items = &items };

    try testing.expectEqual(2, list.count(.rectangle));
    try testing.expectEqual(1, list.count(.scissor_start));
    try testing.expectEqual(0, list.count(.text));
    try testing.expect(list.find(7) != null);
    try testing.expectEqual(null, list.find(99));
}

test "unbalanced scissors are caught, because the symptom appears a frame late" {
    const balanced = [_]RenderCommand{
        .{ .bounding_box = .zero, .config = .scissor_start },
        .{ .bounding_box = .zero, .config = .scissor_start },
        .{ .bounding_box = .zero, .config = .scissor_end },
        .{ .bounding_box = .zero, .config = .scissor_end },
    };
    try testing.expect(List.scissorsBalanced(.{ .items = &balanced }));

    const left_open = [_]RenderCommand{
        .{ .bounding_box = .zero, .config = .scissor_start },
    };
    try testing.expect(!List.scissorsBalanced(.{ .items = &left_open }));

    const closed_twice = [_]RenderCommand{
        .{ .bounding_box = .zero, .config = .scissor_start },
        .{ .bounding_box = .zero, .config = .scissor_end },
        .{ .bounding_box = .zero, .config = .scissor_end },
    };
    try testing.expect(!List.scissorsBalanced(.{ .items = &closed_twice }));
}

test "a command prints as what it would draw" {
    var text: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);

    try w.print("{f}", .{RenderCommand{
        .bounding_box = .init(10, 20, 100, 50),
        .config = .{ .rectangle = .{ .color = .hex(0x262220) } },
    }});
    try testing.expectEqualStrings("rectangle (10.0, 20.0) 100.0x50.0 #262220", w.buffered());
}
