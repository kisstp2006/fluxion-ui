// SPDX-License-Identifier: BSD-2-Clause

//! Text with styles written into it: `{color=red|like this}`.
//!
//! Ply's `text_styling.rs`. A tag is a brace, a command, a bar, the text it
//! covers, and a closing brace, and tags nest:
//!
//! ```text
//! Press {color=red|{opacity=0.6|Escape}} to leave.
//! ```
//!
//! What comes out is the text with the tags taken away, and a list of spans
//! saying which stretch of it is drawn how. The layout then works on real
//! text: it measures what the reader will see, and it breaks lines between
//! words rather than in the middle of a tag. Ply keeps the tags in the string
//! all the way to its renderer and takes care not to measure them, which
//! works because its measurer knows about markup - this way round, nothing
//! below this file has to.
//!
//! ## What a tag can say
//!
//! | | |
//! | --- | --- |
//! | `{color=red\|...}` | a name, `#RRGGBB`, or `(r,g,b)` in 0..255 |
//! | `{opacity=0.5\|...}` | multiplied through nesting, not replaced |
//! | `{hide\|...}` | takes up its room and is not drawn |
//! | `{shadow_color=black_offset=-0.3,0.3\|...}` | offset in ems, so it scales with the size |
//!
//! One command per tag, as in Ply - `{color=red|{opacity=0.5|x}}` rather than
//! one tag saying both. Nesting is how they combine, and it is also what
//! decides which wins: the innermost `color` is the one that is drawn, while
//! `opacity` multiplies all the way up.
//!
//! Ply's animated styles - `wave`, `jitter`, `pulse`, `swing`, `type`, `fade`,
//! `scale`, `transform`, `gradient` - are **not here**. Every one of them
//! moves or resizes single glyphs, and a render command in this library
//! describes a run of text rather than a glyph, so there is nowhere to put a
//! per-glyph transform yet. They belong with rotation and effects, which is a
//! milestone of its own. A tag naming one of them is ignored rather than
//! refused, so the text still reads.
//!
//! ## Malformed markup keeps the text
//!
//! Ply's parser returns an error for a stray `}`, an unclosed tag or a space
//! inside a tag, and its renderer - which has its own copy of the state
//! machine - quietly does something else. This one is forgiving on purpose,
//! and each rule earns it:
//!
//!   - **A space inside a tag means it was never a tag.** `{ x }` in ordinary
//!     prose comes out as `{ x }`. Without this rule, running prose through
//!     `markup` would eat everything after the first brace.
//!   - **A `}` with nothing open is a `}`.**
//!   - **A tag left open runs to the end**, rather than losing the text
//!     inside it.
//!
//! Showing the reader the text with the wrong colour beats showing them
//! nothing, and nothing is what an error would leave on the screen.

const std = @import("std");
const testing = std.testing;

const Color = @import("color.zig").Color;
const geometry = @import("geometry.zig");

/// A drop shadow under a stretch of text.
pub const Shadow = struct {
    color: Color = .black,
    /// **In ems**, as Ply writes it: multiplied by the font size when the
    /// text is drawn, so a shadow set once looks the same at every size.
    offset: geometry.Vec2 = .{ .x = -0.3, .y = 0.3 },
};

/// One stretch of the stripped text, and how it is drawn.
///
/// Offsets are bytes from the start of *this* run's text, not from the start
/// of whatever buffer it was parsed into - a run has to be able to move.
pub const Span = struct {
    start: u32,
    end: u32,
    /// Null means whatever the element's own style says. A tag that names no
    /// colour does not force one.
    color: ?Color = null,
    /// Multiplied into the alpha. One is untouched.
    opacity: f32 = 1,
    /// Still takes up its room, and is not drawn. Ply's `hide`.
    hidden: bool = false,
    shadow: ?Shadow = null,

    /// The colour to draw with, given the element's own.
    pub fn colorOver(self: Span, base: Color) Color {
        var out = self.color orelse base;
        out.a = std.math.clamp(out.a * self.opacity, 0, 1);
        return out;
    }

    /// Whether this span says anything at all. A run with no tags in it comes
    /// out as one of these, and the emitter can take the plain path.
    pub fn plain(self: Span) bool {
        return self.color == null and self.opacity == 1 and !self.hidden and self.shadow == null;
    }
};

/// Where one byte of the stripped text came from in the raw string.
///
/// Usually one byte to one byte, but not always: an escaped brace is `\\{` in
/// the raw and `{` in the text, so its mark is two bytes wide. What this is
/// for is editing - a cursor lives in the text the reader sees, and every
/// change has to land in the string the tags are in.
pub const Mark = struct {
    start: u32,
    end: u32,
};

