// SPDX-License-Identifier: BSD-2-Clause

//! Text: how it is styled, and how the layout finds out how wide it is.
//!
//! A layout engine cannot measure text. How wide `Hello` is depends on a font
//! file, a size, and a rasteriser's opinion about rounding - none of which
//! belongs in a library that only knows about rectangles. So the layout asks,
//! and a `Measurer` answers.
//!
//! That indirection is the same one Ply has - it holds a `measure_text_fn` -
//! and it is worth keeping for the same reasons: a program can measure with
//! [Fluxion Font](https://github.com/kisstp2006/fluxion-font), with a bitmap
//! font, or with `monospace` below, and the layout is identical in all three.
//! The tests in this package use `monospace`, which is why they can check
//! wrapping to the character without a font file anywhere near them.
//!
//! ```zig
//! ui.setMeasurer(.monospace(8, 16));
//!
//! ui.text("Hello, Fluxion!", .{ .font_size = 32, .color = .hex(0xFFFFFF) });
//! ```

const std = @import("std");
const testing = std.testing;

const color = @import("color.zig");
const geometry = @import("geometry.zig");

const AlignX = geometry.AlignX;
const Color = color.Color;
const Dimensions = geometry.Dimensions;

/// What to do when text is wider than the room it has. **Text never runs
/// out of its box**: it breaks onto another line, or a line that cannot
/// break is shortened and ends in an `ellipsis`.
pub const WrapMode = enum {
    /// Break between words, which is what reading requires - and inside a
    /// word too long for a line of its own, a path or an address. The
    /// default.
    words,
    /// Break only where the text itself says to. A line too long for the
    /// room ends in an ellipsis.
    newline,
    /// One line, the text's first, which is what a label, a tab or a list's
    /// row wants: too long for the room, it ends in an ellipsis.
    none,
};

/// What a line cut short ends in.
pub const ellipsis = "\u{2026}";

pub const Outline = struct {
    color: Color = .black,
    width: u16 = 1,

    pub inline fn scaled(self: Outline, by: f32) Outline {
        var out = self;
        out.width = geometry.scaleWhole(self.width, by);
        return out;
    }
};

/// How a run of text is drawn. Ply's `TextConfig`, under Ply's names.
pub const TextStyle = struct {
    color: Color = .white,
    outline: ?Outline = null,
    /// The em size, in pixels.
    font_size: u16 = 16,
    /// Extra pixels between one character and the next.
    letter_spacing: u16 = 0,
    /// Baseline to baseline, in pixels. Zero means "whatever the font says",
    /// which is what `Measurer.lineHeight` answers.
    line_height: u16 = 0,
    wrap: WrapMode = .words,
    /// Where a line sits when the others are wider than it.
    alignment: AlignX = .left,
    /// Which font, as an index into whatever table the measurer was built
    /// with. Zero is the default one. The renderer has to have the same
    /// table in the same order, or a run is measured in one face and drawn
    /// in another.
    font: u16 = 0,

    /// The three lengths multiplied by an interface scale.
    ///
    /// The font size above all: a game that scaled its boxes and forgot its
    /// text ends up with the same words in a box twice the size, which looks
    /// worse than not having scaled at all. A `line_height` of zero stays
    /// zero, and goes on meaning "whatever the font says". See
    /// `layout.Surface.scale`.
    pub inline fn scaled(self: TextStyle, by: f32) TextStyle {
        var out = self;
        out.font_size = geometry.scaleWhole(self.font_size, by);
        out.letter_spacing = geometry.scaleWhole(self.letter_spacing, by);
        out.line_height = geometry.scaleWhole(self.line_height, by);
        if (self.outline) |outline| out.outline = outline.scaled(by);
        return out;
    }
};

/// How wide and tall a run of text is, in pixels.
pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// Whatever can say how big a piece of text is.
///
/// A context pointer and two functions, which is the same shape
/// [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) gives its
/// backends and for the same reason: the thing answering is chosen at run
/// time and the layout must not know what it is.
///
/// **The measurer must be consistent.** The layout measures a run once to
/// decide how much room it wants and again, in pieces, to decide where the
/// lines break - and a measurer that answered differently the second time
/// would produce a paragraph whose lines do not add up to its height.
pub const Measurer = struct {
    context: ?*const anyopaque = null,
    measureFn: *const fn (context: ?*const anyopaque, run: []const u8, style: TextStyle) Size,
    lineHeightFn: *const fn (context: ?*const anyopaque, style: TextStyle) f32,

    pub inline fn measure(self: Measurer, run: []const u8, style: TextStyle) Size {
        return self.measureFn(self.context, run, style);
    }

    /// Baseline to baseline for this style, in pixels. Used when the style's
    /// own `line_height` is zero.
    pub inline fn lineHeight(self: Measurer, style: TextStyle) f32 {
        if (style.line_height > 0) return @floatFromInt(style.line_height);
        return self.lineHeightFn(self.context, style);
    }

    /// A measurer for a font whose characters are all the same width.
    ///
    /// Not only a test fixture, though that is what it is used for here: a
    /// terminal, a code editor with a monospaced face, and a layout being
    /// checked without a font file all want exactly this. `advance` is the
    /// width of one character at a font size of one, so a size of 16 with an
    /// advance of 0.5 gives eight-pixel characters.
    /// `comptime`, and it has to be. The two functions below name `advance`
    /// and `line_spacing` from inside, and Zig has no closures - an inner
    /// function may only reach a value the compiler already knows. Taking
    /// them at run time compiles wherever the call happens to be in a
    /// comptime context and fails everywhere else, which is a worse API than
    /// one that says so in its signature.
    pub fn monospace(comptime advance: f32, comptime line_spacing: f32) Measurer {
        const Mono = struct {
            fn measure(_: ?*const anyopaque, run: []const u8, style: TextStyle) Size {
                // Counted in codepoints, not bytes: an accented letter is one
                // character wide however many bytes it takes.
                var characters: usize = 0;
                var i: usize = 0;
                while (i < run.len) {
                    const length = std.unicode.utf8ByteSequenceLength(run[i]) catch 1;
                    i += @min(length, run.len - i);
                    characters += 1;
                }
                const size: f32 = @floatFromInt(style.font_size);
                const spacing: f32 = @floatFromInt(style.letter_spacing);
                return .{
                    .width = @as(f32, @floatFromInt(characters)) * (advance * size + spacing),
                    .height = line_spacing * size,
                };
            }

            fn height(_: ?*const anyopaque, style: TextStyle) f32 {
                return line_spacing * @as(f32, @floatFromInt(style.font_size));
            }
        };

        return .{ .measureFn = Mono.measure, .lineHeightFn = Mono.height };
    }
};

// -------------------------------------------------------------------------
// Words
// -------------------------------------------------------------------------

/// One piece of a run: a word, or the place a line ends.
pub const Word = struct {
    /// Where it starts in the run.
    start: u32,
    /// How many bytes it is: zero for a newline, and for the spaces a run
    /// starts with, which come before its first word.
    len: u32,
    /// How wide it is on its own, without the space after it.
    width: f32,
    /// How wide the space after it is - zero at the end of a run, and at a
    /// newline.
    space: f32,
    /// A newline: the one break the text asks for itself.
    newline: bool = false,

    pub inline fn isBreak(self: Word) bool {
        return self.newline;
    }
};

/// Split a run into words, measuring each.
///
/// A word is a run of anything that is not a space or a newline. The space
/// after it is measured separately, because a line that ends at a word does
/// not include the space that followed it - and a wrapper that forgot that
/// puts one trailing space of width into every line and slowly loses a
/// character off the right of the paragraph.
///
/// Newlines come through as zero-length words. They are the one break the
/// text asks for itself, and they are honoured under every `WrapMode` except
/// `.none`.
pub const Words = struct {
    run: []const u8,
    style: TextStyle,
    measurer: Measurer,
    at: u32 = 0,

    pub fn init(run: []const u8, style: TextStyle, measurer: Measurer) Words {
        return .{ .run = run, .style = style, .measurer = measurer };
    }

    pub fn next(self: *Words) ?Word {
        if (self.at >= self.run.len) return null;

        // A newline is a break of its own.
        if (self.run[self.at] == '\n') {
            const at = self.at;
            self.at += 1;
            return .{ .start = at, .len = 0, .width = 0, .space = 0, .newline = true };
        }

        // Leading spaces belong to the word that follows, as the space
        // before it - except at the start of a run, where there is nothing
        // before them.
        const start = self.at;
        while (self.at < self.run.len and self.run[self.at] != ' ' and self.run[self.at] != '\n') {
            self.at += 1;
        }
        const end = self.at;

        // And the run of spaces after it.
        const space_start = self.at;
        while (self.at < self.run.len and self.run[self.at] == ' ') self.at += 1;

        return .{
            .start = start,
            .len = end - start,
            .width = if (end > start)
                self.measurer.measure(self.run[start..end], self.style).width
            else
                0,
            .space = if (self.at > space_start)
                self.measurer.measure(self.run[space_start..self.at], self.style).width
            else
                0,
        };
    }
};