/// What a parse produced.
pub const Parsed = struct {
    /// The text with the tags taken out. A slice of whatever was parsed into.
    text: []const u8,
    /// In order, covering the text end to end with no gaps.
    spans: []const Span,
    /// One per byte of `text`, when a map was asked for.
    marks: []const Mark,
};

/// Ply's palette, at Ply's numbers, which are macroquad's.
///
/// Written as bytes rather than as floats so it can be read against
/// `text_styling.rs` line by line - the fractions there (191.25, 229.5) are
/// what a 0..1 colour looks like after being multiplied by 255, and rounding
/// them back is what these are.
const named = [_]struct { []const u8, u8, u8, u8 }{
    .{ "white", 255, 255, 255 },
    .{ "black", 0, 0, 0 },
    .{ "lightgray", 191, 191, 191 },
    .{ "darkgray", 94, 94, 94 },
    .{ "red", 230, 0, 0 },
    .{ "orange", 255, 140, 0 },
    .{ "yellow", 255, 214, 0 },
    .{ "lime", 0, 204, 0 },
    .{ "green", 0, 128, 0 },
    .{ "cyan", 0, 204, 204 },
    .{ "lightblue", 51, 153, 255 },
    .{ "blue", 0, 51, 204 },
    .{ "purple", 115, 38, 196 },
    .{ "magenta", 204, 0, 204 },
    .{ "brown", 138, 69, 18 },
    .{ "pink", 255, 102, 168 },
};

/// A colour as a tag writes one: a name, `#RRGGBB`, or `(r,g,b)` in 0..255.
///
/// Unreadable values come back white, which is Ply's answer and is the right
/// one here: a typo in a colour should leave the text legible rather than
/// invisible.
pub fn parseColor(text: []const u8) Color {
    if (text.len == 0) return .white;

    for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(text, entry[0])) {
            return .bytes(entry[1], entry[2], entry[3], 255);
        }
    }

    if (text[0] == '#') {
        const value = std.fmt.parseInt(u32, text[1..], 16) catch return .white;
        return .hex(@truncate(value));
    }

    if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')') {
        var channels: [3]f32 = .{ 0, 0, 0 };
        var found: usize = 0;
        var parts = std.mem.splitScalar(u8, text[1 .. text.len - 1], ',');
        while (parts.next()) |part| {
            if (found == channels.len) break;
            channels[found] = number(std.mem.trim(u8, part, " \t"));
            found += 1;
        }
        if (found < 3) return .white;
        return .{
            .r = std.math.clamp(channels[0] / 255, 0, 1),
            .g = std.math.clamp(channels[1] / 255, 0, 1),
            .b = std.math.clamp(channels[2] / 255, 0, 1),
            .a = 1,
        };
    }

    return .white;
}

/// Ply's `parse_float`: whatever it reads, or zero.
fn number(text: []const u8) f32 {
    return std.fmt.parseFloat(f32, text) catch 0;
}

/// The arguments of one tag, in the order they were written.
///
/// `color=red_opacity=0.5` is a command and its arguments, split on `_` and
/// then on `=`. The first part is the command, and a value attached to it -
/// the `red` in `color=red` - is reachable under the empty name, which is how
/// Ply's own map spells it.
const Arguments = struct {
    body: []const u8,

    fn command(self: Arguments) []const u8 {
        const first = self.part(0) orelse return "";
        return if (std.mem.indexOfScalar(u8, first, '=')) |at| first[0..at] else first;
    }

    fn get(self: Arguments, name: []const u8) ?[]const u8 {
        var index: usize = 0;
        while (self.part(index)) |piece| : (index += 1) {
            const at = std.mem.indexOfScalar(u8, piece, '=') orelse continue;
            const key = if (index == 0) "" else piece[0..at];
            if (std.mem.eql(u8, key, name)) return piece[at + 1 ..];
        }
        return null;
    }

    fn part(self: Arguments, wanted: usize) ?[]const u8 {
        var index: usize = 0;
        var pieces = std.mem.splitScalar(u8, self.body, '_');
        while (pieces.next()) |piece| : (index += 1) {
            if (index == wanted) return piece;
        }
        return null;
    }
};