/// The narrowest this run can be drawn, in pixels. A text element's
/// `min_dimensions.width`.
///
/// **This is the number that makes the shrink pass mean anything**: every
/// other kind of element has a minimum equal to its content, so nothing could
/// ever give way. Text can, and in every mode, down to about one character -
/// an em - since none of them ever runs out of its box: a paragraph breaks
/// its lines, a word too long for one inside it, and a line that cannot
/// break is cut short with an `ellipsis`. A run narrower than an em is that
/// narrow already.
pub fn narrowest(run: []const u8, style: TextStyle, measurer: Measurer) f32 {
    const em: f32 = @floatFromInt(style.font_size);
    if (style.wrap != .words) return @min(unwrappedWidth(run, style, measurer), em);

    var widest: f32 = 0;
    var words: Words = .init(run, style, measurer);
    while (words.next()) |word| widest = @max(widest, word.width);
    return @min(widest, em);
}

/// What of a run is drawn: all of it, but for a run in one line - `.none` -
/// whose first is all there is.
pub fn shown(run: []const u8, style: TextStyle) []const u8 {
    if (style.wrap != .none) return run;
    return run[0 .. std.mem.indexOfScalar(u8, run, '\n') orelse run.len];
}

/// How many bytes of `piece` fit in `room` pixels, whole characters: the
/// longest start of it no wider. At least one character when `one_at_least`,
/// which is how a word too long for a line still goes somewhere.
pub fn fitting(piece: []const u8, room: f32, style: TextStyle, measurer: Measurer, one_at_least: bool) u32 {
    if (piece.len == 0) return 0;
    if (measurer.measure(piece, style).width <= room + 0.001) return @intCast(piece.len);
    // What fits, and what does not: a start of none fits.
    var fits: usize = 0;
    var too_wide: usize = piece.len;
    while (true) {
        var middle = characterStart(piece, fits + (too_wide - fits) / 2);
        if (middle <= fits) middle = characterStart(piece, fits + 1);
        if (middle >= too_wide) break;
        if (measurer.measure(piece[0..middle], style).width <= room + 0.001) fits = middle else too_wide = middle;
    }
    if (fits == 0 and one_at_least) return @intCast(characterStart(piece, 1));
    return @intCast(fits);
}

/// Where the character at or after byte `at` starts - so a cut never splits
/// one's bytes.
fn characterStart(piece: []const u8, at: usize) usize {
    var i = @min(at, piece.len);
    while (i < piece.len and piece[i] & 0xC0 == 0x80) i += 1;
    return i;
}

/// How wide the run would be if nothing broke it - or, when it has newlines
/// in it, how wide its widest line would be.
pub fn unwrappedWidth(run: []const u8, style: TextStyle, measurer: Measurer) f32 {
    if (std.mem.indexOfScalar(u8, run, '\n') == null) {
        return measurer.measure(run, style).width;
    }

    var widest: f32 = 0;
    var lines = std.mem.splitScalar(u8, run, '\n');
    while (lines.next()) |line| {
        widest = @max(widest, measurer.measure(line, style).width);
    }
    return widest;
}