/// What is in force at one point in the text: the style stack, folded.
const Fold = struct {
    color: ?Color = null,
    opacity: f32 = 1,
    hidden: bool = false,
    shadow: ?Shadow = null,

    /// The same, with one tag's command applied on top.
    ///
    /// A colour replaces the one outside it and an opacity multiplies through
    /// it, which is the difference between "this bit is red" and "this bit is
    /// half as solid as whatever it is inside".
    fn with(self: Fold, body: []const u8) Fold {
        const arguments: Arguments = .{ .body = body };
        const command = arguments.command();
        var out = self;

        if (std.mem.eql(u8, command, "color")) {
            if (arguments.get("")) |value| out.color = parseColor(value);
        } else if (std.mem.eql(u8, command, "opacity")) {
            if (arguments.get("")) |value| out.opacity *= number(value);
        } else if (std.mem.eql(u8, command, "hide")) {
            out.hidden = true;
        } else if (std.mem.eql(u8, command, "shadow")) {
            var shadow: Shadow = .{};
            if (arguments.get("color")) |value| shadow.color = parseColor(value);
            if (arguments.get("offset")) |value| {
                var parts = std.mem.splitScalar(u8, value, ',');
                if (parts.next()) |x| shadow.offset.x = number(x);
                if (parts.next()) |y| shadow.offset.y = number(y);
            }
            out.shadow = shadow;
        }
        // Anything else is one of Ply's animated styles, or a typo. Both are
        // ignored rather than refused: the text still reads.

        return out;
    }

    fn span(self: Fold, start: usize, end: usize) Span {
        return .{
            .start = @intCast(start),
            .end = @intCast(end),
            .color = self.color,
            .opacity = self.opacity,
            .hidden = self.hidden,
            .shadow = self.shadow,
        };
    }
};

/// How deep tags may nest. Past it the braces are text, which is what a
/// runaway generator produces and is better than a stack overflow.
pub const max_depth = 16;

/// Take the tags out of `raw`, leaving the text and the spans over it.
///
/// Both are appended to the lists given, and the slices returned point into
/// them - so a caller with one buffer for a whole frame parses into it once
/// per run and keeps the offsets. Span offsets are relative to the start of
/// this run's text rather than to the buffer, so the run can move.
pub fn parse(
    out_text: *std.ArrayList(u8),
    out_spans: *std.ArrayList(Span),
    out_marks: ?*std.ArrayList(Mark),
    gpa: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error!Parsed {
    const text_from = out_text.items.len;
    const spans_from = out_spans.items.len;
    const marks_from = if (out_marks) |marks| marks.items.len else 0;

    // Every byte of text goes through here, so the map cannot fall out of
    // step with the text it is a map of.
    const Sink = struct {
        text: *std.ArrayList(u8),
        marks: ?*std.ArrayList(Mark),
        gpa: std.mem.Allocator,

        fn one(self: @This(), byte: u8, from: usize, to: usize) std.mem.Allocator.Error!void {
            try self.text.append(self.gpa, byte);
            if (self.marks) |marks| {
                try marks.append(self.gpa, .{ .start = @intCast(from), .end = @intCast(to) });
            }
        }

        fn many(self: @This(), bytes: []const u8, from: usize) std.mem.Allocator.Error!void {
            for (bytes, 0..) |byte, offset| try self.one(byte, from + offset, from + offset + 1);
        }
    };
    const sink: Sink = .{ .text = out_text, .marks = out_marks, .gpa = gpa };

    var stack: [max_depth]Fold = undefined;
    var depth: usize = 0;
    var current: Fold = .{};

    // Where the span being built started, in the stripped text.
    var span_start: usize = 0;

    // While a tag header is being read: where its `{` was in `raw`, and how
    // much of the header has been collected. A space, or the end of the
    // input, means it was never a tag and the whole of it is text.
    var header_at: ?usize = null;
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(gpa);

    var escaped = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const byte = raw[i];

        if (escaped) {
            escaped = false;
            // The backslash before it is part of where this byte came from,
            // so deleting the character takes the escape with it.
            if (header_at != null) try header.append(gpa, byte) else try sink.one(byte, i - 1, i + 1);
            continue;
        }

        switch (byte) {
            '\\' => escaped = true,

            '{' => {
                if (header_at != null) {
                    // A brace inside a header is not a nested tag; Ply keeps
                    // it as part of the name.
                    try header.append(gpa, byte);
                } else {
                    header_at = i;
                    header.clearRetainingCapacity();
                }
            },

            '|' => {
                if (header_at == null) {
                    try sink.one(byte, i, i + 1);
                } else if (depth >= max_depth) {
                    // Too deep to remember the way out. Give the header back
                    // as text and carry on.
                    try sink.many(raw[header_at.?..][0 .. i - header_at.? + 1], header_at.?);
                    header_at = null;
                } else {
                    const here = out_text.items.len - text_from;
                    if (here > span_start) {
                        try out_spans.append(gpa, current.span(span_start, here));
                    }
                    stack[depth] = current;
                    depth += 1;
                    current = current.with(header.items);
                    span_start = here;
                    header_at = null;
                }
            },

            '}' => {
                if (header_at != null) {
                    try header.append(gpa, byte);
                } else if (depth == 0) {
                    // Nothing open, so it is a brace the reader meant.
                    try sink.one(byte, i, i + 1);
                } else {
                    const here = out_text.items.len - text_from;
                    if (here > span_start) {
                        try out_spans.append(gpa, current.span(span_start, here));
                    }
                    depth -= 1;
                    current = stack[depth];
                    span_start = here;
                }
            },

            else => {
                // A space in a header means this was never a tag. Everything
                // since the brace is text, including the brace, and the space
                // itself is handled by the loop going round again.
                if (header_at != null and (byte == ' ' or byte == '\t' or byte == '\n')) {
                    try sink.many(raw[header_at.?..i], header_at.?);
                    header_at = null;
                }
                if (header_at != null) {
                    try header.append(gpa, byte);
                } else {
                    try sink.one(byte, i, i + 1);
                }
            },
        }
    }

    // A header the input ended inside was never a tag either.
    if (header_at) |from| try sink.many(raw[from..], from);
    // A trailing backslash is a backslash.
    if (escaped) try sink.one('\\', raw.len - 1, raw.len);

    const total = out_text.items.len - text_from;
    if (total > span_start or out_spans.items.len == spans_from) {
        try out_spans.append(gpa, current.span(span_start, total));
    }

    return .{
        .text = out_text.items[text_from..],
        .spans = out_spans.items[spans_from..],
        .marks = if (out_marks) |marks| marks.items[marks_from..] else &.{},
    };
}

/// Drop the tags that have nothing left inside them.
///
/// Deleting the last character out of `{color=red|a}` leaves `{color=red|}`,
/// which draws as nothing and reads back as nonsense - so an editor that
/// never removed them would slowly fill a string with the ghosts of styles
/// somebody deleted. Ply calls this `cleanup_empty_styles`.
///
/// Innermost first and around again, because taking one out can empty the one
/// it was in: `{a|{b|}}` is two passes and an empty string. Quadratic in the
/// number of nested empty tags, which is a number that is never large.
pub fn compact(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const from = out.items.len;
    try out.appendSlice(gpa, raw);

    while (emptyTag(out.items[from..])) |range| {
        out.replaceRange(undefined, from + range.start, range.end - range.start, "") catch unreachable;
    }
    return out.items[from..];
}

/// The first `{header|}` with nothing between the bar and the brace.
fn emptyTag(raw: []const u8) ?Range {
    var escaped = false;
    var header_at: ?usize = null;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const byte = raw[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (byte) {
            '\\' => escaped = true,
            '{' => header_at = i,
            ' ', '\t', '\n' => header_at = null,
            '|' => if (header_at) |start| {
                if (i + 1 < raw.len and raw[i + 1] == '}') {
                    return .{ .start = start, .end = i + 2 };
                }
                header_at = null;
            },
            else => {},
        }
    }
    return null;
}

/// A half-open byte range, as `compact` hands one back.
pub const Range = struct { start: usize, end: usize };

/// Put the tags back, so a string can be handed to `parse` as literal text.
///
/// The four characters the syntax uses each get a backslash. Ply's
/// `escape_str`, and what a program does with a name it did not write.
pub fn escape(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const from = out.items.len;
    for (raw) |byte| {
        switch (byte) {
            '{', '}', '|', '\\' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, byte);
    }
    return out.items[from..];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Parse into fresh lists, for a test that does not care where they live.
const Fixture = struct {
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,

    fn run(self: *Fixture, gpa: std.mem.Allocator, raw: []const u8) !Parsed {
        return parse(&self.text, &self.spans, null, gpa, raw);
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.spans.deinit(gpa);
    }
};

test "text with no tags in it comes out unchanged, in one span" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "Hello there");
    try testing.expectEqualStrings("Hello there", parsed.text);
    try testing.expectEqual(@as(usize, 1), parsed.spans.len);
    try testing.expect(parsed.spans[0].plain());
}