/// How many lines the run has, counting only the breaks it asks for itself.
pub fn hardLineCount(run: []const u8) u32 {
    return @intCast(std.mem.count(u8, run, "\n") + 1);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Eight pixels a character at a font size of sixteen, sixteen-pixel lines.
const mono: Measurer = .monospace(0.5, 1.0);
const plain: TextStyle = .{ .font_size = 16 };

test "a monospace measurer is the width times the count" {
    try testing.expectEqual(@as(f32, 40), mono.measure("Hello", plain).width);
    try testing.expectEqual(@as(f32, 0), mono.measure("", plain).width);
    try testing.expectEqual(@as(f32, 16), mono.lineHeight(plain));
}

test "a character is a codepoint, not a byte" {
    // Four letters, six bytes. A measurer counting bytes would make accented
    // text mysteriously wider than it looks.
    try testing.expectEqual(@as(f32, 32), mono.measure("évgj", plain).width);
}

test "letter spacing widens every character" {
    const spaced: TextStyle = .{ .font_size = 16, .letter_spacing = 2 };
    try testing.expectEqual(@as(f32, 50), mono.measure("Hello", spaced).width);
}

test "the style can override the line height, and zero means ask the font" {
    try testing.expectEqual(@as(f32, 16), mono.lineHeight(plain));
    try testing.expectEqual(@as(f32, 24), mono.lineHeight(.{ .font_size = 16, .line_height = 24 }));
}

test "an outline scales with the rest of its text" {
    const style: TextStyle = .{ .outline = .{ .color = .black, .width = 2 } };
    try testing.expectEqual(@as(u16, 3), style.scaled(1.5).outline.?.width);
}

test "words come out with their spaces measured separately" {
    var words: Words = .init("ab cd", plain, mono);

    const first = words.next().?;
    try testing.expectEqual(0, first.start);
    try testing.expectEqual(2, first.len);
    try testing.expectEqual(@as(f32, 16), first.width);
    // The space after it is measured on its own, because a line ending here
    // does not include it.
    try testing.expectEqual(@as(f32, 8), first.space);

    const second = words.next().?;
    try testing.expectEqual(3, second.start);
    try testing.expectEqual(@as(f32, 16), second.width);
    try testing.expectEqual(@as(f32, 0), second.space);

    try testing.expectEqual(null, words.next());
}

test "several spaces between words are one gap" {
    var words: Words = .init("ab   cd", plain, mono);
    const first = words.next().?;
    try testing.expectEqual(@as(f32, 24), first.space);
}

test "a newline is a zero-length word, and it is a break" {
    var words: Words = .init("ab\ncd", plain, mono);

    _ = words.next().?;
    const newline = words.next().?;
    try testing.expect(newline.isBreak());
    try testing.expectEqual(0, newline.len);

    const after = words.next().?;
    try testing.expectEqual(2, after.len);
    try testing.expect(!after.isBreak());
}

test "the spaces a run starts with are the gap before its first word, not a break" {
    // Zero long like a newline, but an indentation: taking it for a break
    // dropped the spaces and, where lines break, left a blank line above.
    var words: Words = .init("  cd", plain, mono);
    const indent = words.next().?;
    try testing.expectEqual(0, indent.len);
    try testing.expect(!indent.isBreak());
    try testing.expectEqual(@as(f32, 16), indent.space);
    try testing.expectEqual(2, words.next().?.start);
}

test "text gives way to about a character, whatever its mode" {
    // This is the number that makes shrinking possible at all: every other
    // element's minimum is its content, so nothing gives way. A paragraph
    // gives way to its longest word or an em, the less: below its longest
    // word, it breaks the word.
    try testing.expectEqual(@as(f32, 16), narrowest("a bb Hello cc", plain, mono));
    try testing.expectEqual(@as(f32, 8), narrowest("a b", plain, mono));

    // A line that cannot break is cut short with an ellipsis, so it gives
    // way as far.
    const unbroken: TextStyle = .{ .font_size = 16, .wrap = .none };
    try testing.expectEqual(@as(f32, 16), narrowest("a bb Hello cc", unbroken, mono));
    const hard: TextStyle = .{ .font_size = 16, .wrap = .newline };
    try testing.expectEqual(@as(f32, 16), narrowest("ab cde\nHello", hard, mono));

    // And a run narrower than an em is as narrow as it already is.
    try testing.expectEqual(@as(f32, 8), narrowest("x", unbroken, mono));
}

test "a run in one line shows its first line" {
    const one: TextStyle = .{ .wrap = .none };
    try testing.expectEqualStrings("first", shown("first\nsecond", one));
    try testing.expectEqualStrings("first\nsecond", shown("first\nsecond", plain));
}

test "what fits is whole characters, and one at least when asked" {
    // Eight pixels a character.
    try testing.expectEqual(@as(u32, 3), fitting("abcdef", 24, plain, mono, false));
    try testing.expectEqual(@as(u32, 3), fitting("abcdef", 31, plain, mono, false));
    try testing.expectEqual(@as(u32, 6), fitting("abcdef", 100, plain, mono, false));
    try testing.expectEqual(@as(u32, 0), fitting("abcdef", 4, plain, mono, false));
    try testing.expectEqual(@as(u32, 1), fitting("abcdef", 4, plain, mono, true));
    // Two bytes a letter here, and never half of one.
    try testing.expectEqual(@as(u32, 4), fitting("éééé", 16, plain, mono, false));
    try testing.expectEqual(@as(u32, 2), fitting("éééé", 4, plain, mono, true));
}

test "the unwrapped width of a run with newlines is its widest line" {
    try testing.expectEqual(@as(f32, 40), unwrappedWidth("Hello", plain, mono));
    try testing.expectEqual(@as(f32, 40), unwrappedWidth("Hello\nab", plain, mono));
    try testing.expectEqual(@as(f32, 24), unwrappedWidth("ab\ncde\nx", plain, mono));
}

test "hard lines are counted from the breaks the text asks for" {
    try testing.expectEqual(1, hardLineCount("Hello"));
    try testing.expectEqual(2, hardLineCount("Hello\nworld"));
    try testing.expectEqual(3, hardLineCount("a\nb\n"));
}

test "an empty run measures as nothing and has one line" {
    try testing.expectEqual(@as(f32, 0), unwrappedWidth("", plain, mono));
    try testing.expectEqual(@as(f32, 0), narrowest("", plain, mono));
    try testing.expectEqual(1, hardLineCount(""));
}