test "a tag is taken out and leaves a span over what it covered" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "Press {color=red|Escape} to leave");
    try testing.expectEqualStrings("Press Escape to leave", parsed.text);
    try testing.expectEqual(@as(usize, 3), parsed.spans.len);

    // Before, inside, after - and only the middle one is red.
    try testing.expect(parsed.spans[0].color == null);
    try testing.expectEqual(@as(f32, 230.0 / 255.0), parsed.spans[1].color.?.r);
    try testing.expectEqual(@as(usize, 6), parsed.spans[1].start);
    try testing.expectEqual(@as(usize, 12), parsed.spans[1].end);
    try testing.expectEqualStrings("Escape", parsed.text[6..12]);
    try testing.expect(parsed.spans[2].color == null);
}

test "the spans cover the text end to end with no gaps" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(
        testing.allocator,
        "a{color=red|b}c{opacity=0.5|d}{hide|e}f",
    );
    try testing.expectEqualStrings("abcdef", parsed.text);

    var at: u32 = 0;
    for (parsed.spans) |span| {
        try testing.expectEqual(at, span.start);
        at = span.end;
    }
    try testing.expectEqual(@as(u32, @intCast(parsed.text.len)), at);
}

test "nesting replaces a colour and multiplies an opacity" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(
        testing.allocator,
        "{opacity=0.5|dim {opacity=0.5|dimmer {color=red|and red}}}",
    );
    try testing.expectEqualStrings("dim dimmer and red", parsed.text);

    // "dim " at a half, "dimmer " at a quarter, "and red" at a quarter and
    // red as well - the colour is the innermost one, the opacity is all of
    // them multiplied.
    try testing.expectEqual(@as(f32, 0.5), parsed.spans[0].opacity);
    try testing.expectEqual(@as(f32, 0.25), parsed.spans[1].opacity);
    try testing.expectEqual(@as(f32, 0.25), parsed.spans[2].opacity);
    try testing.expect(parsed.spans[2].color != null);
    try testing.expect(parsed.spans[1].color == null);
}

test "a colour is a name, a hex triple or three numbers" {
    try testing.expectEqual(Color.bytes(230, 0, 0, 255), parseColor("red"));
    try testing.expectEqual(Color.bytes(230, 0, 0, 255), parseColor("RED"));
    try testing.expectEqual(Color.hex(0xFF8000), parseColor("#FF8000"));

    const triple = parseColor("(255,128,0)");
    try testing.expectEqual(@as(f32, 1), triple.r);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), triple.g, 0.001);
    try testing.expectEqual(@as(f32, 0), triple.b);

    // A typo leaves the text legible rather than invisible.
    try testing.expectEqual(Color.white, parseColor("nosuchcolour"));
}

test "a shadow takes its offset in ems" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "{shadow_color=blue_offset=1,2|x}");
    const shadow = parsed.spans[0].shadow.?;
    try testing.expectEqual(Color.bytes(0, 51, 204, 255), shadow.color);
    try testing.expectEqual(@as(f32, 1), shadow.offset.x);
    try testing.expectEqual(@as(f32, 2), shadow.offset.y);

    // And Ply's defaults when it is asked for bare.
    var bare: Fixture = .{};
    defer bare.deinit(testing.allocator);
    const plain = try bare.run(testing.allocator, "{shadow|x}");
    try testing.expectEqual(Color.black, plain.spans[0].shadow.?.color);
    try testing.expectEqual(@as(f32, -0.3), plain.spans[0].shadow.?.offset.x);
}

test "escapes put the four characters back as themselves" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "a\\{b\\}c\\|d\\\\e");
    try testing.expectEqualStrings("a{b}c|d\\e", parsed.text);
    try testing.expectEqual(@as(usize, 1), parsed.spans.len);

    // And the other direction, so a name nobody wrote can be handed over.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("a\\{b\\}c", try escape(&out, testing.allocator, "a{b}c"));
}

test "prose with a brace in it is prose" {
    // The rule that makes this safe to run arbitrary text through. Ply's
    // parser calls a space inside a tag an error and stops.
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "use { x } for a block");
    try testing.expectEqualStrings("use { x } for a block", parsed.text);
    try testing.expectEqual(@as(usize, 1), parsed.spans.len);
}

test "a stray closing brace is a closing brace" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "closing } alone");
    try testing.expectEqualStrings("closing } alone", parsed.text);
}

test "a tag left open runs to the end rather than losing its text" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "start {color=red|and the rest");
    try testing.expectEqualStrings("start and the rest", parsed.text);
    try testing.expectEqual(@as(usize, 2), parsed.spans.len);
    try testing.expect(parsed.spans[1].color != null);
    try testing.expectEqual(@as(u32, @intCast(parsed.text.len)), parsed.spans[1].end);
}

test "a tag that never closed its header is text" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "trailing {color=red");
    try testing.expectEqualStrings("trailing {color=red", parsed.text);
}

test "an unknown command is ignored and its text still reads" {
    // Ply's animated styles arrive here until they are ported, and so do
    // typos. Neither should take the text away.
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "{wave_amp=3_freq=2|moving} still");
    try testing.expectEqualStrings("moving still", parsed.text);
    try testing.expect(parsed.spans[0].plain());
}

test "an empty tag body leaves no text and no gap" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    const parsed = try fixture.run(testing.allocator, "a{color=red|}b");
    try testing.expectEqualStrings("ab", parsed.text);

    var at: u32 = 0;
    for (parsed.spans) |span| {
        try testing.expectEqual(at, span.start);
        at = span.end;
    }
    try testing.expectEqual(@as(u32, 2), at);
}

test "nesting deeper than the limit gives the braces back as text" {
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    for (0..max_depth + 4) |_| try raw.appendSlice(testing.allocator, "{color=red|");
    try raw.appendSlice(testing.allocator, "deep");

    const parsed = try fixture.run(testing.allocator, raw.items);
    // The text survives, which is the whole point of the limit being a
    // fallback rather than an error.
    try testing.expect(std.mem.endsWith(u8, parsed.text, "deep"));
}

test "parsing twice into one buffer keeps each run's offsets its own" {
    // How `Ui` uses it: one buffer for the whole frame, one parse per run,
    // and a span that still points at its own text afterwards.
    var fixture: Fixture = .{};
    defer fixture.deinit(testing.allocator);

    _ = try fixture.run(testing.allocator, "first {color=red|one}");
    const second = try fixture.run(testing.allocator, "second {color=blue|two}");

    try testing.expectEqualStrings("second two", second.text);
    try testing.expectEqual(@as(u32, 0), second.spans[0].start);
    try testing.expectEqualStrings("two", second.text[second.spans[1].start..second.spans[1].end]);
}

test "the map says where each visible byte came from" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(testing.allocator);
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(testing.allocator);

    //           0123456789...
    const raw = "a{color=red|bc}d";
    const parsed = try parse(&text, &spans, &marks, testing.allocator, raw);
    try testing.expectEqualStrings("abcd", parsed.text);
    try testing.expectEqual(parsed.text.len, parsed.marks.len);

    try testing.expectEqual(@as(u32, 0), parsed.marks[0].start);
    try testing.expectEqual(@as(u32, 12), parsed.marks[1].start);
    try testing.expectEqual(@as(u32, 13), parsed.marks[2].start);
    try testing.expectEqual(@as(u32, 15), parsed.marks[3].start);

    // And every mark points at the byte it stands for.
    for (parsed.marks, parsed.text) |mark, byte| {
        try testing.expectEqual(byte, raw[mark.end - 1]);
    }
}

test "an escaped brace is one visible byte from two raw ones" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(testing.allocator);
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(testing.allocator);

    const parsed = try parse(&text, &spans, &marks, testing.allocator, "a\\{b");
    try testing.expectEqualStrings("a{b", parsed.text);

    // The mark for the brace is two bytes wide, so deleting the character
    // takes its backslash with it rather than leaving a stray escape.
    try testing.expectEqual(@as(u32, 1), parsed.marks[1].start);
    try testing.expectEqual(@as(u32, 3), parsed.marks[1].end);
}

test "an emptied tag is taken away, innermost first" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try testing.expectEqualStrings("ab", try compact(&out, testing.allocator, "a{color=red|}b"));

    out.clearRetainingCapacity();
    // Taking the inner one out empties the outer, so it goes round again.
    try testing.expectEqualStrings("", try compact(&out, testing.allocator, "{a|{b|}}"));

    out.clearRetainingCapacity();
    // One with something in it stays.
    try testing.expectEqualStrings(
        "{color=red|x}",
        try compact(&out, testing.allocator, "{color=red|x}"),
    );

    out.clearRetainingCapacity();
    // And a brace that was never a tag is not one now either.
    try testing.expectEqualStrings(
        "use { x } here",
        try compact(&out, testing.allocator, "use { x } here"),
    );
}
